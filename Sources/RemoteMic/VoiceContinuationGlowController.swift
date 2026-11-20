import AppKit

enum VoiceGlowScreenSelection {
    static func index(window: CGRect, screens: [CGRect]) -> Int? {
        var selected: Int?
        var largestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea {
                selected = index
                largestArea = area
            }
        }
        return selected
    }
}

struct VoiceGlowState {
    static let sessionDuration: TimeInterval = 60
    static let defaultWarningStart: TimeInterval = 50

    var length: Double = 0
    var heat: Double = 0
    var hue: Double = 145

    static func recording(
        elapsed: TimeInterval,
        fullSession: Bool,
        warningStart: TimeInterval = defaultWarningStart
    ) -> Self {
        let clampedStart = min(sessionDuration, max(0, warningStart))
        let warningSpan = sessionDuration - clampedStart
        let warning: Double
        if warningSpan > 0 {
            warning = min(1, max(0, (elapsed - clampedStart) / warningSpan))
        } else {
            warning = elapsed >= sessionDuration ? 1 : 0
        }
        let progress = fullSession ? min(1, max(0, elapsed / sessionDuration)) : warning
        return Self(
            length: 1 - 0.6 * progress * progress * (3 - 2 * progress),
            heat: warning * warning,
            hue: 145 * (1 - min(1, warning / 0.7))
        )
    }

    func interpolated(to target: Self, progress: Double) -> Self {
        let amount = 1 - pow(1 - min(1, max(0, progress)), 3)
        return Self(
            length: length + (target.length - length) * amount,
            heat: heat + (target.heat - heat) * amount,
            hue: hue + (target.hue - hue) * amount
        )
    }
}

@MainActor
final class VoiceContinuationGlowController {
    private var pending: DispatchWorkItem?
    private var releaseTask: DispatchWorkItem?
    private var previewTask: DispatchWorkItem?
    private var timer: Timer?
    private var panel: NSPanel?
    private var view: VoiceContinuationGlowView?
    private var startedAt: TimeInterval = 0
    private var fullSession = false
    private var warningStart: TimeInterval = VoiceGlowState.defaultWarningStart
    private var isRecordingSessionActive = false
    private var generation: UInt64 = 0
    private var lastScreenCheck: TimeInterval = 0
    private let screenCheckInterval: TimeInterval = 1.0
    private var hasResolvedScreen = false
    private var trackedAppPID: pid_t?
    private var trackedScreenFrames: [CGRect] = []
    private var cachedWindowScreenIndex: Int?
    private var axQuerySucceededForTrackedApp = false
    private var width = 0.64
    private var intensity = 0.4
    private var frozen: VoiceGlowState?
    private var transitionFrom: VoiceGlowState?
    private var transitionStartedAt: TimeInterval = 0
    private let transitionDuration: TimeInterval = 0.9
    private var releaseDeadline: TimeInterval?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var frontmostAppPIDProvider: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    var screenFramesProvider: () -> [CGRect] = {
        NSScreen.screens.map(\.frame)
    }
    var mouseLocationProvider: () -> CGPoint = {
        NSEvent.mouseLocation
    }
    var focusedWindowFrameProvider: (pid_t) -> CGRect? = { pid in
        VoiceContinuationGlowController.queryFocusedWindowFrame(pid: pid)
    }

    func setAppearance(width: Double, intensity: Double) {
        self.width = width
        self.intensity = intensity
        view?.widthFraction = width
        view?.intensity = intensity
        view?.needsDisplay = true
    }

    func setWarningStart(_ warningStart: TimeInterval) {
        let clamped = min(VoiceGlowState.sessionDuration, max(0, warningStart))
        guard self.warningStart != clamped else { return }
        self.warningStart = clamped
        guard isRecordingSessionActive, releaseDeadline == nil, previewTask == nil else { return }
        let elapsed = max(0, now - startedAt)
        generation &+= 1
        let expectedGeneration = generation
        pending?.cancel()
        pending = nil
        if fullSession || elapsed >= clamped {
            show()
        } else {
            hide()
            scheduleShow(after: max(0, clamped - elapsed), generation: expectedGeneration)
        }
    }

    func start(
        elapsed: TimeInterval = 0,
        fullSession: Bool = false,
        warningStart: TimeInterval = VoiceGlowState.defaultWarningStart
    ) {
        let resumes = releaseDeadline.map { now < $0 } ?? false
        let previous = resumes ? currentState() : VoiceGlowState()
        generation &+= 1
        let expectedGeneration = generation
        pending?.cancel()
        pending = nil
        releaseTask?.cancel()
        releaseTask = nil
        releaseDeadline = nil
        previewTask?.cancel()
        previewTask = nil
        frozen = nil
        isRecordingSessionActive = true
        self.fullSession = fullSession
        self.warningStart = min(VoiceGlowState.sessionDuration, max(0, warningStart))
        startedAt = now - elapsed
        transitionFrom = fullSession ? previous : nil
        transitionStartedAt = now
        if fullSession || elapsed >= self.warningStart {
            show()
        } else {
            hide()
            scheduleShow(after: max(0, self.warningStart - elapsed), generation: expectedGeneration)
        }
        AppLogger.shared.write("VOICE GLOW start full_session=\(fullSession) resumed=\(resumes)")
    }

    private func scheduleShow(after delay: TimeInterval, generation expectedGeneration: UInt64) {
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.pending = nil
                self.show()
            }
        }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func release(delay: TimeInterval) {
        guard releaseDeadline == nil else { return }
        generation &+= 1
        let expectedGeneration = generation
        pending?.cancel()
        pending = nil
        frozen = currentState()
        transitionFrom = nil
        timer?.invalidate()
        timer = nil
        guard delay > 0 else { stop(); return }
        releaseDeadline = now + delay
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.stop()
            }
        }
        releaseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func finishIfWaiting() {
        if releaseDeadline != nil { stop() }
    }


    func preview(duration: TimeInterval = 3) {
        if previewTask == nil { start(elapsed: 0, fullSession: true) }
        previewTask?.cancel()
        let expectedGeneration = generation
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.stop()
            }
        }
        previewTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }

    var isVisible: Bool { panel != nil }

    func stop() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        releaseTask?.cancel()
        releaseTask = nil
        previewTask?.cancel()
        previewTask = nil
        releaseDeadline = nil
        isRecordingSessionActive = false
        frozen = nil
        transitionFrom = nil
        hide()
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        resetScreenTrackingCache()
    }

    private func resetScreenTrackingCache() {
        hasResolvedScreen = false
        trackedAppPID = nil
        trackedScreenFrames = []
        cachedWindowScreenIndex = nil
        axQuerySucceededForTrackedApp = false
    }

    private func currentState() -> VoiceGlowState {
        let target = frozen ?? .recording(
            elapsed: now - startedAt,
            fullSession: fullSession,
            warningStart: warningStart
        )
        guard let transitionFrom else { return target }
        let progress = (now - transitionStartedAt) / transitionDuration
        if progress >= 1 { self.transitionFrom = nil; return target }
        return transitionFrom.interpolated(to: target, progress: progress)
    }

    private func show() {
        if panel == nil {
            resetScreenTrackingCache()
            guard let screen = activeScreen() else { return }
            lastScreenCheck = now
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 230)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = VoiceContinuationGlowView(frame: NSRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            view.widthFraction = width
            view.intensity = intensity
            panel.contentView = view
            self.panel = panel
            self.view = view
            panel.orderFrontRegardless()
        }
        timer?.invalidate()
        update()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func resolveScreenIndex() -> Int? {
        let screens = screenFramesProvider()
        guard !screens.isEmpty else {
            resetScreenTrackingCache()
            return nil
        }
        let mouseLocation = mouseLocationProvider()
        let mouseScreenIndex = screens.firstIndex { $0.contains(mouseLocation) }
        let currentPID = frontmostAppPIDProvider()
        let appChanged = !hasResolvedScreen || currentPID != trackedAppPID
        let screensChanged = screens != trackedScreenFrames
        let shouldQueryWindow = appChanged || screensChanged || axQuerySucceededForTrackedApp

        hasResolvedScreen = true
        trackedAppPID = currentPID
        trackedScreenFrames = screens

        if shouldQueryWindow {
            if let currentPID, let windowFrame = focusedWindowFrameProvider(currentPID) {
                axQuerySucceededForTrackedApp = true
                cachedWindowScreenIndex = VoiceGlowScreenSelection.index(
                    window: windowFrame,
                    screens: screens
                )
            } else {
                axQuerySucceededForTrackedApp = false
                cachedWindowScreenIndex = nil
            }
        }

        if let cachedWindowScreenIndex, screens.indices.contains(cachedWindowScreenIndex) {
            return cachedWindowScreenIndex
        }
        return mouseScreenIndex ?? 0
    }

    private func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = resolveScreenIndex(), screens.indices.contains(index) else {
            return nil
        }
        return screens[index]
    }

    private static func queryFocusedWindowFrame(pid: pid_t) -> CGRect? {
        if AXSelfTargetPolicy.isOwnProcess(pid) {
            return (NSApp?.keyWindow ?? NSApp?.mainWindow)?.frame
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                &sizeValue
            ) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              let primary = NSScreen.screens.first
        else { return nil }
        return CGRect(
            x: position.x,
            y: primary.frame.maxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func update() {
        if now - lastScreenCheck >= screenCheckInterval {
            lastScreenCheck = now
            if let screen = activeScreen(), let panel {
                let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 230)
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            }
        }
        view?.state = currentState()
        view?.needsDisplay = true
    }
}

@MainActor
final class VoiceContinuationGlowView: NSView {
    /// 100%（1.0）对应的内部亮度倍率，10%（0.1）对应 0.5x，保证界面刻度始终在 10%–100% 内。
    static let maxIntensityGain: Double = 5.0

    var state = VoiceGlowState()
    var widthFraction = 0.64
    var intensity = 0.4


    private func color(hue: Double, saturation: Double, lightness: Double, alpha: Double) -> CGColor {
        let a = saturation * min(lightness, 1 - lightness)
        func channel(_ n: Double) -> CGFloat {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            return CGFloat(lightness - a * max(-1, min(k - 3, 9 - k, 1)))
        }
        return CGColor(
            red: channel(0),
            green: channel(8),
            blue: channel(4),
            alpha: CGFloat(min(1, alpha * intensity * Self.maxIntensityGain))
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        guard state.length > 0 else { return }
        let center = bounds.midX
        let span = max(2, bounds.width * widthFraction / 2 * state.length)
        let heat = state.heat
        let hue = state.hue
        let haloWidth = 9 + span
        let haloHeight = (65 + heat * 33) * min(1, state.length / 0.4)
        let space = CGColorSpaceCreateDeviceRGB()

        func wash(y: Double, width: Double, height: Double, alpha: Double) {
            let colors = [
                color(hue: hue, saturation: 0.95, lightness: 0.65, alpha: alpha),
                color(hue: hue, saturation: 0.95, lightness: 0.56, alpha: alpha * 0.7),
                color(hue: hue, saturation: 0.9, lightness: 0.5, alpha: alpha * 0.22),
                color(hue: hue, saturation: 0.9, lightness: 0.5, alpha: 0)
            ]
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.2, 0.52, 1]) else { return }
            context.saveGState()
            context.translateBy(x: center, y: y)
            context.scaleBy(x: width, y: height)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
        context.setBlendMode(.screen)
        wash(y: -4, width: haloWidth * 1.18, height: haloHeight, alpha: 0.12 + heat * 0.78)
        wash(y: 0, width: haloWidth * 0.7, height: haloHeight * 0.53, alpha: 0.2 + heat * 0.75)
        wash(y: 2, width: haloWidth * 0.48, height: 16 + heat * 20, alpha: heat * 0.85)

        let stops: [(CGFloat, Double, Double)] = [(0, 0, 65), (0.22, 0.13, 65), (0.4, 0.72, 74), (0.5, 1, 93), (0.6, 0.72, 74), (0.78, 0.13, 65), (1, 0, 65)]
        let colors = stops.map { _, alpha, lightness in
            color(hue: hue, saturation: 0.9, lightness: (lightness - 16 * (1 - heat)) / 100, alpha: alpha * (0.6 + heat * 0.4))
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map { $0.0 }) else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let thickness = 1.6 + heat * 1.4
        context.saveGState()
        context.clip(to: CGRect(x: center - span, y: 3 - thickness / 2, width: span * 2, height: thickness))
        context.drawLinearGradient(gradient, start: CGPoint(x: center - span, y: 3), end: CGPoint(x: center + span, y: 3), options: [])
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
