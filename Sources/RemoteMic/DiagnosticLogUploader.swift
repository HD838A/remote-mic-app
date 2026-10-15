import Foundation

struct DiagnosticLogEntry: Equatable {
    let sequence: Int
    let message: String
}

enum DiagnosticLogUploadError: Error, Equatable {
    case serviceNotConfigured
    case invalidServiceConfiguration
    case noLogs
    case uploadFailed
}

final class DiagnosticLogUploader: @unchecked Sendable {
    static let shared = DiagnosticLogUploader()

    typealias Sender = (_ entries: [DiagnosticLogEntry]) throws -> Void
    typealias ConfigurationStateProvider = () -> DiagnosticUploadConfigurationState

    private let eventProvider: () -> [PublicDiagnosticEvent]
    private let publicEventAcknowledger: ([PublicDiagnosticEvent]) -> Void
    private let configurationStateProvider: ConfigurationStateProvider
    private let sender: Sender
    private let queue = DispatchQueue(label: "RemoteMic.diagnosticUpload", qos: .userInitiated)
    private var uploadInProgress = false
    private weak var privateEventProvider: (any PrivateDiagnosticUploadProvider)?

    init(
        eventProvider: @escaping () -> [PublicDiagnosticEvent] = {
            AppLogger.shared.publicDiagnosticEvents()
        },
        publicEventAcknowledger: @escaping ([PublicDiagnosticEvent]) -> Void = {
            AppLogger.shared.markPublicDiagnosticEventsUploaded($0)
        },
        configurationStateProvider: @escaping ConfigurationStateProvider = {
            DiagnosticUploadTransportFactory.configurationState
        },
        sender: @escaping Sender = DiagnosticUploadTransportFactory.send
    ) {
        self.eventProvider = eventProvider
        self.publicEventAcknowledger = publicEventAcknowledger
        self.configurationStateProvider = configurationStateProvider
        self.sender = sender
    }

    func setPrivateEventProvider(_ provider: (any PrivateDiagnosticUploadProvider)?) {
        queue.sync {
            privateEventProvider = provider
        }
    }

    func upload(completion: @escaping (Result<Int, DiagnosticLogUploadError>) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.failure(.uploadFailed)) }
                return
            }
            guard self.configurationStateProvider() == .configured else {
                let result = self.configurationFailure()
                DispatchQueue.main.async { completion(result) }
                return
            }
            guard !self.uploadInProgress else {
                DispatchQueue.main.async { completion(.failure(.uploadFailed)) }
                return
            }
            self.uploadInProgress = true
            let approvedPublicEvents = self.approvedPublicEvents()
            let publicEntries = Self.publicEntries(approvedPublicEvents)
            let provider = self.privateEventProvider
            Task {
                let privateRecords = await provider?.pendingPrivateDiagnosticRecords() ?? []
                self.queue.async {
                    let approvedPrivateRecords = Self.approvedPrivateRecords(privateRecords)
                    let privateEntries = Self.privateEntries(
                        approvedPrivateRecords,
                        startingAt: publicEntries.count
                    )
                    let entries = publicEntries + privateEntries
                    guard !entries.isEmpty else {
                        self.finish(.failure(.noLogs), completion: completion)
                        return
                    }
                    // Bound each transport call, not the history snapshot. A later
                    // failed batch leaves exactly that batch and its successors pending.
                    Task {
                        var sent = 0
                        for offset in stride(from: 0, to: entries.count, by: 256) {
                            let end = min(offset + 256, entries.count)
                            let batch = Array(entries[offset..<end])
                            do { try self.sender(batch) }
                            catch {
                                self.finish(.failure(.uploadFailed), completion: completion)
                                return
                            }
                            let publicStart = min(offset, approvedPublicEvents.count)
                            let publicEnd = min(end, approvedPublicEvents.count)
                            self.publicEventAcknowledger(Array(approvedPublicEvents[publicStart..<publicEnd]))
                            let privateStart = max(0, offset - publicEntries.count)
                            let privateEnd = max(0, end - publicEntries.count)
                            if privateEnd > privateStart {
                                guard await provider?.markPrivateDiagnosticRecordsUploaded(Set(
                                    approvedPrivateRecords[privateStart..<privateEnd].map(\.recordID))) == true else {
                                    self.finish(.failure(.uploadFailed), completion: completion)
                                    return
                                }
                            }
                            sent += batch.count
                        }
                        let count = sent
                        self.finish(approvedPrivateRecords.contains { $0.fields["collection_state"] == "failed" }
                            ? .failure(.uploadFailed) : .success(count), completion: completion)
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<Int, DiagnosticLogUploadError>,
        completion: @escaping (Result<Int, DiagnosticLogUploadError>) -> Void) {
        queue.async {
            self.uploadInProgress = false
            DispatchQueue.main.async { completion(result) }
        }
    }

    func uploadSynchronously() -> Result<Int, DiagnosticLogUploadError> {
        uploadSynchronously(privateRecords: [])
    }

    func uploadSynchronously(
        privateRecords: [PrivateDiagnosticUploadRecord]
    ) -> Result<Int, DiagnosticLogUploadError> {
        guard configurationStateProvider() == .configured else {
            return configurationFailure()
        }
        let approvedPublicEvents = approvedPublicEvents()
        let publicEntries = Self.publicEntries(approvedPublicEvents)
        let entries = publicEntries + Self.privateEntries(
            Self.approvedPrivateRecords(privateRecords),
            startingAt: publicEntries.count
        )
        guard !entries.isEmpty else { return .failure(.noLogs) }

        do {
            for offset in stride(from: 0, to: entries.count, by: 256) {
                try sender(Array(entries[offset..<min(offset + 256, entries.count)]))
            }
            publicEventAcknowledger(approvedPublicEvents)
            return privateRecords.contains { $0.fields["collection_state"] == "failed" }
                ? .failure(.uploadFailed) : .success(entries.count)
        } catch {
            return .failure(.uploadFailed)
        }
    }

    private func configurationFailure() -> Result<Int, DiagnosticLogUploadError> {
        switch configurationStateProvider() {
        case .unavailable:
            return .failure(.serviceNotConfigured)
        case .invalid:
            return .failure(.invalidServiceConfiguration)
        case .configured:
            return .failure(.uploadFailed)
        }
    }

    private func approvedPublicEvents() -> [PublicDiagnosticEvent] {
        eventProvider().filter { event in
            event.isApprovedForUpload && PublicDiagnosticEvent.parse(event.canonicalLine) != nil
        }
    }

    private static func publicEntries(
        _ events: [PublicDiagnosticEvent]
    ) -> [DiagnosticLogEntry] {
        events.enumerated().map { index, event in
            DiagnosticLogEntry(sequence: index, message: event.canonicalLine)
        }
    }

    private static func privateEntries(
        _ records: [PrivateDiagnosticUploadRecord],
        startingAt offset: Int
    ) -> [DiagnosticLogEntry] {
        records.enumerated().map { index, record in
            DiagnosticLogEntry(
                sequence: offset + index,
                message: record.canonicalLine
            )
        }
    }

    private static func approvedPrivateRecords(
        _ records: [PrivateDiagnosticUploadRecord]
    ) -> [PrivateDiagnosticUploadRecord] {
        var approved: [PrivateDiagnosticUploadRecord] = []
        var seenRecordIDs = Set<String>()
        for record in records {
            guard seenRecordIDs.insert(record.recordID).inserted,
                  PrivateDiagnosticUploadRecord.parse(record.canonicalLine) == record
            else { continue }
            approved.append(record)
        }
        return approved
    }
}
