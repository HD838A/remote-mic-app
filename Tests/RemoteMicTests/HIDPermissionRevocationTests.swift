import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

/// 权限撤销必须连带释放共享的 active event tap。
///
/// 2026-10-24 整机卡死的取证（解密后的会话日志）给出的直接证据：权限在 01:56:24 被撤销
/// 并写下 `HID RELEASED permission_revoked`，但 01:57:13 仍然出现 `HID FILTER miss`——
/// tap 回调还在执行。授权已经收回，系统输入路径上却还留着一条 active tap。
// 与进程级 tap 泄漏计数共用串行边界，防止此处释放 tap 改变另一用例的基线。
extension EventTapPortTests {
    @Suite("HID permission revocation", .serialized)
    struct HIDPermissionRevocationTests {
        /// 本机（以及具备权限的 CI）可以创建 active tap；否则跳过这条用例。
        private static let canCreateActiveTap: Bool = {
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            ) else { return false }
            EventTapPort.release(port: port, source: nil)
            return true
        }()

        @Test(.enabled(if: HIDPermissionRevocationTests.canCreateActiveTap))
        func revokedPermissionsReleaseTheSharedEventTap() throws {
            let suiteName = "HIDPermissionRevocationTests.sharedTap.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.customMappingEnabled = true

            // 与生产一致：监视器共享模型持有的那一个 suppressor，且不拥有它的生命周期。
            let suppressor = KeyboardEventSuppressor()
            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: settings.selectedRemoteProfileID,
                eventSuppressor: suppressor,
                ownsEventSuppressor: false,
                runtimePermissions: { true },
                diagnosticLogger: { _ in }
            )

            #expect(suppressor.start())
            #expect(suppressor.isRunning)

            monitor.releaseForRevokedPermissions()

            #expect(!suppressor.isRunning)
        }

        @Test
        func revokedPermissionsStillReleaseTheOwnedEventTap() throws {
            let suiteName = "HIDPermissionRevocationTests.ownedTap.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let settings = AppSettings(defaults: defaults)
            settings.customMappingEnabled = true

            // 独立 suppressor（`ownsEventSuppressor` 默认 true）：释放路径必须幂等。
            let suppressor = KeyboardEventSuppressor()
            let monitor = HIDRemoteMonitor(
                settings: settings,
                profileID: settings.selectedRemoteProfileID,
                eventSuppressor: suppressor,
                runtimePermissions: { true },
                diagnosticLogger: { _ in }
            )

            monitor.releaseForRevokedPermissions()
            monitor.releaseForRevokedPermissions()

            #expect(!suppressor.isRunning)
        }
    }
}
