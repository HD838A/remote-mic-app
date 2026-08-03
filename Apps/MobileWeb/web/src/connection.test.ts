// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import { RemoteConnection } from "./connection";

afterEach(() => {
  vi.unstubAllGlobals();
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
});
