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
