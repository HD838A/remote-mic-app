import {
  buttonEventsCapability,
  encodeAudioFrame,
  parseWireMessage,
  protocolVersion,
  type ButtonTitles,
  type ButtonPhase,
  type RemoteCommandName,
  type WireMessage,
} from "@remote-mic/mobile-web-protocol";
import { MicrophoneCapture } from "./audio";

export type ConnectionPhase =
  | "missingSession"
  | "readyToConnect"
  | "connecting"
  | "reconnecting"
  | "awaitingApproval"
  | "connected"
  | "failed"
  | "closed";

export interface ConnectionState {
  phase: ConnectionPhase;
  statusText: string;
  guidanceText: string;
  pairingCode?: string | undefined;
  macName?: string | undefined;
  appVersion?: string | undefined;
  buttonTitles: ButtonTitles;
  voiceRequested: boolean;
  voiceReady: boolean;
}

type Listener = (state: ConnectionState) => void;

interface SessionCredentials {
  sessionId: string;
  token: string;
  remembered: boolean;
}

interface RememberedCredentials {
  version: 1;
  sessionId: string;
  token: string;
  savedAt: number;
  macName?: string;
}

const rememberedSessionKey = "remote-mic-remembered-session:v1";
const rememberedSessionMaxAgeMS = 2 * 60 * 60 * 1000;

export class RemoteConnection {
  private socket: WebSocket | undefined;
  private credentials: SessionCredentials | undefined;
  private listener: Listener | undefined;
  private microphone = new MicrophoneCapture();
  private sequence = 0;
  private voiceRequestID = 0;
  private heartbeat: number | undefined;
  private reconnectTimer: number | undefined;
  private reconnectDeadline = 0;
  private shouldReconnect = false;
  private supportsButtonEvents = false;
  private pressedButtons = new Set<RemoteCommandName>();
  private state: ConnectionState = {
    phase: "connecting",
    statusText: "正在连接",
    guidanceText: "请在 Mac 上允许本次连接",
    buttonTitles: {},
    voiceRequested: false,
    voiceReady: false,
  };

  subscribe(listener: Listener): () => void {
    this.listener = listener;
    listener(this.state);
    return () => {
      if (this.listener === listener) this.listener = undefined;
    };
  }

  prepare(): void {
    this.credentials = sessionCredentials();
    if (!this.credentials) {
      this.update({
        phase: "missingSession",
        statusText: "等待扫码",
        guidanceText: "请在 Mac 无线麦 App 中选择“连接网页版”，再扫描二维码。",
      });
      return;
    }
    const macName = rememberedMacName();
    this.update({
      phase: "readyToConnect",
      statusText: "等待连接",
      guidanceText: this.credentials.remembered
        ? "已记住上次连接，点击“连接 Mac”即可继续"
        : "点击“连接 Mac”后才会建立网络连接",
      ...(macName ? { macName } : {}),
    });
  }

  connect(): void {
    if (!this.credentials || this.socket?.readyState === WebSocket.OPEN || this.socket?.readyState === WebSocket.CONNECTING) {
      return;
    }
    this.shouldReconnect = true;
    this.reconnectDeadline = Date.now() + 60_000;
    this.openSocket(false);
  }

  private openSocket(reconnecting: boolean): void {
    const credentials = this.credentials;
    if (!credentials || !this.shouldReconnect) return;
    this.stopReconnectTimer();
    this.update({
      phase: reconnecting ? "reconnecting" : "connecting",
      statusText: reconnecting ? "正在恢复连接" : "正在连接",
      guidanceText: reconnecting ? "正在恢复当前会话" : "正在加入 Mac 的临时会话",
    });
    const socket = new WebSocket(webSocketURL());
    socket.binaryType = "arraybuffer";
    this.socket = socket;
    socket.addEventListener("open", () => {
      this.send({
        type: "sessionJoin",
        protocolVersion,
        sessionId: credentials.sessionId,
        token: credentials.token,
        deviceName: browserDeviceName(),
      });
      this.heartbeat = window.setInterval(() => {
        this.send({ type: "heartbeat", protocolVersion, timestamp: Date.now() });
      }, 20_000);
    });
    socket.addEventListener("message", (event) => {
      if (typeof event.data !== "string") return;
      const message = parseWireMessage(event.data);
      if (message) this.handle(message);
    });
    socket.addEventListener("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.stopHeartbeat();
      this.supportsButtonEvents = false;
      this.pressedButtons.clear();
      void this.stopVoiceCapture();
      if (this.shouldReconnect) {
        if (this.reconnectDeadline === 0) this.reconnectDeadline = Date.now() + 60_000;
      }
      if (this.shouldReconnect && Date.now() < this.reconnectDeadline) {
        this.update({
          phase: "reconnecting",
          statusText: "正在恢复连接",
          guidanceText: "网络短暂中断，正在自动恢复当前会话",
        });
        this.reconnectTimer = window.setTimeout(() => this.openSocket(true), reconnecting ? 1_500 : 800);
        return;
      }
      if (this.state.phase !== "failed" && this.state.phase !== "missingSession") {
        this.update({ phase: "closed", statusText: "连接已结束", guidanceText: "请回到 Mac 重新生成二维码" });
      }
    });
    socket.addEventListener("error", () => {
      if (this.socket === socket) {
        this.update({ guidanceText: "网络连接失败，正在尝试恢复" });
      }
    });
  }

  disconnect(): void {
    this.shouldReconnect = false;
    this.stopReconnectTimer();
    this.voiceRequestID += 1;
    this.socket?.close(1000, "web disconnected");
    this.socket = undefined;
    this.stopHeartbeat();
    this.supportsButtonEvents = false;
    this.pressedButtons.clear();
    void this.stopVoiceCapture();
  }

  sendCommand(command: RemoteCommandName): void {
    if (this.state.phase !== "connected") return;
    this.send({ type: "command", protocolVersion, command });
  }

  sendButtonEvent(command: RemoteCommandName, buttonPhase: ButtonPhase): void {
    if (this.state.phase !== "connected") return;
    if (buttonPhase === "press") {
      this.pressedButtons.add(command);
    } else {
      this.pressedButtons.delete(command);
    }
    if (this.supportsButtonEvents) {
      this.send({ type: "buttonEvent", protocolVersion, command, buttonPhase });
    } else if (buttonPhase === "release") {
      this.sendCommand(command);
    }
  }

  releaseAllButtons(): void {
    for (const command of [...this.pressedButtons]) {
      this.sendButtonEvent(command, "release");
    }
    this.pressedButtons.clear();
  }

  async beginVoice(): Promise<void> {
    if (this.state.phase !== "connected" || this.state.voiceRequested) return;
    this.voiceRequestID += 1;
    const requestID = this.voiceRequestID;
    this.update({ voiceRequested: true, voiceReady: false, guidanceText: "正在启用麦克风" });
    this.send({ type: "voiceStart", protocolVersion });
    try {
      await this.microphone.start((samples) => {
        if (!this.state.voiceReady || this.socket?.readyState !== WebSocket.OPEN) return;
        const socket = this.socket;
        const frame = encodeAudioFrame(this.sequence, samples);
        this.sequence = (this.sequence + 1) >>> 0;
        if (socket.bufferedAmount > 64 * 1024) return;
        socket.send(frame);
      });
      if (requestID !== this.voiceRequestID || !this.state.voiceRequested) {
        await this.microphone.stop();
      }
    } catch (error) {
      if (requestID !== this.voiceRequestID) return;
      this.send({ type: "voiceStop", protocolVersion });
      const detail = error instanceof DOMException && error.name === "NotAllowedError"
        ? "请允许浏览器使用麦克风，然后再次按住说话"
        : "无法启用麦克风，请稍后重试";
      await this.stopVoiceCapture(detail);
    }
  }

  endVoice(): void {
    if (!this.state.voiceRequested) return;
    this.voiceRequestID += 1;
    this.send({ type: "voiceStop", protocolVersion });
    void this.stopVoiceCapture();
  }

  private handle(message: WireMessage): void {
    switch (message.type) {
      case "sessionPendingApproval":
        this.update({
          phase: "awaitingApproval",
          statusText: "等待 Mac 确认",
          guidanceText: "请确认手机与 Mac 显示相同校验码",
          pairingCode: message.pairingCode,
          ...(message.macName ? { macName: message.macName } : {}),
          ...(message.appVersion ? { appVersion: message.appVersion } : {}),
        });
        break;
      case "sessionReady":
        this.reconnectDeadline = 0;
        rememberSessionCredentials(this.credentials, message.macName);
        this.supportsButtonEvents = message.capabilities?.includes(buttonEventsCapability) === true;
        this.update({
          phase: "connected",
          statusText: "已连接",
          guidanceText: "麦克风仅在按住时启用",
          pairingCode: undefined,
          ...(message.macName ? { macName: message.macName } : {}),
          ...(message.appVersion ? { appVersion: message.appVersion } : {}),
          buttonTitles: message.buttonTitles ?? {},
        });
        break;
      case "buttonTitles":
        this.update({ buttonTitles: message.buttonTitles });
        break;
      case "voiceReady":
        if (this.state.voiceRequested) {
          this.update({ voiceReady: true, guidanceText: "正在使用麦克风，松开立即停止" });
        }
        break;
      case "error":
        if (this.state.voiceRequested) {
          this.voiceRequestID += 1;
          void this.stopVoiceCapture(message.detail);
        }
        if (message.recoverable) {
          if (!this.state.voiceRequested) this.update({ guidanceText: message.detail });
        } else if (message.code === "join_failed" || message.code === "session_missing") {
          this.invalidateRememberedSession(message.detail);
        } else {
          this.fail(message.detail);
        }
        break;
      case "sessionClose":
        this.shouldReconnect = false;
        this.stopReconnectTimer();
        clearSessionCredentials(this.credentials?.sessionId);
        this.update({ phase: "closed", statusText: "连接已结束", guidanceText: message.reason ?? "请在 Mac 上重新连接" });
        this.socket?.close(1000, "session closed");
        break;
      default:
        break;
    }
  }

  private send(message: WireMessage): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(message));
    }
  }

  private async stopVoiceCapture(guidanceText?: string): Promise<void> {
    await this.microphone.stop();
    this.update({
      voiceRequested: false,
      voiceReady: false,
      guidanceText: guidanceText
        ?? (this.state.phase === "connected" ? "麦克风仅在按住时启用" : this.state.guidanceText),
    });
  }

  private fail(detail: string): void {
    this.shouldReconnect = false;
    this.stopReconnectTimer();
    this.update({ phase: "failed", statusText: "未连接", guidanceText: detail });
    this.socket?.close(1008, "failed");
  }

  private invalidateRememberedSession(detail: string): void {
    this.shouldReconnect = false;
    this.stopReconnectTimer();
    clearSessionCredentials(this.credentials?.sessionId);
    this.credentials = undefined;
    this.update({
      phase: "missingSession",
      statusText: "需要重新扫码",
      guidanceText: `${detail}，请在 Mac 重新生成二维码`,
    });
    this.socket?.close(1008, "session unavailable");
  }

  private update(update: Partial<ConnectionState>): void {
    this.state = { ...this.state, ...update };
    this.listener?.(this.state);
  }

  private stopHeartbeat(): void {
    if (this.heartbeat !== undefined) window.clearInterval(this.heartbeat);
    this.heartbeat = undefined;
  }

  private stopReconnectTimer(): void {
    if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
  }
}

function sessionCredentials(): SessionCredentials | undefined {
  const url = new URL(window.location.href);
  const sessionId = url.searchParams.get("session");
  const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
  const token = hash.get("token");
  if (sessionId && token) {
    const credentials = { sessionId, token, remembered: false };
    storeSessionCredentials(credentials);
    history.replaceState(null, "", `${url.pathname}?session=${encodeURIComponent(sessionId)}#ready`);
    return credentials;
  }

  const remembered = readRememberedCredentials();
  if (remembered && (!sessionId || remembered.sessionId === sessionId)) {
    return { sessionId: remembered.sessionId, token: remembered.token, remembered: true };
  }
  if (!sessionId) return undefined;

  try {
    const stored = window.sessionStorage.getItem(sessionStorageKey(sessionId));
    if (!stored) return undefined;
    const credentials = JSON.parse(stored) as { sessionId?: unknown; token?: unknown };
    return credentials.sessionId === sessionId && typeof credentials.token === "string"
      ? { sessionId, token: credentials.token, remembered: false }
      : undefined;
  } catch {
    return undefined;
  }
}

function storeSessionCredentials(credentials: SessionCredentials): void {
  try {
    window.sessionStorage.setItem(sessionStorageKey(credentials.sessionId), JSON.stringify(credentials));
  } catch {
    // Storage can be unavailable in private browsing; the current in-memory session still works.
  }
}

function rememberSessionCredentials(credentials?: SessionCredentials, macName?: string): void {
  if (!credentials) return;
  try {
    const remembered: RememberedCredentials = {
      version: 1,
      sessionId: credentials.sessionId,
      token: credentials.token,
      savedAt: Date.now(),
      ...(macName ? { macName } : {}),
    };
    window.localStorage.setItem(rememberedSessionKey, JSON.stringify(remembered));
  } catch {
    // Remembering the session is an optional convenience.
  }
}

function readRememberedCredentials(): RememberedCredentials | undefined {
  try {
    const stored = window.localStorage.getItem(rememberedSessionKey);
    if (!stored) return undefined;
    const value = JSON.parse(stored) as Partial<RememberedCredentials>;
    const valid = value.version === 1
      && typeof value.sessionId === "string"
      && typeof value.token === "string"
      && typeof value.savedAt === "number"
      && Date.now() - value.savedAt < rememberedSessionMaxAgeMS;
    if (valid) return value as RememberedCredentials;
    window.localStorage.removeItem(rememberedSessionKey);
  } catch {
    try { window.localStorage.removeItem(rememberedSessionKey); } catch { /* optional storage */ }
  }
  return undefined;
}

function rememberedMacName(): string | undefined {
  return readRememberedCredentials()?.macName;
}

function sessionStorageKey(sessionId: string): string {
  return `remote-mic-session:${sessionId}`;
}

function clearSessionCredentials(sessionId?: string): void {
  try {
    if (sessionId) window.sessionStorage.removeItem(sessionStorageKey(sessionId));
  } catch {
    // Storage cleanup is best effort.
  }
  try {
    const remembered = readRememberedCredentials();
    if (!sessionId || remembered?.sessionId === sessionId) window.localStorage.removeItem(rememberedSessionKey);
  } catch {
    // Storage cleanup is best effort.
  }
}

function webSocketURL(): string {
  const configured = import.meta.env.VITE_WS_URL as string | undefined;
  if (configured) return configured;
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/ws`;
}

function browserDeviceName(): string {
  const userAgent = navigator.userAgent;
  if (/iPhone/i.test(userAgent)) return "iPhone Safari";
  if (/iPad/i.test(userAgent)) return "iPad Safari";
  if (/Android/i.test(userAgent)) return "Android 浏览器";
  return "手机浏览器";
}
