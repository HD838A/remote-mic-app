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

struct MembershipFeatureConfiguration: Equatable {
    let baseURL: URL
    let issuer: String
    let keychainService: String
    let appVersion: String

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> MembershipFeatureConfiguration? {
        let rawBaseURL = environment["SAYALL_MEMBERSHIP_API_BASE_URL"]
            ?? bundle.object(forInfoDictionaryKey: "SayAllMembershipAPIBaseURL") as? String
        guard let rawBaseURL,
              let baseURL = URL(string: rawBaseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host == "127.0.0.1")
        else { return nil }
        return MembershipFeatureConfiguration(
            baseURL: baseURL,
            issuer: environment["SAYALL_MEMBERSHIP_ISSUER"]
                ?? bundle.object(forInfoDictionaryKey: "SayAllMembershipIssuer") as? String
                ?? "getsayall-membership",
            keychainService: environment["SAYALL_MEMBERSHIP_KEYCHAIN_SERVICE"]
                ?? "app.sayall.membership",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0"
        )
    }
}

final class MembershipFeatureIntegration: ObservableObject, @unchecked Sendable {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var buttonProfilesAccessDecision: HostButtonProfilesAccessDecision = .unavailable
    @Published private(set) var accountDisplayName: String? = nil

    private var localeIdentifier: String

    #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
    @MainActor private var adapter: MembershipHostAdapter?
    private var subscriptions = Set<AnyCancellable>()
    #endif

    init(
        localeIdentifier: String = Locale.current.identifier,
        configuration: MembershipFeatureConfiguration? = .current()
    ) {
        self.localeIdentifier = localeIdentifier
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        if let configuration {
            Task { @MainActor [weak self] in
                self?.configure(configuration)
            }
        }
        #endif
    }

    var sectionTitle: String {
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        Locale(identifier: localeIdentifier).identifier.lowercased().hasPrefix("zh")
            ? "会员"
            : "Membership"
        #else
        ""
        #endif
    }

    var sectionSystemImage: String { "crown.fill" }

    func updateLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
        #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
        Task { @MainActor [weak self] in
            self?.adapter?.updateLocaleIdentifier(identifier)
        }
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

    #if SAYALL_MEMBERSHIP_ENABLED && canImport(SayAllMembershipHostAdapter)
    @MainActor
    private func configure(_ configuration: MembershipFeatureConfiguration) {
        guard adapter == nil else { return }
        let adapter = MembershipHostAdapter(
            baseURL: configuration.baseURL,
            issuer: configuration.issuer,
            keychainService: configuration.keychainService,
            appVersion: configuration.appVersion,
            localeIdentifier: localeIdentifier
        )
        self.adapter = adapter
        adapter.$isFeatureVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isFeatureVisible = value
            }
            .store(in: &subscriptions)
        adapter.$buttonProfilesAccessDecision
            .map(Self.mapAccessDecision)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.buttonProfilesAccessDecision = value
            }
            .store(in: &subscriptions)
        adapter.$accountDisplayName
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.accountDisplayName = value
            }
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
