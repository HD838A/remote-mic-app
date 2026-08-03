import Foundation

struct RemoteWireMessage: Codable {
    let type: String
    var deviceName: String?
    var command: String?
    var samples: String?
    var detail: String?
    var publicKey: String?
    var identityPublicKey: String?
    var identitySignature: String?
    var buttonTitles: [String: String]?
    var payload: String?
}
