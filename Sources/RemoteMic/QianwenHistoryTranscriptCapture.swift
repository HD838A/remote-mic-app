import Darwin
import Foundation

struct QianwenHistoryTranscript: Decodable, Equatable {
    let schemaVersion: Int
    let id: String
    let timestampMs: Int64
    let text: String
}

struct QianwenHistoryProcessResult: Equatable {
    let terminationStatus: Int32
    let output: Data
    let timedOut: Bool
    let forceKilled: Bool
}

final class QianwenHistoryReader {
    typealias Completion = (QianwenHistoryTranscript?) -> Void
    typealias ProcessRunner = (
        _ executableURL: URL,
        _ arguments: [String],
        _ currentDirectoryURL: URL,
        _ timeout: TimeInterval
    ) -> QianwenHistoryProcessResult

    private static let sandboxProfile =
        "(version 1)(allow default)(deny network*)(deny file-write*)"
    private static let processTimeout: TimeInterval = 3
    private let processRunner: ProcessRunner

    init(processRunner: @escaping ProcessRunner = QianwenHistoryReader.runProcess) {
        self.processRunner = processRunner
    }

    func readLatest(after startedAt: Date, before date: Date, completion: @escaping Completion) {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/QianwenHistoryReader")
        DispatchQueue.global(qos: .utility).async {
            let result = self.processRunner(
                URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                [
                    "-p", Self.sandboxProfile,
                    helperURL.path,
                    "--after-ms", String(Int64(startedAt.timeIntervalSince1970 * 1_000)),
                    "--before-ms", String(Int64(date.timeIntervalSince1970 * 1_000)),
                ],
                URL(fileURLWithPath: "/private/var/empty"),
                Self.processTimeout
            )
            let transcript = !result.timedOut && result.terminationStatus == 0
                ? try? JSONDecoder().decode(QianwenHistoryTranscript.self, from: result.output)
                : nil
            DispatchQueue.main.async { completion(transcript) }
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: TimeInterval
    ) -> QianwenHistoryProcessResult {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return QianwenHistoryProcessResult(
                terminationStatus: -1,
                output: Data(),
                timedOut: false,
                forceKilled: false
            )
        }

        guard finished.wait(timeout: .now() + timeout) == .timedOut else {
            return QianwenHistoryProcessResult(
                terminationStatus: process.terminationStatus,
                output: output.fileHandleForReading.readDataToEndOfFile(),
                timedOut: false,
                forceKilled: false
            )
        }

        process.terminate()
        var forceKilled = false
        if finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut,
           process.isRunning {
            forceKilled = Darwin.kill(process.processIdentifier, SIGKILL) == 0
            _ = finished.wait(timeout: .now() + .milliseconds(100))
        }
        return QianwenHistoryProcessResult(
            terminationStatus: -1,
            output: Data(),
            timedOut: true,
            forceKilled: forceKilled
        )
    }
}

final class QianwenHistoryTranscriptCapture {
    typealias Reader = (Date, Date, @escaping (QianwenHistoryTranscript?) -> Void) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask

    private struct Session {
        let generation: UInt64
        let startedAt: Date
        let source: UsageEventSource
        let applicationName: String
        let bundleIdentifier: String
        var endedAt: Date?
        var deadline: TimeInterval?
    }

    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let reader: Reader
    private let schedule: Scheduler
    private let clock: () -> TimeInterval
    private let now: () -> Date
    private let onCapture: (CapturedTranscript) -> Void
    private let log: (String) -> Void
    private var generation: UInt64 = 0
    private var session: Session?
    private var pollTask: VoiceFnTapScheduledTask?

    init(
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5,
        reader: @escaping Reader,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping () -> Date = Date.init,
        onCapture: @escaping (CapturedTranscript) -> Void,
        log: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.reader = reader
        self.schedule = schedule
        self.clock = clock
        self.now = now
        self.onCapture = onCapture
        self.log = log
    }

    func startSession(
        startedAt: Date,
        source: UsageEventSource,
        applicationName: String,
        bundleIdentifier: String
    ) {
        cancel()
        generation &+= 1
        session = Session(
            generation: generation,
            startedAt: startedAt,
            source: source,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        log("QIANWEN HISTORY waiting bundle=\(bundleIdentifier)")
    }

    func finishSession(endedAt: Date) {
        guard var session, session.endedAt == nil else { return }
        session.endedAt = endedAt
        session.deadline = clock() + timeout
        self.session = session
        poll(generation: session.generation)
    }

    func cancel(reason: String? = nil) {
        let hadSession = session != nil
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        session = nil
        if hadSession, let reason {
            log("QIANWEN HISTORY canceled reason=\(reason)")
        }
    }

    private func poll(generation: UInt64) {
        guard let session, session.generation == generation,
              let endedAt = session.endedAt,
              let deadline = session.deadline
        else { return }
        reader(session.startedAt, now()) { [weak self] result in
            guard let self,
                  let current = self.session,
                  current.generation == generation
            else { return }
            if let result, result.schemaVersion == 1 {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.cancel(reason: "empty_result")
                    return
                }
                let capture = CapturedTranscript(
                    sessionID: UUID(),
                    startedAt: current.startedAt,
                    endedAt: endedAt,
                    applicationName: current.applicationName,
                    bundleIdentifier: current.bundleIdentifier,
                    source: current.source,
                    text: text
                )
                self.cancel()
                self.log(
                    "QIANWEN HISTORY saved bundle=\(current.bundleIdentifier) " +
                        "characters=\(text.count)"
                )
                self.onCapture(capture)
                return
            }
            guard self.clock() < deadline else {
                self.cancel(reason: "timeout")
                return
            }
            self.pollTask = self.schedule(self.pollInterval) { [weak self] in
                self?.poll(generation: generation)
            }
        }
    }
}
