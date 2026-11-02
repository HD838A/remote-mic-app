import CryptoKit
import Foundation

/// 遥控器档案的稳定身份。
///
/// `hidFingerprint` 由设备属性回退链生成（物理唯一 ID → 序列号 → 设备地址 → 位置），
/// 换接口、重新配对或升级指纹算法都会让它变化。同一台遥控器换了 fingerprint 之后，
/// 档案按指纹去重就认不出来，卡片上会出现两个一模一样、序列号也相同的设备。
///
/// 序列号才是这台设备的稳定身份，但序列号本身**不得落盘或写日志**，所以这里只保存
/// 它的单向摘要。旧档案在迁移前把序列号当成设备名存过（Apple Remote 首次配对会用
/// 序列号当蓝牙名），因此「像序列号的设备名」可以算出同一个摘要，用于把历史重复项
/// 并回一条档案。
enum RemoteDeviceIdentity {
    /// 前缀参与哈希，避免这份摘要与其它地方的摘要混用。
    private static let serialPrefix = "sayall.remote.serial.v1:"

    /// 序列号的单向摘要。只保存摘要，不保存也不记录序列号本身。
    static func token(serialNumber: String) -> String? {
        let normalized = serialNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((serialPrefix + normalized).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 旧档案把序列号存成了设备名。只有「像序列号」的名字参与身份比较，
    /// 普通名字（例如用户起的「客厅」）不参与，避免把两台同名遥控器并成一台。
    static func legacyToken(storedName: String) -> String? {
        let name = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeSerial(name) else { return nil }
        return token(serialNumber: name)
    }

    /// 序列号形态：8–32 位、全部大写字母或数字、至少一位数字。
    static func looksLikeSerial(_ value: String) -> Bool {
        guard (8...32).contains(value.count) else { return false }
        guard value.contains(where: { $0.isNumber }) else { return false }
        return value.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// 去重键。稳定身份优先，其次才是 fingerprint；两者都没有的档案按自身 ID 独占。
    static func key(for profile: RemoteDeviceProfile) -> String {
        if let identity = profile.hardwareIdentity, !identity.isEmpty {
            return "serial:\(identity)"
        }
        if let legacy = legacyToken(storedName: profile.customName) {
            return "serial:\(legacy)"
        }
        if let fingerprint = profile.hidFingerprint, !fingerprint.isEmpty {
            return "fingerprint:\(fingerprint)"
        }
        return "profile:\(profile.id.uuidString.lowercased())"
    }
}
