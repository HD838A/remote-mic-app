#if canImport(SayAllMacroRemoteMic)
import AppKit
import Foundation
import SayAllMacroCore
import SayAllMacroRemoteMic

extension AppSettings {
    func portableHostAdapter(beforeApply: @escaping (Data) throws -> Void) -> RemoteMicPortableHostAdapter {
        RemoteMicPortableHostAdapter(currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.21",
            objectSummaries: { [unowned self] in customApplicationProfiles.map {
                .init(root: .init(kind: .application,id: $0.id.uuidString),name: $0.displayName)
            } },
            exportObjects: { [unowned self] in try portableObjects(applicationIDs: $0,groups: $1,hostActions: $2) },
            prepare: { [unowned self] in try preparePortable($0, options: $1) },
            snapshot: { [unowned self] in try portableLocalSnapshot() },
            apply: { [unowned self] data in
                try beforeApply(data)
                try applyPortableLocalSnapshot(data)
            }, exportAction: { [unowned self] in try portableAction(JSONDecoder().decode(ConfiguredButtonAction.self, from: $0)) },
            importAction: { action, package in try JSONEncoder().encode(Self.configuredPortableAction(action, package: package)) })
    }

    static func portableRemoteModel(_ model: XiaomiRemoteModel?) -> String {
        switch model {
        case .rc001: return "xiaomi-remote-rc001"
        case .appleSiriRemoteA2854: return "apple-siri-remote-a2854"
        case .appleSiriRemoteA2540: return "apple-siri-remote-a2540"
        case .chromecastVoiceRemote: return "chromecast-voice-remote"
        default: return "xiaomi-remote-2-pro"
        }
    }
    private static func shortcutID(_ s: CustomKeyboardShortcut) -> String {
        "host.shortcut.\(s.keyCode).\(s.modifierFlags.rawValue)"
    }
    private static func portableShortcut(_ s: CustomKeyboardShortcut, name: String) -> PortableKeyboardShortcut {
        let flags: [(KeyboardModifier,NSEvent.ModifierFlags)] = [(.command,.command),(.shift,.shift),(.option,.option),(.control,.control),(.function,.function)]
        return .init(id: shortcutID(s), displayName: name, keyCode: s.keyCode, keyLabel: s.keyLabel,
            modifiers: flags.filter { s.modifierFlags.contains($0.1) }.map(\.0),
            deviceModifierFlags: s.modifierFlags.rawValue & 0x207f == 0 ? nil : UInt64(s.modifierFlags.rawValue & 0x207f))
    }
    private static func shortcut(_ s: PortableKeyboardShortcut) -> CustomKeyboardShortcut {
        var flags = NSEvent.ModifierFlags(rawValue: UInt(s.deviceModifierFlags ?? 0))
        for modifier in s.modifiers {
            switch modifier {
            case .command: flags.insert(.command)
            case .shift: flags.insert(.shift)
            case .option: flags.insert(.option)
            case .control: flags.insert(.control)
            case .function: flags.insert(.function)
            }
        }
        return .init(keyCode: s.keyCode, modifierFlags: flags, keyLabel: s.keyLabel)
    }
    private static func fingerprint(_ t: AccessibilityFocusTarget) -> FocusTargetFingerprint {
        .init(role: t.role, identifier: t.identifier, title: t.title, elementDescription: t.description,
            help: t.help, placeholder: t.placeholder, context: t.context, windowTitle: t.windowTitle,
            normalizedFrame: t.normalizedFrame.map { .init(x: $0.x,y: $0.y,width: $0.width,height: $0.height) })
    }
    private static func target(_ t: FocusTargetFingerprint) -> AccessibilityFocusTarget {
        .init(role: t.role, identifier: t.identifier, title: t.title, description: t.elementDescription,
            help: t.help, placeholder: t.placeholder, context: t.context, windowTitle: t.windowTitle,
            normalizedFrame: t.normalizedFrame.map { .init(x: $0.x,y: $0.y,width: $0.width,height: $0.height) })
    }
    private func portableAction(_ c: ConfiguredButtonAction) throws -> PortableAction {
        switch c.action {
        case .disabled: return .init(kind: .disabled)
        case .customShortcut:
            guard let s = c.shortcut else { throw PortableTransferError.missingDependency("快捷键") }
            return .init(kind: .shortcut, referenceID: Self.shortcutID(s))
        case .openCustomApplication:
            guard let id = c.applicationProfileID, customApplicationProfile(id: id) != nil else { throw PortableTransferError.missingDependency("App 配置") }
            return .init(kind: .application, referenceID: id.uuidString)
        default:
            guard PortableTransferCodec.hostActions.contains(c.action.rawValue) else { throw PortableTransferError.invalid(c.action.rawValue) }
            return .init(kind: .host, actionID: c.action.rawValue)
        }
    }
    private static func configuredPortableAction(_ a: PortableAction, package: PortableTransferPackage) throws -> ConfiguredButtonAction {
        switch a.kind {
        case .disabled, .inherit: return .disabled
        case .host:
            guard let id = a.actionID, PortableTransferCodec.hostActions.contains(id), let action = ButtonAction(rawValue: id) else { throw PortableTransferError.invalid("宿主操作") }
            return .init(action: action, shortcut: nil)
        case .shortcut:
            guard let s = package.shortcuts.first(where: { $0.id == a.referenceID }) else { throw PortableTransferError.missingDependency("快捷键") }
            return .init(action: .customShortcut, shortcut: shortcut(s))
        case .application:
            guard let value = a.referenceID, let id = UUID(uuidString: value), package.applications.contains(where: { $0.id == value }) else { throw PortableTransferError.missingDependency("App 配置") }
            return .init(action: .openCustomApplication, shortcut: nil, applicationProfileID: id)
        case .macro: throw PortableTransferError.invalid("组合动作由动作库保存")
        }
    }
    private func portableObjects(applicationIDs: Set<String>, groups: Set<String>, hostActions: [Data]) throws -> PortableTransferPackage {
        var p = PortableTransferPackage(minimumRemoteMicVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.9.21", exportPurpose: .personalBackup)
        var requiredApplications = applicationIDs
        var bindings: [PortableButtonBinding] = []
        var actions = try hostActions.map { try JSONDecoder().decode(ConfiguredButtonAction.self,from: $0) }
        if groups.contains("mappings") {
            for button in RemoteButton.allCases {
                for trigger in ButtonTrigger.allCases {
                    let c = configuredAction(for: button,trigger: trigger)
                    actions.append(c)
                    let gesture = trigger == .singleClick ? "singlePress" : trigger == .doubleClick ? "doublePress" : "longPress"
                    bindings.append(.init(controlID: button.rawValue.replacingOccurrences(of: "_",with: "-"),gesture: gesture,target: try portableAction(c)))
                }
            }
        }
        for c in actions {
            _ = try portableAction(c)
            if c.action == .customShortcut, let s = c.shortcut { p.shortcuts.append(Self.portableShortcut(s,name: s.keyLabel)) }
            if c.action == .openCustomApplication, let id = c.applicationProfileID { requiredApplications.insert(id.uuidString) }
        }
        for a in customApplicationProfiles where requiredApplications.contains(a.id.uuidString) {
            let id = a.id.uuidString
            var app = PortableApplication(id: id, displayName: a.displayName, bundleIdentifier: a.bundleIdentifier,
                focusStrategy: .init(rawValue: a.focusStrategy.rawValue)!)
            if a.focusStrategy == .keyboardShortcut, let s = a.focusShortcut {
                app.shortcutID = Self.shortcutID(s); p.shortcuts.append(Self.portableShortcut(s, name: s.keyLabel))
            }
            if a.focusStrategy == .recordedAccessibility {
                app.focusTargetID = "host.focus.\(id)"
                p.focusTargets.append(.init(id: app.focusTargetID!, displayName: a.displayName, bundleIdentifier: a.bundleIdentifier,
                    target: a.accessibilityTarget.map(Self.fingerprint)))
            }
            p.applications.append(app); p.roots.append(.init(kind: .application,id: id))
        }
        p.shortcuts = Dictionary(grouping: p.shortcuts, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
        if !groups.isEmpty {
            p.hostSettings = .init(general: groups.contains("general") ? .init(applicationLanguage: applicationLanguage.rawValue, appIconIdentifier: appIconIdentifier.rawValue,
                showDockIcon: showDockIcon,showStatusBarIcon: showStatusBarIcon,openMainWindowAtLaunch: openMainWindowAtLaunch,
                checksForPreReleaseUpdates: checksForPreReleaseUpdates) : nil,
                audio: groups.contains("audio") ? .init(gainDB: gainDB) : nil,
                voice: groups.contains("voice") ? .init(voiceKeyMode: voiceKeyMode.rawValue,voiceFnTapModeEnabled: voiceFnTapModeEnabled) : nil,
                mappings: groups.contains("mappings") ? .init(remoteModel: Self.portableRemoteModel(selectedRemoteProfile?.model),customMappingEnabled: customMappingEnabled,
                    bindings: bindings,rapidPressControls: buttonRapidPressEnabled.filter(\.value).keys.map { $0.rawValue.replacingOccurrences(of: "_",with: "-") }.sorted()) : nil)
            p.roots.append(.init(kind: .hostSettings,id: p.hostSettings!.id))
        }
        return p
    }

    private func preparePortable(_ input: PortableTransferPackage, options: RemoteMicPortableImportOptions) throws -> RemoteMicPortableHostPreparation {
        var p = input
        let before = try portableLocalSnapshot()
        var envelope = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        var c = envelope["configuration"] as! [String: Any]
        var pending = portablePendingApplications
        var profiles = customApplicationProfiles
        var map: [String:String] = [:]
        var count = 0
        var affected: [String] = []
        guard Set(options.applicationReplacements.values).count == options.applicationReplacements.values.count else { throw PortableTransferError.invalid("不能用多个 App 配置替换同一配置") }
        for a in p.applications {
            var profile = CustomApplicationProfile(displayName: a.displayName,bundleIdentifier: a.bundleIdentifier,
                applicationPath: "",focusStrategy: .init(rawValue: a.focusStrategy.rawValue)!,
                focusShortcut: p.shortcuts.first { $0.id == a.shortcutID }.map(Self.shortcut),
                accessibilityTarget: p.focusTargets.first { $0.id == a.focusTargetID }?.target.map(Self.target))
            if !options.createCopies, options.applicationReplacements[a.id] == nil, let same = profiles.first(where: { $0.displayName == profile.displayName && $0.bundleIdentifier == profile.bundleIdentifier && $0.focusStrategy == profile.focusStrategy && $0.focusShortcut == profile.focusShortcut && $0.accessibilityTarget == profile.accessibilityTarget }) {
                map[a.id] = same.id.uuidString
                continue
            }
            if let id = options.applicationReplacements[a.id] {
                guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw PortableTransferError.concurrentChange }
                profile = CustomApplicationProfile(id: id,displayName: profile.displayName,bundleIdentifier: profile.bundleIdentifier,
                    applicationPath: "",focusStrategy: profile.focusStrategy,focusShortcut: profile.focusShortcut,accessibilityTarget: profile.accessibilityTarget)
                affected.append("App: \(profiles[index].displayName) → \(profile.displayName)")
                for device in remoteDeviceProfiles {
                    for (key, value) in (device.mappings.buttonApplicationProfileIDs ?? [:]) where value == id {
                        affected.append("\(device.customName.isEmpty ? device.model.rawValue : device.customName): \(key) · singlePress")
                    }
                    for (key, values) in device.mappings.secondaryButtonBindings {
                        for (trigger, value) in values where value.applicationProfileID == id {
                            affected.append("\(device.customName.isEmpty ? device.model.rawValue : device.customName): \(key) · \(trigger)")
                        }
                    }
                }
                for button in RemoteButton.allCases {
                    for trigger in ButtonTrigger.allCases where configuredAction(for: button,trigger: trigger).applicationProfileID == id {
                        affected.append("\(button.rawValue) · \(trigger.rawValue)")
                    }
                }
                profiles.remove(at: index)
                pending.remove(id.uuidString)
            }
            let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: a.bundleIdentifier)
            if urls.count == 1 { profile.applicationPath = urls[0].path }
            else if urls.count > 1 {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.allowedFileTypes = ["app"]; panel.message = "\(a.displayName)：选择要使用的 App 副本"
                guard panel.runModal() == .OK, let url = panel.url, Bundle(url: url)?.bundleIdentifier == a.bundleIdentifier else { throw PortableTransferError.invalid("尚未选择匹配的 App 副本") }
                profile.applicationPath = url.path
            }
            map[a.id] = profile.id.uuidString
            if a.focusStrategy == .recordedAccessibility { pending.insert(profile.id.uuidString) }
            profiles.append(profile); if options.applicationReplacements[a.id] == nil { count += 1 }
        }
        p = PortableTransferGraph.remapping(p, macros: [:],shortcuts: [:],focuses: [:],applications: map)
        p.applications = Dictionary(grouping: p.applications,by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
        p.roots = p.roots.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        c["customApplicationProfiles"] = try Self.json(profiles)
        if let g = p.hostSettings?.general {
            c["applicationLanguage"] = g.applicationLanguage; c["appIconIdentifier"] = g.appIconIdentifier
            c["showDockIcon"] = g.showDockIcon; c["showStatusBarIcon"] = g.showStatusBarIcon
            c["openMainWindowAtLaunch"] = g.openMainWindowAtLaunch; c["checksForPreReleaseUpdates"] = g.checksForPreReleaseUpdates
        }
        if let a = p.hostSettings?.audio { c["gainDB"] = a.gainDB }
        if let v = p.hostSettings?.voice { c["voiceKeyMode"] = v.voiceKeyMode; c["voiceFnTapModeEnabled"] = v.voiceFnTapModeEnabled }
        if let m = p.hostSettings?.mappings {
            var actions = c["buttonBindings"] as? [String:Any] ?? [:]
            var shortcuts = c["buttonShortcuts"] as? [String:Any] ?? [:]
            var apps = c["buttonApplicationProfileIDs"] as? [String:Any] ?? [:]
            var secondary = c["secondaryButtonBindings"] as? [String:[String:Any]] ?? [:]
            for b in m.bindings where b.target.kind != .inherit {
                let key = b.controlID.replacingOccurrences(of: "-",with: "_")
                let trigger = b.gesture == "singlePress" ? "singleClick" : b.gesture == "doublePress" ? "doubleClick" : "longPress"
                let configured = b.target.kind == .macro ? ConfiguredButtonAction.disabled : try Self.configuredPortableAction(b.target, package: p)
                if trigger == "singleClick" {
                    actions[key] = configured.action.rawValue
                    shortcuts[key] = try configured.shortcut.map(Self.json)
                    apps[key] = configured.applicationProfileID?.uuidString
                } else { secondary[key,default: [:]][trigger] = try Self.json(configured) }
            }
            c["customMappingEnabled"] = m.customMappingEnabled; c["buttonBindings"] = actions
            c["buttonShortcuts"] = shortcuts; c["buttonApplicationProfileIDs"] = apps; c["secondaryButtonBindings"] = secondary
            c["buttonRapidPressEnabled"] = Dictionary(uniqueKeysWithValues: m.rapidPressControls.map { ($0.replacingOccurrences(of: "-",with: "_"),true) })
        }
        envelope["configuration"] = c; envelope["pendingApplications"] = pending.sorted()
        let after = try JSONSerialization.data(withJSONObject: envelope,options: [.sortedKeys])
        return .init(package: p,before: before,after: after,newApplicationCount: count, affectedBindings: affected)
    }
    private static func json<T:Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value),options: [.fragmentsAllowed]) }
}
#endif
