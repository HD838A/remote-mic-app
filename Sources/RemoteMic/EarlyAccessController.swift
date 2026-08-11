import Combine
import Foundation

enum EarlyAccessState: Equatable {
    case notEnrolled
    case checking
    case authorized
    case expiringSoon
    case offlineValid
    case expired
    case revoked
    case paused
    case versionBlocked
    case invalidCode
    case deviceLimitReached
    case invalid
    case serviceUnavailable
}

final class EarlyAccessController: ObservableObject {
    @Published private(set) var state: EarlyAccessState = .notEnrolled
    @Published private(set) var hasEffectiveAccess = false
    @Published private(set) var lastRequestID: String?
    @Published private(set) var lastErrorCode: String?

    var onEffectiveAccessChanged: ((Bool) -> Void)?

    private let store: EarlyAccessCredentialStore
    private let client: any EarlyAccessClientProtocol
    private let verifier: EarlyAccessEntitlementVerifier
    private let appVersion: String
    private let appBuild: String
    private let serviceConfigured: Bool
    private let dateProvider: () -> Date
    private let uptimeProvider: () -> TimeInterval
    private var operationTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0

    init(
        store: EarlyAccessCredentialStore = EarlyAccessCredentialStore(),
        client: any EarlyAccessClientProtocol = EarlyAccessClient(),
        verifier: EarlyAccessEntitlementVerifier = EarlyAccessEntitlementVerifier(),
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0",
        appBuild: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0",
        serviceConfigured: Bool = EarlyAccessConfiguration.serviceURL() != nil,
        dateProvider: @escaping () -> Date = Date.init,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.client = client
        self.verifier = verifier
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.serviceConfigured = serviceConfigured
        self.dateProvider = dateProvider
        self.uptimeProvider = uptimeProvider
        restoreCachedState()
    }

    var isEnrolled: Bool {
        (try? store.loadGrantBundle()) != nil
    }

    func redeem(code: String) {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            lastErrorCode = "invalid_code"
            state = .invalidCode
            setEffectiveAccess(false)
            return
        }
        guard serviceConfigured else {
            lastErrorCode = "service_unavailable"
            state = .serviceUnavailable
            setEffectiveAccess(false)
            return
        }

        beginOperation { [weak self] generation in
            guard let self else { return }
            do {
                let deviceID = try store.createDeviceIDIfNeeded()
                let response = try await client.redeem(
                    code: normalizedCode,
                    anonymousDeviceID: deviceID,
                    appVersion: appVersion,
                    appBuild: appBuild
                )
                try Task.checkCancellation()
                try accept(response: response, expectedBundle: nil, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                handle(error: error, duringRefresh: false, generation: generation)
            }
        }
    }

    func refreshIfNeeded(force: Bool = false) {
        guard serviceConfigured else {
            if isEnrolled {
                state = .serviceUnavailable
                setEffectiveAccess(false)
            }
            return
        }
        guard let bundle = try? store.loadGrantBundle(),
              let deviceID = try? store.loadDeviceID()
        else {
            state = .notEnrolled
            setEffectiveAccess(false)
            return
        }
        if !force,
           bundle.blockedReason == nil,
           let now = trustedNow(for: bundle),
           let payload = try? verifier.verify(
               bundle.entitlement,
               feature: .deepSeekPostDictation,
               expectedGrantID: bundle.grantID,
               expectedSubject: bundle.subject,
               appVersion: appVersion,
               now: now
           ),
           Int64(now.timeIntervalSince1970) < payload.refreshAfter
        {
            publishValidState(payload: payload, now: now, offline: false)
            return
        }

        beginOperation { [weak self] generation in
            guard let self else { return }
            do {
                let response = try await client.refresh(
                    grantID: bundle.grantID,
                    refreshCredential: bundle.refreshCredential,
                    anonymousDeviceID: deviceID,
                    appVersion: appVersion,
                    appBuild: appBuild
                )
                try Task.checkCancellation()
                try accept(response: response, expectedBundle: bundle, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                handle(error: error, duringRefresh: true, generation: generation)
            }
        }
    }

    func release() {
        guard let bundle = try? store.loadGrantBundle(),
              let deviceID = try? store.loadDeviceID()
        else {
            clearLocalEnrollment()
            return
        }
        guard serviceConfigured else {
            lastErrorCode = "service_unavailable"
            state = .serviceUnavailable
            return
        }

        beginOperation { [weak self] generation in
            guard let self else { return }
            do {
                let requestID = try await client.release(
                    grantID: bundle.grantID,
                    refreshCredential: bundle.refreshCredential,
                    anonymousDeviceID: deviceID,
                    appVersion: appVersion,
                    appBuild: appBuild
                )
                try Task.checkCancellation()
                guard generation == operationGeneration else { return }
                try store.deleteAll()
                lastRequestID = requestID
                lastErrorCode = nil
                state = .notEnrolled
                setEffectiveAccess(false)
            } catch is CancellationError {
                return
            } catch {
                guard generation == operationGeneration else { return }
                lastErrorCode = Self.errorCode(error)
                evaluateCachedState(offline: true)
            }
        }
    }

    func clearLocalEnrollment() {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        try? store.deleteAll()
        lastRequestID = nil
        lastErrorCode = nil
        state = .notEnrolled
        setEffectiveAccess(false)
    }

    func stop() {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
    }

    func waitForCurrentOperation() async {
        await operationTask?.value
    }

    private func restoreCachedState() {
        guard serviceConfigured else {
            if isEnrolled { state = .serviceUnavailable }
            return
        }
        evaluateCachedState(offline: false)
    }

    private func evaluateCachedState(offline: Bool) {
        guard let bundle = try? store.loadGrantBundle() else {
            state = .notEnrolled
            setEffectiveAccess(false)
            return
        }
        if let blockedReason = bundle.blockedReason {
            publishBlockedState(for: blockedReason)
            return
        }
        guard let now = trustedNow(for: bundle) else {
            state = .invalid
            setEffectiveAccess(false)
            return
        }
        do {
            let payload = try verifier.verify(
                bundle.entitlement,
                feature: .deepSeekPostDictation,
                expectedGrantID: bundle.grantID,
                expectedSubject: bundle.subject,
                appVersion: appVersion,
                now: now
            )
            publishValidState(payload: payload, now: now, offline: offline)
        } catch EarlyAccessEntitlementError.expired {
            state = .expired
            setEffectiveAccess(false)
        } catch EarlyAccessEntitlementError.versionBlocked {
            state = .versionBlocked
            setEffectiveAccess(false)
        } catch {
            state = .invalid
            setEffectiveAccess(false)
        }
    }

    private func accept(
        response: EarlyAccessAPIResponse,
        expectedBundle: EarlyAccessGrantBundle?,
        generation: UInt64
    ) throws {
        guard generation == operationGeneration else { return }
        let payload = try verifier.verify(
            response.entitlement,
            feature: .deepSeekPostDictation,
            expectedGrantID: expectedBundle?.grantID ?? response.grantID,
            expectedSubject: expectedBundle?.subject,
            appVersion: appVersion,
            now: response.serverTime
        )
        let serverTimestamp = Int64(response.serverTime.timeIntervalSince1970.rounded(.down))
        guard payload.grantID == response.grantID,
              payload.refreshAfter == response.refreshAfter,
              payload.expiresAt == response.expiresAt,
              abs(payload.issuedAt - serverTimestamp) <= 300
        else { throw EarlyAccessEntitlementError.invalidClaims }

        let bundle = EarlyAccessGrantBundle(
            grantID: response.grantID,
            refreshCredential: response.refreshCredential,
            entitlement: response.entitlement,
            subject: payload.subject,
            serverTime: response.serverTime,
            processUptime: uptimeProvider()
        )
        try store.saveGrantBundle(bundle)
        guard generation == operationGeneration else { return }
        lastRequestID = response.requestID
        lastErrorCode = nil
        publishValidState(payload: payload, now: response.serverTime, offline: false)
    }

    private func beginOperation(
        _ operation: @escaping (_ generation: UInt64) async -> Void
    ) {
        operationGeneration &+= 1
        let generation = operationGeneration
        operationTask?.cancel()
        state = .checking
        lastErrorCode = nil
        operationTask = Task { @MainActor [weak self] in
            await operation(generation)
            guard let self, generation == self.operationGeneration else { return }
            self.operationTask = nil
        }
    }

    private func handle(error: Error, duringRefresh: Bool, generation: UInt64) {
        guard generation == operationGeneration else { return }
        let code = Self.errorCode(error)
        lastErrorCode = code
        if duringRefresh, Self.isExplicitDenial(code) {
            if Self.canRetryBlockedGrant(code),
               let bundle = try? store.loadGrantBundle()
            {
                let blocked = EarlyAccessGrantBundle(
                    grantID: bundle.grantID,
                    refreshCredential: bundle.refreshCredential,
                    entitlement: bundle.entitlement,
                    subject: bundle.subject,
                    serverTime: bundle.serverTime,
                    processUptime: bundle.processUptime,
                    blockedReason: code
                )
                try? store.saveGrantBundle(blocked)
            } else {
                try? store.deleteGrantBundle()
            }
            publishBlockedState(for: code)
            return
        }
        if duringRefresh {
            evaluateCachedState(offline: true)
        } else {
            publishBlockedState(for: code)
        }
    }

    private func publishValidState(
        payload: EarlyAccessEntitlementPayload,
        now: Date,
        offline: Bool
    ) {
        setEffectiveAccess(true)
        if offline {
            state = .offlineValid
        } else if Int64(now.timeIntervalSince1970) >= payload.refreshAfter {
            state = .expiringSoon
        } else {
            state = .authorized
        }
    }

    private func publishBlockedState(for code: String) {
        switch code {
        case "invalid_code", "code_expired": state = .invalidCode
        case "device_limit_reached": state = .deviceLimitReached
        case "revoked", "credential_invalid": state = .revoked
        case "grant_expired": state = .expired
        case "feature_paused", "feature_unavailable", "cohort_unavailable": state = .paused
        case "version_unsupported": state = .versionBlocked
        case "request_failed", "rate_limited", "service_unavailable", "unavailable_configuration":
            state = .serviceUnavailable
        default: state = .invalid
        }
        setEffectiveAccess(false)
    }

    private func setEffectiveAccess(_ value: Bool) {
        guard hasEffectiveAccess != value else { return }
        hasEffectiveAccess = value
        onEffectiveAccessChanged?(value)
    }

    private func trustedNow(for bundle: EarlyAccessGrantBundle) -> Date? {
        let systemNow = dateProvider()
        let uptime = uptimeProvider()
        if uptime >= bundle.processUptime {
            let monotonicNow = bundle.serverTime.addingTimeInterval(uptime - bundle.processUptime)
            return max(systemNow, monotonicNow)
        }
        guard systemNow.timeIntervalSince(bundle.serverTime) >= -300 else { return nil }
        return max(systemNow, bundle.serverTime)
    }

    private static func errorCode(_ error: Error) -> String {
        if let clientError = error as? EarlyAccessClientError {
            switch clientError {
            case .unavailableConfiguration: return "unavailable_configuration"
            case .invalidResponse: return "invalid_response"
            case .requestFailed: return "request_failed"
            case let .server(code, _): return code
            }
        }
        if let entitlementError = error as? EarlyAccessEntitlementError {
            switch entitlementError {
            case .expired: return "grant_expired"
            case .versionBlocked: return "version_unsupported"
            default: return "invalid_entitlement"
            }
        }
        return "local_storage_failed"
    }

    private static func isExplicitDenial(_ code: String) -> Bool {
        [
            "cohort_unavailable", "credential_invalid", "feature_paused",
            "feature_unavailable", "grant_expired", "revoked", "version_unsupported",
        ].contains(code)
    }

    private static func canRetryBlockedGrant(_ code: String) -> Bool {
        ["cohort_unavailable", "feature_paused", "feature_unavailable", "version_unsupported"]
            .contains(code)
    }
}
