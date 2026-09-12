import Foundation
import IOKit.hid

final class AppleRemoteVoiceController {
    enum Result: Equatable {
        case accepted
        case deviceManagementInterfaceUnavailable
        case rejected(IOReturn)
    }

    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x004C,
            kIOHIDProductIDKey as String: 0x0315,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        device = Self.findDeviceManagementInterface(manager: manager)
    }

    deinit {
        if let device {
            var report: [UInt8] = [0x98, 0x00]
            report.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                _ = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    0x98,
                    baseAddress,
                    buffer.count
                )
            }
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setActive(_ active: Bool) -> Result {
        guard let device else { return .deviceManagementInterfaceUnavailable }
        var report: [UInt8] = [0x98, active ? 0x01 : 0x00]
        let result = report.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                0x98,
                baseAddress,
                buffer.count
            )
        }
        return result == kIOReturnSuccess ? .accepted : .rejected(result)
    }

    private static func findDeviceManagementInterface(manager: IOHIDManager) -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager) else { return nil }
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        for value in values {
            guard let value else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
            let usagePage = (IOHIDDeviceGetProperty(
                device,
                kIOHIDPrimaryUsagePageKey as CFString
            ) as? NSNumber)?.intValue
            let usage = (IOHIDDeviceGetProperty(
                device,
                kIOHIDPrimaryUsageKey as CFString
            ) as? NSNumber)?.intValue
            if usagePage == 0xFF00, usage == 0x000B {
                return device
            }
        }
        return nil
    }
}
