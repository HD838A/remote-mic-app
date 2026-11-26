import AppKit

final class PreferredInputSourceMonitor {
    typealias VoiceToolProvider = () -> OnboardingVoiceTool
    typealias InputSourcePreparer = (OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult
    typealias CurrentInputSourceIDProvider = () -> String?
    typealias InputSourceRestorer = (String) -> OnboardingInputSourceSwitchResult
    typealias InputSourceActivationWaiter = (
        String,
        CurrentInputSourceIDProvider,
        () -> Bool
    ) -> Bool
    typealias MonitorInstaller = (@escaping (Bool) -> Void) -> Any?
    typealias MonitorRemover = (Any) -> Void
    typealias RestoreScheduler = (TimeInterval, @escaping () -> Void) -> Void
    typealias Logger = (String) -> Void

    private let voiceTool: VoiceToolProvider
    private let prepareInputSource: InputSourcePreparer
    private let currentInputSourceID: CurrentInputSourceIDProvider
    private let restoreInputSource: InputSourceRestorer
    private let waitForInputSourceActivation: InputSourceActivationWaiter
    private let installMonitor: MonitorInstaller
    private let removeMonitor: MonitorRemover
    private let scheduleRestore: RestoreScheduler
    private let logger: Logger

    private var monitor: Any?
    private var functionKeyIsPressed = false
    private(set) var lastFunctionKeyDownAtForDiagnostics: TimeInterval?
    private(set) var lastFunctionKeyUpAtForDiagnostics: TimeInterval?
    private var explicitVoiceSessionActivationPending = false
    private var managedInputSourceSession: ManagedInputSourceSession?
    private static let activationTimeout: TimeInterval = 0.5
    private static let activationPollInterval: TimeInterval = 0.02
    /// 软件语音键松开后，语音输入法还要停止采集并把 marked text 提交进输入框。
    /// 现场统一日志：豆包在采集停止后 160–550 ms 才 `Inserting text`，而采集停止本身
    /// 又在松键后 150–330 ms；在此之前切走输入源，文字会停在组合态无法上屏。
    static let explicitRestoreDelay: TimeInterval = 1.5
    private var deferredRestoreGeneration: UInt64 = 0

    var functionKeyIsPressedForDiagnostics: Bool {
        functionKeyIsPressed
    }

    private struct ManagedInputSourceSession {
        enum Owner: Hashable {
            case functionKey
            case explicitVoice
        }

        let previousInputSourceID: String?
        let targetInputSourceID: String
        var owners: Set<Owner>
        var activationPending: Bool
        /// 所有 owner 已结束，正在等待语音工具提交文字后再恢复原输入源。
        var restoreDeferred = false
    }

    init(
        voiceTool: @escaping VoiceToolProvider,
        prepareInputSource: @escaping InputSourcePreparer = OnboardingInputSourceSwitcher.prepareForVoiceSession,
        currentInputSourceID: @escaping CurrentInputSourceIDProvider = OnboardingInputSourceSwitcher.currentInputSourceID,
        restoreInputSource: @escaping InputSourceRestorer = OnboardingInputSourceSwitcher.selectEnabledInputSource,
        waitForInputSourceActivation: @escaping InputSourceActivationWaiter = { target, current, shouldContinue in
            let deadline = Date().addingTimeInterval(PreferredInputSourceMonitor.activationTimeout)
            while shouldContinue(), current() != target, Date() < deadline {
                _ = RunLoop.main.run(
                    // Common modes are a set; run a concrete mode to wait and dispatch events.
                    mode: .default,
                    before: Date().addingTimeInterval(PreferredInputSourceMonitor.activationPollInterval)
                )
            }
            return shouldContinue() && current() == target
        },
        installMonitor: @escaping MonitorInstaller = { handler in
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                handler(event.modifierFlags.contains(.function))
            }
        },
        removeMonitor: @escaping MonitorRemover = NSEvent.removeMonitor,
        scheduleRestore: @escaping RestoreScheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        logger: @escaping Logger = AppLogger.shared.write
    ) {
        self.voiceTool = voiceTool
        self.prepareInputSource = prepareInputSource
        self.currentInputSourceID = currentInputSourceID
        self.restoreInputSource = restoreInputSource
        self.waitForInputSourceActivation = waitForInputSourceActivation
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
        self.scheduleRestore = scheduleRestore
        self.logger = logger
    }

    func start() {
        guard monitor == nil else { return }
        monitor = installMonitor { [weak self] pressed in
            self?.handleFunctionKeyPressed(pressed)
        }
    }

    func stop(preservingExplicitVoiceSession: Bool = false) {
        if !preservingExplicitVoiceSession {
            explicitVoiceSessionActivationPending = false
        }
        if preservingExplicitVoiceSession, managedInputSourceSession?.restoreDeferred == true {
            // 显式语音会话的延迟恢复仍属于该会话，不因 Fn 监听停止而提前切走输入源。
        } else {
            finishManagedInputSourceSession(
                reason: "monitor_stop",
                owner: preservingExplicitVoiceSession ? .functionKey : nil
            )
        }
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        functionKeyIsPressed = false
    }

    func handleFunctionKeyPressed(_ pressed: Bool) {
        guard pressed != functionKeyIsPressed else { return }
        functionKeyIsPressed = pressed
        if pressed {
            lastFunctionKeyDownAtForDiagnostics = ProcessInfo.processInfo.systemUptime
            lastFunctionKeyUpAtForDiagnostics = nil
        } else {
            lastFunctionKeyUpAtForDiagnostics = ProcessInfo.processInfo.systemUptime
        }
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
    @discardableResult
    func beginVoiceSession() -> Bool {
        explicitVoiceSessionActivationPending = true
        defer { explicitVoiceSessionActivationPending = false }
        return beginVoiceSession(
            reason: "voice_session_start",
            owner: .explicitVoice,
            activationShouldContinue: { [weak self] in
                self?.explicitVoiceSessionActivationPending == true
            }
        )
    }

    /// Ends an input-source session previously started for a voice key.
    ///
    /// When the trigger key was actually delivered, the voice tool still has to
    /// stop capture and commit its marked text into the focused field. Restoring
    /// the previous input source immediately takes input focus away from the tool
    /// and leaves the text stuck in composition, so the restore is deferred.
    /// A cancelled activation never delivered the trigger and restores at once.
    func endVoiceSession() {
        explicitVoiceSessionActivationPending = false
        guard var session = managedInputSourceSession,
              session.owners.contains(.explicitVoice),
              !session.activationPending
        else {
            finishManagedInputSourceSession(
                reason: "voice_session_end",
                owner: .explicitVoice
            )
            return
        }
        session.owners.remove(.explicitVoice)
        guard session.owners.isEmpty, session.previousInputSourceID != nil else {
            managedInputSourceSession = session
            if session.owners.isEmpty {
                finishManagedInputSourceSession(reason: "voice_session_end", owner: nil)
            }
            return
        }
        session.restoreDeferred = true
        managedInputSourceSession = session
        deferredRestoreGeneration &+= 1
        let generation = deferredRestoreGeneration
        let delay = Self.explicitRestoreDelay
        logger(
            "VOICE INPUT source_restore phase=deferred reason=voice_session_end " +
                "delay_ms=\(Int(delay * 1_000))"
        )
        scheduleRestore(delay) { [weak self] in
            guard let self,
                  self.deferredRestoreGeneration == generation,
                  self.managedInputSourceSession?.restoreDeferred == true
            else { return }
            self.finishManagedInputSourceSession(reason: "voice_session_end", owner: nil)
        }
    }

    /// A new voice session that starts while a deferred restore is pending keeps
    /// the already selected voice input source instead of switching away and back.
    private func reclaimDeferredRestore(owner: ManagedInputSourceSession.Owner) -> Bool? {
        guard var session = managedInputSourceSession, session.restoreDeferred else { return nil }
        deferredRestoreGeneration &+= 1
        guard currentInputSourceID() == session.targetInputSourceID else {
            // 用户在等待期间换了输入源：放弃这次恢复，按新会话重新准备。
            managedInputSourceSession = nil
            logger("VOICE INPUT source_restore phase=cancelled reason=source_changed")
            return nil
        }
        session.restoreDeferred = false
        session.owners.insert(owner)
        managedInputSourceSession = session
        logger("VOICE INPUT source_restore phase=cancelled reason=new_voice_session")
        return true
    }

    @discardableResult
    private func beginVoiceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner,
        activationShouldContinue: () -> Bool = { true }
    ) -> Bool {
        let selectedVoiceTool = voiceTool()
        if selectedVoiceTool.preferredInputSourceID != nil || managedInputSourceSession != nil {
            logger(
                "VOICE INPUT session edge=down reason=\(reason) " +
                    "tool=\(selectedVoiceTool.rawValue)"
            )
        }
        guard let targetInputSourceID = selectedVoiceTool.preferredInputSourceID else { return true }
        if managedInputSourceSession?.restoreDeferred == true,
           managedInputSourceSession?.targetInputSourceID == targetInputSourceID,
           let reclaimed = reclaimDeferredRestore(owner: owner) {
            return reclaimed
        }
        if managedInputSourceSession?.restoreDeferred == true {
            // 目标输入法已变化：立即按原逻辑结束旧会话的恢复，再开始新会话。
            deferredRestoreGeneration &+= 1
            finishManagedInputSourceSession(reason: "voice_session_end", owner: nil)
        }
        if var session = managedInputSourceSession {
            guard session.targetInputSourceID == targetInputSourceID else {
                logger("VOICE INPUT session_rejected reason=target_changed")
                return false
            }
            if session.activationPending {
                let currentSourceID = currentInputSourceID()
                guard currentSourceID == session.targetInputSourceID ||
                      currentSourceID == session.previousInputSourceID
                else {
                    logger("VOICE INPUT session_rejected reason=source_changed")
                    return false
                }
                session.owners.insert(owner)
                managedInputSourceSession = session
                return true
            }
            if currentInputSourceID() == targetInputSourceID {
                session.owners.insert(owner)
                managedInputSourceSession = session
                return true
            }
            guard owner == .explicitVoice else {
                logger("VOICE INPUT session_rejected reason=source_changed")
                return false
            }
            session.owners.insert(owner)
            session.activationPending = true
            managedInputSourceSession = session
            return completeExplicitActivation(
                targetInputSourceID: targetInputSourceID,
                activationShouldContinue: activationShouldContinue,
                selectedVoiceTool: selectedVoiceTool
            )
        }

        let previousInputSourceID = currentInputSourceID()
        if previousInputSourceID == targetInputSourceID {
            logger(
                "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=selected managed=false"
            )
            return true
        }

        let result = prepareInputSource(selectedVoiceTool)
        logger(
            "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=\(result.rawValue) " +
                "managed=\(result == .selected && previousInputSourceID != nil)"
        )
        guard result == .selected else { return false }
        managedInputSourceSession = ManagedInputSourceSession(
            previousInputSourceID: previousInputSourceID,
            targetInputSourceID: targetInputSourceID,
            owners: [owner],
            activationPending: owner == .explicitVoice
        )
        if owner == .explicitVoice {
            return completeExplicitActivation(
                targetInputSourceID: targetInputSourceID,
                activationShouldContinue: activationShouldContinue,
                selectedVoiceTool: selectedVoiceTool
            )
        }
        return true
    }

    private func completeExplicitActivation(
        targetInputSourceID: String,
        activationShouldContinue: () -> Bool,
        selectedVoiceTool: OnboardingVoiceTool
    ) -> Bool {
        guard waitForInputSourceActivation(
            targetInputSourceID,
            currentInputSourceID,
            activationShouldContinue
        ) else {
            let activationResult = activationShouldContinue()
                ? "activation_timeout"
                : "activation_cancelled"
            logger(
                "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) " +
                    "result=\(activationResult)"
            )
            if var session = managedInputSourceSession {
                session.activationPending = false
                managedInputSourceSession = session
            }
            finishManagedInputSourceSession(
                reason: activationResult,
                owner: .explicitVoice
            )
            return false
        }
        guard var session = managedInputSourceSession,
              session.owners.contains(.explicitVoice),
              session.targetInputSourceID == targetInputSourceID
        else { return false }
        session.activationPending = false
        managedInputSourceSession = session
        return true
    }

    private func finishManagedInputSourceSession(
        reason: String,
        owner: ManagedInputSourceSession.Owner?
    ) {
        guard var session = managedInputSourceSession else { return }
        if let owner {
            session.owners.remove(owner)
            guard session.owners.isEmpty else {
                managedInputSourceSession = session
                return
            }
        }
        managedInputSourceSession = nil
        if session.restoreDeferred { deferredRestoreGeneration &+= 1 }

        guard let previousInputSourceID = session.previousInputSourceID else { return }
        let currentSourceID = currentInputSourceID()
        guard currentSourceID == session.targetInputSourceID ||
              currentSourceID == previousInputSourceID
        else {
            logger(
                "VOICE INPUT source_restore skipped reason=user_changed session_reason=\(reason)"
            )
            return
        }

        let result = restoreInputSource(previousInputSourceID)
        logger(
            "VOICE INPUT source_restore result=\(result.rawValue) reason=\(reason)"
        )
    }

    deinit {
        stop()
    }
}
