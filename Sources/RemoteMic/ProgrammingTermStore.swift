import Foundation

private struct ProgrammingTermFile: Codable {
    let formatVersion: Int
    let terms: [ProgrammingTerm]
}

final class ProgrammingTermStore {
    private let fileURL: URL
    private(set) var terms: [ProgrammingTerm]

    init(fileURL: URL = ProgrammingTermStore.defaultFileURL()) {
        self.fileURL = fileURL
        terms = []
        load()
    }

    func add(_ term: ProgrammingTerm) throws {
        guard !term.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !term.spokenAliases.isEmpty
        else { return }
        terms.append(term)
        try save()
    }

    func remove(id: UUID) throws {
        terms.removeAll { $0.id == id }
        try save()
    }

    func setEnabled(_ enabled: Bool, id: UUID) throws {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].isEnabled = enabled
        try save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ProgrammingTermFile.self, from: data),
              file.formatVersion == 1
        else { return }
        terms = file.terms
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ProgrammingTermFile(formatVersion: 1, terms: terms))
            .write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteMic", isDirectory: true)
            .appendingPathComponent("programming-terms-v1.json")
    }
}
