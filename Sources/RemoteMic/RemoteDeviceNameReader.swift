import Foundation
import IOBluetooth
import IOKit.hid

/// Read-only metadata lookup for HID-backed remotes. Never opens or reconnects a device.
enum RemoteDeviceNameReader {
    struct HIDIdentity {
        let fingerprint: String
        let address: String?
        var serialNumber: String? = nil
    }

    struct PairedDevice {
        let address: String
        let name: String?
    }

    /// Transient observation only; serial numbers must never be persisted or logged.
    struct HIDName: Equatable {
        let name: String
        let serialNumber: String?
    }

    static func readHIDNames() -> [String: HIDName] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let identities = devices.compactMap { device -> HIDIdentity? in
            guard let fingerprint = HIDRemoteMonitor.fingerprint(for: device) else { return nil }
            return HIDIdentity(
                fingerprint: fingerprint,
                address: IOHIDDeviceGetProperty(device, "DeviceAddress" as CFString) as? String,
                serialNumber: IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            )
        }
        // Re-enumerate on every requested refresh: retained objects may keep the old name.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap {
            device -> PairedDevice? in
            guard let address = device.addressString else { return nil }
            return PairedDevice(address: address, name: device.name)
        }
        return namesByFingerprint(identities: identities, paired: paired)
    }

    static func namesByFingerprint(
        identities: [HIDIdentity],
        paired: [PairedDevice]
    ) -> [String: HIDName] {
        let byFingerprint = Dictionary(grouping: identities, by: \.fingerprint)
        var result: [String: HIDName] = [:]
        for (fingerprint, interfaces) in byFingerprint {
            let addresses = Set(interfaces.compactMap { normalizedAddress($0.address) })
            guard addresses.count == 1, let address = addresses.first else { continue }
            let names = Set(paired.filter { normalizedAddress($0.address) == address }.compactMap(\.name))
            guard names.count == 1, let name = names.first else { continue }
            let serials = Set(interfaces.compactMap(\.serialNumber).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            // Multiple HID interfaces may share one identity; conflicting serials are not evidence.
            result[fingerprint] = HIDName(
                name: name,
                serialNumber: serials.count == 1 ? serials.first : nil
            )
        }
        return result
    }

    private static func normalizedAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.lowercased().replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard value.count == 12,
              value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        return value
    }
}

enum RemoteDeviceNameRefreshReason: String {
    case startup
    case connection
    case foreground
    case page
    case peripheralEvent = "peripheral_event"
}
