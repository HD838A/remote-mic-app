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

    static func status(in devices: [AudioDeviceInfo]) -> LocalizedMessage {
        if let device = device(in: devices) {
            return LocalizedMessage("audio.compatibility.device_detected", arguments: [device.name])
        }
        return LocalizedMessage("audio.compatibility.device_not_detected", arguments: [deviceName])
    }
}
