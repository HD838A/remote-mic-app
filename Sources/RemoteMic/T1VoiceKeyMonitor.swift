import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Reads T1 front controls and the physical voice key without seizing its keyboard or mouse.
final class T1VoiceKeyMonitor {
    private let onRelease: () -> Void
    private let onButton: (T1FrontButtonEdge) -> Void
    private var frontButtons = T1FrontButtonTracker()
    private var manager: IOHIDManager?
    private var held = false
    private let searchMapper = RemoteVoiceFunctionMapper(
        voiceMapping: HIDUsageMapping(source: T1VoiceRemote.searchUsage, destination: 0),
        serviceProvider: {
            RemoteVoiceFunctionMapper.systemServices(
                vendor: T1VoiceRemote.vendorID, products: [T1VoiceRemote.productID]
            )
        }
    )

    init(onRelease: @escaping () -> Void, onButton: @escaping (T1FrontButtonEdge) -> Void) {
        self.onRelease = onRelease
        self.onButton = onButton
    }

    deinit { stop() }

    func start() -> Bool {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            return false
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: T1VoiceRemote.vendorID,
            kIOHIDProductIDKey: T1VoiceRemote.productID,
        ] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, _, reportID, data, length in
            guard let context, result == kIOReturnSuccess,
                  (1...3).contains(reportID), (1...9).contains(length)
            else { return }
            let monitor = Unmanaged<T1VoiceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.receive(reportID: reportID, bytes: Array(UnsafeBufferPointer(start: data, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              hasUniqueDevice,
              searchMapper.apply(neutralizeVoiceKey: true, preservePowerKeyMapping: true),
              searchMapper.voiceMappingReadbackMatched == true,
              hasUniqueDevice
        else {
            stop()
            return false
        }
        return true
    }

    var hasUniqueDevice: Bool {
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) else { return false }
        return CFSetGetCount(devices) == 1
    }

    private func receive(reportID: UInt32, bytes: [UInt8]) {
        guard hasUniqueDevice else { return }
        if let down = T1VoiceRemote.voiceIsHeld(reportID: reportID, bytes: bytes) {
            let released = held && !down
            held = down
            if released { onRelease() }
        }
        for edge in frontButtons.observe(reportID: reportID, bytes: bytes) {
            onButton(edge)
        }
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        held = false
        frontButtons = T1FrontButtonTracker()
        searchMapper.restore()
    }
}
