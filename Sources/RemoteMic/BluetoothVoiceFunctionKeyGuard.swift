import Foundation

final class BluetoothVoiceFunctionKeyGuard {
    private var isAvailable = false
    private var isHeld = false

    func setAvailable(_ available: Bool) {
        isAvailable = available
    }

    func beginIfNeeded(onFailure: () -> Void) {
        guard isAvailable, !isHeld else { return }
        guard KeyboardInjector.setFunctionKeyPressed(true) else {
            AppLogger.shared.write("VOICE FN HOLD failed action=down")
            isAvailable = false
            onFailure()
            return
        }
        isHeld = true
        AppLogger.shared.write("VOICE FN HOLD down")
    }

    @discardableResult
    func release() -> Bool {
        guard isHeld else { return true }
        let released = KeyboardInjector.setFunctionKeyPressed(false)
        if released {
            isHeld = false
            AppLogger.shared.write("VOICE FN HOLD up")
        } else {
            AppLogger.shared.write("VOICE FN HOLD failed action=up")
        }
        return released
    }
}
