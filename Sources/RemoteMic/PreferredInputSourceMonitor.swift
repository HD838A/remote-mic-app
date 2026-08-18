import AppKit

final class PreferredInputSourceMonitor {
    typealias VoiceToolProvider = () -> OnboardingVoiceTool
    typealias InputSourcePreparer = (OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult
    typealias MonitorInstaller = (@escaping (Bool) -> Void) -> Any?
    typealias MonitorRemover = (Any) -> Void
    typealias Logger = (String) -> Void

    private let voiceTool: VoiceToolProvider
    private let prepareInputSource: InputSourcePreparer
    private let installMonitor: MonitorInstaller
    private let removeMonitor: MonitorRemover
    private let logger: Logger

    private var monitor: Any?
    private var functionKeyIsPressed = false

    init(
        voiceTool: @escaping VoiceToolProvider,
        prepareInputSource: @escaping InputSourcePreparer = OnboardingInputSourceSwitcher.selectIfNeeded,
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
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        functionKeyIsPressed = false
    }

    func handleFunctionKeyPressed(_ pressed: Bool) {
        guard pressed != functionKeyIsPressed else { return }
        functionKeyIsPressed = pressed
        guard pressed else { return }

        let selectedVoiceTool = voiceTool()
        guard selectedVoiceTool.preferredInputSourceID != nil else { return }
        let result = prepareInputSource(selectedVoiceTool)
        logger(
            "VOICE INPUT source_prepare tool=\(selectedVoiceTool.rawValue) result=\(result.rawValue)"
        )
    }

    deinit {
        stop()
    }
}
