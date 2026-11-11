import Foundation

/// One synchronous commit and its disk recovery. A failed receipt is not a failed commit.
enum ButtonMappingWriteRecovery {
    enum Outcome: Equatable {
        case saved
        case failed
        case unknown
    }

    static func perform(write: () -> Bool, reload: () -> Bool, matches: () -> Bool) -> Outcome {
        if write() { return .saved }
        guard reload() else { return .unknown }
        return matches() ? .saved : .failed
    }

    static func saveAction(write: () -> Bool, reload: () -> Bool, matches: () -> Bool,
                           reconcileHold: () -> Void) -> Outcome {
        let outcome = perform(write: write, reload: reload, matches: matches)
        if outcome == .saved { reconcileHold() }
        return outcome
    }

}

struct ButtonMappingProfileCreation: Identifiable {
    let id = UUID()
    let sourceProfileID: UUID?
    let deviceID: UUID?
    let sourceName: String
    var name: String
}

struct ButtonMappingSaveTarget: Equatable {
    let profileID: UUID?
    let deviceID: UUID?
    let button: RemoteButton
    let trigger: ButtonTrigger?
}

struct ButtonMappingSaveState {
    enum Retry {
        case action(ConfiguredButtonAction?)
        case hold(RemoteButtonHoldMode)
    }

    var target: ButtonMappingSaveTarget?
    var outcome: ButtonMappingWriteRecovery.Outcome?
    var retry: Retry?
    var receipt = UUID()
    var holdActions: [ConfiguredButtonAction] = []
    var holdMode: RemoteButtonHoldMode?

    mutating func record(_ outcome: ButtonMappingWriteRecovery.Outcome, retry: Retry, target: ButtonMappingSaveTarget) {
        self.target = target
        self.outcome = outcome
        self.retry = outcome == .failed ? retry : nil
        receipt = UUID()
    }

    @discardableResult
    func performRetry(target: ButtonMappingSaveTarget,
                      writeAction: (ConfiguredButtonAction?) -> Void,
                      writeHold: (RemoteButtonHoldMode) -> Void) -> Bool {
        guard self.target == target, outcome == .failed, let retry else { return false }
        switch retry {
        case let .action(value): writeAction(value)
        case let .hold(mode): writeHold(mode)
        }
        return true
    }

    mutating func clearSuccess(_ receipt: UUID) {
        guard self.receipt == receipt, outcome == .saved else { return }
        outcome = nil
    }
}

/// Decoding a newer payload must not make an older editor silently drop its fields.
enum MappingHostBindingCodec {
    static func decode(_ payload: Data) -> (configured: ConfiguredButtonAction, isEditable: Bool)? {
        guard let configured = try? JSONDecoder().decode(ConfiguredButtonAction.self, from: payload),
              let encoded = try? JSONEncoder().encode(configured),
              let original = try? JSONSerialization.jsonObject(with: payload) as? NSDictionary,
              let roundTrip = try? JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        else { return nil }
        return (configured, original == roundTrip && configured == configured.normalizedForExecution)
    }
}
