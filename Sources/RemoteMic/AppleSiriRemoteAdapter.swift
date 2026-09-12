import AppleRemoteSupport
import AppKit
import Foundation
import IOKit.hid

private func appleRemoteDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<AppleSiriRemoteAdapter>.fromOpaque(context)
        .takeUnretainedValue()
        .deviceDidMatch(result: result, device: device)
}

private func appleRemoteDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<AppleSiriRemoteAdapter>.fromOpaque(context)
        .takeUnretainedValue()
        .deviceDidRemove(device)
}

private func appleRemoteInputValue(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context, let sender else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    Unmanaged<AppleSiriRemoteAdapter>.fromOpaque(context)
        .takeUnretainedValue()
        .handleInputValue(value, from: device)
}

private func appleRemoteTouchFrame(
    contacts: UnsafePointer<SAYAppleRemoteTouchContact>?,
    contactCount: Int32,
    timestamp: Double,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let adapter = Unmanaged<AppleSiriRemoteAdapter>.fromOpaque(context).takeUnretainedValue()
    let values: [RemoteHardwareTouchContact]
    if let contacts, contactCount > 0 {
        values = (0..<Int(contactCount)).map { index in
            let contact = contacts[index]
            return RemoteHardwareTouchContact(
                identifier: Int(contact.identifier),
                normalizedX: contact.normalizedX,
                normalizedY: contact.normalizedY,
                contactSize: contact.hasContactSize ? contact.contactSize : nil
            )
        }
    } else {
        values = []
    }
    adapter.handleTouchFrame(contacts: values, timestampUptime: timestamp)
}

enum AppleSiriRemoteControl: String, CaseIterable, Equatable {
    case up
    case down
    case left
    case right
    case select
    case back
    case tv
    case siri
    case playPause = "play_pause"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute
    case power

    var remoteButton: RemoteButton? {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .select: return .ok
        case .back: return .back
        case .tv: return .tv
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .playPause: return .playPause
        case .mute: return .mute
        case .power: return .power
        case .siri: return nil
        }
    }

    var nativeEvents: Set<RemoteNativeEvent> {
        switch self {
        case .playPause: return [.systemKey(type: 2), .systemKey(type: 16)]
        case .mute: return [.systemKey(type: 3), .systemKey(type: 7)]
        case .power: return [.keyboard(keyCode: 90), .systemKey(type: 6)]
        default: return remoteButton?.nativeEvents ?? []
        }
    }

    var isOnTouchSurface: Bool {
        switch self {
        case .up, .down, .left, .right, .select: return true
        default: return false
        }
    }

    static func identify(usagePage: UInt32, usage: UInt32) -> AppleSiriRemoteControl? {
        switch (usagePage, usage) {
        case (0x01, 0x86), (0x01, 0x40), (0x0C, 0x40), (0x0C, 0x224): return .back
        case (0x0C, 0x42): return .up
        case (0x0C, 0x43): return .down
        case (0x0C, 0x44): return .left
        case (0x0C, 0x45): return .right
        case (0x0C, 0x04), (0xFF00, 0x01), (0xFF00, 0x02), (0xFF00, 0x03),
             (0x0B, 0x21), (0x0B, 0x2F): return .siri
        case (0x0C, 0x60), (0x0C, 0x223): return .tv
        case (0x0C, 0x80), (0x0C, 0x41), (0x09, 0x01): return .select
        case (0x0C, 0xCD): return .playPause
        case (0x0C, 0xE9): return .volumeUp
        case (0x0C, 0xEA): return .volumeDown
        case (0x0C, 0xE2), (0x0C, 0x20): return .mute
        case (0x0C, 0x30): return .power
        default: return nil
        }
    }
}

struct AppleSiriRemoteDeviceMatch: Equatable {
    static let vendorID = 0x004C
    static let productID = 0x0315
    static let acceptedPrimaryUsagePages: Set<Int> = [0x01, 0x0C, 0x0D, 0xFF00]

    static func accepts(vendorID: Int?, productID: Int?, primaryUsagePage: Int?) -> Bool {
        vendorID == Self.vendorID
            && productID == Self.productID
            && primaryUsagePage.map(acceptedPrimaryUsagePages.contains) == true
    }
}

final class AppleSiriRemoteAdapter {
    struct Connection: Equatable {
        let device: RemoteHardwareDeviceIdentity
        let fingerprint: String
        let isConnected: Bool
    }

    private struct Interface {
        let device: IOHIDDevice
        let identity: RemoteHardwareDeviceIdentity
        let fingerprint: String
    }

    private struct ControlKey: Hashable {
        let device: RemoteHardwareDeviceIdentity
        let control: AppleSiriRemoteControl
    }

    static let descriptor = RemoteHardwareDescriptor(
        adapterID: "apple_siri_remote",
        modelID: "a2854",
        capabilities: [.controlEdges, .touchSurface, .continuousScroll]
    )

    var onConnection: ((Connection) -> Void)?
    var onControlEvent: ((RemoteHardwareControlEvent) -> Void)?
    var onTouchEvent: ((RemoteHardwareTouchEvent) -> Void)?

    private let lifecycleRouter = RemoteHardwareControlLifecycleRouter()
    private let inputMonitoringGranted: () -> Bool
    private let logger: (String) -> Void
    private var manager: IOHIDManager?
    private var interfaces: [UInt: Interface] = [:]
    private var interfaceCountByIdentity: [RemoteHardwareDeviceIdentity: Int] = [:]
    private var fingerprintByIdentity: [RemoteHardwareDeviceIdentity: String] = [:]
    private var customMappingEnabled = false
    private var permissionTimer: DispatchSourceTimer?
    private var touchSession: OpaquePointer?
    private var touchIsRunning = false
    private var touchDeviceIdentity: RemoteHardwareDeviceIdentity?
    private var touchContactsWereActive = false
    private var touchSequence: UInt64 = 0
    private var coalescedControlReports: [ControlKey: Int] = [:]
    private let touchLock = NSLock()

    init(
        inputMonitoringGranted: @escaping () -> Bool = { HIDRemoteMonitor.isInputMonitoringGranted },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.logger = logger
    }

    deinit {
        stop(reason: .adapterStopped, suppressNextRelease: false)
        destroyTouchSession()
    }

    func restart(customMappingEnabled: Bool) {
        stop(reason: .configurationChanged, suppressNextRelease: true)
        start(customMappingEnabled: customMappingEnabled)
    }

    func start(customMappingEnabled: Bool) {
        guard manager == nil else { return }
        self.customMappingEnabled = customMappingEnabled
        guard inputMonitoringGranted() else {
            logger("APPLE REMOTE START rejected reason=input_monitoring_permission")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: AppleSiriRemoteDeviceMatch.vendorID,
            kIOHIDProductIDKey as String: AppleSiriRemoteDeviceMatch.productID,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, appleRemoteDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, appleRemoteDeviceRemoved, context)
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
            logger(
                "APPLE REMOTE START failed " + AppLogger.errorFields(
                    domain: "io_return",
                    code: Int(result)
                )
            )
            return
        }
        self.manager = manager
        startPermissionMonitor()
        logger("APPLE REMOTE START phase=completed result=monitoring model=a2854")
    }

    func stop(
        reason: RemoteHardwareLifecycleCancellationReason,
        suppressNextRelease: Bool
    ) {
        permissionTimer?.cancel()
        permissionTimer = nil
        emit(lifecycleRouter.cancelAll(
            reason: reason,
            timestampUptime: ProcessInfo.processInfo.systemUptime,
            suppressNextRelease: suppressNextRelease
        ))
        cancelActiveTouch(reason: reason)
        stopTouchSession()

        for interface in interfaces.values {
            IOHIDDeviceRegisterInputValueCallback(interface.device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(
                interface.device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDDeviceClose(interface.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (identity, fingerprint) in fingerprintByIdentity {
            onConnection?(Connection(
                device: identity,
                fingerprint: fingerprint,
                isConnected: false
            ))
        }
        interfaces.removeAll()
        interfaceCountByIdentity.removeAll()
        fingerprintByIdentity.removeAll()
        coalescedControlReports.removeAll()
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        logger("APPLE REMOTE STOP reason=\(reason.rawValue)")
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            logger("APPLE REMOTE DEVICE rejected reason=match_error result=\(result)")
            return
        }
        let vendorID = integerProperty(kIOHIDVendorIDKey, device: device)
        let productID = integerProperty(kIOHIDProductIDKey, device: device)
        let usagePage = integerProperty(kIOHIDPrimaryUsagePageKey, device: device)
        guard AppleSiriRemoteDeviceMatch.accepts(
            vendorID: vendorID,
            productID: productID,
            primaryUsagePage: usagePage
        ) else {
            logger("APPLE REMOTE DEVICE rejected reason=interface_not_approved")
            return
        }
        let key = interfaceKey(device)
        guard interfaces[key] == nil,
              let fingerprint = HIDRemoteMonitor.fingerprint(for: device)
        else {
            logger("APPLE REMOTE DEVICE rejected reason=identity_unavailable_or_duplicate")
            return
        }
        let identity = RemoteHardwareDeviceIdentity(
            adapterID: Self.descriptor.adapterID,
            instanceID: fingerprint
        )
        let shouldSeize = customMappingEnabled && usagePage != 0xFF00
        let requestedOptions = IOOptionBits(
            shouldSeize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        )
        var openResult = IOHIDDeviceOpen(device, requestedOptions)
        var isSeized = shouldSeize && openResult == kIOReturnSuccess
        if openResult != kIOReturnSuccess, shouldSeize {
            openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            isSeized = false
        }
        guard openResult == kIOReturnSuccess else {
            logger(
                "APPLE REMOTE DEVICE failed phase=open " + AppLogger.errorFields(
                    domain: "io_return",
                    code: Int(openResult)
                )
            )
            return
        }

        IOHIDDeviceRegisterInputValueCallback(
            device,
            appleRemoteInputValue,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        interfaces[key] = Interface(
            device: device,
            identity: identity,
            fingerprint: fingerprint
        )
        let previousCount = interfaceCountByIdentity[identity, default: 0]
        interfaceCountByIdentity[identity] = previousCount + 1
        fingerprintByIdentity[identity] = fingerprint
        if previousCount == 0 {
            onConnection?(Connection(
                device: identity,
                fingerprint: fingerprint,
                isConnected: true
            ))
        }
        logger(
            "APPLE REMOTE DEVICE phase=connected model=a2854 " +
                "interface_page=\(stableHex(usagePage)) seized=\(isSeized)"
        )
        updateTouchSessionForConnectedDevices()
    }

    fileprivate func deviceDidRemove(_ device: IOHIDDevice) {
        let key = interfaceKey(device)
        guard let interface = interfaces.removeValue(forKey: key) else { return }
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        emit(lifecycleRouter.cancel(
            device: interface.identity,
            reason: .deviceDisconnected,
            timestampUptime: ProcessInfo.processInfo.systemUptime,
            suppressNextRelease: false
        ))
        let remainingCount = max(0, (interfaceCountByIdentity[interface.identity] ?? 1) - 1)
        if remainingCount == 0 {
            interfaceCountByIdentity.removeValue(forKey: interface.identity)
            fingerprintByIdentity.removeValue(forKey: interface.identity)
            onConnection?(Connection(
                device: interface.identity,
                fingerprint: interface.fingerprint,
                isConnected: false
            ))
            logger("APPLE REMOTE DEVICE phase=disconnected model=a2854")
        } else {
            interfaceCountByIdentity[interface.identity] = remainingCount
        }
        updateTouchSessionForConnectedDevices()
    }

    fileprivate func handleInputValue(_ value: IOHIDValue, from device: IOHIDDevice) {
        guard let interface = interfaces[interfaceKey(device)] else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard let control = AppleSiriRemoteControl.identify(
            usagePage: usagePage,
            usage: usage
        ) else { return }
        let isPressed = Self.isPressed(integerValue: IOHIDValueGetIntegerValue(value))
        let controlKey = ControlKey(device: interface.identity, control: control)
        let result = lifecycleRouter.route(RemoteHardwareRawControlEvent(
            device: interface.identity,
            controlID: control.rawValue,
            isPressed: isPressed,
            timestampUptime: ProcessInfo.processInfo.systemUptime
        ))
        switch result {
        case let .emitted(event):
            let coalescedEvents = coalescedControlReports.removeValue(forKey: controlKey) ?? 0
            logger(
                "APPLE REMOTE CONTROL phase=\(event.phase.rawValue) control=\(control.rawValue) " +
                    "sequence=\(event.sequence) coalesced_events=\(coalescedEvents)"
            )
            onControlEvent?(event)
            if event.phase == .began, !touchIsRunning {
                updateTouchSessionForConnectedDevices()
            }
        case let .ignored(reason):
            if reason == .duplicateBegin || reason == .awaitingCancelledEnd {
                coalescedControlReports[controlKey, default: 0] += 1
                return
            }
            let coalescedEvents = coalescedControlReports.removeValue(forKey: controlKey) ?? 0
            logger(
                "APPLE REMOTE CONTROL phase=ignored control=\(control.rawValue) " +
                    "reason=\(reason.rawValue) coalesced_events=\(coalescedEvents)"
            )
        }
    }

    static func isPressed(integerValue: Int) -> Bool {
        integerValue != 0
    }

    fileprivate func handleTouchFrame(
        contacts: [RemoteHardwareTouchContact],
        timestampUptime: TimeInterval
    ) {
        touchLock.lock()
        guard let identity = touchDeviceIdentity else {
            touchLock.unlock()
            return
        }
        let phase: RemoteHardwareTouchPhase
        if contacts.isEmpty {
            guard touchContactsWereActive else {
                touchLock.unlock()
                return
            }
            phase = .ended
            touchContactsWereActive = false
        } else if touchContactsWereActive {
            phase = .changed
        } else {
            phase = .began
            touchContactsWereActive = true
        }
        touchSequence &+= 1
        let event = RemoteHardwareTouchEvent(
            device: identity,
            phase: phase,
            contacts: contacts,
            timestampUptime: timestampUptime,
            sequence: touchSequence
        )
        touchLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onTouchEvent?(event)
        }
    }

    private func emit(_ events: [RemoteHardwareControlEvent]) {
        events.forEach { event in
            let control = AppleSiriRemoteControl(rawValue: event.controlID)
            let coalescedEvents = control.map {
                coalescedControlReports.removeValue(forKey: ControlKey(
                    device: event.device,
                    control: $0
                )) ?? 0
            } ?? 0
            logger(
                "APPLE REMOTE CONTROL phase=cancelled control=\(event.controlID) " +
                    "reason=\(event.cancellationReason?.rawValue ?? "unknown") " +
                    "sequence=\(event.sequence) coalesced_events=\(coalescedEvents)"
            )
            onControlEvent?(event)
        }
    }

    private func startPermissionMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.manager != nil, !self.inputMonitoringGranted() else { return }
            self.stop(reason: .permissionRevoked, suppressNextRelease: false)
        }
        permissionTimer = timer
        timer.resume()
    }

    private func updateTouchSessionForConnectedDevices() {
        guard customMappingEnabled,
              interfaceCountByIdentity.count == 1,
              let identity = interfaceCountByIdentity.keys.first
        else {
            cancelActiveTouch(reason: .superseded)
            touchLock.lock()
            touchDeviceIdentity = nil
            touchLock.unlock()
            stopTouchSession()
            if customMappingEnabled, interfaceCountByIdentity.count > 1 {
                logger("APPLE REMOTE TOUCH unavailable reason=multiple_devices")
            }
            return
        }
        touchLock.lock()
        touchDeviceIdentity = identity
        touchLock.unlock()
        if touchSession == nil {
            touchSession = SAYAppleRemoteTouchSessionCreate(
                appleRemoteTouchFrame,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard let touchSession else {
            logger("APPLE REMOTE TOUCH unavailable reason=framework_or_symbols")
            return
        }
        if !touchIsRunning {
            touchIsRunning = SAYAppleRemoteTouchSessionStart(touchSession)
            logger(
                "APPLE REMOTE TOUCH phase=start result=\(touchIsRunning ? "attached" : "surface_unavailable")"
            )
        }
    }

    private func stopTouchSession() {
        if let touchSession {
            SAYAppleRemoteTouchSessionStop(touchSession)
        }
        touchLock.lock()
        touchDeviceIdentity = nil
        touchLock.unlock()
        touchIsRunning = false
    }

    private func destroyTouchSession() {
        guard let touchSession else { return }
        SAYAppleRemoteTouchSessionDestroy(touchSession)
        self.touchSession = nil
        touchIsRunning = false
    }

    private func cancelActiveTouch(reason: RemoteHardwareLifecycleCancellationReason) {
        touchLock.lock()
        guard touchContactsWereActive,
              let identity = touchDeviceIdentity
        else {
            touchLock.unlock()
            return
        }
        touchContactsWereActive = false
        touchSequence &+= 1
        let event = RemoteHardwareTouchEvent(
            device: identity,
            phase: .cancelled,
            contacts: [],
            timestampUptime: ProcessInfo.processInfo.systemUptime,
            sequence: touchSequence
        )
        touchLock.unlock()
        logger("APPLE REMOTE TOUCH phase=cancelled reason=\(reason.rawValue)")
        onTouchEvent?(event)
    }

    private func integerProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func interfaceKey(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    private func stableHex(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        return String(format: "0x%04x", value)
    }
}

enum AppleSiriRemoteTouchOutput: Equatable {
    case move(deltaX: Double, deltaY: Double)
    case scroll(pixels: Double)
    case click
}

struct AppleSiriRemoteTouchInterpreter {
    private static let pointerScale = 500.0
    private static let pointerSpeed = 0.6
    private static let pointerDeadzone = 0.006
    private static let pointerMinimumAcceleration = 0.4
    private static let pointerMaximumAcceleration = 2.6
    private static let pointerLowSpeed = 0.008
    private static let pointerHighSpeed = 0.06
    private static let circularLowSpeed = 0.01
    private static let circularHighSpeed = 0.07
    private static let tapMaximumDuration = 0.22
    private static let tapMaximumDistance = 0.07

    private let tuning: RemoteHardwareTouchTuning
    private var lastPosition: CGPoint?
    private var startPosition: CGPoint?
    private var startedAt: TimeInterval?
    private var lastAngle: Double?
    private var accumulatedRotation = 0.0
    private var emittedScroll = 0.0
    private var circularStarted = false
    private var circularEligible = false
    private var didMoveOrScroll = false
    private var suppressesCurrentContact = false

    init(tuning: RemoteHardwareTouchTuning = .appleSiriRemoteA2854Experimental) {
        self.tuning = tuning
    }

    mutating func suppressCurrentContact() {
        suppressesCurrentContact = true
    }

    mutating func handle(_ event: RemoteHardwareTouchEvent) -> [AppleSiriRemoteTouchOutput] {
        switch event.phase {
        case .began:
            reset()
            guard let point = averagePoint(event.contacts) else { return [] }
            lastPosition = point
            startPosition = point
            startedAt = event.timestampUptime
            circularEligible = hypot(point.x - 0.5, point.y - 0.5) >= tuning.minimumCircularRadius
            if circularEligible {
                lastAngle = atan2(point.y - 0.5, point.x - 0.5)
            }
            return []
        case .changed:
            guard !suppressesCurrentContact,
                  let point = averagePoint(event.contacts),
                  let previous = lastPosition
            else { return [] }
            defer { lastPosition = point }
            if circularEligible {
                return circularOutput(point: point)
            }
            let deltaX = point.x - previous.x
            let deltaY = point.y - previous.y
            let speed = hypot(deltaX, deltaY)
            guard speed >= Self.pointerDeadzone else { return [] }
            didMoveOrScroll = true
            let gain = interpolatedGain(
                speed: speed,
                low: Self.pointerLowSpeed,
                high: Self.pointerHighSpeed,
                minimum: Self.pointerMinimumAcceleration,
                maximum: Self.pointerMaximumAcceleration
            )
            return [.move(
                deltaX: deltaX * Self.pointerScale * Self.pointerSpeed * gain,
                deltaY: -deltaY * Self.pointerScale * Self.pointerSpeed * gain
            )]
        case .ended:
            defer { reset() }
            guard !suppressesCurrentContact,
                  !didMoveOrScroll,
                  let startPosition,
                  let lastPosition,
                  let startedAt,
                  event.timestampUptime - startedAt <= Self.tapMaximumDuration,
                  hypot(lastPosition.x - startPosition.x, lastPosition.y - startPosition.y)
                    <= Self.tapMaximumDistance
            else { return [] }
            return [.click]
        case .cancelled:
            reset()
            return []
        }
    }

    private mutating func circularOutput(point: CGPoint) -> [AppleSiriRemoteTouchOutput] {
        let angle = atan2(point.y - 0.5, point.x - 0.5)
        guard let lastAngle else {
            self.lastAngle = angle
            return []
        }
        self.lastAngle = angle
        var delta = angle - lastAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        guard abs(delta) <= .pi / 2 else { return [] }

        let gain = interpolatedGain(
            speed: abs(delta),
            low: Self.circularLowSpeed,
            high: Self.circularHighSpeed,
            minimum: tuning.minimumAcceleration,
            maximum: tuning.maximumAcceleration
        )
        accumulatedRotation += delta * gain
        if !circularStarted {
            guard abs(accumulatedRotation) >= tuning.circularScrollStartThreshold else { return [] }
            circularStarted = true
            let sign = accumulatedRotation >= 0 ? 1.0 : -1.0
            accumulatedRotation -= sign * tuning.circularScrollStartThreshold
        }
        let direction = tuning.isScrollInverted ? -1.0 : 1.0
        let target = accumulatedRotation * tuning.circularScrollPixelsPerRadian * direction
        let step = (target - emittedScroll) * tuning.scrollEase
        emittedScroll += step
        guard abs(step) >= 0.01 else { return [] }
        didMoveOrScroll = true
        return [.scroll(pixels: step)]
    }

    private func averagePoint(_ contacts: [RemoteHardwareTouchContact]) -> CGPoint? {
        guard !contacts.isEmpty else { return nil }
        let totals = contacts.reduce(into: (x: 0.0, y: 0.0)) { partial, contact in
            partial.x += contact.normalizedX
            partial.y += contact.normalizedY
        }
        return CGPoint(
            x: totals.x / Double(contacts.count),
            y: totals.y / Double(contacts.count)
        )
    }

    private func interpolatedGain(
        speed: Double,
        low: Double,
        high: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard high > low else { return speed < low ? minimum : maximum }
        let linear = min(1, max(0, (speed - low) / (high - low)))
        let smooth = linear * linear * (3 - 2 * linear)
        return minimum + (maximum - minimum) * smooth
    }

    private mutating func reset() {
        lastPosition = nil
        startPosition = nil
        startedAt = nil
        lastAngle = nil
        accumulatedRotation = 0
        emittedScroll = 0
        circularStarted = false
        circularEligible = false
        didMoveOrScroll = false
        suppressesCurrentContact = false
    }
}

enum AppleSiriRemotePointerController {
    static func perform(_ output: AppleSiriRemoteTouchOutput) -> Bool {
        guard KeyboardInjector.isAccessibilityTrusted,
              let source = CGEventSource(stateID: .hidSystemState)
        else { return false }
        switch output {
        case let .move(deltaX, deltaY):
            let current = CGEvent(source: nil)?.location ?? .zero
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: current.x + deltaX, y: current.y + deltaY),
                mouseButton: .left
            ) else { return false }
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
            return true
        case let .scroll(pixels):
            let rounded = Int32(min(Double(Int32.max), max(Double(Int32.min), pixels.rounded())))
            guard rounded != 0,
                  let event = CGEvent(
                      scrollWheelEvent2Source: source,
                      units: .pixel,
                      wheelCount: 1,
                      wheel1: rounded,
                      wheel2: 0,
                      wheel3: 0
                  )
            else { return false }
            event.location = CGEvent(source: nil)?.location ?? .zero
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
            return true
        case .click:
            let location = CGEvent(source: nil)?.location ?? .zero
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: location,
                mouseButton: .left
            ), let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: location,
                mouseButton: .left
            ) else { return false }
            for event in [down, up] {
                event.setIntegerValueField(
                    .eventSourceUserData,
                    value: KeyboardInjector.syntheticEventMarker
                )
                event.post(tap: .cghidEventTap)
            }
            return true
        }
    }
}
