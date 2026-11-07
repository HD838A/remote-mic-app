import Foundation
import IOKit.hid

/// Only opens the Jieli HID interfaces, never the original Google remote.
/// Unknown vendor usages are learned explicitly instead of guessing branded keys.
final class G9N9NHIDMonitor {
    var prepareNativeInput: (([UInt64]) -> Bool)?
    var restoreNativeInput: (() -> Void)?
    var onEvent: ((ChromecastRemoteControlEvent) -> Void)?
    var onPresence: ((Bool) -> Void)?
    var onUnmappedInput: (() -> Void)?
    var onLearningChange: ((String?) -> Void)?
    var onLog: ((String) -> Void)?
    private var manager: IOHIDManager?
    private var enabled = false
    private var running = false
    private var opened = false
    private(set) var isNativeMappingPrepared = false
    private(set) var isPresent = false
    private var pressed = Set<ChromecastRemoteControl>()
    private var sequence = 0
    private var reportState = G9N9NHIDReportState()
    private var invalidReports = 0
    private var observedReportIDs = Set<UInt32>()
    private var reportedUnmapped = false
    private var access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    private var learning: ChromecastRemoteControl? {
        didSet { onLearningChange?(learning?.rawValue) }
    }
    private var learningUsages = Set<G9N9NHIDUsage>()
    private var learningTimeout: DispatchWorkItem?
    private var learned: [String: String]
    private let defaults: UserDefaults
    private static let key = "g9n9n.hid.learned.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        learned = (defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:])
            .filter { $0.key.count <= 24 && ChromecastRemoteControl(rawValue: $0.value) != nil }
        if learned.count > 32 { learned = [:] }
    }

    deinit { stop() }

    static func control(page: UInt32, usage: UInt32) -> ChromecastRemoteControl? {
        switch (page, usage) {
        case (7, 0x28): return .select
        case (7, 0x29): return .back
        case (7, 0x4A): return .home
        case (7, 0x4F): return .right
        case (7, 0x50): return .left
        case (7, 0x51): return .down
        case (7, 0x52): return .up
        case (12, 0x30): return .power
        case (12, 0x40): return .input
        case (12, 0x41): return .select
        case (12, 0x42): return .up
        case (12, 0x43): return .down
        case (12, 0x44): return .left
        case (12, 0x45): return .right
        case (12, 0xE2): return .mute
        case (12, 0xE9): return .volumeUp
        case (12, 0xEA): return .volumeDown
        case (12, 0x223): return .home
        case (12, 0x224): return .back
        default: return nil
        }
    }

    func start() {
        guard !running else { return }
        running = true
        open()
    }

    func setMappingEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if running { updateNativeInput() }
    }

    func learn(_ control: ChromecastRemoteControl) {
        cancelPressed(reason: "learning")
        learningUsages.removeAll()
        learning = control
        learningTimeout?.cancel()
        if running { updateNativeInput() }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.learning = nil
            self.learningUsages.removeAll()
            self.onLog?("G9N9N HID learning=timed_out")
            if self.running { self.updateNativeInput() }
        }
        learningTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func cancelLearning() {
        guard learning != nil else { return }
        learning = nil
        learningUsages.removeAll()
        learningTimeout?.cancel()
        learningTimeout = nil
        if running { updateNativeInput() }
    }

    func stop() {
        running = false
        learningTimeout?.cancel()
        learningTimeout = nil
        learning = nil
        learningUsages.removeAll()
        close()
    }

    func refreshAccess() {
        let observed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        guard running, observed != access || (!opened && observed == kIOHIDAccessTypeGranted) else { return }
        access = observed
        close()
        open()
    }

    private func open() {
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x18D1, kIOHIDProductIDKey: 0x9450,
            kIOHIDManufacturerKey: "zhuhai_jieli",
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, { context, result, sender, _, reportID, report, length, _ in
            guard let context, let sender, result == kIOReturnSuccess, length > 0, length <= 64 else { return }
            let monitor = Unmanaged<G9N9NHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            monitor.receive(reportID: reportID, data: Data(bytes: report, count: length), device: device)
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, _ in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<G9N9NHIDMonitor>.fromOpaque(context).takeUnretainedValue().presence(true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<G9N9NHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.cancelPressed(reason: "device_removed")
            monitor.presence(false)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = result == kIOReturnSuccess
        updateNativeInput()
        onLog?("G9N9N HID phase=opened result=\(result) mode=observe input_monitoring=\(access.rawValue)")
    }

    private func close() {
        cancelPressed(reason: "monitor_closed")
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
        opened = false
        isNativeMappingPrepared = false
        restoreNativeInput?()
        presence(false)
        observedReportIDs.removeAll()
        reportedUnmapped = false
        if invalidReports > 0 { onLog?("G9N9N HID REPORT phase=completed invalid_reports=\(invalidReports)") }
        invalidReports = 0
    }

    private func presence(_ value: Bool) {
        let changed = value != isPresent
        isPresent = value
        updateNativeInput()
        if changed { onPresence?(value) }
    }

    /// Suppress native delivery with the host's reversible, service-local mapper.
    /// Bluetooth HID does not permit seize on all macOS versions.
    private func updateNativeInput() {
        guard opened, isPresent, enabled || learning != nil else {
            if isNativeMappingPrepared { restoreNativeInput?() }
            isNativeMappingPrepared = false
            return
        }
        isNativeMappingPrepared = prepareNativeInput?(nativeSources) == true
    }

    private var nativeSources: [UInt64] {
        var sources = Set(RemoteNativeKeyMapper.mappings.map(\.source))
        for usage: UInt64 in 0xE0...0xE7 { sources.insert(UInt64(7) << 32 | usage) }
        for page: UInt32 in [7, 12] {
            for usage: UInt32 in [0x0E, 0x0F, 0x11, 0x28, 0x29, 0x30, 0x40, 0x41, 0x42,
                0x43, 0x44, 0x45, 0x4A, 0x4F, 0x50, 0x51, 0x52, 0x66, 0xE2, 0xE9, 0xEA, 0x223, 0x224] {
                if Self.control(page: page, usage: usage) != nil || [0x0E, 0x0F, 0x11].contains(usage) {
                    sources.insert(UInt64(page) << 32 | UInt64(usage))
                }
            }
        }
        for key in learned.keys {
            let parts = key.split(separator: ":")
            if parts.count == 2, let page = UInt64(parts[0]), let usage = UInt64(parts[1]),
               [7, 9, 12].contains(page), usage > 0, usage < 0xFFFF {
                sources.insert(page << 32 | usage)
            }
        }
        return sources.sorted()
    }

    private func receive(reportID: UInt32, data: Data, device: IOHIDDevice) {
        guard running, IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String == "zhuhai_jieli" else { return }
        if observedReportIDs.count < 16, observedReportIDs.insert(reportID).inserted {
            onLog?("G9N9N HID REPORT phase=first_received report_id=\(reportID) bytes=\(data.count)")
        }
        let effectiveID = G9N9NHIDReport.effectiveReportID(reported: reportID, data: data)
        guard effectiveID == 1 || effectiveID == 2 else { return }
        guard let snapshot = reportState.consume(reportID: reportID, data: data) else {
            invalidReports = min(1_000_000, invalidReports + 1)
            if invalidReports == 1 {
                onLog?("G9N9N HID REPORT phase=rejected reason=invalid_layout report_id=\(reportID) bytes=\(data.count)")
            }
            cancelPressed(reason: "invalid_report")
            return
        }
        if let learning {
            guard isNativeMappingPrepared else { return }
            learningUsages.formUnion(snapshot.newlyPressed)
            guard snapshot.pressed.isEmpty,
                  let usage = G9N9NHIDReport.learningCandidate(in: learningUsages) else { return }
            learned = learned.filter { $0.value != learning.rawValue }
            learned[usage.key] = learning.rawValue
            defaults.set(learned, forKey: Self.key)
            self.learning = nil
            learningUsages.removeAll()
            learningTimeout?.cancel()
            onLog?("G9N9N HID learning=completed control=\(learning.rawValue)")
            updateNativeInput()
            // Learning consumes the complete press/release, including modifier
            // chords. A fresh press verifies the new binding.
            return
        }
        if learning != nil { return }
        var controls = Set<ChromecastRemoteControl>()
        for usage in snapshot.pressed {
            if let control = learned[usage.key].flatMap(ChromecastRemoteControl.init(rawValue:))
                ?? Self.control(page: usage.page, usage: usage.usage) {
                controls.insert(control)
            } else if !reportedUnmapped {
                reportedUnmapped = true
                onLog?("G9N9N HID REPORT phase=decoded result=unmapped_control")
                onUnmappedInput?()
            }
        }
        for control in pressed.subtracting(controls).sorted(by: { $0.rawValue < $1.rawValue }) {
            emit(control, phase: .ended)
        }
        for control in controls.subtracting(pressed).sorted(by: { $0.rawValue < $1.rawValue }) {
            onLog?("G9N9N HID CONTROL phase=began control=\(control.rawValue)")
            emit(control, phase: .began)
        }
        pressed = controls
    }

    private func emit(_ control: ChromecastRemoteControl, phase: ChromecastRemoteControlPhase, reason: String? = nil) {
        sequence += 1
        onEvent?(.init(control: control, phase: phase, sequence: sequence, cancellationReason: reason))
    }

    private func cancelPressed(reason: String) {
        for control in pressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            emit(control, phase: .cancelled, reason: reason)
        }
        pressed.removeAll()
        reportState.reset()
    }
}
