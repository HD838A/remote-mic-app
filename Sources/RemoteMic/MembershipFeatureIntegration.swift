import Combine
import Foundation
import SwiftUI

#if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
import SayAllMembershipHostAdapter
#endif

enum HostButtonProfilesAccessDecision: Equatable {
    case allowed(validUntil: Date)
    case temporarilyOffline(validUntil: Date)
    case requiresPlus
    case unavailable
}

enum HostRemoteSessionAccess: Equatable {
    case authorized
    case plusRequired
}

struct HostRemoteSessionAuthorization: Equatable {
    let access: HostRemoteSessionAccess
    let webSocketURL: URL
    let sessionID: String?
    let creatorToken: String?
    let joinURL: URL?
    let pairingCode: String?
    let expiresAt: Date?
}

enum HostRemoteSessionFailure: Error, Equatable {
    case signInRequired
    case deviceBindingRequired
    case plusRequired
    case upgradeRequired
    case unavailable
    case networkUnavailable
    case invalidResponse
}

struct MembershipFeatureConfiguration: Equatable {
    let appVersion: String

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> MembershipFeatureConfiguration? {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        return MembershipFeatureConfiguration(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        #else
        nil
        #endif
    }
}

final class MembershipFeatureIntegration: ObservableObject, @unchecked Sendable {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var isEnvironmentSettingsVisible = false
    @Published private(set) var buttonProfilesAccessDecision: HostButtonProfilesAccessDecision = .unavailable
    @Published private(set) var canUseCompanionConnections = false
    @Published private(set) var accountDisplayName: String? = nil
    @Published private(set) var serviceEnvironmentForDiagnostics = "unavailable"

    private var localeIdentifier: String
    #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
    private var adapter: MembershipHostAdapter?
    private var subscriptions = Set<AnyCancellable>()
    #endif

    var supportsRemoteSessionAuthorization: Bool {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        true
        #else
        false
        #endif
    }

    init(localeIdentifier: String = Locale.current.identifier,
         configuration: MembershipFeatureConfiguration? = .current()) {
        self.localeIdentifier = localeIdentifier
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        if let configuration {
            Task { @MainActor [weak self] in self?.configure(configuration) }
        }
        #endif
    }

    @MainActor var sectionTitle: String {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.sectionTitle ?? (Locale(identifier: localeIdentifier).identifier.lowercased().hasPrefix("zh") ? "会员" : "Membership")
        #else
        ""
        #endif
    }

    var sectionSystemImage: String { "crown.fill" }

    @MainActor func updateLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.updateLocaleIdentifier(identifier)
        #endif
        objectWillChange.send()
    }

    @MainActor
    func refreshIfNeeded() {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.refreshIfNeeded()
        #endif
    }

    @MainActor
    func settingsView() -> AnyView {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.settingsView() ?? AnyView(EmptyView())
        #else
        AnyView(EmptyView())
        #endif
    }

    @MainActor
    func membershipRequiredView(forButtonProfiles: Bool = false, remoteAuthorizationDenied: Bool = false, onOpenMembership: @escaping () -> Void) -> AnyView {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.membershipRequiredView(forButtonProfiles: forButtonProfiles, remoteAuthorizationDenied: remoteAuthorizationDenied, onOpenMembership: onOpenMembership) ?? AnyView(EmptyView())
        #else
        AnyView(EmptyView())
        #endif
    }

    var canStartCompanionConnection: Bool {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.canStartCompanionConnection ?? false
        #else
        false
        #endif
    }

    var remoteSessionMembershipBypassEnabled: Bool {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.remoteSessionMembershipBypassEnabled ?? false
        #else
        false
        #endif
    }

    @MainActor
    func serviceEnvironmentSettingsView() -> AnyView {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        adapter?.serviceEnvironmentSettingsView() ?? AnyView(EmptyView())
        #else
        AnyView(EmptyView())
        #endif
    }

    @MainActor
    func createRemoteSessionAuthorization(
        idempotencyKey: String,
        clientContractVersion: Int = 1,
        testMembershipBypass: Bool = false
    ) async throws -> HostRemoteSessionAuthorization {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        guard let adapter else { throw HostRemoteSessionFailure.unavailable }
        do {
            let authorization = try await adapter.createRemoteSession(
                idempotencyKey: idempotencyKey,
                clientContractVersion: clientContractVersion,
                testMembershipBypass: testMembershipBypass
            )
            return HostRemoteSessionAuthorization(
                access: authorization.access == .plusRequired
                    ? .plusRequired
                    : .authorized,
                webSocketURL: authorization.webSocketURL,
                sessionID: authorization.sessionID,
                creatorToken: authorization.creatorToken,
                joinURL: authorization.joinURL,
                pairingCode: authorization.pairingCode,
                expiresAt: authorization.expiresAt
            )
        } catch let failure as MembershipHostRemoteSessionFailure {
            switch failure {
            case .signInRequired: throw HostRemoteSessionFailure.signInRequired
            case .deviceBindingRequired: throw HostRemoteSessionFailure.deviceBindingRequired
            case .plusRequired: throw HostRemoteSessionFailure.plusRequired
            case .upgradeRequired: throw HostRemoteSessionFailure.upgradeRequired
            case .unavailable: throw HostRemoteSessionFailure.unavailable
            case .networkUnavailable: throw HostRemoteSessionFailure.networkUnavailable
            case .invalidResponse: throw HostRemoteSessionFailure.invalidResponse
            @unknown default: throw HostRemoteSessionFailure.invalidResponse
            }
        } catch {
            throw HostRemoteSessionFailure.invalidResponse
        }
        #else
        throw HostRemoteSessionFailure.unavailable
        #endif
    }

    #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
    @MainActor
    private func configure(_ configuration: MembershipFeatureConfiguration) {
        guard adapter == nil else { return }
        let adapter = MembershipHostAdapter(appVersion: configuration.appVersion,
            localeIdentifier: localeIdentifier)
        self.adapter = adapter
        adapter.$isFeatureVisible.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.isFeatureVisible = $0 }.store(in: &subscriptions)
        adapter.$isEnvironmentSettingsVisible.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.isEnvironmentSettingsVisible = $0 }.store(in: &subscriptions)
        adapter.$buttonProfilesAccessDecision.map(Self.mapAccessDecision).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.buttonProfilesAccessDecision = $0 }.store(in: &subscriptions)
        adapter.$canUseCompanionConnections.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.canUseCompanionConnections = $0 }.store(in: &subscriptions)
        adapter.$accountDisplayName.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.accountDisplayName = $0 }.store(in: &subscriptions)
        adapter.$serviceEnvironmentForDiagnostics.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.serviceEnvironmentForDiagnostics = $0 }
            .store(in: &subscriptions)
    }

    private static func mapAccessDecision(
        _ decision: MembershipHostButtonProfilesAccessDecision
    ) -> HostButtonProfilesAccessDecision {
        switch decision {
        case let .allowed(validUntil):
            return .allowed(validUntil: validUntil)
        case let .temporarilyOffline(validUntil):
            return .temporarilyOffline(validUntil: validUntil)
        case .requiresPlus:
            return .requiresPlus
        case .unavailable:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }
    #endif
}
extension MembershipFeatureIntegration: PrivateDiagnosticUploadProvider {
    func pendingPrivateDiagnosticRecords() async -> [PrivateDiagnosticUploadRecord] {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        return await Task { @MainActor [weak self] in
            guard let adapter = self?.adapter else { return [] }
            let records = await adapter.pendingPrivateDiagnosticRecords()
            return records.compactMap { record in
                PrivateDiagnosticUploadRecord(
                    recordID: record.recordID,
                    occurredAt: record.occurredAt,
                    category: record.category,
                    fields: record.fields
                )
            }
        }.value
        #else
        return []
        #endif
    }

    func markPrivateDiagnosticRecordsUploaded(_ recordIDs: Set<String>) async {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        await Task { @MainActor [weak self] in
            await self?.adapter?.markPrivateDiagnosticRecordsUploaded(recordIDs)
        }.value
        #endif
    }
}
