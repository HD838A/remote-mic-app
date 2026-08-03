export const protocolVersion = 1 as const;
export const audioFrameType = 1 as const;

export const remoteCommands = [
  "power",
  "up",
  "down",
  "left",
  "right",
  "ok",
  "back",
  "home",
  "menu",
  "tv",
  "volume_up",
  "volume_down",
] as const;

export type RemoteCommandName = (typeof remoteCommands)[number];
export type ButtonTitles = Partial<Record<RemoteCommandName, string>>;

export interface SessionCreateMessage {
  type: "sessionCreate";
  protocolVersion: typeof protocolVersion;
  macName: string;
  appVersion?: string;
  buttonTitles: ButtonTitles;
}

export interface SessionJoinMessage {
  type: "sessionJoin";
  protocolVersion: typeof protocolVersion;
  sessionId: string;
  token: string;
  deviceName: string;
}

export interface SessionCreatedMessage {
  type: "sessionCreated";
  protocolVersion: typeof protocolVersion;
  sessionId: string;
  joinURL: string;
  pairingCode: string;
  expiresAt: string;
}

export interface SessionPendingApprovalMessage {
  type: "sessionPendingApproval";
  protocolVersion: typeof protocolVersion;
  pairingCode: string;
  deviceName?: string;
  macName?: string;
  appVersion?: string;
}

export interface SessionApproveMessage {
  type: "sessionApprove";
  protocolVersion: typeof protocolVersion;
}

export interface SessionDenyMessage {
  type: "sessionDeny";
  protocolVersion: typeof protocolVersion;
}

export interface SessionReadyMessage {
  type: "sessionReady";
  protocolVersion: typeof protocolVersion;
  deviceName?: string;
  macName?: string;
  appVersion?: string;
  buttonTitles?: ButtonTitles;
}

export interface ButtonTitlesMessage {
  type: "buttonTitles";
  protocolVersion: typeof protocolVersion;
  buttonTitles: ButtonTitles;
}

export interface CommandMessage {
  type: "command";
  protocolVersion: typeof protocolVersion;
  command: RemoteCommandName;
}

export interface VoiceStartMessage {
  type: "voiceStart";
  protocolVersion: typeof protocolVersion;
}

export interface VoiceReadyMessage {
  type: "voiceReady";
  protocolVersion: typeof protocolVersion;
}

export interface VoiceStopMessage {
  type: "voiceStop";
  protocolVersion: typeof protocolVersion;
}

export interface HeartbeatMessage {
  type: "heartbeat";
  protocolVersion: typeof protocolVersion;
  timestamp: number;
}

export interface ErrorMessage {
  type: "error";
  protocolVersion: typeof protocolVersion;
  code: string;
  detail: string;
  recoverable: boolean;
}

export interface SessionCloseMessage {
  type: "sessionClose";
  protocolVersion: typeof protocolVersion;
  reason?: string;
}

export type WireMessage =
  | SessionCreateMessage
  | SessionJoinMessage
  | SessionCreatedMessage
  | SessionPendingApprovalMessage
  | SessionApproveMessage
  | SessionDenyMessage
  | SessionReadyMessage
  | ButtonTitlesMessage
  | CommandMessage
  | VoiceStartMessage
  | VoiceReadyMessage
  | VoiceStopMessage
  | HeartbeatMessage
  | ErrorMessage
  | SessionCloseMessage;

export function isRemoteCommandName(value: unknown): value is RemoteCommandName {
  return typeof value === "string" && (remoteCommands as readonly string[]).includes(value);
}

export function parseWireMessage(value: string): WireMessage | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    return undefined;
  }

  if (!isRecord(parsed) || parsed.protocolVersion !== protocolVersion || typeof parsed.type !== "string") {
    return undefined;
  }

  switch (parsed.type) {
    case "sessionCreate":
      return isNonEmptyString(parsed.macName, 80) && isButtonTitles(parsed.buttonTitles)
        ? (parsed as unknown as SessionCreateMessage)
        : undefined;
    case "sessionJoin":
      return isNonEmptyString(parsed.sessionId, 80)
        && isNonEmptyString(parsed.token, 160)
        && isNonEmptyString(parsed.deviceName, 80)
        ? (parsed as unknown as SessionJoinMessage)
        : undefined;
    case "sessionCreated":
      return isNonEmptyString(parsed.sessionId, 80)
        && isNonEmptyString(parsed.joinURL, 2048)
        && isNonEmptyString(parsed.pairingCode, 12)
        && isNonEmptyString(parsed.expiresAt, 64)
        ? (parsed as unknown as SessionCreatedMessage)
        : undefined;
    case "sessionPendingApproval":
      return isNonEmptyString(parsed.pairingCode, 12)
        ? (parsed as unknown as SessionPendingApprovalMessage)
        : undefined;
    case "sessionApprove":
    case "sessionDeny":
    case "voiceStart":
    case "voiceReady":
    case "voiceStop":
      return parsed as unknown as WireMessage;
    case "sessionReady":
      return parsed.buttonTitles === undefined || isButtonTitles(parsed.buttonTitles)
        ? (parsed as unknown as SessionReadyMessage)
        : undefined;
    case "buttonTitles":
      return isButtonTitles(parsed.buttonTitles)
        ? (parsed as unknown as ButtonTitlesMessage)
        : undefined;
    case "command":
      return isRemoteCommandName(parsed.command)
        ? (parsed as unknown as CommandMessage)
        : undefined;
    case "heartbeat":
      return typeof parsed.timestamp === "number" && Number.isFinite(parsed.timestamp)
        ? (parsed as unknown as HeartbeatMessage)
        : undefined;
    case "error":
      return isNonEmptyString(parsed.code, 80)
        && isNonEmptyString(parsed.detail, 300)
        && typeof parsed.recoverable === "boolean"
        ? (parsed as unknown as ErrorMessage)
        : undefined;
    case "sessionClose":
      return parsed.reason === undefined || isNonEmptyString(parsed.reason, 160)
        ? (parsed as unknown as SessionCloseMessage)
        : undefined;
    default:
      return undefined;
  }
}

export function encodeAudioFrame(sequence: number, samples: Int16Array): ArrayBuffer {
  const buffer = new ArrayBuffer(5 + samples.length * 2);
  const view = new DataView(buffer);
  view.setUint8(0, audioFrameType);
  view.setUint32(1, sequence >>> 0, false);
  for (let index = 0; index < samples.length; index += 1) {
    view.setInt16(5 + index * 2, samples[index] ?? 0, true);
  }
  return buffer;
}

export function isAudioFrame(data: ArrayBufferView | ArrayBuffer): boolean {
  const view = data instanceof ArrayBuffer
    ? new Uint8Array(data)
    : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  return view.byteLength >= 7
    && view.byteLength <= 4101
    && view[0] === audioFrameType
    && (view.byteLength - 5) % 2 === 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown, maximumLength: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maximumLength;
}

function isButtonTitles(value: unknown): value is ButtonTitles {
  if (!isRecord(value)) return false;
  return Object.entries(value).every(([key, title]) => (
    isRemoteCommandName(key)
    && typeof title === "string"
    && title.length > 0
    && title.length <= 20
  ));
}
