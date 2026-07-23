import Foundation

enum DoubaoAudioDevicePolicy {
    static let deviceUID = "MiRemoteV2ch_UID"
    static let deviceName = "MiRemoteV 2ch"

    static func device(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        devices.first { device in
            device.uid == deviceUID || device.name == deviceName
        }
    }

    static func status(in devices: [AudioDeviceInfo]) -> String {
        if device(in: devices) != nil {
            return "已检测到 \(deviceName)（豆包兼容）"
        }
        return "未检测到 \(deviceName)"
    }
}
