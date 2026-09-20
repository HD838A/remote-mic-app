import Foundation
import Hub
import WhisperKit

/// Transcribes the remote's captured voice audio entirely on-device, using
/// WhisperKit (https://github.com/argmaxinc/argmax-oss-swift, MIT license).
///
/// This is what lets a single build of this fork replace the
/// SayAll + separate-dictation-app pairing: SayAll already decodes the
/// remote's Bluetooth voice audio into 16kHz PCM for its virtual-microphone
/// output (`VirtualAudioOutput`); this engine taps the same samples and
/// turns them into text directly, with no virtual audio device and no
/// second app required.
actor EmbeddedTranscriptionEngine {
    private struct LoadedModels {
        /// `nil` if the Cantonese model failed to download/load — every
        /// transcription then simply uses `fallback`.
        let cantonese: WhisperKit?
        let fallback: WhisperKit
    }

    /// Argmax's recommended "maximum speed and accuracy" variant for macOS.
    /// Always loaded, as the reliable baseline every transcription can fall
    /// back to — see `transcribe(pcm16:)`.
    /// See https://github.com/argmaxinc/argmax-oss-swift#model-selection.
    static let fallbackModelName = "large-v3-v20240930_turbo"

    /// The stock Whisper model (above) has no distinct Cantonese language
    /// tag — only generic "zh" — because it was trained almost entirely on
    /// Cantonese audio paired with *standard written Chinese* transcripts.
    /// It never learned that native Cantonese orthography (嘅/咗/喺/冇/佢/
    /// 唔/嘢/哋/啲/嚟/咁 and so on) is a valid output at all, so no amount of
    /// prompting or decoding options can make it produce it — confirmed by
    /// two independent, failed attempts at prompt-based biasing (see git
    /// history). Fixing this needs a model actually fine-tuned on
    /// Cantonese-speech-to-Cantonese-script pairs. This one is trained on
    /// Common Voice's Cantonese ("yue") config plus a mixed Cantonese/
    /// English corpus, reports 0.64% CER on the Common Voice yue test set,
    /// is MIT-licensed, and — unusually — is already published as a
    /// WhisperKit-format CoreML conversion (`library_name: whisperkit` in
    /// its own model card), based on the same large-v3-turbo architecture
    /// as the fallback above:
    /// https://huggingface.co/hyperkit/whisper-large-v3-turbo-cantonese-yue-english-coreml
    /// (converted from
    /// https://huggingface.co/JackyHoCL/whisper-large-v3-turbo-cantonese-yue-english)
    ///
    /// Its files sit at the repo root rather than in a model-variant
    /// subfolder the way WhisperKit's own `argmaxinc/whisperkit-coreml`
    /// models are laid out, so it can't go through `WhisperKitConfig(model:)`
    /// — it's fetched directly via the same Hub client WhisperKit uses
    /// internally, into a local folder, then loaded via
    /// `WhisperKitConfig(modelFolder:)`.
    ///
    /// It has also proven unreliable in testing: it reliably decodes real
    /// Cantonese script on a genuine first attempt after loading, but on
    /// later calls frequently emits only its 5 mandatory scaffold tokens
    /// (`<|startoftranscript|><|yue|><|transcribe|><|0.00|><|endoftext|>`)
    /// with zero generated content — for audio that is demonstrably
    /// non-silent. Disabling `usePrefillCache` did not fix it. This looks
    /// like a genuine state-handling bug in this specific community CoreML
    /// conversion (or in how WhisperKit drives it), not a decoding option
    /// away from being fixed — so rather than keep guessing at the
    /// internals, `transcribe(pcm16:)` treats that exact empty-output
    /// signature as a signal to immediately retry the same audio through
    /// `fallback`, which has not exhibited this failure. That means: native
    /// Cantonese script when the model cooperates, standard-Chinese meaning
    /// preserved when it doesn't — never silence.
    private static let cantoneseModelRepo =
        "hyperkit/whisper-large-v3-turbo-cantonese-yue-english-coreml"

    /// WhisperKit's default cache root (`~/Documents/huggingface`) is shared
    /// by any app on the Mac that uses swift-transformers' Hub downloader —
    /// including other, unrelated local-STT apps. Two apps racing to
    /// populate that shared tree at once has caused real
    /// "temp file couldn't be moved" download failures in testing. Keep this
    /// fork's models entirely inside its own app-support directory instead.
    private static let downloadBase = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RemoteMic", isDirectory: true)
        .appendingPathComponent("WhisperKitModels", isDirectory: true)

    private var loadTask: Task<LoadedModels, Error>?
    private let logger: (String) -> Void

    enum Status: Equatable {
        case loading
        case ready(usesCantoneseModel: Bool)
        case failed
    }

    init(logger: @escaping (String) -> Void = AppLogger.shared.write) {
        self.logger = logger
    }

    /// Begins loading (and, on first run, downloading) both models in the
    /// background without blocking anything. Safe to call repeatedly; the
    /// underlying work only happens once.
    func prewarm() {
        _ = loadModels()
    }

    /// A failed download/load is kept in `loadTask` until the user retries.
    /// Only reset a completed failed task so an in-flight load is not duplicated.
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

    /// Reports which model(s) are actually available right now, for display
    /// in Settings. Suspends until loading finishes if it's still in
    /// progress — callers should treat this as a one-shot status fetch (see
    /// `BridgeAppModel`, which stores the result in a `@Published` property
    /// rather than calling this repeatedly).
    func status() async -> Status {
        do {
            let models = try await loadModels().value
            return .ready(usesCantoneseModel: models.cantonese != nil)
        } catch {
            return .failed
        }
    }

    /// Transcribes a buffer of 16kHz mono Int16 PCM samples — the same
    /// format SayAll already assembles for the virtual-microphone path — and
    /// returns the recognized text. Returns `nil` (rather than throwing) for
    /// empty or effectively-silent buffers, since that is an expected,
    /// frequent case (a very short button tap) rather than a failure.
    func transcribe(pcm16 samples: [Int16]) async throws -> String? {
        guard !samples.isEmpty else { return nil }
        let floatSamples = Self.normalize(samples)
        guard floatSamples.contains(where: { abs($0) > 0.001 }) else {
            logger("EMBEDDED WHISPER transcribe_skipped reason=silent samples=\(samples.count)")
            return nil
        }
        let models = try await loadModels().value
        if let cantonese = models.cantonese {
            let text = try await Self.runTranscribe(
                cantonese,
                floatSamples: floatSamples,
                sampleCount: samples.count,
                // "yue" per the model's own README; usePrefillCache disabled
                // per the doc comment above this model's declaration.
                decodeOptions: DecodingOptions(language: "yue", usePrefillCache: false),
                modelLabel: "cantonese",
                logger: logger
            )
            if let text {
                return text
            }
            logger("EMBEDDED WHISPER cantonese_empty_retrying_fallback samples=\(samples.count)")
        }
        return try await Self.runTranscribe(
            models.fallback,
            floatSamples: floatSamples,
            sampleCount: samples.count,
            decodeOptions: nil,
            modelLabel: "fallback",
            logger: logger
        )
    }

    private static func runTranscribe(
        _ pipeline: WhisperKit,
        floatSamples: [Float],
        sampleCount: Int,
        decodeOptions: DecodingOptions?,
        modelLabel: String,
        logger: (String) -> Void
    ) async throws -> String? {
        let startedAt = Date()
        let results = try await pipeline.transcribe(
            audioArray: floatSamples,
            decodeOptions: decodeOptions
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let segmentCount = results.reduce(0) { $0 + $1.segments.count }
        logger(
            "EMBEDDED WHISPER transcribe_completed samples=\(sampleCount) " +
                "elapsed_ms=\(elapsedMilliseconds) chars=\(text.count) " +
                "model=\(modelLabel) results=\(results.count) segments=\(segmentCount)"
        )
        return text.isEmpty ? nil : text
    }

    @discardableResult
    private func loadModels() -> Task<LoadedModels, Error> {
        if let loadTask { return loadTask }
        let task = Task<LoadedModels, Error> { [logger] in
            async let cantoneseTask = Self.loadCantoneseModel(logger: logger)
            async let fallbackTask = Self.loadFallbackModel(logger: logger)
            let cantonese = await cantoneseTask
            let fallback = try await fallbackTask
            let models = LoadedModels(cantonese: cantonese, fallback: fallback)
            // Loading a model is fast even on a cold cache; what is not fast
            // is Core ML's own on-device compilation of the compute graph,
            // which only happens lazily on the *first* real prediction —
            // observed taking upwards of 90 seconds. Eat that cost here,
            // against throwaway noise, immediately after loading (i.e. as
            // early as app launch, via `prewarm()`) rather than during the
            // user's first real remote press.
            let warmupStartedAt = Date()
            if let cantonese = models.cantonese {
                _ = try? await cantonese.transcribe(audioArray: Self.warmupNoise)
            }
            _ = try? await models.fallback.transcribe(audioArray: Self.warmupNoise)
            let warmupElapsedMilliseconds = Int(Date().timeIntervalSince(warmupStartedAt) * 1_000)
            logger("EMBEDDED WHISPER model_warmup_completed elapsed_ms=\(warmupElapsedMilliseconds)")
            return models
        }
        loadTask = task
        return task
    }

    /// Downloads (on first use; cached after) and loads the Cantonese-native
    /// model. Returns `nil` — instead of throwing — on *any* failure
    /// (network error, Hub layout change upstream, Core ML load failure),
    /// so the caller can use `fallback` alone rather than leaving dictation
    /// broken while this is worked out.
    private static func loadCantoneseModel(logger: (String) -> Void) async -> WhisperKit? {
        do {
            logger("EMBEDDED WHISPER cantonese_model_load_started repo=\(cantoneseModelRepo)")
            let startedAt = Date()
            let hub = HubApi(downloadBase: downloadBase)
            let repo = Hub.Repo(id: cantoneseModelRepo, type: .models)
            let modelFolder = try await hub.snapshot(from: repo, matching: ["*"])
            let configuration = WhisperKitConfig(modelFolder: modelFolder.path, download: false)
            let pipeline = try await WhisperKit(configuration)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            logger("EMBEDDED WHISPER cantonese_model_load_completed elapsed_ms=\(elapsedMilliseconds)")
            return pipeline
        } catch {
            logger("EMBEDDED WHISPER cantonese_model_load_failed error_type=\(type(of: error))")
            return nil
        }
    }

    private static func loadFallbackModel(logger: (String) -> Void) async throws -> WhisperKit {
        logger("EMBEDDED WHISPER model_load_started model=\(fallbackModelName)")
        let startedAt = Date()
        let configuration = WhisperKitConfig(
            model: fallbackModelName,
            downloadBase: downloadBase,
            download: true
        )
        let pipeline = try await WhisperKit(configuration)
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        logger("EMBEDDED WHISPER model_load_completed elapsed_ms=\(elapsedMilliseconds)")
        return pipeline
    }

    /// One second of quiet synthetic noise at 16kHz — enough signal to make
    /// Core ML run its real compute graph (true silence can short-circuit
    /// early), without ever being mistaken for a real recording.
    private static let warmupNoise: [Float] = (0..<16_000).map { index in
        0.001 * Float(sin(Double(index) * 0.1))
    }

    /// Whisper expects samples normalized to roughly [-1, 1]; SayAll's
    /// captured audio is signed 16-bit PCM.
    private static func normalize(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / Float(Int16.max) }
    }
}
