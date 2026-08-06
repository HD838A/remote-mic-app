import Foundation

struct WebRemoteWireMessage: Codable {
    static let currentProtocolVersion = 1
    static let buttonEventsCapability = "buttonEventsV1"

    let type: String
    var protocolVersion: Int = currentProtocolVersion
    var sessionID: String?
    var joinURL: String?
    var pairingCode: String?
    var expiresAt: String?
    var macName: String?
    var deviceName: String?
    var appVersion: String?
    var buttonTitles: [String: String]?
    var command: String?
    var timestamp: Double?
    var code: String?
    var detail: String?
    var recoverable: Bool?
    var reason: String?
    var capabilities: [String]?
    var buttonPhase: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion
        case sessionID = "sessionId"
        case joinURL
        case pairingCode
        case expiresAt
        case macName
        case deviceName
        case appVersion
        case buttonTitles
        case command
        case timestamp
        case code
        case detail
        case recoverable
        case reason
        case capabilities
        case buttonPhase
    }
}

enum WebRemoteAudioFrame {
    static let type: UInt8 = 1
    static let maximumByteCount = 4_101

    static func decode(_ data: Data) -> (sequence: UInt32, samples: [Int16])? {
        guard data.count >= 7,
              data.count <= maximumByteCount,
              data[0] == type,
              (data.count - 5).isMultiple(of: MemoryLayout<Int16>.size)
        else { return nil }

        let sequence = data[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var samples = [Int16]()
        samples.reserveCapacity((data.count - 5) / 2)
        var index = 5
        while index < data.count {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1]) << 8
            samples.append(Int16(bitPattern: low | high))
            index += 2
        }
        return (sequence, samples)
    }
}

enum WebRemoteConfiguration {
    static let infoDictionaryKey = "RemoteWebRelayURL"
    static let environmentKey = "REMOTE_WEB_RELAY_URL"

    static func relayURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> URL? {
        let rawValue = environment[environmentKey]
            ?? infoDictionary[infoDictionaryKey] as? String
        guard let rawValue else { return nil }
        return validatedRelayURL(rawValue)
    }

    static func validatedRelayURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value),
              url.path == "/ws",
              url.query == nil,
              url.fragment == nil,
              let host = url.host,
              !host.isEmpty
        else { return nil }

        if url.scheme == "wss" { return url }
        let localHosts = Set(["127.0.0.1", "localhost", "::1"])
        return url.scheme == "ws" && localHosts.contains(host) ? url : nil
    }
}

enum WebRemoteSessionState: Equatable {
    case disabled
    case unavailable
    case connecting
    case waitingForPhone(joinURL: URL, pairingCode: String, expiresAt: Date?)
    case awaitingApproval(joinURL: URL, pairingCode: String, deviceName: String)
    case connected(deviceName: String)
    case failed(String)

    var isEnabled: Bool {
        switch self {
        case .disabled, .unavailable, .failed:
            return false
        default:
            return true
        }
    }

    var joinURL: URL? {
        switch self {
        case let .waitingForPhone(joinURL, _, _), let .awaitingApproval(joinURL, _, _):
            return joinURL
        default:
            return nil
        }
    }

    var pairingCode: String? {
        switch self {
        case let .waitingForPhone(_, pairingCode, _), let .awaitingApproval(_, pairingCode, _):
            return pairingCode
        default:
            return nil
        }
    }
}
