import CoreBluetooth
import Foundation

enum BluetoothBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(String)
    case scanning
    case connecting
    case discovering
    case ready(String)
    case reconnecting
    case failed(String)

    var displayText: String {
        switch self {
        case .stopped: return "已停止"
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return "正在寻找 MI RC"
        case .connecting: return "正在连接遥控器"
        case .discovering: return "正在初始化语音服务"
        case .ready(let name): return "已连接 \(name)"
        case .reconnecting: return "连接断开，准备重连"
        case .failed(let reason): return reason
        }
    }
}

protocol XiaomiBluetoothBridgeDelegate: AnyObject {
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didChange state: BluetoothBridgeState)
    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])
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
    private var central: CBCentralManager?
    private var centralGeneration: UInt64?
    private var peripheral: CBPeripheral?
    private var peripheralDelegateProxy: XiaomiPeripheralDelegateProxy?
    private var transmitCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var subscribedUUIDs = Set<CBUUID>()
    private var reconnectWorkItem: DispatchWorkItem?
    private var initializationTimeoutWorkItem: DispatchWorkItem?
    private var capabilitiesRequested = false
    private var capabilitiesConfirmed = false
    private var requestedReconnectDelay: TimeInterval?
    private var generationCounter: UInt64 = 0
    private var lifecycle: BluetoothLifecyclePhase = .stopped
    private var shouldRun = false
    private var capabilities = XiaomiBluetoothBridge.defaultCapabilities
    private var decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private var pendingSync: (predictor: Int, stepIndex: Int)?
    private var streaming = false
    private var microphoneOpened = false
    private var sessionID: UInt8 = 0
    private var lastStopAt: Date?

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)

    private(set) var state: BluetoothBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.bluetoothBridge(self, didChange: state)
        }
    }

    init(settings: AppSettings, delegate: XiaomiBluetoothBridgeDelegate) {
        self.settings = settings
        self.delegate = delegate
        super.init()
    }

    func start() {
        shouldRun = true
        reconnectWorkItem?.cancel()
        beginConnectionCycle()
    }

    func stop() {
        shouldRun = false
        reconnectWorkItem?.cancel()
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
        guard shouldRun, central == nil else { return }
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .scanning(generation)
        let manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        central = manager
        centralGeneration = generation
        if manager.state == .poweredOn {
            discoverOrScan(using: manager, generation: generation)
        }
    }

    private func discoverOrScan(using central: CBCentralManager, generation: UInt64) {
        guard shouldRun,
              self.central === central,
              lifecycle == .scanning(generation),
              central.state == .poweredOn
        else { return }
        resetPeripheral()

        if let identifier = settings.peripheralIdentifier,
           let saved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(saved, using: central, generation: generation)
            return
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .first(where: isCandidate) {
            connect(connected, using: central, generation: generation)
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
        generation: UInt64
    ) {
        guard shouldRun,
              self.central === central,
              peripheral == nil,
              lifecycle == .scanning(generation)
        else { return }
        central.stopScan()
        peripheral = candidate
        let proxy = XiaomiPeripheralDelegateProxy(generation: generation, owner: self)
        peripheralDelegateProxy = proxy
        candidate.delegate = proxy
        lifecycle = .connecting(generation)
        state = .connecting
        central.connect(candidate, options: nil)
        AppLogger.shared.write("BLE CONNECTING name=\(candidate.name ?? "unknown")")
    }

    private func isCandidate(_ candidate: CBPeripheral) -> Bool {
        RC003NameMatcher.matches(candidate.name)
    }

    private func resetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        peripheralDelegateProxy = nil
        transmitCharacteristic = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        subscribedUUIDs.removeAll()
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        capabilitiesRequested = false
        capabilitiesConfirmed = false
        capabilities = Self.defaultCapabilities
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
            self.failInitialization("ATVV 初始化超时")
        }
        initializationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resetSession() {
        if streaming {
            streaming = false
            delegate?.bluetoothBridgeDidStopVoice(self)
        }
        microphoneOpened = false
        sessionID = 0
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
    }

    private func scheduleReconnect(discardCachedIdentity: Bool = false) {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()
        state = .reconnecting
        if discardCachedIdentity {
            settings.peripheralIdentifier = nil
        }
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = 3
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        finishAttempt(reconnectAfter: 3)
    }

    private func finishAttempt(reconnectAfter delay: TimeInterval?) {
        let finishedGeneration = lifecycle.generation ?? generationCounter
        central?.stopScan()
        central?.delegate = nil
        central = nil
        centralGeneration = nil
        requestedReconnectDelay = nil
        resetPeripheral()

        guard shouldRun, let delay else {
            lifecycle = .stopped
            return
        }

        lifecycle = .waitingReconnect(finishedGeneration)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.central == nil,
                  self.lifecycle == .waitingReconnect(finishedGeneration)
            else { return }
            self.beginConnectionCycle()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func write(_ data: Data) {
        guard let peripheral, let transmitCharacteristic else { return }
        let type: CBCharacteristicWriteType = transmitCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(data, for: transmitCharacteristic, type: type)
    }

    private func closeMicrophoneIfNeeded() {
        guard microphoneOpened else { return }
        write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: sessionID
        ))
        microphoneOpened = false
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
                failInitialization("遥控器返回了无效的 ATVV 能力响应")
                return
            }
            capabilities = parsed
            AppLogger.shared.write(
                "ATVV CAPS version=\(parsed.version) codec=\(parsed.selectedCodec) frame=\(parsed.frameSize)"
            )
            if !ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) {
                rejectUnsupportedAudio("遥控器未提供受支持的 16 kHz 语音编码")
                return
            }
            capabilitiesConfirmed = true
            initializationTimeoutWorkItem?.cancel()
            initializationTimeoutWorkItem = nil
            lifecycle = .ready(generation)
            if let peripheral {
                settings.peripheralIdentifier = peripheral.identifier
                state = .ready(peripheral.name ?? "MI RC")
                AppLogger.shared.write("BLE READY name=\(peripheral.name ?? "MI RC")")
            }
        case 0x08:
            guard ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate
            ) else {
                AppLogger.shared.write("ATVV MIC_OPEN ignored_not_ready")
                return
            }
            write(ATVVProtocol.microphoneOpen(
                version: capabilities.version,
                codec: capabilities.selectedCodec
            ))
            microphoneOpened = true
            AppLogger.shared.write("ATVV MIC_OPEN request")
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
                rejectUnsupportedAudio("遥控器切换到了不受支持的 8 kHz 语音编码")
                return
            }
            sessionID = bytes.count >= 4 ? bytes[3] : 0
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
            accumulator.reset()
        default:
            break
        }
    }

    private func startStreaming() {
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
        accumulator.reset()
        pendingSync = nil
        lastStopAt = Date()
        delegate?.bluetoothBridgeDidStopVoice(self)
        AppLogger.shared.write("ATVV STREAM STOP session=\(sessionID)")
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
        if !streaming {
            if let lastStopAt, Date().timeIntervalSince(lastStopAt) < 0.3 {
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

    private func rejectUnsupportedAudio(_ message: String) {
        state = .failed(message)
        closeMicrophoneIfNeeded()
        if streaming {
            stopStreaming()
        } else {
            accumulator.reset()
            pendingSync = nil
            decoder.reset()
        }
        scheduleReconnect(discardCachedIdentity: true)
    }

    private func failInitialization(_ message: String) {
        state = .failed(message)
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        scheduleReconnect(discardCachedIdentity: true)
    }
}

extension XiaomiBluetoothBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, let generation = centralGeneration else { return }
        switch central.state {
        case .poweredOn:
            if shouldRun { discoverOrScan(using: central, generation: generation) }
        case .poweredOff:
            resetPeripheral()
            lifecycle = .scanning(generation)
            state = .bluetoothUnavailable("蓝牙已关闭")
        case .unauthorized:
            resetSession()
            state = .bluetoothUnavailable("未获得蓝牙权限")
        case .unsupported:
            state = .bluetoothUnavailable("此 Mac 不支持低功耗蓝牙")
        case .resetting:
            resetPeripheral()
            lifecycle = .scanning(generation)
            state = .bluetoothUnavailable("蓝牙正在重置")
        case .unknown:
            state = .bluetoothUnavailable("正在初始化蓝牙")
        @unknown default:
            state = .bluetoothUnavailable("蓝牙状态不可用")
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
              serviceMatch || isCandidate(peripheral) || RC003NameMatcher.matches(advertisedName)
        else { return }
        connect(peripheral, using: central, generation: generation)
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
        lifecycle = .discovering(generation)
        state = .discovering
        startInitializationTimeout(generation: generation)
        peripheral.discoverServices([serviceUUID])
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
        settings.peripheralIdentifier = nil
        let delay = shouldRun ? (requestedReconnectDelay ?? 3) : nil
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
        AppLogger.shared.write("BLE DISCONNECTED error=\(error?.localizedDescription ?? "none")")
        let delay = shouldRun ? (requestedReconnectDelay ?? 3) : nil
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
            state = .failed("发现语音服务失败：\(error.localizedDescription)")
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed("遥控器未提供 ATVV 语音服务")
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
    }

    fileprivate func handleDiscoveredCharacteristics(
        peripheral: CBPeripheral,
        generation: UInt64,
        service: CBService,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if let error {
            state = .failed("发现语音通道失败：\(error.localizedDescription)")
            scheduleReconnect(discardCachedIdentity: true)
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
            state = .failed("ATVV 通道不完整")
            scheduleReconnect(discardCachedIdentity: true)
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
        if let error {
            state = .failed("订阅语音通道失败：\(error.localizedDescription)")
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else {
            return
        }
        guard characteristic.isNotifying else {
            subscribedUUIDs.remove(characteristic.uuid)
            failInitialization("ATVV 通知订阅未生效")
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
        guard error == nil, let data = characteristic.value else { return }
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
