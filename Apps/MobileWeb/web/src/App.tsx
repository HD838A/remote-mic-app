import { useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactElement, type ReactNode } from "react";
import type { ButtonPhase, RemoteCommandName } from "@remote-mic/mobile-web-protocol";
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
import appLogoURL from "./assets/app-logo.png?inline";

const iosBetaURL = "https://testflight.apple.com/join/J8k8fb7v";

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
    const stopInteractions = () => {
      connection.releaseAllButtons();
      connection.endVoice();
    };
    const onVisibilityChange = () => {
      if (document.visibilityState !== "visible") stopInteractions();
    };
    window.addEventListener("blur", stopInteractions);
    window.addEventListener("pagehide", stopInteractions);
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      unsubscribe();
      window.removeEventListener("blur", stopInteractions);
      window.removeEventListener("pagehide", stopInteractions);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      connection.disconnect();
    };
  }, [connection]);

  const connected = state.phase === "connected";
  const perform = (command: RemoteCommandName, phase: ButtonPhase) => {
    connection.sendButtonEvent(command, phase);
  };
  return (
    <main className="remote-shell" onContextMenu={(event) => event.preventDefault()}>
      <section className="remote-surface" aria-label="无线麦手机遥控器">
        <header className="remote-header">
          <ControlButton className="header-button" label="关机" haptic="emphasized" disabled={!connected} onPressChanged={(phase) => perform("power", phase)}>
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
          <RoundButton label="返回" title={state.buttonTitles.back} icon={<BackIcon />} disabled={!connected} onPressChanged={(phase) => perform("back", phase)} />
          <RoundButton label="菜单" title={state.buttonTitles.menu} icon={<MenuIcon />} disabled={!connected} onPressChanged={(phase) => perform("menu", phase)} />
          <RoundButton label="音量+" title={state.buttonTitles.volume_up} icon={<VolumeUpIcon />} disabled={!connected} onPressChanged={(phase) => perform("volume_up", phase)} />
          <RoundButton label="主页" title={state.buttonTitles.home} icon={<HomeIcon />} disabled={!connected} onPressChanged={(phase) => perform("home", phase)} />
          <RoundButton label="TV" title={state.buttonTitles.tv} icon={<TVIcon />} disabled={!connected} onPressChanged={(phase) => perform("tv", phase)} />
          <RoundButton label="音量-" title={state.buttonTitles.volume_down} icon={<VolumeDownIcon />} disabled={!connected} onPressChanged={(phase) => perform("volume_down", phase)} />
        </div>

        <div className="primary-controls">
          <VoiceButton state={state} connection={connection} />
          <ControlButton className="primary-button confirm-button" label="确定" haptic="emphasized" disabled={!connected} onPressChanged={(phase) => perform("ok", phase)}>
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
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied" | "failed">("idle");
  const copyIOSBetaLink = async () => {
    triggerHaptic("light");
    try {
      await navigator.clipboard.writeText(iosBetaURL);
      setCopyStatus("copied");
    } catch {
      setCopyStatus("failed");
    }
  };

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
      <nav className="resource-links" aria-label="产品链接">
        <a href="https://8586ai.com/" target="_blank" rel="noreferrer">官方网站</a>
        <a href={iosBetaURL} target="_blank" rel="noreferrer" onPointerDown={() => triggerHaptic("light")}>iOS 公测</a>
        <button type="button" onClick={() => void copyIOSBetaLink()}>
          {copyStatus === "copied" ? "已复制" : copyStatus === "failed" ? "复制失败" : "复制链接"}
        </button>
      </nav>
      <p className="remote-recommendation" aria-live="polite">日常使用更推荐实体遥控器，网页版和 iOS 公测适合体验与备用。</p>
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
  perform: (command: RemoteCommandName, phase: ButtonPhase) => void;
  confirmTitle?: string | undefined;
}): ReactElement {
  return (
    <div className="dpad" aria-label="方向控制">
      <ControlButton className="dpad-direction up" label="向上" disabled={disabled} onPressChanged={(phase) => perform("up", phase)}><ChevronUp /></ControlButton>
      <ControlButton className="dpad-direction right" label="向右" disabled={disabled} onPressChanged={(phase) => perform("right", phase)}><ChevronRight /></ControlButton>
      <ControlButton className="dpad-direction down" label="向下" disabled={disabled} onPressChanged={(phase) => perform("down", phase)}><ChevronDown /></ControlButton>
      <ControlButton className="dpad-direction left" label="向左" disabled={disabled} onPressChanged={(phase) => perform("left", phase)}><ChevronLeft /></ControlButton>
      <ControlButton className="dpad-center" label="确定" disabled={disabled} onPressChanged={(phase) => perform("ok", phase)}>
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
  onPressChanged,
}: {
  label: string;
  title?: string | undefined;
  icon: ReactNode;
  disabled: boolean;
  onPressChanged: (phase: ButtonPhase) => void;
}): ReactElement {
  return (
    <ControlButton className="round-button" label={label} disabled={disabled} onPressChanged={onPressChanged}>
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
  onPressChanged,
  children,
}: {
  className: string;
  label: string;
  disabled?: boolean;
  haptic?: WebHaptic;
  onPressChanged: (phase: ButtonPhase) => void;
  children: ReactNode;
}): ReactElement {
  const activePointer = useRef<number | undefined>(undefined);
  const finishPointer = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (activePointer.current !== event.pointerId) return;
    activePointer.current = undefined;
    onPressChanged("release");
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  };
  return (
    <button
      type="button"
      className={className}
      aria-label={label}
      disabled={disabled}
      onPointerDown={(event) => {
        if (activePointer.current !== undefined) return;
        activePointer.current = event.pointerId;
        event.currentTarget.setPointerCapture(event.pointerId);
        triggerHaptic(haptic);
        onPressChanged("press");
      }}
      onPointerUp={finishPointer}
      onPointerCancel={finishPointer}
      onLostPointerCapture={(event) => {
        if (activePointer.current !== event.pointerId) return;
        activePointer.current = undefined;
        onPressChanged("release");
      }}
      onClick={(event) => {
        if (event.detail !== 0) return;
        triggerHaptic(haptic);
        onPressChanged("press");
        onPressChanged("release");
      }}
    >
      {children}
    </button>
  );
}

function CustomTitle({ value }: { value?: string | undefined }): ReactElement | null {
  return value ? <span className="custom-title">{value}</span> : null;
}
