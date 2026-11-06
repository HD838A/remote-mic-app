import AppKit
import Combine
import SayAllMacRemoteCore

enum VoiceSessionWarningLevel: String, Equatable {
    case none
    case warning
    case critical

    static func resolve(elapsed: TimeInterval, model: XiaomiRemoteModel) -> Self {
        guard model == .rc001 || model == .rc003 else { return .none }
        if elapsed >= 57 { return .critical }
        if elapsed >= 53 { return .warning }
        return .none
    }
}

/// Presentation only: a connection is not proof that audio or input permissions are ready.
enum StatusItemPresentation: String, Equatable {
    case disconnected
    case connected
    case streaming
    case streamingWarning = "streaming_warning"
    case streamingCritical = "streaming_critical"

    var descriptionKey: String {
        switch self {
        case .streamingWarning, .streamingCritical:
            return "status_item.state.streaming"
        default:
            return "status_item.state.\(rawValue)"
        }
    }

    static func resolve(
        physicalConnected: Bool,
        phoneConnected: Bool,
        watchConnected: Bool,
        webState: WebRemoteSessionState,
        isStreaming: Bool,
        voiceWarningLevel: VoiceSessionWarningLevel = .none
    ) -> Self {
        if isStreaming {
            switch voiceWarningLevel {
            case .none: return .streaming
            case .warning: return .streamingWarning
            case .critical: return .streamingCritical
            }
        }
        if physicalConnected || phoneConnected || watchConnected { return .connected }
        if case .connected = webState { return .connected }
        return .disconnected
    }

    static func publisher(
        physicalConnected: AnyPublisher<Bool, Never>,
        phoneConnected: AnyPublisher<Bool, Never>,
        watchConnected: AnyPublisher<Bool, Never>,
        webState: AnyPublisher<WebRemoteSessionState, Never>,
        isStreaming: AnyPublisher<Bool, Never>,
        voiceWarningLevel: AnyPublisher<VoiceSessionWarningLevel, Never>? = nil
    ) -> AnyPublisher<Self, Never> {
        let warning = voiceWarningLevel ?? Just(VoiceSessionWarningLevel.none).eraseToAnyPublisher()
        return Publishers.CombineLatest4(
            physicalConnected, phoneConnected, watchConnected, webState
        )
        .combineLatest(isStreaming, warning)
        .map { connections, streaming, warningLevel in
            resolve(
                physicalConnected: connections.0,
                phoneConnected: connections.1,
                watchConnected: connections.2,
                webState: connections.3,
                isStreaming: streaming,
                voiceWarningLevel: warningLevel
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    @MainActor
    func apply(to button: NSStatusBarButton, description: String) {
        let isStreaming = self == .streaming || self == .streamingWarning || self == .streamingCritical
        let resourceName = isStreaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = isStreaming ? "mic.fill" : "dot.radiowaves.left.and.right"
        // Named images are shared. Keep localized descriptions local to this status item.
        let templateImage = (NSImage(named: NSImage.Name(resourceName))?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
        let image: NSImage?
        switch self {
        case .streamingWarning:
            image = Self.coloredImage(templateImage, color: .systemYellow)
        case .streamingCritical:
            image = Self.coloredImage(templateImage, color: .systemRed)
        default:
            image = templateImage
            image?.isTemplate = true
        }
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = description
        button.image = image
        button.title = image == nil ? description : ""
        button.contentTintColor = nil
        button.appearsDisabled = self == .disconnected
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private static func coloredImage(_ source: NSImage?, color: NSColor) -> NSImage? {
        guard let source else { return nil }
        let image = NSImage(size: source.size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(origin: .zero, size: source.size)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceIn)
        image.isTemplate = false
        return image
    }
}

@MainActor
enum StatusMenuBatterySection {
    static let itemIdentifier = NSUserInterfaceItemIdentifier("remoteBattery")

    static func update(
        in menu: NSMenu, before anchor: NSMenuItem,
        profiles: [RemoteDeviceProfile], connectedIDs: Set<UUID>,
        levels: [UUID: Int], powerStates: [UUID: RemotePowerState],
        localization: LocalizationStore
    ) {
        guard anchor.menu === menu else { return }
        let connected = profiles.filter { connectedIDs.contains($0.id) }
        let titles = connected.compactMap { profile -> String? in
            let level = levels[profile.id]
            let power = powerStates[profile.id]
            guard RemoteBatteryPresentationPolicy.shouldShowBattery(
                model: profile.model, level: level, powerState: power
            ) else { return nil }

            let value: String
            if let level {
                value = "\(level)%"
            } else if power == .charging {
                value = localization.text("remote.device.power.charging")
            } else if power == .externalPower {
                value = localization.text("remote.device.power.external")
            } else {
                value = localization.text("common.value.unknown")
            }
            if connected.count == 1 {
                return LocalizedMessage("menu.remote_battery", arguments: [value]).text(using: localization)
            }
            let name = RemoteDeviceNamePolicy.displayName(
                for: profile, among: profiles, defaultName: localization.text(profile.model.localizationKey)
            )
            return LocalizedMessage("menu.named_remote_battery", arguments: [name, value]).text(using: localization)
        }

        let items = menu.items.filter { $0.identifier == itemIdentifier }
        guard items.map(\.title) != titles else { return }
        items.forEach(menu.removeItem)
        let index = menu.index(of: anchor)
        for (offset, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.identifier = itemIdentifier
            item.isEnabled = false
            menu.insertItem(item, at: index + offset)
        }
    }
}
