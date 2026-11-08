use std::{path::PathBuf, sync::OnceLock};

#[derive(Debug, Clone)]
pub struct DiagnosticLogMetadata {
    pub app_version: String,
    pub app_build: String,
    pub source_revision: String,
    pub build_channel: String,
    pub release_tag: String,
}

static LOG: OnceLock<(PathBuf, DiagnosticLogMetadata)> = OnceLock::new();

pub fn initialize_diagnostic_log(path: PathBuf, metadata: DiagnosticLogMetadata) -> bool {
    let path = std::env::var_os("SAYALL_GATT_LOG").map(PathBuf::from).unwrap_or(path);
    let writable = crate::diagnostic_log::probe(&path);
    let _ = LOG.set((path, metadata));
    writable
}

pub fn diagnostic_log_path() -> Option<PathBuf> { LOG.get().map(|(p, _)| p.clone()) }
pub fn diagnostic_log_directory() -> Option<PathBuf> { diagnostic_log_path()?.parent().map(ToOwned::to_owned) }
pub fn utc_stamp_compact() -> String { chrono::Utc::now().format("%Y%m%dT%H%M%S%3fZ").to_string() }

pub fn gatt_note(note: String) {
    if let Some((path, build)) = LOG.get() {
        crate::diagnostic_log::append_line(path, &format!("{} source_revision={} {}", utc_stamp_compact(), build.source_revision, note));
    }
}
