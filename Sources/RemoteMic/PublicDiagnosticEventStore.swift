import Foundation

/// Persists only upload-approved events, independently of encrypted local logs.
/// AppLogger serializes all access to this store.
final class PublicDiagnosticEventStore {
    private struct Record: Codable {
        let occurredAt: Date
        let line: String
    }

    private let fileURL: URL
    private let capacity: Int
    private let ttl: TimeInterval
    private let now: () -> Date
    private var records: [Record]

    init(fileURL: URL, capacity: Int = 256, ttl: TimeInterval = 7 * 24 * 60 * 60,
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        self.ttl = ttl
        self.now = now
        records = (try? JSONDecoder().decode([Record].self, from: Data(contentsOf: fileURL))) ?? []
        prune()
    }

    func append(_ event: PublicDiagnosticEvent) throws {
        guard event.isApprovedForUpload, PublicDiagnosticEvent.parse(event.canonicalLine) != nil else { return }
        prune()
        records.append(Record(occurredAt: now(), line: event.canonicalLine))
        trim()
        try persist()
    }

    func pending() -> [PublicDiagnosticEvent] {
        prune()
        return records.compactMap { PublicDiagnosticEvent.parse($0.line) }
    }

    func acknowledge(_ events: [PublicDiagnosticEvent]) throws {
        for event in events {
            if let index = records.firstIndex(where: { $0.line == event.canonicalLine }) {
                records.remove(at: index)
            }
        }
        prune()
        try persist()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-ttl)
        records.removeAll { record in
            record.occurredAt < cutoff ||
                PublicDiagnosticEvent.parse(record.line)?.isApprovedForUpload != true
        }
        trim()
    }

    private func trim() {
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
