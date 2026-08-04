import Foundation
import IOKit.hid
import IOKit.hidsystem

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.deviceDidMatch(result: result, device: device)
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.deviceDidRemove(device: device)
}

private func hidInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: report, count: reportLength)
    monitor.handleReport(reportID: reportID, data: data)
}

final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let eventSuppressor = KeyboardEventSuppressor()
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: DispatchSourceTimer] = [:]
    private var gestureRecognizer = RemoteButtonGestureRecognizer()
    private var doubleClickTimers: [RemoteButton: DispatchSourceTimer] = [:]
    private var longPressTimers: [RemoteButton: DispatchSourceTimer] = [:]
    private var permissionMonitor: DispatchSourceTimer?
    private(set) var status = LocalizedMessage("button_mapping.status.disabled")
    var onStatus: ((LocalizedMessage) -> Void)?
    var onActiveButtons: ((Set<RemoteButton>) -> Void)?
    var onButtonPressed: ((RemoteButton) -> Void)?
    var onInternalAction: ((ButtonAction) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    static var isInputMonitoringGranted: Bool {
        inputMonitoringAccess == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start(powerKeySuppressed: Bool) {
        stop()
        guard settings.customMappingEnabled else {
            updateStatus(LocalizedMessage("button_mapping.status.system_managed"))
            return
        }
        let inputGranted = Self.isInputMonitoringGranted
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            mappingEnabled: settings.customMappingEnabled,
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted,
            powerKeySuppressed: powerKeySuppressed
        ) else {
            if !inputGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.input_monitoring_required"))
            } else if !accessibilityGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.accessibility_required"))
            } else {
                updateStatus(LocalizedMessage("button_mapping.error.power_suppression_failed"))
                AppLogger.shared.write("HID START rejected power_suppressed=false")
            }
            return
        }

        let suppressionReady = eventSuppressor.start()
        AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: 0x2717,
            kIOHIDProductIDKey as String: 0x32B8,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, hidInputReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            eventSuppressor.stop()
            updateStatus(LocalizedMessage("button_mapping.error.remote_read_failed", arguments: [String(result)]))
            return
        }
        self.manager = manager
        startPermissionMonitor()
        updateStatus(LocalizedMessage("button_mapping.status.waiting_for_device"))
        AppLogger.shared.write("HID START mode=adaptive")
    }

    func stop() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        resetGestureRecognition()
        activeUsages.removeAll()
        onActiveButtons?([])
        eventSuppressor.stop()
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            activeDeviceIsSeized = false
        }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            updateStatus(LocalizedMessage("button_mapping.error.device_open_failed"))
            return
        }
        guard activeDevice == nil else { return }
        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        if seizeResult == kIOReturnSuccess {
            activeDevice = device
            activeDeviceIsSeized = true
            updateStatus(LocalizedMessage("button_mapping.status.connected"))
            AppLogger.shared.write("HID CONNECTED mode=seized")
            return
        }

        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            updateStatus(LocalizedMessage("button_mapping.error.device_read_failed", arguments: [String(monitorResult)]))
            AppLogger.shared.write(
                "HID DEVICE OPEN FAILED seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return
        }

        activeDevice = device
        activeDeviceIsSeized = false
        updateStatus(
            LocalizedMessage(
                eventSuppressor.isRunning
                    ? "button_mapping.status.connected_fallback"
                    : "button_mapping.status.connected_system_actions_may_remain"
            )
        )
        AppLogger.shared.write("HID CONNECTED mode=monitored seize_error=\(seizeResult)")
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        self.activeDevice = nil
        activeDeviceIsSeized = false
        activeUsages.removeAll()
        onActiveButtons?([])
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        resetGestureRecognition()
        updateStatus(LocalizedMessage("button_mapping.status.disconnected"))
        AppLogger.shared.write("HID DISCONNECTED")
    }

    fileprivate func handleReport(reportID: UInt32, data: Data) {
        guard manager != nil, settings.customMappingEnabled else { return }
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return
        }
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            return
        }
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        activeUsages = usages
        onActiveButtons?(RemoteButton.buttons(for: usages))

        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            if !activeDeviceIsSeized {
                eventSuppressor.arm(button: button, edge: .down)
            }
            onButtonPressed?(button)

            let recognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick
            ).action != .disabled
            let recognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress
            ).action != .disabled
            if recognizesDoubleClick || recognizesLongPress || gestureRecognizer.isTracking(button) {
                let commands = gestureRecognizer.press(
                    button,
                    recognizesDoubleClick: recognizesDoubleClick,
                    recognizesLongPress: recognizesLongPress
                )
                guard processGestureCommands(commands) else { return }
            } else {
                guard performConfiguredAction(for: button, trigger: .singleClick) else { return }
                startRepeatIfNeeded(
                    usage: usage,
                    button: button,
                    action: settings.action(for: button)
                )
            }
        }

        for usage in released {
            if !activeDeviceIsSeized, let button = RemoteButton.usageMap[usage] {
                eventSuppressor.arm(button: button, edge: .up)
            }
            repeatTimers.removeValue(forKey: usage)?.cancel()
            if let button = RemoteButton.usageMap[usage] {
                guard processGestureCommands(gestureRecognizer.release(button)) else { return }
            }
        }
    }

    private func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction
    ) {
        let repeatable: Set<RemoteButton> = [
            .up, .down, .left, .right, .back, .volumeUp, .volumeDown,
        ]
        guard
            repeatable.contains(button),
            !settings.hasSecondaryAction(for: button),
            action != .disabled,
            action.allowsRepeat
        else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = button == .back ? .milliseconds(50) : .milliseconds(100)
        timer.schedule(deadline: .now() + .milliseconds(350), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeUsages.contains(usage) else { return }
            if self.settings.hasSecondaryAction(for: button) {
                self.repeatTimers.removeValue(forKey: usage)?.cancel()
                return
            }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            if !self.activeDeviceIsSeized {
                self.eventSuppressor.arm(button: button, edge: .down)
            }
            if !KeyboardInjector.send(action, shortcut: self.settings.shortcut(for: button)) {
                self.releaseForRevokedPermissions()
            }
        }
        repeatTimers[usage] = timer
        timer.resume()
    }

    private func processGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command]
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleDoubleClickTimeout(for: button)
            case let .cancelDoubleClickTimeout(button):
                doubleClickTimers.removeValue(forKey: button)?.cancel()
            case let .scheduleLongPressTimeout(button):
                scheduleLongPressTimeout(for: button)
            case let .cancelLongPressTimeout(button):
                longPressTimers.removeValue(forKey: button)?.cancel()
            case let .trigger(button, trigger):
                guard performConfiguredAction(for: button, trigger: trigger) else { return false }
            }
        }
        return true
    }

    private func scheduleDoubleClickTimeout(for button: RemoteButton) {
        doubleClickTimers.removeValue(forKey: button)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.doubleClickTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.doubleClickTimedOut(button))
        }
        doubleClickTimers[button] = timer
        timer.resume()
    }

    private func scheduleLongPressTimeout(for button: RemoteButton) {
        longPressTimers.removeValue(forKey: button)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(550))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.longPressTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.longPressTimedOut(button))
        }
        longPressTimers[button] = timer
        timer.resume()
    }

    private func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return false
        }
        let configured = settings.configuredAction(for: button, trigger: trigger)
        if configured.action.isAppInternal {
            onInternalAction?(configured.action)
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
            )
            return true
        }
        guard KeyboardInjector.send(configured.action, shortcut: configured.shortcut) else {
            stop()
            updateStatus(LocalizedMessage("button_mapping.permission.accessibility_expired"))
            return false
        }
        AppLogger.shared.write(
            "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
        )
        return true
    }

    private func resetGestureRecognition() {
        doubleClickTimers.values.forEach { $0.cancel() }
        doubleClickTimers.removeAll()
        longPressTimers.values.forEach { $0.cancel() }
        longPressTimers.removeAll()
        gestureRecognizer.reset()
    }

    private func runtimePermissionsAreValid() -> Bool {
        Self.inputMonitoringAccess == kIOHIDAccessTypeGranted &&
            KeyboardInjector.isAccessibilityTrusted
    }

    private func startPermissionMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.manager != nil else { return }
            if !self.runtimePermissionsAreValid() {
                self.releaseForRevokedPermissions()
            }
        }
        permissionMonitor = timer
        timer.resume()
    }

    private func releaseForRevokedPermissions() {
        stop()
        updateStatus(LocalizedMessage("button_mapping.permission.system_expired"))
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    private func updateStatus(_ value: LocalizedMessage) {
        status = value
        onStatus?(value)
    }
}
