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
            return LocalizedMessage("已检测到 %@（豆包兼容）", arguments: [deviceName])
        }
        return LocalizedMessage("未检测到 %@", arguments: [deviceName])
    }
}
