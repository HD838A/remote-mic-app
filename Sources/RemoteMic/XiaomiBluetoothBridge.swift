import CoreBluetooth
import Foundation

enum BluetoothBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(LocalizedMessage)
    case scanning
    case connecting
    case discovering
    case ready(String)
    case reconnecting
    case failed(LocalizedMessage)

    var message: LocalizedMessage {
        switch self {
        case .stopped: return LocalizedMessage("common.status.stopped")
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return LocalizedMessage("connection.status.searching")
        case .connecting: return LocalizedMessage("connection.status.connecting")
        case .discovering: return LocalizedMessage("connection.status.initializing_voice")
        case .ready: return LocalizedMessage("connection.status.connected_to_device")
        case .reconnecting: return LocalizedMessage("connection.status.reconnecting")
        case .failed(let reason): return reason
        }
    }
}

protocol XiaomiBluetoothBridgeDelegate: AnyObject {
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didChange state: BluetoothBridgeState)
    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didIdentifyRemoteModel model: XiaomiRemoteModel)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdatePowerState state: RemotePowerState?)
}

private final class XiaomiPeripheralDelegateProxy: NSObject, CBPeripheralDelegate {
    let generation: UInt64
    weak var owner: XiaomiBluetoothBridge?

    init(generation: UInt64, owner: XiaomiBluetoothBridge) {
        self.generation = generation
        self.owner = owner
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.handleDiscoveredServices(
            peripheral: peripheral,
            generation: generation,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        owner?.handleDiscoveredCharacteristics(
            peripheral: peripheral,
            generation: generation,
            service: service,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleNotificationState(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleCharacteristicValue(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }
}

final class XiaomiBluetoothBridge: NSObject {
    private static let defaultCapabilities = ATVVCapabilities(
        version: 0x0100,
        codecs: 0x02,
        interaction: 0x03,
        frameSize: 120,
        selectedCodec: 0x02,
        sampleRate: 16_000
    )

    private let settings: AppSettings
    private weak var delegate: XiaomiBluetoothBridgeDelegate?
    private let targetIdentifier: UUID?
    private let excludedIdentifiers: () -> Set<UUID>
    private var central: CBCentralManager?
    private var centralGeneration: UInt64?
    private var peripheral: CBPeripheral?
    private var peripheralDelegateProxy: XiaomiPeripheralDelegateProxy?
    private var transmitCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var batteryStatusCharacteristic: CBCharacteristic?
    private var subscribedUUIDs = Set<CBUUID>()
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var initializationTimeoutWorkItem: DispatchWorkItem?
    private var capabilitiesRequested = false
    private var capabilitiesConfirmed = false
    private var requestedReconnectDelay: TimeInterval?
    private var reconnectPolicy = BluetoothReconnectPolicy()
    private var currentAttemptUsesCachedTarget = false
    private var generationCounter: UInt64 = 0
    private var lifecycle: BluetoothLifecyclePhase = .stopped
    private var shouldRun = false
    private var capabilities = XiaomiBluetoothBridge.defaultCapabilities
    private var decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private var pendingSync: (predictor: Int, stepIndex: Int)?
    private var streaming = false
    private var microphoneOpened = false
    private var cancelledMicrophoneOpenAt: Date?
    private var sessionID: UInt8 = 0
    private var lastStopAt: Date?

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let batteryLevelStatusUUID = CBUUID(string: "2BED")
    private let deviceInformationServiceUUID = CBUUID(string: "180A")
    private let modelNumberUUID = CBUUID(string: "2A24")

    var deviceIdentifier: UUID? {
        peripheral?.identifier ?? targetIdentifier
    }

    private(set) var state: BluetoothBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.bluetoothBridge(self, didChange: state)
        }
    }

    init(
        settings: AppSettings,
        delegate: XiaomiBluetoothBridgeDelegate,
        targetIdentifier: UUID? = nil,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] }
    ) {
        self.settings = settings
        self.delegate = delegate
        self.targetIdentifier = targetIdentifier
        self.excludedIdentifiers = excludedIdentifiers
        super.init()
    }

    func start() {
        shouldRun = true
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        beginConnectionCycle()
    }

    func stop() {
        shouldRun = false
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        central?.stopScan()
        closeMicrophoneIfNeeded()
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = nil
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
        } else {
            finishAttempt(reconnectAfter: nil)
        }
        resetSession()
        state = .stopped
    }

    func reconnectNow() {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        central?.stopScan()
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = 0.1
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            state = .reconnecting
            central.cancelPeripheralConnection(peripheral)
            return
        }
        finishAttempt(reconnectAfter: 0.1)
    }

    private func beginConnectionCycle() {
        guard shouldRun else { return }
        let existingCentral = central
        if existingCentral != nil {
            guard case .waitingReconnect = lifecycle else { return }
        }
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .scanning(generation)
        let manager: CBCentralManager
        if let existingCentral {
            manager = existingCentral
        } else {
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
            central = manager
        }
        centralGeneration = generation
        if manager.state == .poweredOn {
            discoverOrScan(using: manager, generation: generation)
        }
    }

    @discardableResult
    func requestMicrophoneOpen() -> Bool {
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                  phase: lifecycle,
                  generation: generation,
                  capabilitiesConfirmed: capabilitiesConfirmed,
                  sampleRate: capabilities.sampleRate
              ),
              !microphoneOpened,
              !streaming
        else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_rejected")
            return false
        }
        guard write(ATVVProtocol.microphoneOpen(
            version: capabilities.version,
            codec: capabilities.selectedCodec
        )) else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_write_failed")
            return false
        }
        cancelledMicrophoneOpenAt = nil
        microphoneOpened = true
        AppLogger.shared.write("ATVV MIC_OPEN host_request")
        return true
    }

    @discardableResult
    func requestMicrophoneExtend() -> Bool {
        guard microphoneOpened,
              streaming,
              let command = ATVVProtocol.microphoneExtend(
                  version: capabilities.version,
                  sessionID: sessionID
              ),
              write(command)
        else {
            AppLogger.shared.write("ATVV MIC_EXTEND rejected session=\(sessionID)")
            return false
        }
        AppLogger.shared.write("ATVV MIC_EXTEND request session=\(sessionID)")
        return true
    }

    @discardableResult
    func requestMicrophoneClose() -> Bool {
        guard microphoneOpened || streaming else { return true }
        let cancelledOpenAt = ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: microphoneOpened,
            streaming: streaming
        )
        let didWrite = write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: sessionID
        ))
        microphoneOpened = false
        cancelledMicrophoneOpenAt = cancelledOpenAt
        AppLogger.shared.write(
            "ATVV MIC_CLOSE request session=\(sessionID) written=\(didWrite)"
        )
        return didWrite
    }

    private func discoverOrScan(using central: CBCentralManager, generation: UInt64) {
        guard shouldRun,
              self.central === central,
              lifecycle == .scanning(generation),
              central.state == .poweredOn
        else { return }
        resetPeripheral()

        if reconnectPolicy.allowsCachedTargetRetrieval,
           let identifier = targetIdentifier,
           let saved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(
                saved,
                using: central,
                generation: generation,
                source: "target_identifier",
                usesCachedTarget: true
            )
            return
        }

        if targetIdentifier == nil,
           let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .first(where: { isCandidate($0) && !excludedIdentifiers().contains($0.identifier) }) {
            connect(connected, using: central, generation: generation, source: "connected_peripheral")
            return
        }

        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        AppLogger.shared.write("BLE SCANNING")
    }

    private func connect(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String,
        usesCachedTarget: Bool = false
    ) {
        guard shouldRun,
              self.central === central,
              peripheral == nil,
              lifecycle == .scanning(generation)
        else { return }
        central.stopScan()
        peripheral = candidate
        currentAttemptUsesCachedTarget = usesCachedTarget
        let proxy = XiaomiPeripheralDelegateProxy(generation: generation, owner: self)
        peripheralDelegateProxy = proxy
        candidate.delegate = proxy
        lifecycle = .connecting(generation)
        state = .connecting
        startConnectionTimeout(generation: generation)
        central.connect(candidate, options: nil)
        AppLogger.shared.write("BLE CONNECTING source=\(source) name=\(candidate.name ?? "unknown")")
    }

    private func isCandidate(_ candidate: CBPeripheral) -> Bool {
        XiaomiVoiceRemoteNameMatcher.matches(candidate.name)
    }

    private func resetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        peripheralDelegateProxy = nil
        requestedReconnectDelay = nil
        transmitCharacteristic = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        batteryCharacteristic = nil
        batteryStatusCharacteristic = nil
        subscribedUUIDs.removeAll()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        capabilitiesRequested = false
        capabilitiesConfirmed = false
        capabilities = Self.defaultCapabilities
        currentAttemptUsesCachedTarget = false
        resetSession()
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        guard let peripheral else { return false }
        return peripheral === candidate
    }

    private func currentGeneration() -> UInt64? {
        lifecycle.generation
    }

    private func startInitializationTimeout(generation: UInt64) {
        initializationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.currentGeneration() == generation,
                  self.lifecycle == .discovering(generation) ||
                    self.lifecycle == .awaitingCapabilities(generation)
            else { return }
            self.failInitialization(LocalizedMessage("connection.error.voice_service_timeout"))
        }
        initializationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func startConnectionTimeout(generation: UInt64) {
        connectionTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.currentGeneration() == generation,
                  self.lifecycle == .connecting(generation)
            else { return }
            AppLogger.shared.write("BLE CONNECT TIMEOUT")
            self.state = .reconnecting
            if let central = self.central,
               let peripheral = self.peripheral,
               peripheral.state != .disconnected {
                central.cancelPeripheralConnection(peripheral)
            }
            let delay = self.nextAutomaticReconnectDelay(
                bypassCachedTarget: self.currentAttemptUsesCachedTarget
            )
            self.finishAttempt(reconnectAfter: delay)
        }
        connectionTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resetSession() {
        if streaming {
            streaming = false
            delegate?.bluetoothBridgeDidStopVoice(self)
        }
        microphoneOpened = false
        cancelledMicrophoneOpenAt = nil
        sessionID = 0
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
    }

    private func scheduleReconnect(bypassCachedTarget: Bool = false) {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()
        state = .reconnecting
        let delay = nextAutomaticReconnectDelay(
            bypassCachedTarget: bypassCachedTarget || currentAttemptUsesCachedTarget
        )
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = delay
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        finishAttempt(reconnectAfter: delay)
    }

    private func nextAutomaticReconnectDelay(bypassCachedTarget: Bool) -> TimeInterval {
        let delay = reconnectPolicy.nextAutomaticDelay(
            bypassCachedTarget: bypassCachedTarget,
            jitterUnit: Double.random(in: 0 ... 1)
        )
        let cachedIdentifierBypassed = targetIdentifier != nil &&
            !reconnectPolicy.allowsCachedTargetRetrieval
        AppLogger.shared.write(
            "BLE RECONNECT scheduled failure_count=\(reconnectPolicy.consecutiveFailureCount) " +
                "delay_ms=\(Int((delay * 1_000).rounded())) " +
                "cached_identifier_bypassed=\(cachedIdentifierBypassed)"
        )
        return delay
    }

    private func finishAttempt(reconnectAfter delay: TimeInterval?) {
        let finishedGeneration = lifecycle.generation ?? generationCounter
        central?.stopScan()
        requestedReconnectDelay = nil
        resetPeripheral()

        guard shouldRun, let delay else {
            central?.delegate = nil
            central = nil
            centralGeneration = nil
            lifecycle = .stopped
            return
        }

        state = .reconnecting
        lifecycle = .waitingReconnect(finishedGeneration)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.lifecycle == .waitingReconnect(finishedGeneration)
            else { return }
            self.reconnectWorkItem = nil
            self.beginConnectionCycle()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        guard let peripheral, let transmitCharacteristic else { return false }
        let type: CBCharacteristicWriteType = transmitCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(data, for: transmitCharacteristic, type: type)
        return true
    }

    private func closeMicrophoneIfNeeded() {
        _ = requestMicrophoneClose()
    }

    private func requestCapabilitiesIfPossible() {
        guard let generation = currentGeneration(),
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        guard transmitCharacteristic != nil,
              let audioCharacteristic,
              let controlCharacteristic,
              subscribedUUIDs.contains(audioCharacteristic.uuid),
              subscribedUUIDs.contains(controlCharacteristic.uuid),
              let peripheral
        else { return }
        guard !capabilitiesRequested else { return }
        capabilitiesRequested = true
        write(ATVVProtocol.getCapabilitiesV10)
        lifecycle = .awaitingCapabilities(generation)
        state = .discovering
        AppLogger.shared.write("ATVV CAPABILITIES requested name=\(peripheral.name ?? "MI RC")")
    }

    private func handleControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first,
              let generation = currentGeneration()
        else { return }

        switch opcode {
        case 0x0B:
            guard lifecycle.acceptsCapabilities(generation: generation) else {
                AppLogger.shared.write("ATVV CAPS ignored_stale_phase")
                return
            }
            guard let parsed = ATVVCapabilities.parse(data) else {
                failInitialization(LocalizedMessage("connection.error.invalid_voice_response"))
                return
            }
            capabilities = parsed
            AppLogger.shared.write(
                "ATVV CAPS version=\(parsed.version) codec=\(parsed.selectedCodec) frame=\(parsed.frameSize)"
            )
            if !ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_16khz_codec"))
                return
            }
            capabilitiesConfirmed = true
            initializationTimeoutWorkItem?.cancel()
            initializationTimeoutWorkItem = nil
            reconnectPolicy.reset()
            currentAttemptUsesCachedTarget = false
            lifecycle = .ready(generation)
            if let peripheral {
                state = .ready(peripheral.name ?? "MI RC")
                AppLogger.shared.write("BLE READY name=\(peripheral.name ?? "MI RC")")
            }
        case 0x08:
            guard requestMicrophoneOpen() else {
                AppLogger.shared.write("ATVV MIC_OPEN remote_request_ignored")
                return
            }
            AppLogger.shared.write("ATVV MIC_OPEN remote_request")
        case 0x04:
            guard ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate
            ) else {
                AppLogger.shared.write("ATVV STREAM_START ignored_not_ready")
                return
            }
            if bytes.count >= 3 {
                let codec = bytes[2]
                capabilities = ATVVCapabilities(
                    version: capabilities.version,
                    codecs: capabilities.codecs,
                    interaction: bytes[1],
                    frameSize: capabilities.frameSize,
                    selectedCodec: codec,
                    sampleRate: codec == 0x02 ? 16_000 : 8_000
                )
            }
            guard ATVVProtocol.supportsAudio(sampleRate: capabilities.sampleRate) else {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_8khz_codec"))
                return
            }
            let receivedSessionID = bytes.count >= 4 ? bytes[3] : 0
            if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
                cancelledAt: cancelledMicrophoneOpenAt
            ) {
                write(ATVVProtocol.microphoneClose(
                    version: capabilities.version,
                    sessionID: receivedSessionID
                ))
                AppLogger.shared.write(
                    "ATVV STREAM_START ignored_cancelled session=\(receivedSessionID)"
                )
                return
            }
            cancelledMicrophoneOpenAt = nil
            sessionID = receivedSessionID
            startStreaming()
        case 0x00:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            stopStreaming()
        case 0x0A:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            guard bytes.count >= 7 else { return }
            let predictorBits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let predictor = Int(Int16(bitPattern: predictorBits))
            pendingSync = (predictor, Int(bytes[6]))
            let partialFrameBytes = accumulator.pending.count
            if partialFrameBytes > 0 {
                AppLogger.shared.write(
                    "ATVV FRAME discarded session=\(sessionID) reason=sync " +
                        "partial_frame_bytes=\(partialFrameBytes)"
                )
            }
            accumulator.reset()
        default:
            break
        }
    }

    private func startStreaming() {
        let partialFrameBytes = accumulator.pending.count
        if partialFrameBytes > 0 {
            AppLogger.shared.write(
                "ATVV FRAME discarded session=\(sessionID) reason=stream_start " +
                    "streaming_before=\(streaming) partial_frame_bytes=\(partialFrameBytes)"
            )
        }
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        lastStopAt = nil
        guard !streaming else { return }
        streaming = true
        delegate?.bluetoothBridgeDidStartVoice(self)
        AppLogger.shared.write("ATVV STREAM START session=\(sessionID)")
    }

    private func stopStreaming() {
        guard streaming else { return }
        streaming = false
        microphoneOpened = false
        let partialFrameBytes = accumulator.pending.count
        accumulator.reset()
        pendingSync = nil
        lastStopAt = Date()
        AppLogger.shared.write(
            "ATVV STREAM STOP session=\(sessionID) partial_frame_bytes=\(partialFrameBytes)"
        )
        delegate?.bluetoothBridgeDidStopVoice(self)
    }

    private func handleAudio(_ data: Data) {
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate
              )
        else {
            AppLogger.shared.write("ATVV AUDIO ignored_not_ready")
            return
        }
        if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledMicrophoneOpenAt
        ) {
            AppLogger.shared.write("ATVV AUDIO ignored_cancelled_open")
            return
        }
        cancelledMicrophoneOpenAt = nil
        if !streaming {
            let receivedAt = Date()
            if let lastStopAt, receivedAt.timeIntervalSince(lastStopAt) < 0.3 {
                let delayMilliseconds = max(
                    0,
                    Int((receivedAt.timeIntervalSince(lastStopAt) * 1_000).rounded())
                )
                AppLogger.shared.write(
                    "ATVV AUDIO ignored_after_stop session=\(sessionID) " +
                        "delay_ms=\(delayMilliseconds) bytes=\(data.count)"
                )
                return
            }
            startStreaming()
            AppLogger.shared.write("ATVV STREAM implicit_audio_race")
        }

        let frames = accumulator.append(data, frameSize: capabilities.frameSize)
        for frame in frames {
            if let pendingSync {
                decoder.reset(
                    predictor: pendingSync.predictor,
                    stepIndex: pendingSync.stepIndex
                )
                self.pendingSync = nil
            }
            let decoded = decoder.decode(frame)
            let samples = PCMPostprocessor.process(decoded, gainDB: settings.gainDB)
            delegate?.bluetoothBridge(self, didDecode: samples)
        }
    }

    private func rejectUnsupportedAudio(_ message: LocalizedMessage) {
        state = .failed(message)
        closeMicrophoneIfNeeded()
        if streaming {
            stopStreaming()
        } else {
            accumulator.reset()
            pendingSync = nil
            decoder.reset()
        }
        scheduleReconnect(bypassCachedTarget: true)
    }

    private func failInitialization(_ message: LocalizedMessage) {
        state = .failed(message)
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        scheduleReconnect(bypassCachedTarget: true)
    }
}

extension XiaomiBluetoothBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, let generation = centralGeneration else { return }
        switch central.state {
        case .poweredOn:
            applyCentralRecovery(
                .poweredOn,
                central: central,
                generation: generation
            )
        case .poweredOff:
            applyCentralRecovery(
                .poweredOff,
                central: central,
                generation: generation
            )
            resetPeripheral()
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.off"))
        case .unauthorized:
            resetSession()
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.permission_denied"))
        case .unsupported:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unsupported"))
        case .resetting:
            applyCentralRecovery(
                .resetting,
                central: central,
                generation: generation
            )
            resetPeripheral()
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.resetting"))
        case .unknown:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.initializing"))
        @unknown default:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unavailable"))
        }
    }

    private func applyCentralRecovery(
        _ event: BluetoothCentralRecoveryEvent,
        central: CBCentralManager,
        generation: UInt64
    ) {
        let transition = BluetoothCentralRecoveryPolicy.transition(
            from: lifecycle,
            generation: generation,
            event: event,
            shouldRun: shouldRun
        )
        if transition.shouldCancelScheduledReconnect {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
        }
        lifecycle = transition.phase
        if transition.shouldDiscover {
            discoverOrScan(using: central, generation: generation)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceMatch = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(serviceUUID) == true
        guard let generation = centralGeneration,
              lifecycle == .scanning(generation),
              self.peripheral == nil,
              !excludedIdentifiers().contains(peripheral.identifier),
              targetIdentifier == nil || peripheral.identifier == targetIdentifier,
              serviceMatch || isCandidate(peripheral) || XiaomiVoiceRemoteNameMatcher.matches(advertisedName)
        else { return }
        connect(peripheral, using: central, generation: generation, source: "scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        guard shouldRun else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidConnect(generation: generation)
        else { return }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        lifecycle = .discovering(generation)
        state = .discovering
        startInitializationTimeout(generation: generation)
        peripheral.discoverServices([
            serviceUUID,
            batteryServiceUUID,
            deviceInformationServiceUUID,
        ])
        AppLogger.shared.write("BLE CONNECTED name=\(peripheral.name ?? "unknown")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidFailToConnect(generation: generation)
        else { return }
        AppLogger.shared.write("BLE CONNECT FAILED error=\(error?.localizedDescription ?? "unknown")")
        let delay = shouldRun
            ? requestedReconnectDelay ?? nextAutomaticReconnectDelay(
                bypassCachedTarget: currentAttemptUsesCachedTarget
            )
            : nil
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    private func handleDisconnect(error: Error?) {
        let shouldBypassCachedTarget: Bool
        switch lifecycle {
        case .connecting, .discovering, .awaitingCapabilities:
            shouldBypassCachedTarget = true
        default:
            shouldBypassCachedTarget = false
        }
        AppLogger.shared.write(
            "BLE DISCONNECTED phase=\(lifecycle) error=\(error?.localizedDescription ?? "none")"
        )
        let delay = shouldRun
            ? requestedReconnectDelay ?? nextAutomaticReconnectDelay(
                bypassCachedTarget: shouldBypassCachedTarget || currentAttemptUsesCachedTarget
            )
            : nil
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }
}

extension XiaomiBluetoothBridge {
    fileprivate func handleDiscoveredServices(
        peripheral: CBPeripheral,
        generation: UInt64,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_service_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed(LocalizedMessage("connection.error.voice_service_missing"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
        if let batteryService = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics(
                [batteryLevelUUID, batteryLevelStatusUUID],
                for: batteryService
            )
        }
        if let deviceInformationService = peripheral.services?.first(where: {
            $0.uuid == deviceInformationServiceUUID
        }) {
            peripheral.discoverCharacteristics([modelNumberUUID], for: deviceInformationService)
        }
    }

    fileprivate func handleDiscoveredCharacteristics(
        peripheral: CBPeripheral,
        generation: UInt64,
        service: CBService,
        error: Error?
    ) {
        let isOptionalService = service.uuid == batteryServiceUUID ||
            service.uuid == deviceInformationServiceUUID
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              isOptionalService
                ? lifecycle.acceptsNotificationUpdate(generation: generation)
                : lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if service.uuid == batteryServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY characteristic_discovery_failed error=\(error.localizedDescription)"
                )
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            guard let characteristics = service.characteristics else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelUUID }) {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelStatusUUID }) {
                batteryStatusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            }
            return
        }
        if service.uuid == deviceInformationServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE MODEL characteristic_discovery_failed error=\(error.localizedDescription)"
                )
                return
            }
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == modelNumberUUID }) else {
                return
            }
            peripheral.readValue(for: characteristic)
            return
        }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case transmitUUID:
                transmitCharacteristic = characteristic
            case audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                continue
            }
        }
        guard transmitCharacteristic != nil,
              audioCharacteristic != nil,
              controlCharacteristic != nil
        else {
            state = .failed(LocalizedMessage("connection.error.voice_channel_incomplete"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleNotificationState(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsNotificationUpdate(generation: generation)
        else { return }
        let isOptionalCharacteristic = characteristic.uuid == batteryLevelUUID ||
            characteristic.uuid == batteryLevelStatusUUID
        if isOptionalCharacteristic {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY notification_failed uuid=\(characteristic.uuid.uuidString) " +
                        "error=\(error.localizedDescription)"
                )
            }
            return
        }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_subscription_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else {
            return
        }
        guard characteristic.isNotifying else {
            subscribedUUIDs.remove(characteristic.uuid)
            failInitialization(LocalizedMessage("connection.error.voice_channel_subscription_inactive"))
            return
        }
        subscribedUUIDs.insert(characteristic.uuid)
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleCharacteristicValue(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation
        else { return }
        if let error {
            if characteristic.uuid == batteryLevelUUID {
                AppLogger.shared.write("BLE BATTERY read_failed error=\(error.localizedDescription)")
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            } else if characteristic.uuid == batteryLevelStatusUUID {
                AppLogger.shared.write("BLE POWER read_failed error=\(error.localizedDescription)")
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            } else if characteristic.uuid == modelNumberUUID {
                AppLogger.shared.write("BLE MODEL read_failed error=\(error.localizedDescription)")
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == batteryLevelUUID {
            let level = data.first.map(Int.init)
            AppLogger.shared.write("BLE BATTERY level=\(level.map(String.init) ?? "unknown")")
            delegate?.bluetoothBridge(self, didUpdateBatteryLevel: level)
            return
        }
        if characteristic.uuid == batteryLevelStatusUUID {
            let powerState = RemotePowerState.decodeBatteryLevelStatus(data)
            AppLogger.shared.write("BLE POWER state=\(String(describing: powerState))")
            delegate?.bluetoothBridge(self, didUpdatePowerState: powerState)
            return
        }
        if characteristic.uuid == modelNumberUUID {
            guard let modelNumber = String(data: data, encoding: .utf8) else {
                AppLogger.shared.write("BLE MODEL unreadable")
                return
            }
            let normalizedModelNumber = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalizedModelNumber.contains("ARN9") {
                // ARN9 firmware encodes ADPCM low-nibble-first; flipping the
                // default high-first order is required for intelligible audio.
                decoder.lowNibbleFirst = true
                AppLogger.shared.write("BLE MODEL ARN9 adpcm=low-nibble-first")
            }
            guard let model = XiaomiRemoteModel.identified(by: modelNumber) else {
                AppLogger.shared.write("BLE MODEL unrecognized modelNumber=\(normalizedModelNumber)")
                return
            }
            AppLogger.shared.write("BLE MODEL identified=\(model.rawValue)")
            delegate?.bluetoothBridge(self, didIdentifyRemoteModel: model)
            return
        }
        if characteristic.uuid == controlUUID {
            guard lifecycle.acceptsCapabilities(generation: generation) ||
                    lifecycle.acceptsProtocolData(generation: generation)
            else { return }
            handleControl(data)
        } else if characteristic.uuid == audioUUID {
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleAudio(data)
        }
    }
}
