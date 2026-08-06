// @vitest-environment jsdom

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  buttonEventsCapability,
  protocolVersion,
  remoteCommands,
} from "@remote-mic/mobile-web-protocol";
import { RemoteConnection } from "./connection";

beforeEach(() => {
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: memoryStorage(),
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  window.localStorage?.clear();
  window.sessionStorage.clear();
});

describe("RemoteConnection manual start", () => {
  it("does not create a WebSocket until the user starts the connection", () => {
    window.history.replaceState(null, "", "/?session=test-session#token=test-token");
    let socketCount = 0;
    class FakeWebSocket {
      static readonly OPEN = 1;
      static readonly CONNECTING = 0;
      readyState = FakeWebSocket.CONNECTING;
      binaryType = "blob";

      constructor(_url: string) {
        socketCount += 1;
      }

      addEventListener(): void {}
      close(): void {}
      send(): void {}
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);

    const connection = new RemoteConnection();
    let phase = "";
    connection.subscribe((state) => { phase = state.phase; });
    connection.prepare();

    expect(phase).toBe("readyToConnect");
    expect(socketCount).toBe(0);

    connection.connect();
    expect(socketCount).toBe(1);
  });

  it("remembers an approved session without reconnecting automatically", () => {
    window.history.replaceState(null, "", "/?session=remembered-session#token=remembered-token");
    let socketCount = 0;
    class FakeWebSocket {
      static readonly OPEN = 1;
      static readonly CONNECTING = 0;
      static instance: FakeWebSocket | undefined;
      readyState = FakeWebSocket.CONNECTING;
      binaryType = "blob";
      private listeners = new Map<string, Array<(event: { data?: string }) => void>>();
      constructor(_url: string) {
        socketCount += 1;
        FakeWebSocket.instance = this;
      }
      addEventListener(type: string, listener: (event: { data?: string }) => void): void {
        this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
      }
      emit(type: string, event: { data?: string } = {}): void {
        for (const listener of this.listeners.get(type) ?? []) listener(event);
      }
      close(): void {}
      send(): void {}
    }
    vi.stubGlobal("WebSocket", FakeWebSocket);

    const initial = new RemoteConnection();
    initial.prepare();
    initial.connect();
    FakeWebSocket.instance?.emit("message", {
      data: JSON.stringify({
        type: "sessionReady",
        protocolVersion,
        macName: "Test Mac",
        buttonTitles: {},
      }),
    });
    window.history.replaceState(null, "", "/");

    const resumed = new RemoteConnection();
    let stateText = "";
    resumed.subscribe((state) => { stateText = state.guidanceText; });
    resumed.prepare();

    expect(stateText).toContain("已记住上次连接");
    expect(socketCount).toBe(1);
  });

  it("discards remembered sessions after two hours", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-04T00:00:00Z"));
    window.localStorage.setItem("remote-mic-remembered-session:v1", JSON.stringify({
      version: 1,
      sessionId: "expired-session",
      token: "expired-token",
      savedAt: Date.now() - 2 * 60 * 60 * 1000,
    }));
    window.history.replaceState(null, "", "/");

    const connection = new RemoteConnection();
    let phase = "";
    connection.subscribe((state) => { phase = state.phase; });
    connection.prepare();

    expect(phase).toBe("missingSession");
    expect(window.localStorage.getItem("remote-mic-remembered-session:v1")).toBeNull();
  });

  it("sends press and release events for every button when the Mac supports them", () => {
    const { connection, socket } = connectReady([buttonEventsCapability]);

    for (const command of remoteCommands) {
      connection.sendButtonEvent(command, "press");
      connection.sendButtonEvent(command, "release");
    }

    const buttonEvents = socket.sent.map((value) => JSON.parse(value) as { type: string })
      .filter((message) => message.type === "buttonEvent");
    expect(buttonEvents).toHaveLength(remoteCommands.length * 2);
    expect(buttonEvents).toContainEqual(expect.objectContaining({
      type: "buttonEvent",
      command: "power",
      buttonPhase: "press",
    }));
    expect(buttonEvents).toContainEqual(expect.objectContaining({
      type: "buttonEvent",
      command: "ok",
      buttonPhase: "release",
    }));
  });

  it("falls back to one command on release for an older Mac", () => {
    const { connection, socket } = connectReady();

    connection.sendButtonEvent("power", "press");
    connection.sendButtonEvent("power", "release");

    const remoteMessages = socket.sent.map((value) => JSON.parse(value) as { type: string; command?: string })
      .filter((message) => message.type === "command" || message.type === "buttonEvent");
    expect(remoteMessages).toEqual([{ type: "command", protocolVersion, command: "power" }]);
  });
});

function connectReady(capabilities?: string[]): { connection: RemoteConnection; socket: TestWebSocket } {
  window.history.replaceState(null, "", "/?session=test-session#token=test-token");
  TestWebSocket.instances = [];
  vi.stubGlobal("WebSocket", TestWebSocket);
  const connection = new RemoteConnection();
  connection.prepare();
  connection.connect();
  const socket = TestWebSocket.instances[0];
  if (!socket) throw new Error("missing test socket");
  socket.emit("open");
  socket.emit("message", {
    data: JSON.stringify({
      type: "sessionReady",
      protocolVersion,
      macName: "Test Mac",
      buttonTitles: {},
      ...(capabilities ? { capabilities } : {}),
    }),
  });
  return { connection, socket };
}

class TestWebSocket {
  static readonly OPEN = 1;
  static readonly CONNECTING = 0;
  static instances: TestWebSocket[] = [];
  readyState = TestWebSocket.OPEN;
  binaryType = "blob";
  sent: string[] = [];
  private listeners = new Map<string, Array<(event: { data?: string }) => void>>();

  constructor(_url: string) {
    TestWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: { data?: string }) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  emit(type: string, event: { data?: string } = {}): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }

  close(): void {}

  send(value: string): void {
    this.sent.push(value);
  }
}

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    get length() { return values.size; },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key); },
    setItem: (key, value) => { values.set(key, String(value)); },
  };
}
