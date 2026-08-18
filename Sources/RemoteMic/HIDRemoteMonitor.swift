import AppKit
import CryptoKit
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
    guard let context, let sender, result == kIOReturnSuccess, reportLength > 0 else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let data = Data(bytes: report, count: reportLength)
    monitor.handleReport(from: device, reportID: reportID, data: data)
}

final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let eventSuppressor: KeyboardEventSuppressor
    private let ownsEventSuppressor: Bool
    private let scheduler: HIDRemoteScheduling
    private let runtimePermissions: () -> Bool
    private let actionPerformer: (RemoteButton, ButtonTrigger, ConfiguredButtonAction) -> Bool
    private let globalControlPerformer: (UUID?, RemoteButton) -> Bool?
    private let overrideActionPerformer: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let hasOverrideBinding: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let frontmostBundleIdentifier: () -> String?
    private let targetFingerprint: String?
    private let excludedFingerprints: () -> Set<String>
    private var allowedLocationIDs: Set<UInt32>?
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private(set) var deviceFingerprint: String?
    private(set) var profileID: UUID?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var nativePassthroughUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    private var nonRepeatablePressedButtons = Set<RemoteButton>()
    private var nonRepeatableReleaseTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var gestureRecognizer = RemoteButtonGestureRecognizer()
    private var doubleClickTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var longPressTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var permissionMonitor: HIDRemoteScheduledTask?
    private(set) var status = LocalizedMessage("button_mapping.status.disabled")
    var onStatus: ((LocalizedMessage) -> Void)?
    var onActiveButtons: ((UUID?, Set<RemoteButton>) -> Void)?
    var onButtonPressed: ((UUID?, String, RemoteButton) -> (profileID: UUID, shouldPerformAction: Bool)?)?
    var onInternalAction: ((UUID?, ButtonAction) -> Void)?

    init(
        settings: AppSettings,
        profileID: UUID? = nil,
        targetFingerprint: String? = nil,
        excludedFingerprints: @escaping () -> Set<String> = { [] },
        eventSuppressor: KeyboardEventSuppressor = KeyboardEventSuppressor(),
        ownsEventSuppressor: Bool = true,
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        runtimePermissions: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        },
        actionPerformer: ((
            RemoteButton,
            ButtonTrigger,
            ConfiguredButtonAction
        ) -> Bool)? = nil,
        globalControlPerformer: @escaping (UUID?, RemoteButton) -> Bool? = {
            _, _ in nil
        },
        overrideActionPerformer: @escaping (UUID?, RemoteButton, ButtonTrigger) -> Bool = {
            _, _, _ in false
        },
        hasOverrideBinding: @escaping (UUID?, RemoteButton, ButtonTrigger) -> Bool = {
            _, _, _ in false
        },
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.settings = settings
        self.profileID = profileID
        self.targetFingerprint = targetFingerprint
        self.excludedFingerprints = excludedFingerprints
        self.eventSuppressor = eventSuppressor
        self.ownsEventSuppressor = ownsEventSuppressor
        self.scheduler = scheduler
        self.runtimePermissions = runtimePermissions
        self.actionPerformer = actionPerformer ?? { _, _, configured in
            KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: settings.customApplicationProfile(
                    id: configured.applicationProfileID
                )
            )
        }
        self.globalControlPerformer = globalControlPerformer
        self.overrideActionPerformer = overrideActionPerformer
        self.hasOverrideBinding = hasOverrideBinding
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    func assignProfileID(_ profileID: UUID) {
        self.profileID = profileID
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

    func start(powerKeySuppressed: Bool, allowedLocationIDs: Set<UInt32>? = nil) {
        stop()
        self.allowedLocationIDs = allowedLocationIDs
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
        resetInputState()
        if ownsEventSuppressor { eventSuppressor.stop() }
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
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
        guard Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            AppLogger.shared.write("HID DEVICE rejected unsafe_location")
            return
        }
        guard let fingerprint = Self.fingerprint(for: device) else { return }
        if profileID == nil, targetFingerprint == nil, deviceFingerprint == nil {
            return
        }
        guard activeDevice == nil,
              targetFingerprint == nil || targetFingerprint == fingerprint,
              !excludedFingerprints().contains(fingerprint)
        else { return }
        _ = activateDevice(device, fingerprint: fingerprint, allowManagerFallback: false)
    }

    @discardableResult
    private func activateDevice(
        _ device: IOHIDDevice,
        fingerprint: String,
        allowManagerFallback: Bool
    ) -> Bool {
        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        if seizeResult == kIOReturnSuccess {
            activeDevice = device
            deviceFingerprint = fingerprint
            activeDeviceIsSeized = true
            updateStatus(LocalizedMessage("button_mapping.status.connected"))
            AppLogger.shared.write("HID CONNECTED mode=seized")
            return true
        }

        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess || allowManagerFallback else {
            updateStatus(LocalizedMessage("button_mapping.error.device_read_failed", arguments: [String(monitorResult)]))
            AppLogger.shared.write(
                "HID DEVICE OPEN FAILED seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return false
        }

        activeDevice = device
        deviceFingerprint = fingerprint
        activeDeviceIsSeized = false
        updateStatus(
            LocalizedMessage(
                eventSuppressor.isRunning
                    ? "button_mapping.status.connected_fallback"
                    : "button_mapping.status.connected_system_actions_may_remain"
            )
        )
        if monitorResult == kIOReturnSuccess {
            AppLogger.shared.write("HID CONNECTED mode=monitored seize_error=\(seizeResult)")
        } else {
            AppLogger.shared.write(
                "HID CONNECTED mode=manager_report seize_error=\(seizeResult) monitor_error=\(monitorResult)"
            )
        }
        return true
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        self.activeDevice = nil
        deviceFingerprint = nil
        resetInputState()
        activeDeviceIsSeized = false
        updateStatus(LocalizedMessage("button_mapping.status.disconnected"))
        AppLogger.shared.write("HID DISCONNECTED")
    }

    fileprivate func handleReport(from device: IOHIDDevice, reportID: UInt32, data: Data) {
        guard manager != nil, settings.customMappingEnabled else { return }
        guard Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else { return }
        guard let fingerprint = Self.resolvedFingerprintForReport(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) else { return }
        if deviceFingerprint == nil {
            guard activateDevice(
                device,
                fingerprint: fingerprint,
                allowManagerFallback: true
            ) else { return }
        }
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return
        }
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            return
        }
        process(usages: usages)
    }

    func connectSimulatedDevice(
        fingerprint: String,
        profileID: UUID,
        isSeized: Bool = true
    ) {
        resetInputState()
        deviceFingerprint = fingerprint
        self.profileID = profileID
        activeDeviceIsSeized = isSeized
    }

    func handleSimulatedReport(reportID: UInt32, data: Data) {
        guard settings.customMappingEnabled, runtimePermissionsAreValid() else { return }
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            return
        }
        process(usages: usages)
    }

    func disconnectSimulatedDevice() {
        deviceFingerprint = nil
        resetInputState()
        activeDeviceIsSeized = false
    }

    private func process(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        activeUsages = usages
        onActiveButtons?(profileID, RemoteButton.buttons(for: usages))

        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            let preflightProfileID = profileID
            let preflightRecognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: preflightProfileID
            ).action != .disabled || hasOverrideBinding(
                preflightProfileID,
                button,
                .doubleClick
            )
            let preflightRecognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: preflightProfileID
            ).action != .disabled || hasOverrideBinding(
                preflightProfileID,
                button,
                .longPress
            )
            let preflightAction = settings.action(for: button, profileID: preflightProfileID)
            let preflightHasOverrideSingleClick = hasOverrideBinding(
                preflightProfileID,
                button,
                .singleClick
            )
            let usesNativePassthrough = preflightProfileID != nil && shouldUseNativePassthrough(
                button: button,
                action: preflightAction,
                hasOverrideSingleClick: preflightHasOverrideSingleClick,
                recognizesDoubleClick: preflightRecognizesDoubleClick,
                recognizesLongPress: preflightRecognizesLongPress
            )
            if !activeDeviceIsSeized, !usesNativePassthrough {
                eventSuppressor.arm(button: button, edge: .down)
            }
            var shouldPerformAction = true
            if let deviceFingerprint,
               let routing = onButtonPressed?(profileID, deviceFingerprint, button) {
                if profileID == nil {
                    profileID = routing.profileID
                }
                shouldPerformAction = routing.shouldPerformAction
            }
            if let handled = globalControlPerformer(profileID, button) {
                guard handled else {
                    stop()
                    updateStatus(LocalizedMessage("button_mapping.permission.accessibility_expired"))
                    return
                }
                AppLogger.shared.write(
                    "HID BUTTON button=\(button.rawValue) action=global_app_switcher"
                )
                continue
            }
            guard let profileID, shouldPerformAction else {
                if !activeDeviceIsSeized, usesNativePassthrough {
                    eventSuppressor.arm(button: button, edge: .down)
                }
                continue
            }

            let recognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: profileID
            ).action != .disabled || hasOverrideBinding(profileID, button, .doubleClick)
            let recognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: profileID
            ).action != .disabled || hasOverrideBinding(profileID, button, .longPress)
            let action = settings.action(for: button, profileID: profileID)
            if usesNativePassthrough {
                nativePassthroughUsages.insert(usage)
                AppLogger.shared.write(
                    "HID NATIVE PASSTHROUGH button=\(button.rawValue) action=\(action.rawValue)"
                )
                continue
            }
            if recognizesDoubleClick || recognizesLongPress || gestureRecognizer.isTracking(button) {
                let commands = gestureRecognizer.press(
                    button,
                    recognizesDoubleClick: recognizesDoubleClick,
                    recognizesLongPress: recognizesLongPress
                )
                guard processGestureCommands(commands) else { return }
            } else {
                guard shouldAcceptRawPress(
                    button: button,
                    action: action,
                    frontmostBundleIdentifier: frontmostBundleIdentifier()
                ) else { continue }
                guard performConfiguredAction(for: button, trigger: .singleClick) else { return }
                startRepeatIfNeeded(
                    usage: usage,
                    button: button,
                    action: action
                )
            }
        }

        for usage in released {
            let usedNativePassthrough = nativePassthroughUsages.remove(usage) != nil
            if !activeDeviceIsSeized, !usedNativePassthrough,
               let button = RemoteButton.usageMap[usage] {
                eventSuppressor.arm(button: button, edge: .up)
            }
            repeatTimers.removeValue(forKey: usage)?.cancel()
            if let button = RemoteButton.usageMap[usage] {
                scheduleNonRepeatableRelease(for: button)
                guard processGestureCommands(gestureRecognizer.release(button)) else { return }
            }
        }
    }

    static func acceptsReport(reportingFingerprint: String?, activeFingerprint: String?) -> Bool {
        guard let reportingFingerprint, let activeFingerprint else { return false }
        return reportingFingerprint == activeFingerprint
    }

    static func resolvedFingerprintForReport(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> String? {
        guard let reportingFingerprint else { return nil }
        if let activeFingerprint {
            return reportingFingerprint == activeFingerprint ? activeFingerprint : nil
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else { return nil }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint ? targetFingerprint : nil
        }
        return reportingFingerprint
    }

    func shouldAcceptRawPress(
        button: RemoteButton,
        action: ButtonAction,
        frontmostBundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) -> Bool {
        guard !Self.shouldRepeat(
            action: action,
            frontmostBundleIdentifier: frontmostBundleIdentifier
        ) else { return true }
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        return nonRepeatablePressedButtons.insert(button).inserted
    }

    static func shouldRepeat(
        action: ButtonAction,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard action.allowsRepeat else { return false }
        guard frontmostBundleIdentifier == PresetApplication.remoteMic.bundleIdentifier else {
            return true
        }
        return ![.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .deleteBackward].contains(action)
    }

    private func shouldUseNativePassthrough(
        button: RemoteButton,
        action: ButtonAction,
        hasOverrideSingleClick: Bool,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> Bool {
        guard !activeDeviceIsSeized,
              !hasOverrideSingleClick,
              !recognizesDoubleClick,
              !recognizesLongPress,
              frontmostBundleIdentifier() != PresetApplication.remoteMic.bundleIdentifier
        else { return false }
        return (button == .left && action == .arrowLeft) ||
            (button == .right && action == .arrowRight)
    }

    private func scheduleNonRepeatableRelease(for button: RemoteButton) {
        guard nonRepeatablePressedButtons.contains(button) else { return }
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.stableReleaseMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            self?.finishNonRepeatablePress(button)
        }
        nonRepeatableReleaseTimers[button] = timer
    }

    func finishNonRepeatablePress(_ button: RemoteButton) {
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        nonRepeatablePressedButtons.remove(button)
    }

    private func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction
    ) {
        guard let interval = HIDRemoteTiming.repeatIntervalMilliseconds(for: button) else { return }
        guard
            !settings.hasSecondaryAction(for: button, profileID: profileID),
            action != .disabled,
            Self.shouldRepeat(
                action: action,
                frontmostBundleIdentifier: frontmostBundleIdentifier()
            )
        else { return }

        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.repeatStartMilliseconds,
            repeatingEveryMilliseconds: interval
        ) { [weak self] in
            guard let self, self.activeUsages.contains(usage) else { return }
            if self.settings.hasSecondaryAction(for: button, profileID: self.profileID) ||
                !Self.shouldRepeat(
                    action: action,
                    frontmostBundleIdentifier: self.frontmostBundleIdentifier()
                ) {
                self.repeatTimers.removeValue(forKey: usage)?.cancel()
                return
            }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            let configured = ConfiguredButtonAction(
                action: action,
                shortcut: self.settings.shortcut(for: button, profileID: self.profileID)
            )
            if !self.actionPerformer(button, .singleClick, configured) {
                self.releaseForRevokedPermissions()
            }
        }
        repeatTimers[usage] = timer
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
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.doubleClickMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.doubleClickTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.doubleClickTimedOut(button))
        }
        doubleClickTimers[button] = timer
    }

    private func scheduleLongPressTimeout(for button: RemoteButton) {
        longPressTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.longPressMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.longPressTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.longPressTimedOut(button))
        }
        longPressTimers[button] = timer
    }

    private func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return false
        }
        if overrideActionPerformer(profileID, button, trigger) {
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=private_feature"
            )
            return true
        }
        let configured = settings.configuredAction(
            for: button,
            trigger: trigger,
            profileID: profileID
        )
        if configured.action.isAppInternal {
            onInternalAction?(profileID, configured.action)
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
            )
            return true
        }
        guard actionPerformer(button, trigger, configured) else {
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

    private func resetInputState() {
        if !activeDeviceIsSeized {
            for usage in activeUsages {
                if let button = RemoteButton.usageMap[usage] {
                    eventSuppressor.arm(button: button, edge: .up)
                }
            }
        }
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        nativePassthroughUsages.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        resetGestureRecognition()
        activeUsages.removeAll()
        onActiveButtons?(profileID, [])
    }

    private func runtimePermissionsAreValid() -> Bool {
        runtimePermissions()
    }

    private func startPermissionMonitor() {
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.permissionPollMilliseconds
        ) { [weak self] in
            guard let self, self.manager != nil else { return }
            if !self.runtimePermissionsAreValid() {
                self.releaseForRevokedPermissions()
            }
        }
        permissionMonitor = timer
    }

    private func releaseForRevokedPermissions() {
        stop()
        updateStatus(LocalizedMessage("button_mapping.permission.system_expired"))
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    static func fingerprint(for device: IOHIDDevice) -> String? {
        let keys = ["PhysicalDeviceUniqueID", kIOHIDSerialNumberKey, "DeviceAddress"]
        for key in keys {
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? String,
                  !value.isEmpty
            else { continue }
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            return nil
        }
        return SHA256.hash(data: Data("location:\(location.uint64Value)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func locationID(for device: IOHIDDevice) -> UInt32? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    static func isLocationAllowed(
        locationID: UInt32?,
        allowedLocationIDs: Set<UInt32>?
    ) -> Bool {
        guard let allowedLocationIDs else { return true }
        guard let locationID else { return false }
        return allowedLocationIDs.contains(locationID)
    }

    private func updateStatus(_ value: LocalizedMessage) {
        status = value
        onStatus?(value)
    }
}
