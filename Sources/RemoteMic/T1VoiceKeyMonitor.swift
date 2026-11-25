import Foundation
import IOKit.hid
import IOKit.hidsystem

/// Tracks the physical voice key independently of the synthetic Search event.
final class T1VoiceKeyMonitor {
    private let onRelease: () -> Void
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

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
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
            guard let context, result == kIOReturnSuccess, reportID == 1,
                  length == 8 || length == 9
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
        guard hasUniqueDevice, let down = T1VoiceRemote.voiceIsHeld(reportID: reportID, bytes: bytes) else { return }
        let released = held && !down
        held = down
        if released { onRelease() }
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        held = false
        searchMapper.restore()
    }
}
