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
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    guard result == kIOReturnSuccess else {
        monitor.reportCallbackRejected(reason: "io_error", result: result, reportLength: reportLength)
        return
    }
    guard let sender else {
        monitor.reportCallbackRejected(reason: "missing_sender", result: result, reportLength: reportLength)
        return
    }
    guard reportLength > 0 else {
        monitor.reportCallbackRejected(reason: "empty_report", result: result, reportLength: reportLength)
        return
    }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let data = Data(bytes: report, count: reportLength)
    monitor.handleReport(from: device, reportID: reportID, data: data)
}

enum HIDReportRoutingDecision: Equatable {
    case accepted(String)
    case rejected(String)
}

enum HIDDeviceMatchDecision: Equatable {
    case activate(String)
    case probe
    case rejected(String)
}

final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let eventSuppressor: KeyboardEventSuppressor
    private let ownsEventSuppressor: Bool
    private let scheduler: HIDRemoteScheduling
    private let runtimePermissions: () -> Bool
    private let actionPerformer: (RemoteButton, ButtonTrigger, ConfiguredButtonAction) -> Bool
    private let appSwitcherSession: KeyboardInjector.AppSwitcherSession
    private let overrideActionPerformer: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let hasOverrideBinding: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let frontmostBundleIdentifier: () -> String?
    private let diagnosticLogger: (String) -> Void
    private let karabinerElementsInstalled: () -> Bool
    private let targetFingerprint: String?
    private let excludedFingerprints: () -> Set<String>
    private var allowedLocationIDs: Set<UInt32>?
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var probedDevices: [IOHIDDevice] = []
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
    private var discoveryWatchdog: HIDRemoteScheduledTask?
    private var discoveryRecoveryAttempt = 0
    private var powerKeySuppressed = false
    private var appSwitcherTimeout: HIDRemoteScheduledTask?
    private var appSwitcherFrontmostMonitor: HIDRemoteScheduledTask?
    private var appSwitcherConfirmationProbe: HIDRemoteScheduledTask?
    private var appSwitcherOriginBundleIdentifier: String?
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
        overrideActionPerformer: @escaping (UUID?, RemoteButton, ButtonTrigger) -> Bool = {
            _, _, _ in false
        },
        hasOverrideBinding: @escaping (UUID?, RemoteButton, ButtonTrigger) -> Bool = {
            _, _, _ in false
        },
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        diagnosticLogger: @escaping (String) -> Void = AppLogger.shared.write,
        karabinerElementsInstalled: @escaping () -> Bool = {
            HIDRemoteMonitor.isKarabinerElementsInstalled()
        },
        appSwitcherKeyStatePoster: @escaping KeyboardInjector.KeyStatePoster = KeyboardInjector.postKeyState
    ) {
        self.settings = settings
        self.profileID = profileID
        self.targetFingerprint = targetFingerprint
        self.excludedFingerprints = excludedFingerprints
        self.eventSuppressor = eventSuppressor
        self.ownsEventSuppressor = ownsEventSuppressor
        self.scheduler = scheduler
        self.runtimePermissions = runtimePermissions
        self.appSwitcherSession = KeyboardInjector.AppSwitcherSession(
            keyStatePoster: appSwitcherKeyStatePoster
        )
        self.actionPerformer = actionPerformer ?? { _, _, configured in
            KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: settings.customApplicationProfile(
                    id: configured.applicationProfileID
                )
            )
        }
        self.overrideActionPerformer = overrideActionPerformer
        self.hasOverrideBinding = hasOverrideBinding
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.diagnosticLogger = diagnosticLogger
        self.karabinerElementsInstalled = karabinerElementsInstalled
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
        self.powerKeySuppressed = powerKeySuppressed
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
            let karabinerInstalled = karabinerElementsInstalled()
            if let exclusiveMessageKey = Self.deviceOpenFailureMessageKey(
                result: result,
                karabinerElementsInstalled: karabinerInstalled
            ) {
                updateStatus(LocalizedMessage(exclusiveMessageKey))
                AppLogger.shared.write(
                    "HID MANAGER OPEN BLOCKED reason=exclusive_access " +
                        "karabiner_installed=\(karabinerInstalled) result=\(result)"
                )
            } else {
                updateStatus(LocalizedMessage(
                    "button_mapping.error.remote_read_failed",
                    arguments: [String(result)]
                ))
            }
            return
        }
        self.manager = manager
        startPermissionMonitor()
        scheduleDiscoveryWatchdog()
        updateStatus(LocalizedMessage("button_mapping.status.waiting_for_device"))
        AppLogger.shared.write("HID START mode=adaptive")
    }

    func stop() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        discoveryRecoveryAttempt = 0
        resetInputState()
        if ownsEventSuppressor { eventSuppressor.stop() }
        probedDevices.forEach {
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
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
            diagnosticLogger("HID DEVICE rejected reason=match_error result=\(result)")
            updateStatus(LocalizedMessage("button_mapping.error.device_open_failed"))
            return
        }
        guard Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID DEVICE rejected reason=unsafe_location")
            return
        }
        switch Self.deviceMatchDecision(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) {
        case let .activate(fingerprint):
            _ = activateDevice(device, fingerprint: fingerprint, allowManagerFallback: false)
        case .probe:
            probeDevice(device)
        case let .rejected(reason):
            diagnosticLogger("HID DEVICE rejected reason=\(reason)")
        }
    }

    private func probeDevice(_ device: IOHIDDevice) {
        guard !probedDevices.contains(where: { CFEqual($0, device) }) else { return }
        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            let karabinerInstalled = karabinerElementsInstalled()
            updateStatus(Self.deviceOpenFailureMessage(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ))
            if Self.deviceOpenFailureMessageKey(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ) != nil {
                AppLogger.shared.write(
                    "HID DEVICE PROBE BLOCKED reason=exclusive_access " +
                        "karabiner_installed=\(karabinerInstalled) monitor=\(monitorResult)"
                )
            }
            diagnosticLogger("HID DEVICE PROBE FAILED monitor=\(monitorResult)")
            return
        }
        probedDevices.append(device)
        diagnosticLogger("HID DEVICE probing mode=monitored")
    }

    private func promoteProbedDevice(_ device: IOHIDDevice, fingerprint: String) -> Bool {
        guard let selectedIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return false
        }
        let selectedDevice = probedDevices.remove(at: selectedIndex)
        probedDevices.forEach {
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
        activeDevice = selectedDevice
        deviceFingerprint = fingerprint
        activeDeviceIsSeized = false
        updateStatus(LocalizedMessage(
            eventSuppressor.isRunning
                ? "button_mapping.status.connected_fallback"
                : "button_mapping.status.connected_system_actions_may_remain"
        ))
        AppLogger.shared.write("HID CONNECTED mode=probed")
        return true
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
        let karabinerInstalled = karabinerElementsInstalled()
        if let exclusiveMessageKey = Self.deviceOpenFailureMessageKey(
            result: monitorResult,
            karabinerElementsInstalled: karabinerInstalled
        ) {
            updateStatus(LocalizedMessage(exclusiveMessageKey))
            AppLogger.shared.write(
                "HID DEVICE OPEN BLOCKED reason=exclusive_access " +
                    "karabiner_installed=\(karabinerInstalled) " +
                    "seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return false
        }
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
            AppLogger.shared.write(
                "HID CONNECTED mode=monitored " +
                    AppLogger.errorFields(
                        domain: "io_return",
                        code: Int(seizeResult),
                        fieldPrefix: "seize_error"
                    )
            )
        } else {
            AppLogger.shared.write(
                "HID CONNECTED mode=manager_report " +
                    AppLogger.errorFields(
                        domain: "io_return",
                        code: Int(seizeResult),
                        fieldPrefix: "seize_error"
                    ) + " " +
                    AppLogger.errorFields(
                        domain: "io_return",
                        code: Int(monitorResult),
                        fieldPrefix: "monitor_error"
                    )
            )
        }
        return true
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        if let activeDevice, CFEqual(activeDevice, device) {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
            resetInputState()
            activeDeviceIsSeized = false
            updateStatus(LocalizedMessage("button_mapping.status.disconnected"))
            AppLogger.shared.write("HID DISCONNECTED")
            return
        }
        guard let probeIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return
        }
        let probedDevice = probedDevices.remove(at: probeIndex)
        IOHIDDeviceClose(probedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        diagnosticLogger("HID DEVICE probe_removed")
    }

    fileprivate func handleReport(from device: IOHIDDevice, reportID: UInt32, data: Data) {
        guard manager != nil else {
            diagnosticLogger("HID REPORT rejected reason=monitor_inactive")
            return
        }
        guard settings.customMappingEnabled else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled")
            return
        }
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
        discoveryRecoveryAttempt = 0
        guard Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID REPORT rejected reason=unsafe_location")
            return
        }
        let routing = Self.reportRoutingDecision(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        )
        let fingerprint: String
        switch routing {
        case let .accepted(value):
            fingerprint = value
        case let .rejected(reason):
            diagnosticLogger("HID REPORT rejected reason=\(reason)")
            return
        }
        let discoveryUsages: Set<UInt16>?
        if deviceFingerprint == nil, targetFingerprint == nil {
            guard let usages = parsedUsages(reportID: reportID, data: data, source: "device") else {
                return
            }
            guard Self.shouldPromoteDiscoveryReport(usages: usages) else {
                diagnosticLogger(
                    "HID REPORT deferred reason=discovery_no_known_button source=device " +
                        "id=\(reportID) bytes=\(data.count) usage_count=\(usages.count)"
                )
                return
            }
            discoveryUsages = usages
        } else {
            discoveryUsages = nil
        }
        if deviceFingerprint == nil {
            if !promoteProbedDevice(device, fingerprint: fingerprint) {
                guard activateDevice(
                    device,
                    fingerprint: fingerprint,
                    allowManagerFallback: true
                ) else {
                    diagnosticLogger("HID REPORT rejected reason=device_activation_failed")
                    return
                }
            }
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked")
            releaseForRevokedPermissions()
            return
        }
        if let discoveryUsages {
            processParsedReport(
                reportID: reportID,
                data: data,
                source: "device",
                usages: discoveryUsages
            )
        } else {
            parseAndProcess(reportID: reportID, data: data, source: "device")
        }
    }

    fileprivate func reportCallbackRejected(
        reason: String,
        result: IOReturn,
        reportLength: CFIndex
    ) {
        diagnosticLogger(
            "HID REPORT callback_rejected reason=\(reason) result=\(result) " +
                "bytes=\(max(0, reportLength))"
        )
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
        guard settings.customMappingEnabled else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled source=simulated")
            return
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked source=simulated")
            return
        }
        parseAndProcess(reportID: reportID, data: data, source: "simulated")
    }

    private func parseAndProcess(reportID: UInt32, data: Data, source: String) {
        guard let usages = parsedUsages(reportID: reportID, data: data, source: source) else {
            return
        }
        processParsedReport(reportID: reportID, data: data, source: source, usages: usages)
    }

    private func parsedUsages(reportID: UInt32, data: Data, source: String) -> Set<UInt16>? {
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            diagnosticLogger(
                "HID REPORT rejected reason=parse_failed source=\(source) " +
                    "id=\(reportID) bytes=\(data.count)"
            )
            return nil
        }
        return usages
    }

    private func processParsedReport(
        reportID: UInt32,
        data: Data,
        source: String,
        usages: Set<UInt16>
    ) {
        diagnosticLogger(
            "HID REPORT accepted source=\(source) id=\(reportID) bytes=\(data.count) " +
                "usage_count=\(usages.count) buttons=\(Self.buttonList(for: usages))"
        )
        process(usages: usages)
    }

    private func scheduleDiscoveryWatchdog() {
        discoveryWatchdog?.cancel()
        guard manager != nil, activeDevice == nil, discoveryRecoveryAttempt < 2 else { return }
        discoveryWatchdog = scheduler.schedule(
            afterMilliseconds: 2_000,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self,
                  self.manager != nil,
                  self.activeDevice == nil
            else { return }
            self.discoveryWatchdog = nil
            self.discoveryRecoveryAttempt += 1
            let attempt = self.discoveryRecoveryAttempt
            self.diagnosticLogger("HID DISCOVERY watchdog_rebuild attempt=\(attempt)")
            self.start(powerKeySuppressed: self.powerKeySuppressed, allowedLocationIDs: self.allowedLocationIDs)
            self.discoveryRecoveryAttempt = attempt
        }
    }

    func disconnectSimulatedDevice() {
        deviceFingerprint = nil
        resetInputState()
        activeDeviceIsSeized = false
    }

    private func process(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        if !pressed.isEmpty || !released.isEmpty {
            diagnosticLogger(
                "HID EDGE pressed=\(Self.buttonList(for: pressed)) " +
                    "released=\(Self.buttonList(for: released))"
            )
        }
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
            let usesNativePassthrough = preflightProfileID != nil && shouldUseNativePassthrough(
                button: button,
                action: preflightAction,
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
            if appSwitcherSession.isActive,
               handleAppSwitcherControlPress(button) {
                continue
            }
            if appSwitcherSession.isActive, button == .tv {
                diagnosticLogger(
                    "HID GESTURE button=tv trigger=singleClick path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    return
                }
                continue
            }
            if appSwitcherSession.isActive, action == .appSwitcher,
               !recognizesDoubleClick, !recognizesLongPress {
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick " +
                        "path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    return
                }
                continue
            }
            if appSwitcherSession.isActive, action != .appSwitcher {
                finishAppSwitcherLifecycle(
                    reason: "unrelated_button_\(button.rawValue)",
                    confirmed: false
                )
            }
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
                    allowsRapidPress: settings.allowsRapidPress(
                        for: button,
                        profileID: profileID
                    ),
                    frontmostBundleIdentifier: frontmostBundleIdentifier()
                ) else {
                    diagnosticLogger(
                        "HID PRESS rejected button=\(button.rawValue) " +
                            "action=\(action.rawValue) reason=awaiting_stable_release " +
                            "stable_release_ms=\(HIDRemoteTiming.stableReleaseMilliseconds)"
                    )
                    continue
                }
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick path=raw"
                )
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
        switch reportRoutingDecision(
            reportingFingerprint: reportingFingerprint,
            activeFingerprint: activeFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints
        ) {
        case let .accepted(fingerprint): fingerprint
        case .rejected: nil
        }
    }

    static func reportRoutingDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDReportRoutingDecision {
        guard let reportingFingerprint else { return .rejected("fingerprint_unavailable") }
        if let activeFingerprint {
            return reportingFingerprint == activeFingerprint
                ? .accepted(activeFingerprint)
                : .rejected("active_fingerprint_mismatch")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .accepted(targetFingerprint)
                : .rejected("target_fingerprint_mismatch")
        }
        return .accepted(reportingFingerprint)
    }

    static func deviceMatchDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDDeviceMatchDecision {
        guard let reportingFingerprint else {
            return .rejected("fingerprint_unavailable")
        }
        guard activeFingerprint == nil else {
            return .rejected("active_device_exists")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .activate(targetFingerprint)
                : .rejected("target_mismatch")
        }
        return .probe
    }

    static func shouldPromoteDiscoveryReport(usages: Set<UInt16>) -> Bool {
        !RemoteButton.buttons(for: usages).isEmpty
    }

    static func deviceOpenFailureMessageKey(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> String? {
        guard result == kIOReturnExclusiveAccess else { return nil }
        return karabinerElementsInstalled
            ? "button_mapping.error.exclusive_access.karabiner"
            : "button_mapping.error.exclusive_access"
    }

    static func isKarabinerElementsInstalled(
        applicationURL: URL? = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.pqrs.Karabiner-Elements"
        ),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if applicationURL != nil { return true }
        return [
            "/Applications/Karabiner-Elements.app",
            "/Library/Application Support/org.pqrs.Karabiner-Elements",
        ].contains(where: fileExists)
    }

    private static func deviceOpenFailureMessage(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> LocalizedMessage {
        if let key = deviceOpenFailureMessageKey(
            result: result,
            karabinerElementsInstalled: karabinerElementsInstalled
        ) {
            return LocalizedMessage(key)
        }
        return LocalizedMessage(
            "button_mapping.error.device_read_failed",
            arguments: [String(result)]
        )
    }

    private static func buttonList(for usages: Set<UInt16>) -> String {
        let buttons = usages.compactMap { RemoteButton.usageMap[$0]?.rawValue }.sorted()
        return buttons.isEmpty ? "none" : buttons.joined(separator: ",")
    }

    func shouldAcceptRawPress(
        button: RemoteButton,
        action: ButtonAction,
        allowsRapidPress: Bool = false,
        frontmostBundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) -> Bool {
        guard !Self.shouldRepeat(
            action: action,
            frontmostBundleIdentifier: frontmostBundleIdentifier
        ) else { return true }
        guard !allowsRapidPress else {
            finishNonRepeatablePress(button)
            return true
        }
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
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> Bool {
        guard !activeDeviceIsSeized,
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
            action != .appSwitcher,
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
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=\(trigger.rawValue) path=recognizer"
                )
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
        if appSwitcherSession.isActive, button == .tv {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if configured.action == .appSwitcher {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if appSwitcherSession.isActive {
            finishAppSwitcherLifecycle(
                reason: "unrelated_action_\(configured.action.rawValue)",
                confirmed: false
            )
        }
        if configured.action.isAppInternal {
            onInternalAction?(profileID, configured.action)
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
            )
            return true
        }
        guard actionPerformer(button, trigger, configured) else {
            diagnosticLogger(
                "HID ACTION failed button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue)"
            )
            stop()
            updateStatus(LocalizedMessage("button_mapping.permission.accessibility_expired"))
            return false
        }
        AppLogger.shared.write(
            "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
        )
        return true
    }

    private func performAppSwitcherAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        let wasActive = appSwitcherSession.isActive
        if !wasActive {
            appSwitcherOriginBundleIdentifier = frontmostBundleIdentifier()
        }
        let phase = appSwitcherSession.isActive ? "tab" : "start"
        let submitted = appSwitcherSession.trigger()
        diagnosticLogger(
            "HID APP SWITCHER button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "phase=\(phase) success=\(submitted)"
        )
        if submitted, !wasActive {
            startAppSwitcherLifecycle()
        } else if submitted {
            scheduleAppSwitcherTimeout()
        } else if wasActive {
            finishAppSwitcherLifecycle(reason: "tab_failed", confirmed: false)
        } else {
            appSwitcherOriginBundleIdentifier = nil
        }
        return submitted
    }

    private func handleAppSwitcherControlPress(_ button: RemoteButton) -> Bool {
        switch button {
        case .ok:
            let confirmed = appSwitcherSession.confirm()
            finishAppSwitcherLifecycle(
                reason: confirmed ? "confirmed" : "confirm_failed",
                confirmed: confirmed
            )
            return true
        case .back:
            finishAppSwitcherLifecycle(reason: "back", confirmed: false)
            return true
        case .left, .right:
            let moved = appSwitcherSession.moveSelection(left: button == .left)
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=\(moved)"
            )
            if !moved {
                finishAppSwitcherLifecycle(reason: "navigate_failed", confirmed: false)
            } else {
                scheduleAppSwitcherTimeout()
            }
            return true
        case .up, .down:
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=true " +
                    "direction=unsupported"
            )
            return true
        default:
            return false
        }
    }

    private func startAppSwitcherLifecycle() {
        scheduleAppSwitcherTimeout()
        appSwitcherConfirmationProbe?.cancel()
        appSwitcherConfirmationProbe = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds
        ) { [weak self] in
            guard let self, self.appSwitcherSession.isActive else { return }
            guard let origin = self.appSwitcherOriginBundleIdentifier,
                  let current = self.frontmostBundleIdentifier(),
                  current != origin
            else { return }
            self.finishAppSwitcherLifecycle(reason: "frontmost_changed", confirmed: false)
        }
    }

    private func scheduleAppSwitcherTimeout() {
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.appSwitcherSession.isActive else { return }
            self.finishAppSwitcherLifecycle(reason: "timeout", confirmed: false)
        }
    }

    private func finishAppSwitcherLifecycle(reason: String, confirmed: Bool) {
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = nil
        if appSwitcherSession.isActive {
            _ = appSwitcherSession.cancel()
        }
        diagnosticLogger(
            "HID APP SWITCHER ended reason=\(reason) confirmed=\(confirmed)"
        )
        if confirmed {
            appSwitcherConfirmationProbe?.cancel()
            appSwitcherConfirmationProbe = scheduler.schedule(
                afterMilliseconds: HIDRemoteTiming.appSwitcherConfirmationProbeMilliseconds,
                repeatingEveryMilliseconds: nil
            ) { [weak self] in
                guard let self else { return }
                self.appSwitcherConfirmationProbe = nil
                self.diagnosticLogger(
                    "HID APP SWITCHER selection bundle_id=" +
                        (self.frontmostBundleIdentifier() ?? "unknown")
                )
            }
        }
        appSwitcherOriginBundleIdentifier = nil
    }

    private func resetGestureRecognition() {
        doubleClickTimers.values.forEach { $0.cancel() }
        doubleClickTimers.removeAll()
        longPressTimers.values.forEach { $0.cancel() }
        longPressTimers.removeAll()
        gestureRecognizer.reset()
    }

    private func resetInputState() {
        if appSwitcherSession.isActive {
            _ = appSwitcherSession.cancel()
            diagnosticLogger("HID APP SWITCHER cancelled reason=input_reset")
        }
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = nil
        appSwitcherConfirmationProbe?.cancel()
        appSwitcherConfirmationProbe = nil
        appSwitcherOriginBundleIdentifier = nil
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
