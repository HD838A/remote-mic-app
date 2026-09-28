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
                        DispatchQueue.main.async { completion(.failure(.noLogs)) }
                        return
                    }
                    do {
                        try self.sender(entries)
                    } catch {
                        DispatchQueue.main.async { completion(.failure(.uploadFailed)) }
                        return
                    }
                    self.publicEventAcknowledger(approvedPublicEvents)
                    let uploadedRecordIDs = Set(approvedPrivateRecords.map(\.recordID))
                    Task {
                        await provider?.markPrivateDiagnosticRecordsUploaded(uploadedRecordIDs)
                        DispatchQueue.main.async { completion(.success(entries.count)) }
                    }
                }
            }
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
            try sender(entries)
            publicEventAcknowledger(approvedPublicEvents)
            return .success(entries.count)
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
        for record in records.prefix(256) {
            guard seenRecordIDs.insert(record.recordID).inserted,
                  PrivateDiagnosticUploadRecord.parse(record.canonicalLine) == record
            else { continue }
            approved.append(record)
        }
        return approved
    }
}
