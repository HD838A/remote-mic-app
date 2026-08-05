import XCTest
@testable import RemoteMicIOS

final class RemoteWireMessageTests: XCTestCase {
    func testMessageRoundTripPreservesRemoteControlFields() throws {
        let original = RemoteWireMessage(
            type: "ready",
            deviceName: "Test Mac",
            command: "volume_up",
            samples: "AQID",
            detail: "detail",
            publicKey: "public",
            identityPublicKey: "identity",
            identitySignature: "signature",
            buttonTitles: ["menu": "自定义菜单", "ok": "确定"],
            appVersion: "1.0.0",
            payload: "payload",
            capabilities: [RemoteWireMessage.buttonEventsCapability],
            buttonPhase: "press"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteWireMessage.self, from: data)

        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.command, original.command)
        XCTAssertEqual(decoded.samples, original.samples)
        XCTAssertEqual(decoded.detail, original.detail)
        XCTAssertEqual(decoded.publicKey, original.publicKey)
        XCTAssertEqual(decoded.identityPublicKey, original.identityPublicKey)
        XCTAssertEqual(decoded.identitySignature, original.identitySignature)
        XCTAssertEqual(decoded.buttonTitles, original.buttonTitles)
        XCTAssertEqual(decoded.appVersion, original.appVersion)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded.capabilities, original.capabilities)
        XCTAssertEqual(decoded.buttonPhase, original.buttonPhase)
    }

    func testMinimalMessageRemainsBackwardCompatible() throws {
        let data = try XCTUnwrap(#"{"type":"voiceStop"}"#.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RemoteWireMessage.self, from: data)

        XCTAssertEqual(decoded.type, "voiceStop")
        XCTAssertNil(decoded.deviceName)
        XCTAssertNil(decoded.command)
        XCTAssertNil(decoded.samples)
        XCTAssertNil(decoded.detail)
        XCTAssertNil(decoded.publicKey)
        XCTAssertNil(decoded.identityPublicKey)
        XCTAssertNil(decoded.identitySignature)
        XCTAssertNil(decoded.buttonTitles)
        XCTAssertNil(decoded.appVersion)
        XCTAssertNil(decoded.payload)
        XCTAssertNil(decoded.capabilities)
        XCTAssertNil(decoded.buttonPhase)
    }
}
