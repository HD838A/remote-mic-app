import Combine
import Foundation
import SwiftUI

#if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
import SayAllMembershipCore
import SayAllMembershipUI
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

final class MembershipFeatureIntegration: ObservableObject {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var buttonProfilesAccessDecision: HostButtonProfilesAccessDecision = .unavailable

    private var localeIdentifier: String

    #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
    @MainActor private var controller: MembershipCenterController?
    private var subscriptions = Set<AnyCancellable>()
    #endif

    init(
        localeIdentifier: String = Locale.current.identifier,
        configuration: MembershipFeatureConfiguration? = .current()
    ) {
        self.localeIdentifier = localeIdentifier
        #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
        if let configuration {
            Task { @MainActor [weak self] in
                self?.configure(configuration)
            }
        }
        #endif
    }

    var sectionTitle: String {
        #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
        MembershipCenterLocalization(locale: Locale(identifier: localeIdentifier))
            .text("membership.title")
        #else
        ""
        #endif
    }

    var sectionSystemImage: String { "crown.fill" }

    func updateLocaleIdentifier(_ identifier: String) {
        localeIdentifier = identifier
        #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
        Task { @MainActor [weak self] in
            self?.controller?.updateLocaleIdentifier(identifier)
        }
        #endif
        objectWillChange.send()
    }

    @MainActor
    func refreshIfNeeded() {
        #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
        guard let controller else { return }
        if controller.membershipSessionState == .uninitialized {
            controller.prepareMembershipSession()
        } else {
            controller.refreshMembership()
        }
        #endif
    }

    @MainActor
    func settingsView() -> AnyView {
        #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
        guard let controller else { return AnyView(EmptyView()) }
        return AnyView(MembershipCenterView(
            model: controller,
            localization: MembershipCenterLocalization(
                locale: Locale(identifier: localeIdentifier)
            )
        ))
        #else
        return AnyView(EmptyView())
        #endif
    }

    #if canImport(SayAllMembershipCore) && canImport(SayAllMembershipUI)
    @MainActor
    private func configure(_ configuration: MembershipFeatureConfiguration) {
        guard controller == nil else { return }
        let controller = MembershipCenterController(
            baseURL: configuration.baseURL,
            issuer: configuration.issuer,
            keychainService: configuration.keychainService,
            appVersion: configuration.appVersion,
            localeIdentifier: localeIdentifier
        )
        self.controller = controller
        isFeatureVisible = true
        controller.$membershipAccount
            .map(Self.buttonProfilesAccessDecision)
            .removeDuplicates()
            .assign(to: &$buttonProfilesAccessDecision)
        controller.prepareMembershipSession()
    }

    private static func buttonProfilesAccessDecision(
        account: MembershipAccountState
    ) -> HostButtonProfilesAccessDecision {
        switch MembershipAccessController.evaluate(.buttonProfiles, account: account) {
        case let .allowed(validUntil):
            return .allowed(validUntil: validUntil)
        case let .temporarilyOffline(validUntil):
            return .temporarilyOffline(validUntil: validUntil)
        case .requires:
            return .requiresPlus
        case .unavailable:
            return .unavailable
        }
    }
    #endif
}
