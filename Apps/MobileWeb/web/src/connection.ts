import {
  encodeAudioFrame,
  parseWireMessage,
  protocolVersion,
  type ButtonTitles,
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

export class RemoteConnection {
  private socket: WebSocket | undefined;
  private credentials: { sessionId: string; token: string } | undefined;
  private listener: Listener | undefined;
  private microphone = new MicrophoneCapture();
  private sequence = 0;
  private voiceRequestID = 0;
  private heartbeat: number | undefined;
  private reconnectTimer: number | undefined;
  private reconnectDeadline = 0;
  private shouldReconnect = false;
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
    this.update({
      phase: "readyToConnect",
      statusText: "等待连接",
      guidanceText: "点击“连接 Mac”后才会建立网络连接",
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
    this.send({ type: "sessionClose", protocolVersion, reason: "网页已退出" });
    this.socket?.close(1000, "web disconnected");
    this.socket = undefined;
    this.stopHeartbeat();
    void this.stopVoiceCapture();
  }

  sendCommand(command: RemoteCommandName): void {
    if (this.state.phase !== "connected") return;
    this.send({ type: "command", protocolVersion, command });
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

function sessionCredentials(): { sessionId: string; token: string } | undefined {
  const url = new URL(window.location.href);
  const sessionId = url.searchParams.get("session");
  const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
  const token = hash.get("token");
  if (!sessionId) return undefined;
  const storageKey = sessionStorageKey(sessionId);
  if (token) {
    const credentials = { sessionId, token };
    window.sessionStorage.setItem(storageKey, JSON.stringify(credentials));
    history.replaceState(null, "", `${url.pathname}?session=${encodeURIComponent(sessionId)}#ready`);
    return credentials;
  }
  const stored = window.sessionStorage.getItem(storageKey);
  if (!stored) return undefined;
  try {
    const credentials = JSON.parse(stored) as { sessionId?: unknown; token?: unknown };
    return credentials.sessionId === sessionId && typeof credentials.token === "string"
      ? { sessionId, token: credentials.token }
      : undefined;
  } catch {
    return undefined;
  }
}

function sessionStorageKey(sessionId: string): string {
  return `remote-mic-session:${sessionId}`;
}

function clearSessionCredentials(sessionId?: string): void {
  if (sessionId) window.sessionStorage.removeItem(sessionStorageKey(sessionId));
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
