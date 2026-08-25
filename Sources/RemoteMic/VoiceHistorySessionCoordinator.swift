import AppKit
import Foundation

struct CompletedVoiceHistorySession: Equatable {
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let applicationName: String
    let bundleIdentifier: String
    let source: UsageEventSource
    let transcript: String?
    let audio: TranscriptAudioAttachment?
}

final class VoiceHistorySessionCoordinator {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask

    private struct Session {
        let id: UUID
        let startedAt: Date
        let source: UsageEventSource
        let fallbackApplicationName: String
        let fallbackBundleIdentifier: String
        var endedAt: Date?
        var capture: CapturedTranscript?
        var audio: TranscriptAudioAttachment?
        var audioFinalized: Bool
    }

    private let transcriptWaitAfterVoiceEnd: TimeInterval
    private let schedule: Scheduler
    private let onComplete: (CompletedVoiceHistorySession) -> Void
    private var sessions: [UUID: Session] = [:]
    private var timeoutTasks: [UUID: VoiceFnTapScheduledTask] = [:]

    init(
        transcriptWaitAfterVoiceEnd: TimeInterval = 8.25,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        onComplete: @escaping (CompletedVoiceHistorySession) -> Void
    ) {
        self.transcriptWaitAfterVoiceEnd = transcriptWaitAfterVoiceEnd
        self.schedule = schedule
        self.onComplete = onComplete
    }

    func begin(
        sessionID: UUID,
        startedAt: Date,
        source: UsageEventSource,
        applicationName: String,
        bundleIdentifier: String,
        expectsAudio: Bool
    ) {
        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        sessions[sessionID] = Session(
            id: sessionID,
            startedAt: startedAt,
            source: source,
            fallbackApplicationName: applicationName,
            fallbackBundleIdentifier: bundleIdentifier,
            audioFinalized: !expectsAudio
        )
    }

    func finish(sessionID: UUID, endedAt: Date) {
        guard var session = sessions[sessionID] else { return }
        session.endedAt = endedAt
        sessions[sessionID] = session
        completeIfReady(sessionID: sessionID, transcriptTimedOut: false)
        guard sessions[sessionID] != nil else { return }
        timeoutTasks[sessionID]?.cancel()
        timeoutTasks[sessionID] = schedule(transcriptWaitAfterVoiceEnd) { [weak self] in
            self?.completeIfReady(sessionID: sessionID, transcriptTimedOut: true)
        }
    }

    func receiveTranscript(_ capture: CapturedTranscript) {
        guard var session = sessions[capture.sessionID] else { return }
        session.capture = capture
        sessions[capture.sessionID] = session
        completeIfReady(sessionID: capture.sessionID, transcriptTimedOut: false)
    }

    func receiveAudioResult(
        sessionID: UUID,
        attachment: TranscriptAudioAttachment?
    ) {
        guard var session = sessions[sessionID] else { return }
        session.audio = attachment
        session.audioFinalized = true
        sessions[sessionID] = session
        completeIfReady(sessionID: sessionID, transcriptTimedOut: false)
    }

    func cancelAll() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        sessions.removeAll()
    }

    private func completeIfReady(sessionID: UUID, transcriptTimedOut: Bool) {
        guard let session = sessions[sessionID],
              let endedAt = session.endedAt,
              session.audioFinalized,
              session.capture != nil || transcriptTimedOut
        else { return }

        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        sessions.removeValue(forKey: sessionID)
        let capture = session.capture
        let transcript = capture?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        onComplete(CompletedVoiceHistorySession(
            sessionID: session.id,
            startedAt: session.startedAt,
            endedAt: endedAt,
            applicationName: capture?.applicationName.nilIfBlank
                ?? session.fallbackApplicationName,
            bundleIdentifier: capture?.bundleIdentifier.nilIfBlank
                ?? session.fallbackBundleIdentifier,
            source: session.source,
            transcript: transcript?.nilIfBlank,
            audio: session.audio
        ))
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
