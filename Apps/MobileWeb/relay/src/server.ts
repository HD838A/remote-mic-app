import { randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { extname, resolve, sep } from "node:path";
import {
  isAudioFrame,
  parseWireMessage,
  protocolVersion,
  type ButtonTitles,
  type SessionCreateMessage,
  type SessionJoinMessage,
  type WireMessage,
} from "@remote-mic/mobile-web-protocol";
import { WebSocket, WebSocketServer } from "ws";

type Role = "unknown" | "mac" | "web";

interface ConnectionContext {
  socket: WebSocket;
  role: Role;
  sessionId?: string;
  alive: boolean;
  jsonWindowStartedAt: number;
  jsonCount: number;
  commandWindowStartedAt: number;
  commandCount: number;
  audioWindowStartedAt: number;
  audioCount: number;
}

interface Session {
  id: string;
  token: Buffer;
  pairingCode: string;
  createdAt: number;
  expiresAt: number;
  mac: ConnectionContext;
  web?: ConnectionContext;
  approved: boolean;
  macName: string;
  appVersion?: string;
  deviceName?: string;
  buttonTitles: ButtonTitles;
}

export interface RelayOptions {
  publicOrigin: string;
  staticDirectory: string;
  pendingSessionTTLMS?: number;
  maximumSessionTTLMS?: number;
  maximumSessions?: number;
}

export interface RelayServer {
  server: Server;
  close: () => Promise<void>;
}

const jsonLimitPerSecond = 80;
const commandLimitPerSecond = 30;
const audioLimitPerSecond = 100;
const maximumJSONBytes = 16 * 1024;

export function createRelayServer(options: RelayOptions): RelayServer {
  const publicOrigin = normalizeOrigin(options.publicOrigin);
  const staticDirectory = resolve(options.staticDirectory);
  const pendingSessionTTLMS = options.pendingSessionTTLMS ?? 5 * 60 * 1000;
  const maximumSessionTTLMS = options.maximumSessionTTLMS ?? 2 * 60 * 60 * 1000;
  const maximumSessions = options.maximumSessions ?? 100;
  const sessions = new Map<string, Session>();
  const contexts = new Set<ConnectionContext>();

  const server = createServer((request, response) => {
    serveHTTP(request, response, staticDirectory);
  });
  const webSocketServer = new WebSocketServer({ noServer: true, maxPayload: maximumJSONBytes });

  server.on("upgrade", (request, socket, head) => {
    const requestURL = new URL(request.url ?? "/", publicOrigin);
    if (requestURL.pathname !== "/ws") {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    const origin = request.headers.origin;
    if (origin !== undefined && normalizeOrigin(origin) !== publicOrigin) {
      socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      webSocketServer.emit("connection", webSocket, request);
    });
  });

  webSocketServer.on("connection", (socket) => {
    if (contexts.size >= maximumSessions * 3) {
      socket.close(1013, "server capacity reached");
      return;
    }
    const context: ConnectionContext = {
      socket,
      role: "unknown",
      alive: true,
      jsonWindowStartedAt: Date.now(),
      jsonCount: 0,
      commandWindowStartedAt: Date.now(),
      commandCount: 0,
      audioWindowStartedAt: Date.now(),
      audioCount: 0,
    };
    contexts.add(context);

    socket.on("pong", () => {
      context.alive = true;
    });
    socket.on("message", (data, isBinary) => {
      if (isBinary) {
        handleAudio(context, data, sessions);
      } else {
        handleJSON(
          context,
          data.toString(),
          sessions,
          publicOrigin,
          pendingSessionTTLMS,
          maximumSessionTTLMS,
          maximumSessions,
        );
      }
    });
    socket.on("close", () => {
      contexts.delete(context);
      closeContextSession(context, sessions, "连接已断开");
    });
    socket.on("error", () => {
      socket.close();
    });
  });

  const heartbeatTimer = setInterval(() => {
    const now = Date.now();
    for (const session of sessions.values()) {
      if (now >= session.expiresAt) {
        destroySession(session, sessions, "会话已过期");
      }
    }
    for (const context of contexts) {
      if (!context.alive) {
        context.socket.terminate();
        continue;
      }
      context.alive = false;
      context.socket.ping();
    }
  }, 20_000);
  heartbeatTimer.unref();

  return {
    server,
    close: async () => {
      clearInterval(heartbeatTimer);
      for (const session of sessions.values()) {
        destroySession(session, sessions, "服务正在停止");
      }
      for (const context of contexts) {
        context.socket.terminate();
      }
      await new Promise<void>((resolveClose, rejectClose) => {
        webSocketServer.close(() => {
          server.close((error) => error ? rejectClose(error) : resolveClose());
        });
      });
    },
  };
}

function handleJSON(
  context: ConnectionContext,
  raw: string,
  sessions: Map<string, Session>,
  publicOrigin: string,
  pendingSessionTTLMS: number,
  maximumSessionTTLMS: number,
  maximumSessions: number,
): void {
  if (Buffer.byteLength(raw, "utf8") > maximumJSONBytes || !allowRate(context, "json", jsonLimitPerSecond)) {
    rejectConnection(context, "rate_limited", "消息过于频繁");
    return;
  }
  const message = parseWireMessage(raw);
  if (!message) {
    rejectConnection(context, "invalid_message", "消息格式无效");
    return;
  }

  if (context.role === "unknown") {
    if (message.type === "sessionCreate") {
      createSession(context, message, sessions, publicOrigin, pendingSessionTTLMS, maximumSessions);
      return;
    }
    if (message.type === "sessionJoin") {
      joinSession(context, message, sessions, maximumSessionTTLMS);
      return;
    }
    rejectConnection(context, "handshake_required", "必须先创建或加入会话");
    return;
  }

  const session = context.sessionId ? sessions.get(context.sessionId) : undefined;
  if (!session) {
    rejectConnection(context, "session_missing", "会话不存在或已结束");
    return;
  }

  switch (message.type) {
    case "sessionApprove":
      if (context.role !== "mac" || !session.web) return rejectInvalidState(context);
      session.approved = true;
      session.expiresAt = Date.now() + maximumSessionTTLMS;
      send(session.mac, {
        type: "sessionReady",
        protocolVersion,
        ...(session.deviceName ? { deviceName: session.deviceName } : {}),
      });
      send(session.web, {
        type: "sessionReady",
        protocolVersion,
        macName: session.macName,
        ...(session.appVersion ? { appVersion: session.appVersion } : {}),
        buttonTitles: session.buttonTitles,
      });
      logEvent(session, "approved");
      break;
    case "sessionDeny":
      if (context.role !== "mac" || !session.web) return rejectInvalidState(context);
      send(session.web, errorMessage("denied", "Mac 拒绝了本次连接", false));
      destroySession(session, sessions, "连接已拒绝");
      break;
    case "buttonTitles":
      if (context.role !== "mac") return rejectInvalidState(context);
      session.buttonTitles = message.buttonTitles;
      if (session.approved && session.web) send(session.web, message);
      break;
    case "command":
      if (context.role !== "web" || !session.approved) return rejectInvalidState(context);
      if (!allowRate(context, "command", commandLimitPerSecond)) {
        return rejectConnection(context, "rate_limited", "按键消息过于频繁");
      }
      send(session.mac, message);
      break;
    case "voiceStart":
    case "voiceStop":
      if (context.role !== "web" || !session.approved) return rejectInvalidState(context);
      send(session.mac, message);
      break;
    case "voiceReady":
      if (context.role !== "mac" || !session.approved || !session.web) return rejectInvalidState(context);
      send(session.web, message);
      break;
    case "error":
      if (context.role !== "mac" || !session.approved || !session.web) return rejectInvalidState(context);
      send(session.web, message);
      break;
    case "heartbeat":
      send(context, { type: "heartbeat", protocolVersion, timestamp: Date.now() });
      break;
    case "sessionClose":
      destroySession(session, sessions, message.reason ?? "会话已结束");
      break;
    default:
      rejectInvalidState(context);
  }
}

function createSession(
  context: ConnectionContext,
  message: SessionCreateMessage,
  sessions: Map<string, Session>,
  publicOrigin: string,
  pendingSessionTTLMS: number,
  maximumSessions: number,
): void {
  if (sessions.size >= maximumSessions) {
    rejectConnection(context, "capacity", "当前会话过多，请稍后重试");
    return;
  }
  const id = randomBytes(16).toString("base64url");
  const token = randomBytes(32);
  const pairingCode = String(randomBytes(2).readUInt16BE(0) % 10_000).padStart(4, "0");
  const now = Date.now();
  const session: Session = {
    id,
    token,
    pairingCode,
    createdAt: now,
    expiresAt: now + pendingSessionTTLMS,
    mac: context,
    approved: false,
    macName: message.macName,
    ...(message.appVersion ? { appVersion: message.appVersion } : {}),
    buttonTitles: message.buttonTitles,
  };
  sessions.set(id, session);
  context.role = "mac";
  context.sessionId = id;
  const joinURL = new URL(publicOrigin);
  joinURL.searchParams.set("session", id);
  joinURL.hash = `token=${token.toString("base64url")}`;
  send(context, {
    type: "sessionCreated",
    protocolVersion,
    sessionId: id,
    joinURL: joinURL.toString(),
    pairingCode,
    expiresAt: new Date(session.expiresAt).toISOString(),
  });
  logEvent(session, "created");
}

function joinSession(
  context: ConnectionContext,
  message: SessionJoinMessage,
  sessions: Map<string, Session>,
  maximumSessionTTLMS: number,
): void {
  const session = sessions.get(message.sessionId);
  const suppliedToken = decodeBase64URL(message.token);
  if (!session || !suppliedToken || session.web || Date.now() >= session.expiresAt
      || suppliedToken.length !== session.token.length
      || !timingSafeEqual(suppliedToken, session.token)) {
    rejectConnection(context, "join_failed", "二维码无效或已经过期");
    return;
  }
  context.role = "web";
  context.sessionId = session.id;
  session.web = context;
  session.deviceName = message.deviceName;
  session.expiresAt = Date.now() + maximumSessionTTLMS;
  send(context, {
    type: "sessionPendingApproval",
    protocolVersion,
    pairingCode: session.pairingCode,
    macName: session.macName,
    ...(session.appVersion ? { appVersion: session.appVersion } : {}),
  });
  send(session.mac, {
    type: "sessionPendingApproval",
    protocolVersion,
    pairingCode: session.pairingCode,
    deviceName: session.deviceName,
  });
  logEvent(session, "joined");
}

function handleAudio(
  context: ConnectionContext,
  data: Buffer | ArrayBuffer | Buffer[],
  sessions: Map<string, Session>,
): void {
  const session = context.sessionId ? sessions.get(context.sessionId) : undefined;
  const buffer = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
  if (!session || context.role !== "web" || !session.approved || !isAudioFrame(buffer)) {
    rejectInvalidState(context);
    return;
  }
  if (!allowRate(context, "audio", audioLimitPerSecond)) {
    rejectConnection(context, "rate_limited", "音频消息过于频繁");
    return;
  }
  if (session.mac.socket.readyState === WebSocket.OPEN) {
    session.mac.socket.send(buffer, { binary: true });
  }
}

function closeContextSession(
  context: ConnectionContext,
  sessions: Map<string, Session>,
  reason: string,
): void {
  const session = context.sessionId ? sessions.get(context.sessionId) : undefined;
  if (session) destroySession(session, sessions, reason, context);
}

function destroySession(
  session: Session,
  sessions: Map<string, Session>,
  reason: string,
  alreadyClosed?: ConnectionContext,
): void {
  if (!sessions.delete(session.id)) return;
  const closeMessage: WireMessage = { type: "sessionClose", protocolVersion, reason };
  for (const context of [session.mac, session.web]) {
    if (!context || context === alreadyClosed) continue;
    send(context, closeMessage);
    context.socket.close(1000, "session closed");
  }
  logEvent(session, "closed");
}

function rejectInvalidState(context: ConnectionContext): void {
  send(context, errorMessage("invalid_state", "当前会话状态不允许这个操作", true));
}

function rejectConnection(context: ConnectionContext, code: string, detail: string): void {
  send(context, errorMessage(code, detail, false));
  context.socket.close(1008, "policy violation");
}

function errorMessage(code: string, detail: string, recoverable: boolean): WireMessage {
  return { type: "error", protocolVersion, code, detail, recoverable };
}

function send(context: ConnectionContext, message: WireMessage): void {
  if (context.socket.readyState === WebSocket.OPEN) {
    context.socket.send(JSON.stringify(message));
  }
}

function allowRate(
  context: ConnectionContext,
  kind: "json" | "command" | "audio",
  limit: number,
): boolean {
  const now = Date.now();
  const windowKey = `${kind}WindowStartedAt` as const;
  const countKey = `${kind}Count` as const;
  if (now - context[windowKey] >= 1_000) {
    context[windowKey] = now;
    context[countKey] = 0;
  }
  context[countKey] += 1;
  return context[countKey] <= limit;
}

function serveHTTP(request: IncomingMessage, response: ServerResponse, staticDirectory: string): void {
  setSecurityHeaders(response);
  const requestURL = new URL(request.url ?? "/", "http://localhost");
  if (requestURL.pathname === "/healthz") {
    response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
    response.end(JSON.stringify({ status: "ok" }));
    return;
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { allow: "GET, HEAD" });
    response.end();
    return;
  }
  let pathname: string;
  try {
    pathname = decodeURIComponent(requestURL.pathname);
  } catch {
    response.writeHead(400);
    response.end();
    return;
  }
  const relativePath = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  let filePath = resolve(staticDirectory, relativePath);
  if (!filePath.startsWith(`${staticDirectory}${sep}`) && filePath !== staticDirectory) {
    response.writeHead(403);
    response.end();
    return;
  }
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    filePath = resolve(staticDirectory, "index.html");
  }
  if (!existsSync(filePath)) {
    response.writeHead(503, { "content-type": "text/plain; charset=utf-8" });
    response.end("Mobile Web build is unavailable");
    return;
  }
  const extension = extname(filePath);
  const immutable = filePath.includes(`${sep}assets${sep}`);
  response.writeHead(200, {
    "content-type": mimeType(extension),
    "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
  });
  if (request.method === "HEAD") {
    response.end();
  } else {
    createReadStream(filePath).pipe(response);
  }
}

function setSecurityHeaders(response: ServerResponse): void {
  response.setHeader("content-security-policy", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "connect-src 'self' ws: wss:",
    "font-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "form-action 'none'",
  ].join("; "));
  response.setHeader("permissions-policy", "microphone=(self), camera=(), geolocation=()");
  response.setHeader("referrer-policy", "no-referrer");
  response.setHeader("x-content-type-options", "nosniff");
  response.setHeader("x-frame-options", "DENY");
  response.setHeader("cross-origin-opener-policy", "same-origin");
}

function mimeType(extension: string): string {
  switch (extension) {
    case ".html": return "text/html; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".json": return "application/json; charset=utf-8";
    case ".png": return "image/png";
    case ".svg": return "image/svg+xml";
    case ".ico": return "image/x-icon";
    default: return "application/octet-stream";
  }
}

function normalizeOrigin(value: string): string {
  const url = new URL(value);
  return url.origin;
}

function decodeBase64URL(value: string): Buffer | undefined {
  try {
    return Buffer.from(value, "base64url");
  } catch {
    return undefined;
  }
}

function logEvent(session: Session, event: string): void {
  const shortSession = session.id.slice(0, 8);
  process.stdout.write(`${new Date().toISOString()} session=${shortSession} event=${event}\n`);
}
