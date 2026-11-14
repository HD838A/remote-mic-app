import Foundation

enum DoubaoAudioDevicePolicy {
    static let deviceUID = "MiRemoteV2ch_UID"
    static let deviceName = "SayAll"
    static let legacyDeviceName = "MiRemoteV 2ch"

    static func device(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        // Prefer the stable UID, even if a physical device has the same name.
        devices.first { $0.uid == deviceUID }
            ?? devices.first { $0.name == legacyDeviceName }
    }
}
