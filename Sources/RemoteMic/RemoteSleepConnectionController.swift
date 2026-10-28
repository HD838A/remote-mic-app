import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Power acknowledgements have a hard deadline; this feature never vetoes sleep.
/// IOKit willSleep starts isolation. Full wake plus an awake display permits recovery.
final class RemoteSleepConnectionController {
    private var policy = RemoteSleepConnectionPolicy()
    private var adapter: (any RemoteSleepConnectionTransport)?
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pendingAcknowledgement: Int?
    private var deadline: DispatchWorkItem?
    private var wakeTimer: Timer?
    var makeAdapter: () -> any RemoteSleepConnectionTransport = { RemoteSleepConnectionAdapter() }
    var isSupported: () -> Bool = { RemoteSleepConnectionAdapter.isSupported }
    var acknowledge: ((Int) -> Void)?
    var isolationTimeout: TimeInterval = 2
    var selectedTarget: () -> UUID? = { nil }
    var setProtectedTarget: (UUID?) -> Void = { _ in }
    var onStatus: (String) -> Void = { _ in }
    var log: (String) -> Void = { _ in }

    func start() {
        guard root == 0 else { return }
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port,
            { context, _, message, argument in
                guard let context else { return }
                let owner = Unmanaged<RemoteSleepConnectionController>.fromOpaque(context).takeUnretainedValue()
                owner.handle(message, argument: argument)
            }, &notifier)
        if let port, root != 0 {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        }
        if root == 0 { onStatus("sleep_connection.status.unavailable") }
    }

    func configurationChanged() {
        // Disabling/removing/changing the selected device must release the old target.
        if let target = policy.target, selectedTarget() != target { release(reason: "configuration_changed") }
        if selectedTarget() != nil && adapter == nil { adapter = makeAdapter() }
    }

    func stop() {
        release(reason: "app_stop")
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if root != 0 { IOServiceClose(root); root = 0 }
        adapter = nil
    }

    func handle(_ message: natural_t, argument: UnsafeMutableRawPointer?) {
        switch message {
        case 0xe0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(root, Int(bitPattern: argument))
        case 0xe0000280: // kIOMessageSystemWillSleep
            wakeTimer?.invalidate()
            wakeTimer = nil
            acknowledgeSleep()
            pendingAcknowledgement = Int(bitPattern: argument)
            guard policy.beginSleep(target: selectedTarget()) else { acknowledgeSleep(); return }
            let operation = policy.operation
            setProtectedTarget(policy.target)
            guard isSupported(), let target = policy.target else {
                finishIsolation(operation: operation, success: false, reason: "unsupported")
                return
            }
            log("SLEEP CONNECTION operation_id=\(operation) phase=started result=requested")
            onStatus("sleep_connection.status.isolating")
            if adapter == nil { adapter = makeAdapter() }
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishIsolation(operation: operation, success: false, reason: "timed_out")
            }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + isolationTimeout, execute: timeout)
            adapter?.isolate(target) { [weak self] success in
                self?.finishIsolation(operation: operation, success: success,
                    reason: success ? "session_disconnected" : "connection_failed")
            }
        case 0xe0000300: // kIOMessageSystemHasPoweredOn; never sufficient by itself.
            policy.didWake()
            checkInteractiveWake()
            if policy.target != nil {
                wakeTimer?.invalidate()
                wakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.checkInteractiveWake()
                }
            }
        case 0xe0000290: // kIOMessageSystemWillNotSleep
            policy.didWake()
            release(reason: "sleep_cancelled")
        default: break
        }
    }

    private func finishIsolation(operation: Int, success: Bool, reason: String) {
        guard policy.operation == operation, policy.phase == .isolating else { return }
        policy.finishIsolation(operation: operation, succeeded: success)
        if !success { adapter?.cancelPendingIsolation() }
        deadline?.cancel()
        deadline = nil
        onStatus(success ? "sleep_connection.status.isolated" : "sleep_connection.status.failed")
        log("SLEEP CONNECTION operation_id=\(operation) phase=completed result=\(success ? "session_disconnected" : "failed") reason=\(reason) physical_link=unverified")
        acknowledgeSleep()
    }

    private func acknowledgeSleep() {
        guard let token = pendingAcknowledgement else { return }
        pendingAcknowledgement = nil
        if let acknowledge { acknowledge(token) }
        else {
            let result = IOAllowPowerChange(root, token)
            log("SLEEP CONNECTION phase=sleep_ack result=\(result == kIOReturnSuccess ? "accepted" : "failed")")
        }
    }

    private func checkInteractiveWake() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
        let displayAwake = result == .success && displays.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let sessionActive = session?[kCGSessionOnConsoleKey as String] as? Bool == true
        guard policy.systemAwake, displayAwake, sessionActive, policy.target != nil else { return }
        release(reason: "interactive_wake")
    }

    private func release(reason: String) {
        acknowledgeSleep()
        deadline?.cancel()
        deadline = nil
        wakeTimer?.invalidate()
        wakeTimer = nil
        guard policy.release() != nil else { return }
        adapter?.restore()
        setProtectedTarget(nil)
        onStatus("sleep_connection.status.recovering")
        log("SLEEP CONNECTION phase=released result=recovery_requested reason=\(reason)")
    }
}
