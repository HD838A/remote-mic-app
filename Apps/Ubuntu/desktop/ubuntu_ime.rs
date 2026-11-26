use sayall_core::VoiceInputTool;
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImeStatus {
    pub detected: bool,
    pub active: Option<String>,
    pub installed: Vec<String>,
    pub expected: Option<String>,
    pub matches_expected: Option<bool>,
}

impl ImeStatus {
    /// 查询不可用（线程创建失败 / 超时 / COM 初始化失败）：全部按未检测。
    pub fn unavailable() -> Self {
        Self {
            detected: false,
            active: None,
            installed: Vec::new(),
            expected: None,
            matches_expected: None,
        }
    }
}

pub fn ime_status_for(_: Option<VoiceInputTool>) -> ImeStatus {
    let mut status = ImeStatus::unavailable();
    if let Ok(result) = std::process::Command::new("ibus").arg("engine").output() {
        if result.status.success() {
            let name = String::from_utf8_lossy(&result.stdout).trim().to_owned();
            if !name.is_empty() {
                status.active = Some(name);
                status.detected = true;
            }
        }
    }
    status
}

pub fn ime_status_log_line(
    action: &str,
    _: Option<VoiceInputTool>,
    status: &ImeStatus,
    elapsed_ms: u128,
) -> String {
    format!(
        "ime_status action={action} detected={} elapsed_ms={elapsed_ms}",
        status.detected
    )
}
