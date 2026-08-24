import AppKit

final class PreferredInputSourceMonitor {
    typealias VoiceToolProvider = () -> OnboardingVoiceTool
    typealias InputSourcePreparer = (OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult
    typealias CurrentInputSourceIDProvider = () -> String?
    typealias InputSourceRestorer = (String) -> OnboardingInputSourceSwitchResult
    typealias MonitorInstaller = (@escaping (Bool) -> Void) -> Any?
    typealias MonitorRemover = (Any) -> Void
    typealias Logger = (String) -> Void

    private let voiceTool: VoiceToolProvider
    private let prepareInputSource: InputSourcePreparer
    private let currentInputSourceID: CurrentInputSourceIDProvider
    private let restoreInputSource: InputSourceRestorer
    private let installMonitor: MonitorInstaller
    private let removeMonitor: MonitorRemover
    private let logger: Logger

    private var monitor: Any?
    private var functionKeyIsPressed = false
    private var managedInputSourceSession: ManagedInputSourceSession?

    var functionKeyIsPressedForDiagnostics: Bool {
        functionKeyIsPressed
    }

    private struct ManagedInputSourceSession {
        enum Owner: Equatable {
            case functionKey
            case explicitVoice
        }

        let previousInputSourceID: String
        let targetInputSourceID: String
        let owner: Owner
    }

    init(
        voiceTool: @escaping VoiceToolProvider,
        prepareInputSource: @escaping InputSourcePreparer = OnboardingInputSourceSwitcher.prepareForVoiceSession,
        currentInputSourceID: @escaping CurrentInputSourceIDProvider = OnboardingInputSourceSwitcher.currentInputSourceID,
        restoreInputSource: @escaping InputSourceRestorer = OnboardingInputSourceSwitcher.selectEnabledInputSource,
        installMonitor: @escaping MonitorInstaller = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                handler(event.modifierFlags.contains(.function))
            }
        },
        removeMonitor: @escaping MonitorRemover = NSEvent.removeMonitor,
        logger: @escaping Logger = AppLogger.shared.write
    ) {
        self.voiceTool = voiceTool
        self.prepareInputSource = prepareInputSource
        self.currentInputSourceID = currentInputSourceID
        self.restoreInputSource = restoreInputSource
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
        self.logger = logger
    }

    func start() {
        guard monitor == nil else { return }
        monitor = installMonitor { [weak self] pressed in
            self?.handleFunctionKeyPressed(pressed)
        }
    }

    func stop() {
        finishManagedInputSourceSession(reason: "monitor_stop", owner: nil)
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        functionKeyIsPressed = false
    }

    func handleFunctionKeyPressed(_ pressed: Bool) {
        guard pressed != functionKeyIsPressed else { return }
        functionKeyIsPressed = pressed
        if !pressed {
            let selectedVoiceTool = voiceTool()
            if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
                logger(
                    "VOICE INPUT function_key edge=up tool=\(selectedVoiceTool.rawValue)"
                )
            }
            finishManagedInputSourceSession(
                reason: "function_key_up",
                owner: .functionKey
            )
            return
        }

        let selectedVoiceTool = voiceTool()
        if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
            logger(
                "VOICE INPUT function_key edge=down tool=\(selectedVoiceTool.rawValue)"
            )
        }
        beginVoiceSession(reason: "function_key_down", owner: .functionKey)
    }

    /// Starts the input-source session for a software-emitted voice key.
    /// Command keys do not produce the Fn `flagsChanged` event that the legacy
    /// monitor observes, so their lifecycle is driven explicitly by the voice
    /// session instead of by every ordinary Command press on the Mac keyboard.
    func beginVoiceSession() {
        beginVoiceSession(reason: "voice_session_start", owner: .explicitVoice)
    }

    /// Ends an input-source session previously started for a voice key.
    func endVoiceSession() {
        finishManagedInputSourceSession(
            reason: "voice_session_end",
            owner: .explicitVoice
        )
    }

    private func beginVoiceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner
    ) {
        let selectedVoiceTool = voiceTool()
        if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
            logger(
                "VOICE INPUT session edge=down reason=\(reason) " +
                    "tool=\(selectedVoiceTool.rawValue)"
            )
        }
        guard managedInputSourceSession == nil else { return }

        guard let targetInputSourceID = selectedVoiceTool.preferredInputSourceID else { return }
        let previousInputSourceID = currentInputSourceID()
        if previousInputSourceID == targetInputSourceID {
            logger(
                "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=selected managed=false"
            )
            return
        }

        let result = prepareInputSource(selectedVoiceTool)
        logger(
            "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=\(result.rawValue) " +
                "managed=\(result == .selected && previousInputSourceID != nil)"
        )
        if result == .selected, let previousInputSourceID {
            managedInputSourceSession = ManagedInputSourceSession(
                previousInputSourceID: previousInputSourceID,
                targetInputSourceID: targetInputSourceID,
                owner: owner
            )
        }
    }

    private func finishManagedInputSourceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner?
    ) {
        guard let session = managedInputSourceSession else { return }
        if let owner, session.owner != owner { return }
        managedInputSourceSession = nil

        guard currentInputSourceID() == session.targetInputSourceID else {
            logger(
                "VOICE INPUT source_restore skipped reason=user_changed session_reason=\(reason)"
            )
            return
        }

        let result = restoreInputSource(session.previousInputSourceID)
        logger(
            "VOICE INPUT source_restore result=\(result.rawValue) reason=\(reason)"
        )
    }

    deinit {
        stop()
    }
}
