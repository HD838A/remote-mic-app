import { useEffect, useMemo, useState, type PointerEvent as ReactPointerEvent, type ReactElement, type ReactNode } from "react";
import type { RemoteCommandName } from "@remote-mic/mobile-web-protocol";
import { RemoteConnection, type ConnectionState } from "./connection";
import {
  BackIcon,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  HomeIcon,
  LaptopIcon,
  MenuIcon,
  MicrophoneIcon,
  PowerIcon,
  ReturnIcon,
  TVIcon,
  VolumeDownIcon,
  VolumeUpIcon,
} from "./icons";
import { triggerHaptic, type WebHaptic } from "./haptics";
import appLogoURL from "./assets/app-logo.png";

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
    <main className="remote-shell" onContextMenu={(event) => event.preventDefault()}>
      <section className="remote-surface" aria-label="无线麦手机遥控器">
        <header className="remote-header">
          <ControlButton className="header-button" label="关机" haptic="emphasized" disabled={!connected} onPress={() => perform("power")}>
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
          <ControlButton className="primary-button confirm-button" label="确定" haptic="emphasized" disabled={!connected} onPress={() => perform("ok")}>
            <ReturnIcon />
            <span className="primary-title">确定</span>
            <span className="primary-subtitle">{state.buttonTitles.ok ?? "Return"}</span>
          </ControlButton>
        </div>

        {state.phase === "readyToConnect" || state.phase === "failed" ? (
          <button type="button" className="connect-button" onPointerDown={() => triggerHaptic("light")} onClick={() => connection.connect()}>
            {state.phase === "failed" ? "重试连接" : "连接 Mac"}
          </button>
        ) : (
          <p className={`guidance ${state.phase === "closed" ? "issue" : ""}`} aria-live="polite">
            {state.guidanceText}
          </p>
        )}
      </section>
      <MacAppGuide />
    </main>
  );
}

function MacAppGuide(): ReactElement {
  return (
    <aside className="mac-app-guide" aria-labelledby="mac-app-guide-title">
      <div className="guide-heading">
        <img src={appLogoURL} alt="无线麦 App Logo" draggable={false} width="42" height="42" decoding="async" />
        <div>
          <h2 id="mac-app-guide-title">在 Mac 上安装无线麦</h2>
          <p>Apple Silicon · macOS 14 或更高版本</p>
        </div>
      </div>
      <a
        className="download-link"
        href="https://github.com/HD838A/remote-mic-app/releases/latest"
        target="_blank"
        rel="noreferrer"
        onPointerDown={() => triggerHaptic("light")}
      >
        下载最新版 Mac App
      </a>
      <nav className="official-sites" aria-label="官方网站">
        <a href="https://8586ai.com/" target="_blank" rel="noreferrer">中文官网</a>
        <a href="https://8586ai.com/en/" target="_blank" rel="noreferrer">English Website</a>
      </nav>
      <div className="connection-tutorial" aria-label="连接教程">
        <h3>连接教程</h3>
        <ol>
          <li>打开 Mac 上的“无线麦”，选择“连接网页版”。</li>
          <li>用手机扫描 Mac 显示的二维码，然后点击网页上的“连接 Mac”。</li>
          <li>核对校验码并在 Mac 允许连接。成功后两小时内无需再次扫码。</li>
        </ol>
      </div>
      <p className="privacy-note">语音仅在按住麦克风时传输，不记录语音内容。</p>
    </aside>
  );
}

function ConnectionStatus({ state }: { state: ConnectionState }): ReactElement {
  if (state.pairingCode) {
    return (
      <div className="connection-status pairing" aria-live="polite">
        <BrandMark />
        <span className="status-label">校验码</span>
        <strong>{state.pairingCode.split("").join(" ")}</strong>
        <span className="mac-name">{state.macName ?? "等待 Mac 确认"}</span>
      </div>
    );
  }
  const healthy = state.phase === "connected";
  return (
    <div className="connection-status" aria-live="polite">
      <BrandMark />
      <span className={`status-line ${healthy ? "healthy" : "pending"}`}>
        <i aria-hidden="true" />
        {state.statusText}
      </span>
      <span className="mac-name">{state.macName ?? "无线麦 Mac"}</span>
    </div>
  );
}

function BrandMark(): ReactElement {
  return (
    <span className="brand-mark" aria-label="无线麦">
      <img src={appLogoURL} alt="" draggable={false} width="18" height="18" />
      <span>无线麦</span>
    </span>
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
    triggerHaptic("emphasized");
    event.currentTarget.setPointerCapture(event.pointerId);
    void connection.beginVoice();
  };
  const stop = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (!disabled) triggerHaptic("release");
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
      <span className="primary-title">{state.voiceReady ? "正在说话" : "按住说话"}</span>
      <span className="primary-subtitle">松手停止</span>
    </button>
  );
}

function ControlButton({
  className,
  label,
  disabled = false,
  haptic = "light",
  onPress,
  children,
}: {
  className: string;
  label: string;
  disabled?: boolean;
  haptic?: WebHaptic;
  onPress: () => void;
  children: ReactNode;
}): ReactElement {
  return (
    <button type="button" className={className} aria-label={label} disabled={disabled} onPointerDown={() => triggerHaptic(haptic)} onClick={onPress}>
      {children}
    </button>
  );
}

function CustomTitle({ value }: { value?: string | undefined }): ReactElement | null {
  return value ? <span className="custom-title">{value}</span> : null;
}
