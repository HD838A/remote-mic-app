import Foundation

enum HostButtonProfilesAccessDecision: Equatable {
    case allowed(validUntil: Date)
    case temporarilyOffline(validUntil: Date)
    case authorized
    case requiresPlus
    case unavailable
}
