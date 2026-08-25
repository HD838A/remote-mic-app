import Foundation

enum DoubaoAudioDevicePolicy {
    static let deviceUID = "MiRemoteV2ch_UID"
    static let deviceName = "MiRemoteV 2ch"

    static func device(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        devices.first { device in
            device.uid == deviceUID || device.name == deviceName
        }
    }

    static func status(in devices: [AudioDeviceInfo]) -> LocalizedMessage {
        if device(in: devices) != nil {
            return LocalizedMessage("audio.compatibility.device_detected", arguments: [deviceName])
        }
        return LocalizedMessage("audio.compatibility.device_not_detected", arguments: [deviceName])
    }

    static func resolvedDeviceUID(
        requestedUID: String,
        qianwenModeEnabled: Bool,
        devices: [AudioDeviceInfo]
    ) -> String {
        guard qianwenModeEnabled else { return requestedUID }
        return device(in: devices)?.uid ?? ""
    }

    static func persistedDeviceUID(
        resolvedDeviceUID: String,
        qianwenModeEnabled: Bool
    ) -> String {
        guard qianwenModeEnabled, resolvedDeviceUID.isEmpty else {
            return resolvedDeviceUID
        }
        return deviceUID
    }
}
