import Foundation
import Testing
@testable import RemoteMic

@Suite("Selected remote connection status")
struct ConnectionStatusTests {
    @Test @MainActor func searchingFollowsSelectedModelAndLanguage() throws {
        let suite = "ConnectionStatus.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try #require(Bundle(path: root.appendingPathComponent("Resources").path))
        let localization = LocalizationStore(settings: settings, resourceBundle: bundle)
        for remoteModel in XiaomiRemoteModel.allCases {
            let profileID = settings.registerHIDRemote(
                fingerprint: "connection-status-\(remoteModel.rawValue)"
            )
            settings.updateRemoteProfileModel(profileID, model: remoteModel)
            model.selectRemoteProfile(profileID)
            #expect(settings.selectedRemoteProfile?.model == remoteModel)
            for language in [AppLanguage.simplifiedChinese, .english] {
                localization.select(language)
                let nameKey = remoteModel.localizationKey
                let hasKnownName = nameKey != "remote.device.model.unknown"
                let expected: String
                if language == .english {
                    expected = hasKnownName
                        ? "Looking for \(localization.text(nameKey))"
                        : "Looking for a remote"
                } else {
                    expected = hasKnownName
                        ? "正在查找\(localization.text(nameKey))"
                        : "正在查找遥控器"
                }
                #expect(model.connectionStatusText(using: localization) == expected)
            }
        }
    }

    @Test @MainActor func searchingWithLegacyUnknownProfileUsesGenericCopy() throws {
        let suite = "ConnectionStatusEmpty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        model.selectRemoteProfile(UUID())
        #expect(model.connectionStatus.key == "connection.status.searching")
        #expect(settings.selectedRemoteProfile?.model == .unknown)
    }

    @Test @MainActor func otherBluetoothRemoteDoesNotReplaceSelectedDisconnectedRemote() throws {
        let suite = "ConnectionStatusMultiple.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let bridge = XiaomiBluetoothBridge(delegate: model)
        let profileID = settings.registerHIDRemote(fingerprint: "disconnected-selected-remote")

        for remoteModel in [XiaomiRemoteModel.appleSiriRemoteA2540, .appleSiriRemoteA2854,
                            .chromecastVoiceRemote] {
            settings.updateRemoteProfileModel(profileID, model: remoteModel)
            model.selectRemoteProfile(profileID)
            model.bluetoothBridge(bridge, didChange: .connecting)
            #expect(model.connectionStatus.key == "connection.status.searching")
            #expect(!model.isRemoteConnected(profileID))
        }
    }
}
