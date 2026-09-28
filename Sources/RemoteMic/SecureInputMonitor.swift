import Carbon

/// Public macOS signal indicating that an application has enabled secure event input.
/// It is intentionally exposed only as a boolean; no process identity or private app
/// state is read or shown to the user.
enum SecureInputMonitor {
    static func isEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }
}
