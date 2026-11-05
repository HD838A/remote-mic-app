import Foundation

enum RemoteDeviceNamePolicy {
    /// nil 表示本次没有读到有效名称；空字符串表示出厂名称，调用方应清除旧缓存。
    static func customName(
        from rawName: String?,
        model: XiaomiRemoteModel,
        serialNumber: String? = nil
    ) -> String? {
        guard let name = observedSystemName(from: rawName) else { return nil }
        // A2854 can expose its serial as its initial Bluetooth name. Compare this device's
        // actual metadata exactly; never infer a serial from the name's shape or prefix.
        if model == .appleSiriRemoteA2854 || model == .appleSiriRemoteA2540,
           let serialNumber, !serialNumber.isEmpty, rawName == serialNumber {
            return ""
        }
        return isFactoryName(name, model: model) ? "" : name
    }

    static func displayName(
        for profile: RemoteDeviceProfile,
        among profiles: [RemoteDeviceProfile],
        defaultName: String
    ) -> String {
        let customName = normalizedName(profile.customName)
        let base: String
        let peers: [RemoteDeviceProfile]
        if customName.isEmpty {
            base = defaultName
            // 保留原型号编号：已改名的历史档案仍占据其保存顺序中的位置。
            peers = profiles.filter { $0.model == profile.model }
        } else {
            base = customName
            // 同名分组跨型号且包含离线档案；Swift 字符串比较区分大小写。
            peers = profiles.filter { normalizedName($0.customName) == customName }
        }
        guard peers.count > 1,
              let index = peers.firstIndex(where: { $0.id == profile.id })
        else { return base }
        return "\(base) \(index + 1)"
    }

    static func observedSystemName(from rawName: String?) -> String? {
        guard let rawName else { return nil }
        let name = normalizedName(rawName)
        return name.isEmpty ? nil : name
    }

    static func sortedForCards(
        _ profiles: [RemoteDeviceProfile],
        modelName: (RemoteDeviceProfile) -> String,
        systemName: (RemoteDeviceProfile) -> String?
    ) -> [RemoteDeviceProfile] {
        profiles.sorted { lhs, rhs in
            let lhsFamily = cardFamilyOrder(lhs.model)
            let rhsFamily = cardFamilyOrder(rhs.model)
            if lhsFamily != rhsFamily { return lhsFamily < rhsFamily }

            let modelOrder = compareCardNames(modelName(lhs), modelName(rhs), emptyLast: false)
            if modelOrder != .orderedSame { return modelOrder == .orderedAscending }

            let systemOrder = compareCardNames(systemName(lhs), systemName(rhs), emptyLast: true)
            if systemOrder != .orderedSame { return systemOrder == .orderedAscending }

            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    /// 卡片区不重复展示同一台设备。
    ///
    /// 指纹会随接口、重新配对或指纹算法版本变化，同一台遥控器因此可能留下两条档案；
    /// 旧档案还把序列号存成了设备名，于是两张卡片标题相同、第二行也是同一个序列号。
    /// 两台真实设备不可能共用序列号，所以「同型号 + 同一个像序列号的名字」只保留一条：
    /// 优先正在用的那条，其余留在前面的那条。
    ///
    /// 只影响展示，不改写已保存的档案——合并档案会连带丢掉另一条上配置过的映射。
    static func cardsWithoutRepeatedSerial(
        _ profiles: [RemoteDeviceProfile],
        selectedProfileID: UUID?,
        isConnected: (RemoteDeviceProfile) -> Bool,
        systemName: (RemoteDeviceProfile) -> String?
    ) -> [RemoteDeviceProfile] {
        // 正在编辑的那条不参与去重：藏掉它，页面就会在编辑一台卡片上看不到的设备，
        // 用户会以为配置丢了。宁可这一组暂时显示两张，也不让编辑目标消失。
        let pinnedKey = profiles.first { $0.id == selectedProfileID }
            .flatMap { serialKey(for: $0, systemName: systemName) }
        var result: [RemoteDeviceProfile] = []
        var indexByKey: [String: Int] = [:]
        for profile in profiles {
            guard let key = serialKey(for: profile, systemName: systemName), key != pinnedKey else {
                result.append(profile)
                continue
            }
            guard let index = indexByKey[key] else {
                indexByKey[key] = result.count
                result.append(profile)
                continue
            }
            // 同一台设备只留一张：优先正在用的那条，其次留在前面的那条。
            if isConnected(profile), !isConnected(result[index]) {
                result[index] = profile
            }
        }
        return result
    }

    /// 名字不像序列号（例如「客厅」）时无法证明是同一台设备，返回 nil 表示不参与去重。
    private static func serialKey(
        for profile: RemoteDeviceProfile,
        systemName: (RemoteDeviceProfile) -> String?
    ) -> String? {
        guard let name = systemName(profile), RemoteDeviceIdentity.looksLikeSerial(name) else {
            return nil
        }
        return "\(profile.model.rawValue)|\(name.uppercased())"
    }

    static func defaultMappingProfile(
        from profiles: [RemoteDeviceProfile]
    ) -> RemoteDeviceProfile? {
        profiles.first { $0.model == .rc001 || $0.model == .rc003 }
    }

    /// 链路就绪事件是否接管按键页的选中态。
    ///
    /// 多遥控器同时在线时按键页优选小米画布：Chromecast 不得抢走已连接的小米。
    /// 启动顺序不稳定（Chromecast 常比小米先 ready），只按「谁后连谁赢」会让页面
    /// 永远停在 Chromecast。其余情况保持「连接即选中」，与小米链路的
    /// `activateRemoteProfile` 一致。
    static func shouldAdoptConnectionSelection(
        for incoming: XiaomiRemoteModel,
        isAlreadySelected: Bool,
        hasConnectedXiaomi: Bool
    ) -> Bool {
        guard !isAlreadySelected else { return false }
        return !(incoming.isChromecastRemote && hasConnectedXiaomi)
    }

    private static func cardFamilyOrder(_ model: XiaomiRemoteModel) -> Int {
        switch model {
        case .rc001, .rc003: 0
        case .appleSiriRemoteA2854, .appleSiriRemoteA2540: 1
        case .chromecastVoiceRemote, .googleTVRemoteG9N9N: 2
        case .unknown: 3
        }
    }

    private static func normalizedName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\t")))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    private static func compareCardNames(
        _ lhs: String?,
        _ rhs: String?,
        emptyLast: Bool
    ) -> ComparisonResult {
        let left = cardSortKey(lhs)
        let right = cardSortKey(rhs)
        if emptyLast, left.isEmpty != right.isEmpty {
            return left.isEmpty ? .orderedDescending : .orderedAscending
        }
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private static func cardSortKey(_ rawName: String?) -> String {
        guard let name = rawName.map(normalizedName), !name.isEmpty else { return "" }
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let withoutDiacritics = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return withoutDiacritics
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isFactoryName(_ name: String, model: XiaomiRemoteModel) -> Bool {
        let lowercased = name.lowercased()
        switch model {
        case .rc001, .rc003:
            return XiaomiVoiceRemoteNameMatcher.matches(name) || [
                "小米蓝牙遥控器 2",
                "小米蓝牙遥控器 2 pro",
            ].contains(lowercased)
        case .appleSiriRemoteA2854, .appleSiriRemoteA2540:
            let commonNames = ["siri remote", "apple tv remote", "apple remote"]
            let modelNames = model == .appleSiriRemoteA2854
                ? ["苹果遥控器 type-c", "apple remote type-c"]
                : ["苹果遥控器 lightning", "apple remote lightning"]
            return commonNames.contains(lowercased) || modelNames.contains(lowercased)
        case .chromecastVoiceRemote:
            return ["chromecast 遥控器", "chromecast remote"].contains(lowercased)
        case .googleTVRemoteG9N9N:
            // 出厂名以型号本身与英文组合名为准；中文零售名（「谷歌电视遥控器」等）
            // 尚无真机上报证据，不预置——宁可让用户看到系统名，也不猜。
            return ["g9n9n", "g9n9n remote", "remote g9n9n"].contains(lowercased)
        case .unknown:
            // 小米发现阶段可能先读到名称、后读到型号；沿用已有发现白名单。
            return XiaomiVoiceRemoteNameMatcher.matches(name)
        }
    }
}
