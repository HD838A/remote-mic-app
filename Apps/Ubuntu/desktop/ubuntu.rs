// SPDX-License-Identifier: GPL-3.0-only
use super::*;
use base64::Engine;
use button_mapping::{EngineMessage, MappingInjector};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc, OnceLock, Weak,
};
use std::time::Duration;

pub const MIC: &str = "sayall.rc003.mic";
static DESKTOP: OnceLock<Weak<Desktop>> = OnceLock::new();
pub static GRABBED: AtomicBool = AtomicBool::new(false);
type Reply = Result<Value, String>;
pub fn call(op: &str, data: Value) -> Reply {
    DESKTOP
        .get()
        .and_then(Weak::upgrade)
        .ok_or("Ubuntu desktop unavailable")?
        .call(op, data)
}

#[derive(Default)]
struct Transport {
    writer: Option<ChildStdin>,
    pending: HashMap<u64, mpsc::Sender<Reply>>,
}

#[derive(Default)]
pub struct Desktop {
    transport: Mutex<Transport>,
    next: AtomicU64,
    pub applied_edges: AtomicU64,
    pub connection: Mutex<ConnectionSnapshot>,
    pub audio: Mutex<AudioSnapshot>,
    pub input: Mutex<send_input::SendInputSnapshot>,
    held_chord: Mutex<Option<send_input::KeyChord>>,
    voice_at: Mutex<Option<Instant>>,
    callback: OnceLock<Box<dyn Fn(&str, &Value) + Send + Sync>>,
}

impl Desktop {
    pub fn install(self: &Arc<Self>, platform: WindowsPlatform) {
        // The session owns the platform resources. Capture only independent handles.
        let usage = platform.usage_counters();
        let capture = platform.transcript_capture.clone();
        let hotkey = platform.voice_hold_hotkey.clone();
        let raw = platform.raw_input_snapshot.clone();
        let sender = platform.button_mapping.sender();
        let weak = Arc::downgrade(self);
        let _ = DESKTOP.set(weak.clone());
        let _ = self.callback.set(Box::new(move |kind, value| {
            let Some(host) = weak.upgrade() else { return };
            match kind {
                "connecting" => {
                    *lock(&host.connection) = ConnectionSnapshot {
                        phase: ConnectionPhase::Connecting,
                        remote_name: value["name"].as_str().map(String::from),
                        remote_model: serde_json::from_value(value["model"].clone())
                            .unwrap_or_default(),
                        remote_token: value["id"].as_str().map(device_token),
                        battery_level: value["battery"].as_u64().and_then(|v| u8::try_from(v).ok()),
                        ..Default::default()
                    };
                }
                "model" => {
                    lock(&host.connection).remote_model =
                        serde_json::from_value(value.clone()).unwrap_or_default()
                }
                "ready" => {
                    let Ok(packet) = serde_json::from_value::<Vec<u8>>(value.clone()) else {
                        return;
                    };
                    let Ok(caps) = AtvvCapabilities::parse(&packet) else {
                        return;
                    };
                    let mut conn = lock(&host.connection);
                    conn.capabilities = Some(caps);
                    conn.phase = ConnectionPhase::Ready;
                    conn.last_error = None;
                    let mut audio = lock(&host.audio);
                    audio.phase = AudioPhase::Ready;
                    audio.selected_endpoint_id = Some(MIC.into());
                    audio.selected_endpoint_name = Some("SayAll RC003".into());
                }
                "voice_start" => {
                    let now = unix_ms_now();
                    let id = new_session_id();
                    if capture.is_enabled() {
                        capture.begin_pending(now);
                        capture.bind_session(id.clone());
                        capture.start_audio_recording(&id, now, None);
                    }
                    usage.ensure_voice_session_started(None);
                    *lock(&host.voice_at) = Some(Instant::now());
                    {
                        let mut conn = lock(&host.connection);
                        conn.generation += 1;
                        conn.phase = ConnectionPhase::Streaming;
                        conn.voice_state = VoiceSessionState::Streaming;
                    }
                    lock(&host.audio).phase = AudioPhase::Streaming;
                    let _ = sender.send(EngineMessage::VoiceSessionStarted);
                    host.voice_chord(&hotkey, "down");
                }
                "recording" if capture.is_enabled() && capture.is_audio_recording_enabled() => {
                    if let Some(bytes) = value
                        .as_str()
                        .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                    {
                        let samples = bytes
                            .chunks_exact(2)
                            .map(|p| i16::from_le_bytes([p[0], p[1]]))
                            .collect::<Vec<_>>();
                        capture.append_audio(&samples);
                    }
                }
                "voice_stop" => {
                    host.voice_chord(&hotkey, "up");
                    capture.finish_audio(unix_ms_now());
                    capture.finish_session(unix_ms_now());
                    let samples = value.as_u64().unwrap_or(0);
                    usage.record_voice_session(samples);
                    usage.finish_voice_session();
                    let mut conn = lock(&host.connection);
                    conn.phase = ConnectionPhase::Ready;
                    conn.voice_state = VoiceSessionState::Idle;
                    conn.decoded_samples += samples;
                    if let Some(at) = lock(&host.voice_at).take() {
                        let elapsed = at.elapsed().as_secs_f64();
                        if elapsed >= 1.0 {
                            let rate = (samples as f64 / elapsed) as u32;
                            conn.voice_audio_rate_hz = Some(rate);
                            conn.voice_audio_health = if rate >= 12000 {
                                VoiceAudioHealth::Full
                            } else {
                                VoiceAudioHealth::Degraded
                            };
                        }
                    }
                    let mut audio = lock(&host.audio);
                    audio.phase = AudioPhase::Ready;
                    audio.submitted_samples += samples;
                }
                "lost" | "disconnected" => {
                    if lock(&host.voice_at).take().is_some() {
                        host.voice_chord(&hotkey, "up");
                    }
                    capture.cancel("disconnect");
                    capture.cancel_audio();
                    usage.finish_voice_session();
                    let mut conn = lock(&host.connection);
                    conn.phase = if kind == "lost" {
                        ConnectionPhase::Reconnecting
                    } else {
                        ConnectionPhase::Disconnected
                    };
                    conn.voice_state = VoiceSessionState::Idle;
                    conn.capabilities = None;
                    *lock(&host.audio) = Default::default();
                    let _ = sender.send(EngineMessage::DeviceRemoved);
                }
                "input" => {
                    let count = value[0].as_u64().unwrap_or(0) as u32;
                    let authorized = value[1].as_bool().unwrap_or(false);
                    let mut state = lock(&raw);
                    state.matched_device_count = count;
                    state.phase = if !value[2].as_bool().unwrap_or(false) {
                        RawInputPhase::Stopped
                    } else if count == 0 {
                        RawInputPhase::Awaiting
                    } else {
                        RawInputPhase::Ready
                    };
                    GRABBED.store(count > 0 && authorized, Ordering::Release);
                    lock(&host.input).available = value[3].as_bool().unwrap_or(false);
                    if count == 0 {
                        let _ = sender.send(EngineMessage::DeviceRemoved);
                    }
                }
                "edge" => {
                    if let Ok(edge) = serde_json::from_value(value.clone()) {
                        lock(&raw).raw_event_count += 1;
                        if GRABBED.load(Ordering::Acquire) {
                            host.applied_edges.fetch_add(1, Ordering::Relaxed);
                        }
                        let _ = sender.send(EngineMessage::GateEdge(edge));
                    }
                }
                _ => {}
            }
        }));
        let mut cmd = Command::new("/usr/bin/python3");
        let sibling = std::env::current_exe()
            .ok()
            .and_then(|p| Some(p.parent()?.join("desktop.py")));
        let path = sibling
            .filter(|p| p.is_file())
            .unwrap_or_else(|| "/usr/lib/sayall-ubuntu/desktop.py".into());
        let Ok(mut child) = cmd
            .arg(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
        else {
            return;
        };
        lock(&self.transport).writer = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        let weak = Arc::downgrade(self);
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                let Some(host) = weak.upgrade() else { break };
                let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if let Some(id) = msg["id"].as_u64() {
                    if let Some(tx) = lock(&host.transport).pending.remove(&id) {
                        let _ = tx.send(if let Some(e) = msg["error"].as_str() {
                            Err(e.to_owned())
                        } else {
                            Ok(msg["result"].clone())
                        });
                    }
                } else if let (Some(kind), Some(cb)) = (msg["event"].as_str(), host.callback.get())
                {
                    cb(kind, &msg["data"]);
                }
            }
            if let Some(host) = weak.upgrade() {
                *lock(&host.transport) = Transport::default();
                if let Some(cb) = host.callback.get() {
                    cb("disconnected", &Value::Null);
                }
            }
            let _ = child.wait();
        });
    }

    fn voice_chord(&self, hotkey: &Mutex<Option<send_input::KeyChord>>, op: &str) {
        let chord = if op == "down" {
            let chosen = lock(hotkey).clone();
            *lock(&self.held_chord) = chosen.clone();
            chosen
        } else {
            lock(&self.held_chord).take()
        };
        if let Some(chord) = chord {
            // Reader thread must never wait on its own response.
            let _ = self.send(0, op, json!(chord.keys));
        }
    }

    fn send(&self, id: u64, op: &str, arg: Value) -> Result<(), String> {
        let mut io = lock(&self.transport);
        let pipe = io
            .writer
            .as_mut()
            .ok_or("Ubuntu desktop service unavailable")?;
        writeln!(pipe, "{}", json!({"id":id,"op":op,"arg":arg})).map_err(|e| e.to_string())
    }

    pub fn call(&self, op: &str, arg: Value) -> Reply {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = mpsc::channel();
        lock(&self.transport).pending.insert(id, tx);
        let result = self.send(id, op, arg).and_then(|()| {
            rx.recv_timeout(Duration::from_secs(if op == "capture" { 100 } else { 10 }))
                .map_err(|_| "Ubuntu desktop request timed out".to_owned())?
        });
        lock(&self.transport).pending.remove(&id);
        result
    }

    pub fn scan(&self) -> Result<Vec<PairedRemote>, PlatformError> {
        let items = self
            .call("scan", Value::Null)
            .map_err(PlatformError::Gatt)?;
        items
            .as_array()
            .ok_or(PlatformError::WorkerUnavailable)?
            .iter()
            .map(|item| {
                let id = item["id"]
                    .as_str()
                    .ok_or(PlatformError::WorkerUnavailable)?
                    .to_string();
                Ok(PairedRemote {
                    token: device_token(&id),
                    id,
                    name: item["name"].as_str().unwrap_or("RC003").into(),
                    model: serde_json::from_value(item["model"].clone()).unwrap_or_default(),
                    is_supported_candidate: true,
                })
            })
            .collect()
    }
}

#[derive(Default)]
pub struct Injector;
impl MappingInjector for Injector {
    fn tap(&self, chord: &send_input::KeyChord) -> Result<(), String> {
        send_input::plan_key_tap(chord).map_err(|e| e.to_string())?;
        call("tap", json!(chord.keys)).map(drop)
    }
    fn scroll(&self, direction: send_input::ScrollDirection, steps: u16) -> Result<(), String> {
        let count = if direction == send_input::ScrollDirection::Up {
            -i32::from(steps)
        } else {
            i32::from(steps)
        };
        call("scroll", json!(count)).map(drop)
    }
    fn mouse_click(&self, kind: send_input::MouseClickKind) -> Result<(), String> {
        call("click", json!(kind)).map(drop)
    }
    fn mouse_move(
        &self,
        direction: send_input::MoveDirection,
        distance: u16,
    ) -> Result<(), String> {
        call(
            "move",
            json!(direction.offset(distance).map_err(|e| e.to_string())?),
        )
        .map(drop)
    }
    fn focus_frontmost(&self) -> Result<(), String> {
        call("focus", json!({})).map(drop)
    }
    fn launch_app(&self, target: &str) -> Result<(), String> {
        call("launch", json!(target)).map(drop)
    }
    fn launch_app_and_focus(
        &self,
        target: &str,
        profile: Option<&focus::AppFocusProfile>,
    ) -> Result<(), String> {
        self.launch_app(target)?;
        let Some(profile) = profile else {
            return Ok(());
        };
        if profile.strategy == focus::FocusStrategy::OpenOnly {
            return Ok(());
        }
        for _ in 0..15 {
            if call("active", json!(target)).ok().and_then(|v| v.as_bool()) == Some(true) {
                return match profile.strategy {
                    focus::FocusStrategy::AppShortcut => {
                        self.tap(profile.shortcut.as_ref().ok_or("Missing shortcut")?)
                    }
                    focus::FocusStrategy::RecordedPoint => {
                        call("point", json!({"target":target,"point":profile.point})).map(drop)
                    }
                    _ => call(
                        "focus",
                        json!({"target":target,"recorded":profile.recorded}),
                    )
                    .map(drop),
                };
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        Err("Target application did not acquire focus".into())
    }
    fn learn_focus_target(&self) -> Result<focus::RecordedFocusTarget, String> {
        std::thread::sleep(Duration::from_secs(3));
        serde_json::from_value(call("learn", Value::Null)?).map_err(|e| e.to_string())
    }
    fn learn_focus_point(&self, target: &str) -> Result<focus::RecordedPoint, String> {
        std::thread::sleep(Duration::from_secs(3));
        serde_json::from_value(call("learn_point", json!(target))?).map_err(|e| e.to_string())
    }
    fn app_switcher_submit(&self, cmd: app_switcher::AppSwitcherCommand) -> Result<(), String> {
        use app_switcher::AppSwitcherCommand::*;
        let (op, keys) = match cmd {
            AltDown => ("down", vec!["alt"]),
            AltUp => ("up", vec!["alt"]),
            Tab => ("tap", vec!["tab"]),
            ReverseTab => ("tap", vec!["shift", "tab"]),
            Escape => ("tap", vec!["escape"]),
        };
        call(op, json!(keys)).map(drop)
    }
    fn app_switcher_alt_down(&self) -> bool {
        call("alt_down", Value::Null)
            .ok()
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    }
    fn app_switcher_present(&self) -> bool {
        self.app_switcher_alt_down()
    }
    fn start_app_switcher(&self) -> Result<(), String> {
        button_mapping::request_app_switcher_start()
    }
}

pub struct Provider;
impl SnapshotProvider for Provider {
    fn snapshot(&self) -> Result<CaptureSnapshot, SnapshotError> {
        let v = call("snapshot", Value::Null).map_err(|_| SnapshotError::Unavailable)?;
        let string = |key: &str| {
            v[key]
                .as_str()
                .map(str::to_owned)
                .ok_or(SnapshotError::Unavailable)
        };
        Ok(CaptureSnapshot {
            focus_id: string("focus")?,
            application_key: sayall_core::transcripts::application_key(
                &string("app")?,
                &string("app")?,
            ),
            application_name: string("app")?,
            text: string("text")?,
            selection_text: v["selection"].as_str().map(str::to_owned),
            icon_png: None,
        })
    }
    fn read(&self, focus_id: &str) -> Result<CaptureText, SnapshotError> {
        let v = call("snapshot", json!(focus_id)).map_err(|_| SnapshotError::FocusChanged)?;
        Ok(CaptureText {
            focus_id: focus_id.into(),
            text: v["text"].as_str().ok_or(SnapshotError::Unavailable)?.into(),
            selection_text: v["selection"].as_str().map(str::to_owned),
            safe: true,
        })
    }
}
