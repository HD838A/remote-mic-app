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
    private lazy var buttonInteractions = RemoteButtonInteractionController(scheduler: scheduler)
    private let scheduler: HIDRemoteScheduling
    private let permissionPoll: HIDPermissionPoll
    private let runtimePermissions: () -> Bool
    private let actionPerformer: (RemoteButton, ButtonTrigger, ConfiguredButtonAction) -> Bool
    private let appSwitcherSession: KeyboardInjector.AppSwitcherSession
    private let overrideActionPerformer: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let hasOverrideBinding: (UUID?, RemoteButton, ButtonTrigger) -> Bool
    private let frontmostBundleIdentifier: () -> String?
    private let diagnosticLogger: (String) -> Void
    private let monotonicNow: () -> UInt64
    private let karabinerElementsInstalled: () -> Bool
    private let prepareNativeKeys: (() -> Bool)?
    private let restoreNativeKeys: () -> Void
    private let targetFingerprint: String?
    private let excludedFingerprints: () -> Set<String>
    private var allowedLocationIDs: Set<UInt32>?
    private var backOnlyMode = false
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var probedDevices: [IOHIDDevice] = []
    private(set) var deviceFingerprint: String?
    private(set) var profileID: UUID?
    private var activeDeviceIsSeized = false
    private var nativeKeysNeutralized = false
    private var activeUsages = Set<UInt16>()
    private var nativePassthroughUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    private var nonRepeatablePressedButtons = Set<RemoteButton>()
    private var nonRepeatableReleaseTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    // Physical edge timing used only for diagnostics: how long a button was held
    // and how long ago it was released before the next press arrived.
    private var physicalPressStartedAt: [RemoteButton: UInt64] = [:]
    private var lastPhysicalReleaseAt: [RemoteButton: UInt64] = [:]
    private var gestureRecognizer = RemoteButtonGestureRecognizer()
    private var doubleClickTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var longPressTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var permissionPollSubscription: HIDPermissionPoll.Subscription?
    private var appSwitcherTimeout: HIDRemoteScheduledTask?
    private var appSwitcherFrontmostMonitor: HIDRemoteScheduledTask?
    private var appSwitcherConfirmationProbe: HIDRemoteScheduledTask?
    private var appSwitcherOriginBundleIdentifier: String?
    private(set) var status = LocalizedMessage("button_mapping.status.disabled")
    var onStatus: ((LocalizedMessage) -> Void)?
    var onActiveButtons: ((UUID?, Set<RemoteButton>) -> Void)?
    var onButtonPressed: ((UUID?, String, RemoteButton) -> (profileID: UUID, shouldPerformAction: Bool)?)?
    var onRuntimeButton: ((UUID?, RemoteButton, RemoteButtonPhase) -> Bool)?
    var claimsRuntimeButton: ((UUID?, RemoteButton) -> Bool)?
    var onInputReset: ((UUID?) -> Void)?
    var onInternalAction: ((UUID?, ButtonAction) -> Void)?

    init(
        settings: AppSettings,
        profileID: UUID? = nil,
        targetFingerprint: String? = nil,
        excludedFingerprints: @escaping () -> Set<String> = { [] },
        eventSuppressor: KeyboardEventSuppressor = KeyboardEventSuppressor(),
        ownsEventSuppressor: Bool = true,
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionPoll: HIDPermissionPoll = .shared,
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
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        karabinerElementsInstalled: @escaping () -> Bool = {
            HIDRemoteMonitor.isKarabinerElementsInstalled()
        },
        prepareNativeKeys: (() -> Bool)? = nil,
        restoreNativeKeys: @escaping () -> Void = {},
        appSwitcherKeyStatePoster: @escaping KeyboardInjector.KeyStatePoster = KeyboardInjector.postKeyState
    ) {
        self.settings = settings
        self.profileID = profileID
        self.targetFingerprint = targetFingerprint
        self.excludedFingerprints = excludedFingerprints
        self.eventSuppressor = eventSuppressor
        self.ownsEventSuppressor = ownsEventSuppressor
        self.scheduler = scheduler
        self.permissionPoll = permissionPoll
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
        self.monotonicNow = monotonicNow
        self.karabinerElementsInstalled = karabinerElementsInstalled
        self.prepareNativeKeys = prepareNativeKeys
        self.restoreNativeKeys = restoreNativeKeys
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

    func start(
        powerKeySuppressed: Bool,
        allowedLocationIDs: Set<UInt32>? = nil,
        allowBackOnly: Bool = false
    ) {
        stop()
        self.allowedLocationIDs = allowedLocationIDs
        backOnlyMode = allowBackOnly && !settings.customMappingEnabled
        guard settings.customMappingEnabled || backOnlyMode else {
            updateStatus(LocalizedMessage("button_mapping.status.system_managed"))
            return
        }
        let inputGranted = Self.isInputMonitoringGranted
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            mappingEnabled: settings.customMappingEnabled || backOnlyMode,
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted,
            powerKeySuppressed: powerKeySuppressed || backOnlyMode
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

        if settings.customMappingEnabled {
            let suppressionReady = eventSuppressor.start()
            AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")
        }

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
        updateStatus(LocalizedMessage("button_mapping.status.waiting_for_device"))
        AppLogger.shared.write(
            "HID START mode=adaptive back_only=\(backOnlyMode) " +
                "allowlist_configured=\(allowedLocationIDs != nil) " +
                "allowlist_count=\(allowedLocationIDs?.count ?? 0) " +
                "target_bound=\(targetFingerprint != nil)"
        )
    }

    func stop() {
        permissionPollSubscription?.cancel()
        permissionPollSubscription = nil
        resetInputState()
        nativeKeysNeutralized = false
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
            diagnosticLogger(
                "HID DEVICE rejected reason=unsafe_location " +
                    "has_location=\(Self.locationID(for: device) != nil) " +
                    "allowlist_configured=\(allowedLocationIDs != nil)"
            )
            return
        }
        switch Self.deviceMatchDecision(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) {
        case let .activate(fingerprint):
            if backOnlyMode {
                probeDevice(device)
            } else {
                _ = activateDevice(device, fingerprint: fingerprint, allowManagerFallback: false)
            }
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
        guard prepareNativeKeyMapping() else {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            return
        }
        probedDevices.append(device)
        diagnosticLogger("HID DEVICE probing mode=monitored")
    }

    private func promoteProbedDevice(_ device: IOHIDDevice, fingerprint: String) -> Bool {
        guard let selectedIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return false
        }
        guard prepareNativeKeyMapping() else { return false }
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
            guard prepareNativeKeyMapping() else {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                return false
            }
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

        guard prepareNativeKeyMapping() else {
            if monitorResult == kIOReturnSuccess {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
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
            nativeKeysNeutralized = false
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
        guard settings.customMappingEnabled || backOnlyMode else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled")
            return
        }
        guard Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger(
                "HID REPORT rejected reason=unsafe_location " +
                    "report_id=\(reportID) bytes=\(data.count) " +
                    "has_location=\(Self.locationID(for: device) != nil) " +
                    "allowlist_configured=\(allowedLocationIDs != nil)"
            )
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

    @discardableResult
    func connectSimulatedDevice(
        fingerprint: String,
        profileID: UUID?,
        isSeized: Bool = true
    ) -> Bool {
        resetInputState()
        guard prepareNativeKeyMapping() else { return false }
        deviceFingerprint = fingerprint
        self.profileID = profileID
        activeDeviceIsSeized = isSeized
        return true
    }

    func handleSimulatedReport(reportID: UInt32, data: Data) {
        guard settings.customMappingEnabled || backOnlyMode else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled source=simulated")
            return
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked source=simulated")
            return
        }
        parseAndProcess(reportID: reportID, data: data, source: "simulated")
    }

    func handleSimulatedBackOnlyReport(reportID: UInt32, data: Data) {
        let previousBackOnlyMode = backOnlyMode
        backOnlyMode = true
        defer { backOnlyMode = previousBackOnlyMode }
        handleSimulatedReport(reportID: reportID, data: data)
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
        // TV and volume are always managed, unlike intentional left/right passthrough.
        // Register before diagnostics, UI callbacks and configuration lookups.
        if !backOnlyMode {
            for usage in usages.subtracting(activeUsages) {
                guard let button = RemoteButton.usageMap[usage],
                      button == .volumeUp || button == .volumeDown || button == .tv,
                      shouldArmNativeEvent(for: button) else { continue }
                eventSuppressor.arm(button: button, edge: .down)
            }
        }
        diagnosticLogger(
            "HID REPORT accepted source=\(source) id=\(reportID) bytes=\(data.count) " +
                "usage_count=\(usages.count) buttons=\(Self.buttonList(for: usages))"
        )
        if backOnlyMode {
            processBackOnly(usages: usages.intersection([RemoteButton.back.hidUsage]))
        } else {
            process(usages: usages)
        }
    }

    func disconnectSimulatedDevice() {
        deviceFingerprint = nil
        resetInputState()
        nativeKeysNeutralized = false
        activeDeviceIsSeized = false
    }

    private func process(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        if !pressed.isEmpty || !released.isEmpty {
            let timing = recordPhysicalEdgeTiming(pressed: pressed, released: released)
            diagnosticLogger(
                "HID EDGE pressed=\(Self.buttonList(for: pressed)) " +
                    "released=\(Self.buttonList(for: released))" + timing
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
            // An explicit binding owns the click even when it resolves to the same arrow.
            let preflightHasSingleClickOverride = settings.configuredActionOverride?(
                preflightProfileID, button, .singleClick
            ) != nil || hasOverrideBinding(preflightProfileID, button, .singleClick)
            let usesNativePassthrough = preflightProfileID != nil &&
                (settings.buttonInteractionSettings(profileID: preflightProfileID).modes[button.rawValue] == nil ||
                 settings.buttonInteractionSettings(profileID: preflightProfileID).migratedRepeatButtons?.contains(button.rawValue) == true) &&
                settings.interactionModeOverride?(preflightProfileID, button) == nil &&
                !preflightHasSingleClickOverride &&
                claimsRuntimeButton?(preflightProfileID, button) != true && shouldUseNativePassthrough(
                button: button,
                action: preflightAction,
                recognizesDoubleClick: preflightRecognizesDoubleClick,
                recognizesLongPress: preflightRecognizesLongPress
            )
            // Seizing one HID interface does not guarantee that sibling interfaces
            // stop emitting native events. Every managed press owns its native
            // descriptors; intentional passthrough and marked host events remain free.
            if !usesNativePassthrough, shouldArmNativeEvent(for: button), button != .volumeUp, button != .volumeDown, button != .tv {
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

            // Discovery may associate an existing configured device during the callback.
            let hasSingleClickOverride = settings.configuredActionOverride?(
                profileID, button, .singleClick
            ) != nil || hasOverrideBinding(profileID, button, .singleClick)

            if onRuntimeButton?(profileID, button, .press) == true {
                if !activeDeviceIsSeized, usesNativePassthrough { eventSuppressor.arm(button: button, edge: .down) }
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
                diagnosticLogger(
                    "HID NATIVE PASSTHROUGH button=\(button.rawValue) action=\(action.rawValue)"
                )
                continue
            }
            if hasSingleClickOverride {
                diagnosticLogger(
                    "HID ROUTE button=\(button.rawValue) trigger=singleClick " +
                        "path=configured reason=single_click_override override_present=true"
                )
            }
            let snapshot = interactionSnapshot(button: button, profileID: profileID)
            if snapshot.mode == .once, !snapshot.recognizesDouble, !snapshot.recognizesLong {
                guard shouldAcceptRawPress(button: button, action: action,
                    allowsRapidPress: hasSingleClickOverride ||
                        settings.configuredActionOverride?(profileID, button, .doubleClick) != nil ||
                        settings.configuredActionOverride?(profileID, button, .longPress) != nil ||
                        snapshot.single.allowsSingleClickRepeat ||
                        settings.allowsRapidPress(for: button, profileID: profileID),
                    frontmostBundleIdentifier: frontmostBundleIdentifier()) else {
                    diagnosticLogger(
                        "HID PRESS rejected button=\(button.rawValue) " +
                            "action=\(action.rawValue) reason=awaiting_stable_release " +
                            "stable_release_ms=\(HIDRemoteTiming.stableReleaseMilliseconds)" +
                            pressLatchDiagnosticSuffix(for: button)
                    )
                    continue
                }
            }
            diagnosticLogger("HID GESTURE button=\(button.rawValue) path=raw mode=\(snapshot.mode?.rawValue ?? "invalid") external_result=unknown")
            let target = frontmostBundleIdentifier()
            buttonInteractions.handle(.press, button: button, snapshot: snapshot,
                valid: { [weak self] in
                    guard let self else { return false }
                    return self.profileID == profileID && self.runtimePermissionsAreValid() &&
                        self.frontmostBundleIdentifier() == target &&
                        snapshot.hasSameBinding(as: self.interactionSnapshot(button: button, profileID: profileID))
                }, perform: { [weak self] trigger, configured in
                    self?.performConfiguredAction(for: button, trigger: trigger, captured: configured) ?? false
                })
        }

        for usage in released {
            let usedNativePassthrough = nativePassthroughUsages.remove(usage) != nil
            if let button = RemoteButton.usageMap[usage],
               !usedNativePassthrough, shouldArmNativeEvent(for: button) {
                eventSuppressor.arm(button: button, edge: .up)
            }
            repeatTimers.removeValue(forKey: usage)?.cancel()
            if let button = RemoteButton.usageMap[usage] {
                if onRuntimeButton?(profileID, button, .release) == true { continue }
                if buttonInteractions.isTracking(button) {
                    buttonInteractions.handle(.release, button: button,
                        snapshot: settings.interactionSnapshot(for: button, profileID: profileID),
                        valid: { false }, perform: { _, _ in false })
                    scheduleNonRepeatableRelease(for: button)
                    continue
                }
                scheduleNonRepeatableRelease(for: button)
                guard processGestureCommands(gestureRecognizer.release(button)) else { return }
            }
        }
    }

    private func processBackOnly(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        activeUsages = usages
        onActiveButtons?(profileID, RemoteButton.buttons(for: usages))
        guard pressed.contains(RemoteButton.back.hidUsage) else { return }
        let configured = ConfiguredButtonAction(action: .deleteBackward, shortcut: nil)
        guard actionPerformer(.back, .singleClick, configured) else {
            releaseForRevokedPermissions()
            return
        }
        AppLogger.shared.write(
            "HID BUTTON button=back trigger=singleClick action=deleteBackward path=back_only"
        )
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

    static func isKarabinerElementsRunning(
        bundleIdentifiers: [String] = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    ) -> Bool {
        bundleIdentifiers.contains { identifier in
            let normalized = identifier.lowercased()
            return normalized == "org.pqrs.karabiner-elements" ||
                normalized == "org.pqrs.karabiner-eventviewer" ||
                normalized.hasPrefix("org.pqrs.karabiner.")
        }
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

    /// Records physical edge timing and returns the fields that let a reader tell a
    /// device bounce apart from a real press the stable-release latch swallowed,
    /// instead of correlating `HID EDGE` timestamps by hand.
    private func recordPhysicalEdgeTiming(
        pressed: Set<UInt16>,
        released: Set<UInt16>
    ) -> String {
        let now = monotonicNow()
        var releaseGaps: [String] = []
        var holds: [String] = []
        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            if let releasedAt = lastPhysicalReleaseAt[button] {
                releaseGaps.append(
                    "\(button.rawValue):\(Self.elapsedMilliseconds(from: releasedAt, to: now))"
                )
            }
            physicalPressStartedAt[button] = now
        }
        for usage in released.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            if let startedAt = physicalPressStartedAt.removeValue(forKey: button) {
                holds.append(
                    "\(button.rawValue):\(Self.elapsedMilliseconds(from: startedAt, to: now))"
                )
            }
            lastPhysicalReleaseAt[button] = now
        }
        var suffix = ""
        if !releaseGaps.isEmpty {
            suffix += " since_release_ms=\(releaseGaps.joined(separator: ","))"
        }
        if !holds.isEmpty {
            suffix += " hold_ms=\(holds.joined(separator: ","))"
        }
        return suffix
    }

    /// `latch_remaining_ms` is the nominal time left in the stable-release window at
    /// the moment the press arrived; the window timer is only re-armed by a release.
    private func pressLatchDiagnosticSuffix(for button: RemoteButton) -> String {
        guard let releasedAt = lastPhysicalReleaseAt[button] else {
            return " since_release_ms=unobserved"
        }
        let elapsed = Self.elapsedMilliseconds(from: releasedAt, to: monotonicNow())
        let window = Int(clamping: HIDRemoteTiming.stableReleaseMilliseconds)
        return " since_release_ms=\(elapsed) latch_remaining_ms=\(max(0, window - elapsed))"
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard end >= start else { return 0 }
        return Int(clamping: (end - start) / 1_000_000)
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
        return ![.arrowUp, .arrowDown, .arrowLeft, .arrowRight].contains(action)
    }

    static func shouldRepeat(
        configured: ConfiguredButtonAction,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard configured.allowsSingleClickRepeat else { return false }
        guard frontmostBundleIdentifier == PresetApplication.remoteMic.bundleIdentifier else {
            return true
        }
        if configured.action == .deleteBackward ||
            (configured.action == .customShortcut && configured.shortcut?.keyCode == 51) {
            return true
        }
        return !configured.isDirectionalOrDeleteBackward
    }

    private func shouldUseNativePassthrough(
        button: RemoteButton,
        action: ButtonAction,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> Bool {
        guard !nativeKeysNeutralized, !activeDeviceIsSeized,
              !appSwitcherSession.isActive,
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
        configured: ConfiguredButtonAction
    ) {
        guard let interval = HIDRemoteTiming.repeatIntervalMilliseconds(for: button) else { return }
        guard
            !settings.hasSecondaryAction(for: button, profileID: profileID),
            configured.action != .disabled,
            configured.action != .appSwitcher,
            Self.shouldRepeat(
                configured: configured,
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
                    configured: configured,
                    frontmostBundleIdentifier: self.frontmostBundleIdentifier()
                ) {
                self.repeatTimers.removeValue(forKey: usage)?.cancel()
                return
            }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            let current = self.settings.configuredAction(
                for: button, trigger: .singleClick, profileID: self.profileID
            )
            let hasOpaqueOverride = self.hasOverrideBinding(
                self.profileID, button, .singleClick
            ) && self.settings.configuredActionOverride?(
                self.profileID, button, .singleClick
            ) == nil
            guard current == configured, !hasOpaqueOverride else {
                self.repeatTimers.removeValue(forKey: usage)?.cancel()
                return
            }
            if !self.actionPerformer(button, .singleClick, current) {
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

    private func interactionSnapshot(button: RemoteButton, profileID: UUID) -> RemoteButtonInteractionSnapshot {
        var snapshot = settings.interactionSnapshot(for: button, profileID: profileID) { [self] trigger in
            hasOverrideBinding(profileID, button, trigger) &&
                settings.configuredActionOverride?(profileID, button, trigger) == nil
        }
        let repeated = snapshot.mode == .repeatLong ? snapshot.long : snapshot.single
        snapshot.repeatAllowed = Self.shouldRepeat(configured: repeated,
            frontmostBundleIdentifier: frontmostBundleIdentifier())
        return snapshot
    }

    private func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        captured: ConfiguredButtonAction? = nil
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
        let configured = captured ?? settings.configuredAction(
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
            // A library rejection is not evidence of revoked Accessibility permission.
            // Preserve the held edge so duplicate reports cannot restart the action.
            if configured.action == .combinationAction { return false }
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
        buttonInteractions.cancelAll(reason: "input_reset")
        doubleClickTimers.values.forEach { $0.cancel() }
        doubleClickTimers.removeAll()
        longPressTimers.values.forEach { $0.cancel() }
        longPressTimers.removeAll()
        gestureRecognizer.reset()
    }

    func cancelMappingInteractions() { resetInputState() }

    func cancelConfiguredInteractions(reason: String) { buttonInteractions.cancelAll(reason: reason) }

    func cancelPendingButtonActions() {
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        resetGestureRecognition()
        if appSwitcherSession.isActive { finishAppSwitcherLifecycle(reason: "common_phrases_opened", confirmed: false) }
    }

    private func resetInputState() {
        onInputReset?(profileID)
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
        for usage in activeUsages.subtracting(nativePassthroughUsages) {
            if let button = RemoteButton.usageMap[usage], shouldArmNativeEvent(for: button) {
                eventSuppressor.arm(button: button, edge: .up)
            }
        }
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        nativePassthroughUsages.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        physicalPressStartedAt.removeAll()
        lastPhysicalReleaseAt.removeAll()
        resetGestureRecognition()
        activeUsages.removeAll()
        onActiveButtons?(profileID, [])
    }

    private func runtimePermissionsAreValid() -> Bool {
        runtimePermissions()
    }

    private func shouldArmNativeEvent(for button: RemoteButton) -> Bool {
        // UserKeyMapping readback only proves that the mapping was written. It
        // does not prove that macOS stopped delivering the native event. Intel
        // monitored mode can still deliver TV/volume events after a successful
        // readback, so keep the event-tap fallback for those three controls.
        if button == .tv || button == .volumeUp || button == .volumeDown {
            return !activeDeviceIsSeized || !nativeKeysNeutralized
        }
        return !nativeKeysNeutralized
    }

    private func prepareNativeKeyMapping() -> Bool {
        nativeKeysNeutralized = false
        guard !backOnlyMode, let prepareNativeKeys else { return true }
        guard prepareNativeKeys() else {
            updateStatus(LocalizedMessage("button_mapping.error.native_mapping_failed"))
            diagnosticLogger("HID DEVICE rejected reason=native_mapping_not_verified")
            return false
        }
        nativeKeysNeutralized = true
        return true
    }

    private func startPermissionMonitor() {
        permissionPollSubscription?.cancel()
        permissionPollSubscription = permissionPoll.subscribe { [weak self] permissionsGranted in
            guard let self, self.manager != nil else { return }
            if !permissionsGranted {
                self.releaseForRevokedPermissions()
            }
        }
    }

    /// 权限被撤销后的释放路径。
    ///
    /// 这里**不受 `ownsEventSuppressor` 约束**：那个标记只针对「本监视器因设备移除等局部
    /// 原因停止」——共享的 tap 还要服务其它监视器。但权限撤销是全局的，用户已经收回了
    /// 授权，tap 就不该继续挂在系统输入路径上。留着它有两条代价：
    ///
    /// 1. 授权已收回却仍在拦截系统按键；
    /// 2. 2026-10-24 那次整机卡死的前提条件（一条活着的 active event tap + 主线程
    ///    被同步 TCC 查询钉住）依然成立。实测日志里权限撤销后 49 秒 tap 回调仍在执行。
    ///
    /// 释放后由既有的 `applyHIDSettings()` → `startHIDMonitors()` 路径重建，与 HID 设备
    /// 监听的恢复时机完全一致，不会多出新的恢复要求。
    func releaseForRevokedPermissions() {
        stop()
        eventSuppressor.stop()
        restoreNativeKeys()
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
