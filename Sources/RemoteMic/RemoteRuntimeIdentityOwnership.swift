import Foundation

/// Runtime channels are keyed by Bluetooth identifier and HID fingerprint, not by profile ID.
/// Conflicting duplicate profiles may therefore share one of those identities. Deleting one
/// history profile must not stop a bridge or monitor that another profile still uses.
enum RemoteRuntimeIdentityOwnership {
    static func hasOtherBluetoothOwner(
        of identifier: UUID,
        excluding profileID: UUID,
        in profiles: [RemoteDeviceProfile]
    ) -> Bool {
        profiles.contains {
            $0.id != profileID && $0.bluetoothIdentifier == identifier
        }
    }

    static func hasOtherHIDOwner(
        of fingerprint: String,
        excluding profileID: UUID,
        in profiles: [RemoteDeviceProfile]
    ) -> Bool {
        profiles.contains {
            $0.id != profileID && $0.hidFingerprint == fingerprint
        }
    }
}
