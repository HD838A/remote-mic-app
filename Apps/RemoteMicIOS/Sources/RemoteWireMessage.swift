import Foundation

struct RemoteWireMessage: Codable {
    let type: String
    var deviceName: String?
    var command: String?
    var samples: String?
    var detail: String?
    var publicKey: String?
    var payload: String?
}
