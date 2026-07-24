import Foundation
import Testing

@Suite("Build signing")
struct BuildSigningTests {
    @Test func buildPrefersAStableCodeSigningIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(source.contains("CODE_SIGN_IDENTITY"))
        #expect(source.contains("security find-identity -p codesigning -v"))
        #expect(source.contains("git config --get user.email"))
        #expect(source.contains("designated => identifier"))
        #expect(!source.contains("codesign --force --deep --sign - \"$APP_DIR\""))
    }
}
