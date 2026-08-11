import Foundation
import Testing
@testable import RemoteMic

@Suite("Programming term store")
struct ProgrammingTermStoreTests {
    @Test func savesLoadsDisablesAndRemovesTerms() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicProgrammingTermTests-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("terms.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = ProgrammingTermStore(fileURL: fileURL)

        try store.add(ProgrammingTerm(
            id: id,
            canonicalText: "open-voice-bridge",
            spokenAliases: ["open voice bridge"],
            kind: .projectName
        ))
        #expect(ProgrammingTermStore(fileURL: fileURL).terms.first?.canonicalText == "open-voice-bridge")

        try store.setEnabled(false, id: id)
        #expect(ProgrammingTermStore(fileURL: fileURL).terms.first?.isEnabled == false)

        try store.remove(id: id)
        #expect(ProgrammingTermStore(fileURL: fileURL).terms.isEmpty)
    }
}
