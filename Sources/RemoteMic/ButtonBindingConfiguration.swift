import Foundation

/// A host-owned binding. A missing profile override inherits this base value;
/// `.disabled` is an explicit value and never falls through to another action.
struct UnifiedButtonBinding: Codable, Equatable {
    var remoteProfileID: UUID?
    var button: RemoteButton
    var trigger: ButtonTrigger
    var configured: ConfiguredButtonAction
}

struct ButtonLibraryAction: Identifiable, Equatable {
    var id: String
    var name: String
}

struct ButtonMappingProfile: Identifiable, Equatable {
    var id: UUID
    var name: String
}
