import Foundation

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)")
    }
}

let versionOne = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78]))
check(
    versionOne?.version == 0x0100 &&
        versionOne?.selectedCodec == 0x02 &&
        versionOne?.sampleRate == 16_000 &&
        versionOne?.frameSize == 120,
    "ATVV v1 capabilities"
)

let legacyLayout = ATVVCapabilities.parse(
    Data([0x0B, 0x01, 0x00, 0x00, 0x02, 0x00, 0x78, 0x00, 0x00])
)
check(
    legacyLayout?.selectedCodec == 0x02 && legacyLayout?.interaction == 0x03,
    "ATVV legacy codec layout"
)
check(
    ATVVCapabilities.parse(Data()) == nil &&
        ATVVCapabilities.parse(Data([0x0B, 0x01])) == nil &&
        ATVVCapabilities.parse(Data([0x00, 1, 0, 2, 3, 0, 120])) == nil,
    "ATVV malformed capabilities"
)
check(
    ATVVProtocol.microphoneOpen(version: 0x0100, codec: 2) == Data([0x0C, 0x00]) &&
        ATVVProtocol.microphoneOpen(version: 1, codec: 2) == Data([0x0C, 0x00, 0x02]) &&
        ATVVProtocol.microphoneClose(version: 0x0100, sessionID: 7) == Data([0x0D, 0x07]) &&
        ATVVProtocol.microphoneClose(version: 1, sessionID: 7) == Data([0x0D]) &&
        ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 7) == Data([0x0E, 0x07]) &&
        ATVVProtocol.microphoneExtend(version: 1, sessionID: 7) == nil,
    "ATVV microphone commands"
)
check(
    ATVVProtocol.supportsAudio(sampleRate: 16_000) &&
        !ATVVProtocol.supportsAudio(sampleRate: 8_000),
    "ATVV audio rate gate"
)

check(
    XiaomiVoiceRemoteNameMatcher.matches("MI RC") &&
        XiaomiVoiceRemoteNameMatcher.matches("mi rc") &&
        XiaomiVoiceRemoteNameMatcher.matches("  MI RC  ") &&
        XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2") &&
        XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2") &&
        XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro") &&
        XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2 pro") &&
        XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙语音遥控器") &&
        XiaomiVoiceRemoteNameMatcher.matches(" 小米蓝牙语音遥控器 "),
    "Xiaomi voice remote matcher accepts approved candidate names"
)
check(
    !XiaomiVoiceRemoteNameMatcher.matches(nil) &&
        !XiaomiVoiceRemoteNameMatcher.matches("") &&
        !XiaomiVoiceRemoteNameMatcher.matches("   ") &&
        !XiaomiVoiceRemoteNameMatcher.matches("Mi Mouse") &&
        !XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙遥控器") &&
        !XiaomiVoiceRemoteNameMatcher.matches("MI RC2") &&
        !XiaomiVoiceRemoteNameMatcher.matches("小米"),
    "Xiaomi voice remote matcher rejects blank, nil, and similar non-target names"
)

let generationOne: UInt64 = 1
let generationTwo: UInt64 = 2
let connecting = BluetoothLifecyclePhase.connecting(generationOne)
let discovering = BluetoothLifecyclePhase.discovering(generationOne)
let awaiting = BluetoothLifecyclePhase.awaitingCapabilities(generationOne)
let ready = BluetoothLifecyclePhase.ready(generationOne)
let disconnecting = BluetoothLifecyclePhase.disconnecting(generationOne)
check(
    connecting.acceptsDidConnect(generation: generationOne) &&
        connecting.acceptsDidFailToConnect(generation: generationOne) &&
        connecting.acceptsDisconnect(generation: generationOne) &&
        !connecting.acceptsDisconnect(generation: generationTwo) &&
        !connecting.acceptsDidConnect(generation: generationTwo) &&
        disconnecting.acceptsDidFailToConnect(generation: generationOne),
    "Bluetooth generation and connect phase"
)
check(
    discovering.acceptsInitializationCallback(generation: generationOne) &&
        !discovering.acceptsCapabilities(generation: generationOne) &&
        awaiting.acceptsCapabilities(generation: generationOne) &&
        !awaiting.acceptsProtocolData(generation: generationOne) &&
        ready.acceptsProtocolData(generation: generationOne) &&
        !ready.acceptsProtocolData(generation: generationTwo) &&
        disconnecting.acceptsDisconnect(generation: generationOne),
    "Bluetooth lifecycle callback gates"
)
check(
    !ATVVSessionGate.canOpenMicrophone(
        phase: awaiting,
        generation: generationOne,
        capabilitiesConfirmed: true,
        sampleRate: 16_000
    ) &&
        !ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ) &&
        !ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ) &&
        ATVVSessionGate.canOpenMicrophone(
            phase: ready,
            generation: generationOne,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ),
    "ATVV READY microphone hard gate"
)
let cancelledOpenTime = Date(timeIntervalSince1970: 1_000)
check(
    ATVVSessionGate.cancelledOpenDate(
        microphoneOpened: false,
        streaming: false,
        now: cancelledOpenTime
    ) == nil &&
        ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledOpenTime,
            now: cancelledOpenTime.addingTimeInterval(1)
        ) &&
        !ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledOpenTime,
            now: cancelledOpenTime.addingTimeInterval(2)
        ),
    "ATVV cancelled host-open suppression window"
)

let decoder = IMAADPCMDecoder()
check(decoder.decode(Data([0x11])) == [1, 2], "ADPCM nibble order")
decoder.reset()
check(decoder.decode(Data([0x7F])) == [11, -19], "ADPCM signed decode")
decoder.reset(predictor: 100_000, stepIndex: 1_000)
check(decoder.predictor == 32_767 && decoder.stepIndex == 88, "ADPCM state clamping")

check(
    PCMPostprocessor.process([0, 1000, 0], gainDB: 0) == [0, 500, 0] &&
        PCMPostprocessor.process([20_000], gainDB: 24) == [Int16.max] &&
        PCMPostprocessor.process([20_000], gainDB: .infinity) == [20_000],
    "PCM smoothing and gain clamp"
)

var accumulator = FrameAccumulator()
let partial = accumulator.append(Data([1, 2]), frameSize: 3)
let frames = accumulator.append(Data([3, 4, 5, 6, 7]), frameSize: 3)
check(
    partial.isEmpty &&
        frames == [Data([1, 2, 3]), Data([4, 5, 6])] &&
        accumulator.pending == Data([7]),
    "frame accumulation"
)

check(
    RemoteHIDReportParser.usages(
        reportID: 1,
        data: Data([0xF1, 0x00, 0x80, 0x00, 0x00, 0x00])
    ) == Set([UInt16(0xF1), UInt16(0x80)]),
    "RC003 raw HID report"
)
check(
    RemoteHIDReportParser.usages(
        reportID: 1,
        data: Data([0x01, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00])
    ) == Set([UInt16(0x35)]),
    "RC003 included report ID"
)
check(
    RemoteHIDReportParser.usages(reportID: 2, data: Data([0, 0])) == nil &&
        RemoteHIDReportParser.usages(reportID: 1, data: Data()) == nil &&
        RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil,
    "RC003 malformed report rejection"
)
check(
    Set(RemoteButton.usageMap.values).allSatisfy {
        AppSettings.defaultBindings[$0] != nil
    },
    "all known buttons have defaults"
)
check(
    RemoteButton.usageMap == [
        0x28: .ok,
        0x35: .tv,
        0x4A: .home,
        0x4F: .right,
        0x50: .left,
        0x51: .down,
        0x52: .up,
        0x65: .menu,
        0x66: .power,
        0x80: .volumeUp,
        0x81: .volumeDown,
        0xF1: .back,
    ],
    "verified RC003 usage table"
)
check(
    RemoteButton.up.nativeEvent == .keyboard(keyCode: 126) &&
        RemoteButton.ok.nativeEvent == .keyboard(keyCode: 36) &&
        // Real RC003 hardware emits keyCode 10 (ISO §) for the TV key.
        RemoteButton.tv.nativeEvent == .keyboard(keyCode: 10) &&
        RemoteButton.power.nativeEvent == .keyboard(keyCode: 90) &&
        RemoteButton.volumeUp.nativeEvent == .systemKey(type: 0) &&
        RemoteButton.back.nativeEvent == nil,
    "native duplicate-event descriptors"
)
check(
    !HIDPermissionGate.canMonitor(
        mappingEnabled: true,
        inputMonitoringGranted: false,
        accessibilityGranted: true,
        powerKeySuppressed: true
    ) &&
        !HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false,
            powerKeySuppressed: true
        ) &&
        !HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            powerKeySuppressed: false
        ) &&
        HIDPermissionGate.canMonitor(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            powerKeySuppressed: true
        ),
    "HID permission gate fails closed"
)

let unrelatedKeyMapping = HIDUsageMapping(
    source: 0x0000_0007_0000_0004,
    destination: 0x0000_0007_0000_0005
)
check(
    RemoteVoiceFunctionMappingPolicy.applying(
        to: [unrelatedKeyMapping],
        powerMapping: RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
    ) == [
        unrelatedKeyMapping,
        RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
        RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey,
    ],
    "RC003 power is remapped to harmless F20"
)

check(
    HIDPermissionGate.nextPermissionRequest(
        mappingEnabled: false,
        inputMonitoringGranted: false,
        accessibilityGranted: false
    ) == .none &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .inputMonitoring &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ) == .accessibility &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ) == .none &&
        HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            voiceFnTapModeEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .accessibility,
    "HID permission requests are sequential and opt-in"
)

var voiceFunctionKeyLatch = VoiceFunctionKeyLatch()
let firstVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
let duplicateVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
let firstVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
let duplicateVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
check(
    firstVoicePress == .press &&
        duplicateVoicePress == nil &&
        firstVoiceRelease == .release &&
        duplicateVoiceRelease == nil &&
        !voiceFunctionKeyLatch.isHeld,
    "voice Fn latch emits one press and one release"
)

let failedVoicePress = voiceFunctionKeyLatch.transition(streaming: true)
if let failedVoicePress {
    voiceFunctionKeyLatch.rollback(failedVoicePress)
}
let voicePressForFailedRelease = voiceFunctionKeyLatch.transition(streaming: true)
let failedVoiceRelease = voiceFunctionKeyLatch.transition(streaming: false)
if let failedVoiceRelease {
    voiceFunctionKeyLatch.rollback(failedVoiceRelease)
}
check(
    failedVoicePress == .press &&
        voicePressForFailedRelease == .press &&
        failedVoiceRelease == .release &&
        voiceFunctionKeyLatch.isHeld,
    "voice Fn latch rolls back failed injection"
)
_ = voiceFunctionKeyLatch.transition(streaming: false)

let unrelatedMapping = HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 0x0000_0007_0000_0005)
let staleVoiceMapping = HIDUsageMapping(
    source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
    destination: 0x0000_0007_0000_00E1
)
let hardwareVoiceMappings = RemoteVoiceFunctionMappingPolicy.applying(
    to: [unrelatedMapping, staleVoiceMapping]
)
check(
    hardwareVoiceMappings == [
        unrelatedMapping,
        RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
    ],
    "RC003 hardware voice mapping replaces only F5 and preserves unrelated mappings"
)
check(
    RemoteVoiceFunctionMappingPolicy.applying(to: hardwareVoiceMappings) == hardwareVoiceMappings,
    "RC003 hardware voice mapping is idempotent"
)
check(
    RemoteVoiceFunctionMappingPolicy.applying(
        to: [unrelatedMapping],
        voiceMapping: RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
    ) == [
        unrelatedMapping,
        RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
    ],
    "RC003 neutralized voice key drops the F5 event for tap-style voice tools"
)
var transactionalFirstMappings = [unrelatedMapping]
var transactionalFirstWrites = 0
let transactionalMapper = RemoteVoiceFunctionMapper {
    [
        RemoteVoiceMappingService(
            registryID: 1,
            readMappings: { transactionalFirstMappings },
            setMappings: { mappings in
                transactionalFirstWrites += 1
                transactionalFirstMappings = mappings
                return true
            }
        ),
        RemoteVoiceMappingService(
            registryID: 2,
            readMappings: { [unrelatedMapping] },
            setMappings: { _ in false }
        ),
    ]
}
check(
    !transactionalMapper.apply(neutralizeVoiceKey: true) &&
        !transactionalMapper.isVoiceKeyNeutralized &&
        transactionalFirstMappings == [unrelatedMapping] &&
        transactionalFirstWrites == 2,
    "RC003 neutralization rolls back partial HID mapping success"
)
let changedUnrelatedMapping = HIDUsageMapping(
    source: unrelatedMapping.source,
    destination: 0x0000_0007_0000_0006
)
check(
    RemoteVoiceFunctionMappingPolicy.restoring(
        originalVoiceMapping: staleVoiceMapping,
        originalPowerMapping: nil,
        in: [changedUnrelatedMapping, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
    ) == [changedUnrelatedMapping, staleVoiceMapping] &&
        RemoteVoiceFunctionMappingPolicy.restoring(
            originalVoiceMapping: nil,
            originalPowerMapping: nil,
            in: [changedUnrelatedMapping, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey]
        ) == [changedUnrelatedMapping],
    "RC003 hardware voice mapping restore preserves unrelated runtime changes"
)
check(
    HIDUsageMapping(property: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.property) ==
        RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
    "RC003 hardware voice mapping property round-trips"
)

check(
    TestToneGenerator.samples(sampleRate: 16_000).count == 16_000 &&
        TestToneGenerator.samples(sampleRate: 8_000).count == 8_000 &&
        TestToneGenerator.samples(sampleRate: 0).isEmpty &&
        TestToneGenerator.samples(sampleRate: -1).isEmpty,
    "test tone sample count follows duration and sample rate"
)
check(
    TestToneGenerator.duration >= 0.8 && TestToneGenerator.duration <= 1.2,
    "test tone duration stays close to 1 second"
)
check(
    TestToneGenerator.frequency >= 200 && TestToneGenerator.frequency <= 2_000,
    "test tone frequency stays in an audible mid-range"
)
check(
    TestToneGenerator.amplitude > 0 && TestToneGenerator.amplitude <= 0.2,
    "test tone amplitude stays low volume"
)
let toneSamples = TestToneGenerator.samples(sampleRate: 16_000)
let toneLimit = Int((Double(Int16.max) * TestToneGenerator.amplitude).rounded()) + 1
check(
    toneSamples.allSatisfy { abs(Int($0)) <= toneLimit },
    "test tone samples never exceed the low-volume safety limit"
)
check(
    !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: false) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: true, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: false, isPlaying: true) &&
        !TestToneGate.canPlay(hasSelectedDevice: false, isStreaming: true, isPlaying: true) &&
        TestToneGate.canPlay(hasSelectedDevice: true, isStreaming: false, isPlaying: false),
    "test tone safety gate rejects missing device, active RC003 voice stream, or in-flight playback"
)

let suiteName = "RemoteMicSelfTest.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: suiteName) {
    let saved = try JSONEncoder().encode([
        RemoteButton.back.rawValue: ButtonAction.disabled,
    ])
    defaults.set(saved, forKey: "buttonBindings")
    defaults.set(true, forKey: "exclusiveHID")
    let settings = AppSettings(defaults: defaults)
    check(
        settings.action(for: .back) == .disabled &&
            settings.action(for: .up) == .arrowUp &&
            settings.action(for: .power) == .escape &&
            !settings.experimentalContinuousRecordingEnabled &&
            settings.customMappingEnabled,
        "saved bindings and legacy mapping toggle migrate"
    )
    settings.setExperimentalContinuousRecordingEnabled(true)
    check(
        !settings.experimentalContinuousRecordingEnabled &&
            settings.action(for: .power) == .escape &&
            settings.customMappingEnabled,
        "unavailable continuous recording experiment cannot replace power binding"
    )
    defaults.removePersistentDomain(forName: suiteName)
} else {
    check(false, "saved bindings merge with defaults")
}

var fnTapScheduledOperations: [() -> Void] = []
var fnTapEvents: [Bool] = []
var fnTapAudio: [[Int16]] = []
var fnTapDrainCompletion: (() -> Void)?
let fnTapController = VoiceFnTapSessionController(
    schedule: { _, operation in
        fnTapScheduledOperations.append(operation)
        return VoiceFnTapScheduledTask {}
    },
    setFunctionKeyPressed: { pressed in
        fnTapEvents.append(pressed)
        return true
    },
    enqueueAudio: { fnTapAudio.append($0) },
    drainAudio: { fnTapDrainCompletion = $0 },
    onFailure: { _ in }
)
fnTapController.setEnabled(true)
let fnTapStarted = fnTapController.startVoice()
let fnTapBuffered = fnTapController.receive([1, 2, 3])
let preRollStayedBuffered = fnTapAudio.isEmpty
fnTapScheduledOperations.removeFirst()()
fnTapScheduledOperations.removeFirst()()
let preRollFlushedAfterStart = fnTapAudio == [[1, 2, 3]]
let fnTapStopped = fnTapController.stopVoice()
let stopWaitedForDrain = fnTapEvents == [true, false]
fnTapDrainCompletion?()
fnTapScheduledOperations.removeFirst()()
check(
    fnTapStarted && fnTapBuffered && preRollStayedBuffered && preRollFlushedAfterStart &&
        fnTapStopped && stopWaitedForDrain && fnTapEvents == [true, false, true, false] &&
        fnTapController.phase == .idle,
    "Typeless Fn tap session buffers pre-roll and stops after drain"
)

print("RESULT passed=\(passed) failed=\(failed)")
if failed > 0 {
    exit(1)
}
