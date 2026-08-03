import { useEffect, useMemo, useState, type PointerEvent as ReactPointerEvent, type ReactElement, type ReactNode } from "react";
import type { RemoteCommandName } from "@remote-mic/mobile-web-protocol";
import { RemoteConnection, type ConnectionState } from "./connection";
import {
  BackIcon,
  CheckIcon,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  HomeIcon,
  LaptopIcon,
  MenuIcon,
  MicrophoneIcon,
  PowerIcon,
  TVIcon,
  VolumeDownIcon,
  VolumeUpIcon,
} from "./icons";

const initialState: ConnectionState = {
  phase: "readyToConnect",
  statusText: "等待连接",
  guidanceText: "点击“连接 Mac”后才会建立网络连接",
  buttonTitles: {},
  voiceRequested: false,
  voiceReady: false,
};

export default function App(): ReactElement {
  const connection = useMemo(() => new RemoteConnection(), []);
  const [state, setState] = useState(initialState);

  useEffect(() => {
    const unsubscribe = connection.subscribe(setState);
    connection.prepare();
    const stopVoice = () => connection.endVoice();
    const onVisibilityChange = () => {
      if (document.visibilityState !== "visible") stopVoice();
    };
    window.addEventListener("blur", stopVoice);
    window.addEventListener("pagehide", stopVoice);
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      unsubscribe();
      window.removeEventListener("blur", stopVoice);
      window.removeEventListener("pagehide", stopVoice);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      connection.disconnect();
    };
  }, [connection]);

  const connected = state.phase === "connected";
  const perform = (command: RemoteCommandName) => connection.sendCommand(command);
  return (
    <main className="remote-shell">
      <section className="remote-surface" aria-label="无线麦手机遥控器">
        <header className="remote-header">
          <ControlButton className="header-button" label="关机" disabled={!connected} onPress={() => perform("power")}>
            <PowerIcon />
            <CustomTitle value={state.buttonTitles.power} />
          </ControlButton>

          <ConnectionStatus state={state} />

          <div className="header-button informational" aria-label="Mac 连接信息">
            <LaptopIcon />
          </div>
        </header>

        <DPad disabled={!connected} perform={perform} confirmTitle={state.buttonTitles.ok} />

        <div className="middle-controls" aria-label="常用遥控按键">
          <RoundButton label="返回" title={state.buttonTitles.back} icon={<BackIcon />} disabled={!connected} onPress={() => perform("back")} />
          <RoundButton label="菜单" title={state.buttonTitles.menu} icon={<MenuIcon />} disabled={!connected} onPress={() => perform("menu")} />
          <RoundButton label="音量+" title={state.buttonTitles.volume_up} icon={<VolumeUpIcon />} disabled={!connected} onPress={() => perform("volume_up")} />
          <RoundButton label="主页" title={state.buttonTitles.home} icon={<HomeIcon />} disabled={!connected} onPress={() => perform("home")} />
          <RoundButton label="TV" title={state.buttonTitles.tv} icon={<TVIcon />} disabled={!connected} onPress={() => perform("tv")} />
          <RoundButton label="音量-" title={state.buttonTitles.volume_down} icon={<VolumeDownIcon />} disabled={!connected} onPress={() => perform("volume_down")} />
        </div>

        <div className="primary-controls">
          <VoiceButton state={state} connection={connection} />
          <ControlButton className="primary-button confirm-button" label="确定" disabled={!connected} onPress={() => perform("ok")}>
            <CheckIcon />
            <CustomTitle value={state.buttonTitles.ok} />
          </ControlButton>
        </div>

        {state.phase === "readyToConnect" || state.phase === "failed" ? (
          <button type="button" className="connect-button" onClick={() => connection.connect()}>
            {state.phase === "failed" ? "重试连接" : "连接 Mac"}
          </button>
        ) : (
          <p className={`guidance ${state.phase === "closed" ? "issue" : ""}`} aria-live="polite">
            {state.guidanceText}
          </p>
        )}
      </section>
    </main>
  );
}

function ConnectionStatus({ state }: { state: ConnectionState }): ReactElement {
  if (state.pairingCode) {
    return (
      <div className="connection-status pairing" aria-live="polite">
        <span className="status-label">校验码</span>
        <strong>{state.pairingCode.split("").join(" ")}</strong>
        <span className="mac-name">{state.macName ?? "等待 Mac 确认"}</span>
      </div>
    );
  }
  const healthy = state.phase === "connected";
  return (
    <div className="connection-status" aria-live="polite">
      <span className={`status-line ${healthy ? "healthy" : "pending"}`}>
        <i aria-hidden="true" />
        {state.statusText}
      </span>
      <span className="mac-name">{state.macName ?? "无线麦 Mac"}</span>
    </div>
  );
}

function DPad({
  disabled,
  perform,
  confirmTitle,
}: {
  disabled: boolean;
  perform: (command: RemoteCommandName) => void;
  confirmTitle?: string | undefined;
}): ReactElement {
  return (
    <div className="dpad" aria-label="方向控制">
      <ControlButton className="dpad-direction up" label="向上" disabled={disabled} onPress={() => perform("up")}><ChevronUp /></ControlButton>
      <ControlButton className="dpad-direction right" label="向右" disabled={disabled} onPress={() => perform("right")}><ChevronRight /></ControlButton>
      <ControlButton className="dpad-direction down" label="向下" disabled={disabled} onPress={() => perform("down")}><ChevronDown /></ControlButton>
      <ControlButton className="dpad-direction left" label="向左" disabled={disabled} onPress={() => perform("left")}><ChevronLeft /></ControlButton>
      <ControlButton className="dpad-center" label="确定" disabled={disabled} onPress={() => perform("ok")}>
        <span>{confirmTitle ?? "OK"}</span>
      </ControlButton>
    </div>
  );
}

function RoundButton({
  label,
  title,
  icon,
  disabled,
  onPress,
}: {
  label: string;
  title?: string | undefined;
  icon: ReactNode;
  disabled: boolean;
  onPress: () => void;
}): ReactElement {
  return (
    <ControlButton className="round-button" label={label} disabled={disabled} onPress={onPress}>
      <span className="round-icon">{icon}</span>
      <span className="round-label">{title ?? label}</span>
    </ControlButton>
  );
}

function VoiceButton({ state, connection }: { state: ConnectionState; connection: RemoteConnection }): ReactElement {
  const disabled = state.phase !== "connected";
  const onPointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (disabled) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    void connection.beginVoice();
  };
  const stop = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
    connection.endVoice();
  };
  return (
    <button
      type="button"
      className={`primary-button voice-button ${state.voiceRequested ? "requested" : ""} ${state.voiceReady ? "recording" : ""}`}
      disabled={disabled}
      aria-label="按住说话"
      aria-pressed={state.voiceRequested}
      onPointerDown={onPointerDown}
      onPointerUp={stop}
      onPointerCancel={stop}
      onLostPointerCapture={() => connection.endVoice()}
      onContextMenu={(event) => event.preventDefault()}
    >
      <MicrophoneIcon />
      <span>{state.voiceReady ? "正在说话" : "按住说话"}</span>
    </button>
  );
}

function ControlButton({
  className,
  label,
  disabled = false,
  onPress,
  children,
}: {
  className: string;
  label: string;
  disabled?: boolean;
  onPress: () => void;
  children: ReactNode;
}): ReactElement {
  return (
    <button type="button" className={className} aria-label={label} disabled={disabled} onClick={onPress}>
      {children}
    </button>
  );
}

function CustomTitle({ value }: { value?: string | undefined }): ReactElement | null {
  return value ? <span className="custom-title">{value}</span> : null;
}
