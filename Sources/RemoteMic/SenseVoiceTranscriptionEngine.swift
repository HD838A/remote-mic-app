import FluidAudio
import Foundation

/// The primary local transcription engine for the remote's voice button —
/// SenseVoice via FluidAudio (https://github.com/FluidInference/FluidAudio,
/// Apache-2.0).
///
/// SenseVoice is non-autoregressive: a SANM encoder feeding a single CTC
/// head, producing every output token in one forward pass with a greedy
/// blank-collapse decode — no iterative decode loop, no KV-cache, no forced
/// language/task token sequence for a decoder to go astray on. That's
/// structurally different from Whisper's autoregressive decoder, so it
/// doesn't hit the empty-output collapse documented in
/// `EmbeddedTranscriptionEngine.transcribe(pcm16:)`, which is specific to
/// WhisperKit's static-KV-cache greedy decoder loop. Real-remote testing
/// confirmed it also genuinely preserves colloquial Cantonese script
/// (讲嘢/得唔得/系/嗰个/噶 and similar), where every WhisperKit-based
/// Cantonese model tried this session either collapsed or normalized to
/// standard written Chinese.
///
/// `EmbeddedTranscriptionEngine` (WhisperKit) is kept only as an automatic
/// fallback for if this engine fails to load — see
/// `BridgeAppModel.transcribeEmbeddedBufferAndInsertIfReady()`.
///
/// Fine-tuning on the user's own voice was considered (their normal-length
/// speech transcribes accurately; occasional word-level slips appear only
/// on longer sentences) and deliberately not pursued: those slips are
/// minor and typical of any ASR system, while fine-tuning would require
/// both collecting and hand-correcting a personal training set *and*
/// rebuilding this model's CoreML conversion from scratch for the tuned
/// checkpoint — unlike Whisper, there's no packaged converter (no
/// `whisperkittools` equivalent) for SenseVoice; FluidAudio's own
/// conversion notes document real pitfalls they solved by hand (an
/// FP16-vs-compute-unit NaN bug, a from-scratch CoreML replica of the
/// fbank front-end). Revisit only if accuracy becomes a real problem
/// rather than an occasional minor slip.
actor SenseVoiceTranscriptionEngine {
    /// FunASR's own language-embed index for Cantonese, distinct from
    /// Mandarin (3) and auto-detect (0) — from `lid_dict` in
    /// https://github.com/modelscope/FunASR/blob/main/funasr/models/sense_voice/model.py
    /// (`{"auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12}`).
    /// FluidAudio's `SenseVoiceManager` doesn't expose a named enum for
    /// this — just the raw embed index it passes straight through to the
    /// CoreML model — so this fork owns the mapping.
    private static let cantoneseLanguageIndex: Int32 = 7

    enum Status: Equatable {
        case loading
        case ready
        case failed
    }

    private var loadTask: Task<SenseVoiceManager, Error>?
    private let logger: (String) -> Void

    /// Same best-effort time-based estimate as
    /// `EmbeddedTranscriptionEngine.currentLoadProgress()` — see that type's
    /// doc comment for why it can't be an exact measurement. SenseVoice
    /// loads much faster than the WhisperKit models in practice (~2 minutes
    /// including first-run download, vs. 3+ minutes), hence the lower
    /// default guess.
    private var loadStartedAt: Date?
    private(set) var isDownloadingModel = false

    private static let typicalTotalDurationKey = "SenseVoiceTranscription.typicalTotalDurationMs"
    private static let defaultTypicalTotalDurationMs: Double = 120_000

    private static func recordTypicalTotalDuration(_ milliseconds: Int) {
        UserDefaults.standard.set(milliseconds, forKey: typicalTotalDurationKey)
    }

    private static func typicalTotalDurationMilliseconds() -> Double {
        let stored = UserDefaults.standard.double(forKey: typicalTotalDurationKey)
        return stored > 0 ? stored : defaultTypicalTotalDurationMs
    }

    init(logger: @escaping (String) -> Void = AppLogger.shared.write) {
        self.logger = logger
    }

    func currentLoadProgress() -> Double {
        guard let loadStartedAt else { return 0 }
        let elapsedMilliseconds = Date().timeIntervalSince(loadStartedAt) * 1_000
        return min(0.97, elapsedMilliseconds / Self.typicalTotalDurationMilliseconds())
    }

    /// Begins downloading (first use only; cached after) and loading the
    /// model in the background. Safe to call repeatedly.
    func prewarm() {
        _ = loadModels()
    }

    /// A failed download/load is kept in `loadTask` until retried. Only
    /// resets a completed failed task so an in-flight load isn't duplicated.
    func retryAfterFailure() async -> Status {
        if let loadTask {
            do {
                _ = try await loadTask.value
                return await status()
            } catch {
                self.loadTask = nil
            }
        }
        return await status()
    }

    func status() async -> Status {
        do {
            _ = try await loadModels().value
            return .ready
        } catch {
            return .failed
        }
    }

    /// Transcribes 16kHz mono Int16 PCM — the same format
    /// `EmbeddedTranscriptionEngine.transcribe(pcm16:)` takes — forcing the
    /// Cantonese language embed, and converting SenseVoice's Simplified
    /// Chinese output to Traditional (via macOS's built-in ICU `Hans-Hant`
    /// transform — verified against real transcripts, e.g. 试->試, 讲->講,
    /// 个->個, leaving already-shared characters and embedded English words
    /// untouched). Returns `nil` for empty/silent buffers or genuinely empty
    /// output, matching `EmbeddedTranscriptionEngine`'s contract so callers
    /// can use either interchangeably.
    /// Below this, there isn't enough audio to fill even SenseVoice's
    /// smallest 128-frame post-LFR encoder bucket (roughly 0.77s of 16kHz
    /// audio); shorter buffers throw from the encoder rather than returning
    /// an empty result. An accidental sub-quarter-second button tap isn't
    /// real speech anyway, so this is treated the same as silence rather
    /// than an error worth falling back to WhisperKit for.
    private static let minimumSampleCount = 4_000

    func transcribe(pcm16 samples: [Int16]) async throws -> String? {
        guard samples.count >= Self.minimumSampleCount else {
            logger("SENSEVOICE transcribe_skipped reason=too_short samples=\(samples.count)")
            return nil
        }
        let floatSamples = samples.map { Float($0) / Float(Int16.max) }
        guard floatSamples.contains(where: { abs($0) > 0.001 }) else {
            logger("SENSEVOICE transcribe_skipped reason=silent samples=\(samples.count)")
            return nil
        }
        let manager = try await loadModels().value
        let startedAt = Date()
        let rawText = try await manager.transcribe(audio: floatSamples)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = rawText.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? rawText
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        logger(
            "SENSEVOICE transcribe_completed samples=\(samples.count) " +
                "elapsed_ms=\(elapsedMilliseconds) chars=\(text.count) text=\(text)"
        )
        return text.isEmpty ? nil : text
    }

    private func loadModels() -> Task<SenseVoiceManager, Error> {
        if let loadTask { return loadTask }
        let overallStartedAt = Date()
        loadStartedAt = overallStartedAt
        let task = Task<SenseVoiceManager, Error> { [logger] in
            logger("SENSEVOICE model_load_started")
            let startedAt = Date()
            self.isDownloadingModel = true
            let models = try await SenseVoiceModels.downloadAndLoad()
            self.isDownloadingModel = false
            let manager = SenseVoiceManager(models: models, language: Self.cantoneseLanguageIndex)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            logger("SENSEVOICE model_load_completed elapsed_ms=\(elapsedMilliseconds)")
            Self.recordTypicalTotalDuration(
                Int(Date().timeIntervalSince(overallStartedAt) * 1_000)
            )
            return manager
        }
        loadTask = task
        return task
    }
}
