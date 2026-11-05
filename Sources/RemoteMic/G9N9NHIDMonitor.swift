import Foundation
import IOKit.hid

/// Only opens the Jieli HID interfaces, never the original Google remote.
/// Unknown vendor usages are learned explicitly instead of guessing branded keys.
final class G9N9NHIDMonitor {
    var prepareNativeInput: (([UInt64]) -> Bool)?
    var restoreNativeInput: (() -> Void)?
    var onEvent: ((ChromecastRemoteControlEvent) -> Void)?
    var onPresence: ((Bool) -> Void)?
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
    private var access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    private var learning: ChromecastRemoteControl? {
        didSet { onLearningChange?(learning?.rawValue) }
    }
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
        learning = control
        learningTimeout?.cancel()
        if running { updateNativeInput() }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.learning = nil
            self.onLog?("G9N9N HID learning=timed_out")
            if self.running { self.updateNativeInput() }
        }
        learningTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func cancelLearning() {
        guard learning != nil else { return }
        learning = nil
        learningTimeout?.cancel()
        learningTimeout = nil
        if running { updateNativeInput() }
    }

    func stop() {
        running = false
        learningTimeout?.cancel()
        learningTimeout = nil
        learning = nil
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
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<G9N9NHIDMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
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
               [7, 12].contains(page), usage > 0, usage < 0xFFFF {
                sources.insert(page << 32 | usage)
            }
        }
        return sources.sorted()
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String == "zhuhai_jieli" else { return }
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard page == 7 || page == 12, usage > 0, usage < 0xFFFF else { return }
        let key = "\(page):\(usage)"
        let down = IOHIDValueGetIntegerValue(value) != 0
        if let learning {
            guard down, isNativeMappingPrepared else { return }
            learned = learned.filter { $0.value != learning.rawValue }
            learned[key] = learning.rawValue
            defaults.set(learned, forKey: Self.key)
            self.learning = nil
            learningTimeout?.cancel()
            onLog?("G9N9N HID learning=completed control=\(learning.rawValue)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.updateNativeInput()
            }
            return
        }
        guard let control = learned[key].flatMap(ChromecastRemoteControl.init(rawValue:))
                ?? Self.control(page: page, usage: usage) else { return }
        if down {
            guard pressed.insert(control).inserted else { return }
        } else {
            guard pressed.remove(control) != nil else { return }
        }
        emit(control, phase: down ? .began : .ended)
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
    }
}
