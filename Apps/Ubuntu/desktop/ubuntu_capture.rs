use sayall_windows::ubuntu;
use serde_json::json;
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskStatus {
    pub installed: bool,
    pub authorization_required: bool,
    pub enabled: bool,
    pub helper_path: Option<String>,
    pub last_error: Option<String>,
}
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSupport {
    pub native_arch: String,
    pub helper_expected: String,
    pub available: bool,
    pub reason: Option<String>,
}

pub fn status(enabled: bool) -> TaskStatus {
    TaskStatus { installed: capture_support().available, authorization_required: true, enabled, helper_path: None, last_error: None }
}
pub fn capture_support() -> CaptureSupport {
    let available = std::env::current_exe().ok().and_then(|p| Some(p.parent()?.join("desktop.py").is_file())).unwrap_or(false);
    CaptureSupport { native_arch: std::env::consts::ARCH.into(), helper_expected: "desktop.py".into(), available,
        reason: if available { None } else { Some("helper_missing".into()) }}
}
pub fn enable_capture() -> Result<(), String> { ubuntu::call("capture", json!(true)).map(drop) }
pub fn disable_capture() -> Result<(), String> { ubuntu::call("capture", json!(false)).map(drop) }

/// XDG_RUNTIME_DIR is private to the logged-in user and discarded at logout.
pub fn primary_instance() -> std::io::Result<Option<(std::fs::File, std::os::unix::net::UnixListener)>> {
    use std::{fs, io, os::unix::net::{UnixListener, UnixStream}, path::PathBuf, time::Duration};
    let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").ok_or(io::ErrorKind::NotFound)?);
    let lock = fs::OpenOptions::new().write(true).create(true).truncate(false).open(runtime.join("sayall-desktop.lock"))?;
    let socket = runtime.join("sayall-desktop.sock");
    match lock.try_lock() {
        Ok(()) => {
            if socket.exists() { fs::remove_file(&socket)?; }
            Ok(Some((lock, UnixListener::bind(&socket)?)))
        }
        Err(std::fs::TryLockError::WouldBlock) => {
            for _ in 0..20 {
                if UnixStream::connect(&socket).is_ok() { return Ok(None); }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(io::ErrorKind::ConnectionRefused.into())
        }
        Err(std::fs::TryLockError::Error(e)) => Err(e),
    }
}
