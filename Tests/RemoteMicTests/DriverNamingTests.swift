import Foundation
import Testing

@Suite("Virtual microphone naming")
struct DriverNamingTests {
    @Test func resolvesInstallHistoryWithoutRenamingExistingDrivers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
        set -euo pipefail
        source "$1"
        assert_variant() {
          local actual
          actual="$(resolve_driver_naming "$1" "$2" "$3")"
          [[ "$actual" == "$4" ]]
        }
        assert_blocked() {
          if resolve_driver_naming "$1" "$2" "$3"; then exit 1; fi
        }
        assert_variant none none no brand
        assert_variant none none yes legacy
        for evidence in yes no; do
          assert_variant legacy none "$evidence" legacy
          assert_variant brand none "$evidence" brand
          assert_variant legacy legacy "$evidence" legacy
          assert_variant brand brand "$evidence" brand
          assert_variant none legacy "$evidence" legacy
          assert_variant none brand "$evidence" brand
          assert_variant unknown legacy "$evidence" legacy
          assert_variant unknown brand "$evidence" brand
          assert_blocked legacy brand "$evidence"
          assert_blocked brand legacy "$evidence"
          assert_blocked unknown none "$evidence"
          assert_blocked none unknown "$evidence"
          assert_blocked other none "$evidence"
        done
        assert_blocked none none other
        """, "driver-naming-test", root.appendingPathComponent("packaging/doubao-driver/install/driver-naming.zsh").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
    }
}
