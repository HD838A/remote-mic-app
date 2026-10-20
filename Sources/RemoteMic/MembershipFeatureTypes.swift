import Foundation

enum HostButtonProfilesAccessDecision: Equatable {
    case allowed(validUntil: Date)
    case temporarilyOffline(validUntil: Date)
    case allowedWithHistoryContinuation(verifiedUntil: Date)
    case continuedFromVerifiedHistory
    case requiresPlus
    case unavailable
}
