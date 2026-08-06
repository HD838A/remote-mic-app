import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";
import {
  buttonEventsCapability,
  encodeAudioFrame,
  parseWireMessage,
  protocolVersion,
  type WireMessage,
} from "@remote-mic/mobile-web-protocol";
import { createRelayServer, type RelayServer } from "./server.js";

const openServers: RelayServer[] = [];
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(openServers.splice(0).map((relay) => relay.close()));
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("relay session", () => {
  it("does not forward commands before the Mac approves the session", async () => {
    const session = await createPendingSession();
    openServers.push(session.relay);

    session.web.send(JSON.stringify({ type: "command", protocolVersion, command: "home" }));
    expect(await nextJSON(session.web)).toMatchObject({ type: "error", code: "invalid_state", recoverable: true });

    session.mac.send(JSON.stringify({ type: "sessionApprove", protocolVersion }));
    expect((await nextJSON(session.mac)).type).toBe("sessionReady");
    expect((await nextJSON(session.web)).type).toBe("sessionReady");

    session.web.close();
    session.mac.close();
  });

  it("requires Mac approval before forwarding commands and audio", async () => {
    const { relay, baseURL } = await startRelay();
    openServers.push(relay);
    const mac = await connect(`${baseURL}/ws`);
    mac.send(JSON.stringify({
      type: "sessionCreate",
      protocolVersion,
      macName: "Test Mac",
      appVersion: "1.0",
      buttonTitles: { home: "打开 Codex" },
      capabilities: [buttonEventsCapability],
    }));
    const created = await nextJSON(mac);
    expect(created.type).toBe("sessionCreated");
    if (created.type !== "sessionCreated") throw new Error("missing session");
    const joinURL = new URL(created.joinURL);
    const token = new URLSearchParams(joinURL.hash.slice(1)).get("token");
    expect(token).toBeTruthy();

    const web = await connect(`${baseURL}/ws`, "http://127.0.0.1");
    web.send(JSON.stringify({
      type: "sessionJoin",
      protocolVersion,
      sessionId: created.sessionId,
      token,
      deviceName: "Test iPhone",
    }));
    expect((await nextJSON(web)).type).toBe("sessionPendingApproval");
    expect((await nextJSON(mac)).type).toBe("sessionPendingApproval");

    mac.send(JSON.stringify({ type: "sessionApprove", protocolVersion }));
    expect((await nextJSON(mac)).type).toBe("sessionReady");
    const ready = await nextJSON(web);
    expect(ready).toMatchObject({
      type: "sessionReady",
      macName: "Test Mac",
      capabilities: [buttonEventsCapability],
    });

    web.send(JSON.stringify({ type: "command", protocolVersion, command: "home" }));
    expect(await nextJSON(mac)).toMatchObject({ type: "command", command: "home" });

    web.send(JSON.stringify({
      type: "buttonEvent",
      protocolVersion,
      command: "power",
      buttonPhase: "press",
    }));
    expect(await nextJSON(mac)).toMatchObject({
      type: "buttonEvent",
      command: "power",
      buttonPhase: "press",
    });

    const binary = Buffer.from(encodeAudioFrame(3, new Int16Array([1, 2, 3])));
    web.send(binary);
    const receivedAudio = await nextBinary(mac);
    expect(receivedAudio.equals(binary)).toBe(true);

    web.send(JSON.stringify({ type: "voiceStart", protocolVersion }));
    expect((await nextJSON(mac)).type).toBe("voiceStart");
    mac.send(JSON.stringify({ type: "voiceReady", protocolVersion }));
    expect((await nextJSON(web)).type).toBe("voiceReady");

    web.close();
    mac.close();
  });

  it("rejects an invalid one-time token", async () => {
    const { relay, baseURL } = await startRelay();
    openServers.push(relay);
    const mac = await connect(`${baseURL}/ws`);
    mac.send(JSON.stringify({
      type: "sessionCreate",
      protocolVersion,
      macName: "Test Mac",
      buttonTitles: {},
    }));
    const created = await nextJSON(mac);
    if (created.type !== "sessionCreated") throw new Error("missing session");
    const web = await connect(`${baseURL}/ws`, "http://127.0.0.1");
    web.send(JSON.stringify({
      type: "sessionJoin",
      protocolVersion,
      sessionId: created.sessionId,
      token: "invalid",
      deviceName: "Test Phone",
    }));
    expect(await nextJSON(web)).toMatchObject({ type: "error", code: "join_failed" });
    web.close();
    mac.close();
  });

  it("ends both sides when either peer closes the session", async () => {
    const session = await createPendingSession();
    openServers.push(session.relay);

    session.mac.send(JSON.stringify({ type: "sessionClose", protocolVersion, reason: "test complete" }));
    expect(await nextJSON(session.web)).toMatchObject({ type: "sessionClose", reason: "test complete" });

    session.web.close();
    session.mac.close();
  });

  it("closes a web peer that exceeds the command rate limit", async () => {
    const session = await createPendingSession();
    openServers.push(session.relay);
    session.mac.send(JSON.stringify({ type: "sessionApprove", protocolVersion }));
    expect((await nextJSON(session.mac)).type).toBe("sessionReady");
    expect((await nextJSON(session.web)).type).toBe("sessionReady");

    const errorMessage = collectJSON(session.web, 1);
    for (let index = 0; index < 31; index += 1) {
      session.web.send(JSON.stringify({ type: "command", protocolVersion, command: "home" }));
    }
    const messages = await errorMessage;
    expect(messages).toContainEqual(expect.objectContaining({ type: "error", code: "rate_limited" }));

    session.web.close();
    session.mac.close();
  });

  it("lets an approved web peer resume its remembered session without scanning or approving again", async () => {
    const session = await createPendingSession();
    openServers.push(session.relay);
    session.mac.send(JSON.stringify({ type: "sessionApprove", protocolVersion }));
    expect((await nextJSON(session.mac)).type).toBe("sessionReady");
    expect((await nextJSON(session.web)).type).toBe("sessionReady");

    const stopped = nextJSON(session.mac);
    const closed = waitForClose(session.web);
    session.web.terminate();
    await closed;
    expect((await stopped).type).toBe("voiceStop");

    const resumed = await connect(`${session.baseURL}/ws`, "http://127.0.0.1");
    resumed.send(JSON.stringify({
      type: "sessionJoin",
      protocolVersion,
      sessionId: session.sessionId,
      token: session.token,
      deviceName: "Test Phone",
    }));
    expect((await nextJSON(resumed)).type).toBe("sessionReady");
    expect((await nextJSON(session.mac)).type).toBe("sessionReady");

    resumed.send(JSON.stringify({ type: "command", protocolVersion, command: "home" }));
    expect(await nextJSON(session.mac)).toMatchObject({ type: "command", command: "home" });
    resumed.close();
    session.mac.close();
  });
});

async function createPendingSession(): Promise<{
  relay: RelayServer;
  baseURL: string;
  mac: WebSocket;
  web: WebSocket;
  sessionId: string;
  token: string;
}> {
  const { relay, baseURL } = await startRelay();
  const mac = await connect(`${baseURL}/ws`);
  mac.send(JSON.stringify({
    type: "sessionCreate",
    protocolVersion,
    macName: "Test Mac",
    buttonTitles: {},
  }));
  const created = await nextJSON(mac);
  if (created.type !== "sessionCreated") throw new Error("missing session");
  const joinURL = new URL(created.joinURL);
  const token = new URLSearchParams(joinURL.hash.slice(1)).get("token");
  if (!token) throw new Error("missing token");

  const web = await connect(`${baseURL}/ws`, "http://127.0.0.1");
  web.send(JSON.stringify({
    type: "sessionJoin",
    protocolVersion,
    sessionId: created.sessionId,
    token,
    deviceName: "Test Phone",
  }));
  expect((await nextJSON(web)).type).toBe("sessionPendingApproval");
  expect((await nextJSON(mac)).type).toBe("sessionPendingApproval");
  return { relay, baseURL, mac, web, sessionId: created.sessionId, token };
}

async function startRelay(): Promise<{ relay: RelayServer; baseURL: string }> {
  const staticDirectory = await mkdtemp(join(tmpdir(), "remote-mic-web-"));
  temporaryDirectories.push(staticDirectory);
  await writeFile(join(staticDirectory, "index.html"), "<!doctype html><title>test</title>");
  const relay = createRelayServer({
    publicOrigin: "http://127.0.0.1",
    staticDirectory,
    pendingSessionTTLMS: 5_000,
    maximumSessionTTLMS: 10_000,
  });
  await new Promise<void>((resolveListen) => relay.server.listen(0, "127.0.0.1", resolveListen));
  const address = relay.server.address();
  if (!address || typeof address === "string") throw new Error("missing address");
  return { relay, baseURL: `http://127.0.0.1:${address.port}` };
}

async function connect(url: string, origin?: string): Promise<WebSocket> {
  const socket = new WebSocket(url, origin ? { origin } : undefined);
  await new Promise<void>((resolveOpen, rejectOpen) => {
    socket.once("open", resolveOpen);
    socket.once("error", rejectOpen);
  });
  return socket;
}

function nextJSON(socket: WebSocket): Promise<WireMessage> {
  return new Promise((resolveMessage, rejectMessage) => {
    socket.once("message", (data, isBinary) => {
      if (isBinary) return rejectMessage(new Error("expected JSON"));
      const message = parseWireMessage(data.toString());
      if (!message) return rejectMessage(new Error("invalid JSON message"));
      resolveMessage(message);
    });
  });
}

function nextBinary(socket: WebSocket): Promise<Buffer> {
  return new Promise((resolveMessage, rejectMessage) => {
    socket.once("message", (data: RawData, isBinary) => {
      if (!isBinary) return rejectMessage(new Error("expected binary"));
      resolveMessage(Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer));
    });
  });
}

function collectJSON(socket: WebSocket, count: number): Promise<WireMessage[]> {
  return new Promise((resolveMessages, rejectMessages) => {
    const messages: WireMessage[] = [];
    const handleMessage = (data: RawData, isBinary: boolean) => {
      if (isBinary) return;
      const message = parseWireMessage(data.toString());
      if (!message) {
        socket.off("message", handleMessage);
        rejectMessages(new Error("invalid JSON message"));
        return;
      }
      messages.push(message);
      if (messages.length >= count) {
        socket.off("message", handleMessage);
        resolveMessages(messages);
      }
    };
    socket.on("message", handleMessage);
  });
}

function waitForClose(socket: WebSocket): Promise<void> {
  return new Promise((resolveClose) => socket.once("close", () => resolveClose()));
}
