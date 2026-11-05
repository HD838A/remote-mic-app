import CoreBluetooth
import Foundation

/// One public G9N9N transport per host. Identity is proven through DIS before
/// subscribing to ATVV; a Google VID/PID or a Bluetooth name alone is insufficient.
final class G9N9NBluetoothBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((ChromecastLinkStatus) -> Void)?
    var onCapabilities: ((ChromecastDeclaredCapabilities) -> Void)?
    var onVoiceStart: (() -> Void)?
    var onVoiceStop: ((ChromecastVoiceEndReason) -> Void)?
    var onSamples: (([Int16], Int) -> Void)?
    var onLog: ((String) -> Void)?
    let hid = G9N9NHIDMonitor()
    private let voice = G9N9NVoiceSession()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var model: String?
    private var manufacturer: String?
    private var enabled = false
    private var admitted = false
    private var requestedCapabilities = false
    private var rejected = Set<UUID>()
    private var retry: Timer?
    private var extend: Timer?
    private var initializationTimeout: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    private var tail: DispatchWorkItem?
    private var status: ChromecastLinkStatus = .disabled {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private static let service = CBUUID(string: ATVVProtocol.serviceUUID)
    private static let dis = CBUUID(string: "180A")
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        voice.onWrite = { [weak self] in self?.write($0) }
        voice.onStart = { [weak self] in self?.onVoiceStart?() }
        voice.onStop = { [weak self] in self?.onVoiceStop?($0) }
        voice.onSamples = { [weak self] in self?.onSamples?($0, $1) }
        voice.onLog = { [weak self] in self?.onLog?($0) }
        hid.onLog = { [weak self] in self?.onLog?($0) }
    }

    deinit {
        retry?.invalidate()
        extend?.invalidate()
        initializationTimeout?.cancel()
        reconnectWork?.cancel()
        idle?.cancel()
        tail?.cancel()
        peripheral?.delegate = nil
        central?.delegate = nil
        central?.stopScan()
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        central = CBCentralManager(delegate: self, queue: .main)
        retry = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.hid.refreshAccess()
            if self.central?.state == .unauthorized,
               CBCentralManager.authorization == .allowedAlways {
                self.central?.delegate = nil
                self.central = CBCentralManager(delegate: self, queue: .main)
            } else { self.discover() }
        }
        extend = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            self?.voice.extend()
        }
    }

    func stop() {
        enabled = false
        reconnectWork?.cancel()
        reconnectWork = nil
        retry?.invalidate()
        extend?.invalidate()
        retry = nil
        extend = nil
        central?.stopScan()
        clearConnection()
        central?.delegate = nil
        central = nil
        status = .disabled
    }

    func reconnect() {
        // A cancelled link can deliver didDisconnect after connect on the same
        // peripheral. A fresh manager isolates that old callback from this retry.
        if enabled { stop() }
        rejected.removeAll()
        start()
    }

    func hostEnded() { voice.cancel(reason: "host_stop", now: now) }

    private func discover() {
        guard enabled, let central, central.state == .poweredOn, peripheral == nil else { return }
        status = .searching
        let candidates = central.retrieveConnectedPeripherals(withServices: [Self.service])
        if let candidate = candidates.first(where: { !rejected.contains($0.identifier) }) {
            connect(candidate)
        } else if !central.isScanning {
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func connect(_ candidate: CBPeripheral) {
        guard enabled, peripheral == nil, !rejected.contains(candidate.identifier) else { return }
        central?.stopScan()
        peripheral = candidate
        candidate.delegate = self
        status = .connecting
        central?.connect(candidate)
        let timeout = DispatchWorkItem { [weak self, weak candidate] in
            guard let self, self.peripheral === candidate else { return }
            self.onLog?("G9N9N LINK phase=failed reason=initialization_timeout")
            self.clearConnection()
            self.status = .disconnected
        }
        initializationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func clearConnection() {
        initializationTimeout?.cancel()
        initializationTimeout = nil
        tail?.cancel()
        tail = nil
        idle?.cancel()
        idle = nil
        // Deliver cancellation while the characteristic still belongs to this link.
        voice.reset(now: now)
        hid.stop()
        onCapabilities?([])
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        transmit = nil
        audio = nil
        control = nil
        model = nil
        manufacturer = nil
        admitted = false
        requestedCapabilities = false
    }

    private func verifyIdentity() {
        guard let peripheral, let model, let manufacturer, !admitted else { return }
        guard G9N9NVoiceSession.matches(model: model, manufacturer: manufacturer) else {
            if rejected.count < 64 { rejected.insert(peripheral.identifier) }
            onLog?("G9N9N IDENTITY phase=rejected reason=dis_mismatch")
            clearConnection()
            discover()
            return
        }
        admitted = true
        onLog?("G9N9N IDENTITY phase=accepted model=g9n9n")
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([
                CBUUID(string: ATVVProtocol.transmitUUID),
                CBUUID(string: ATVVProtocol.audioUUID),
                CBUUID(string: ATVVProtocol.controlUUID),
            ], for: service)
        }
    }

    private func negotiate() {
        guard admitted, transmit != nil, audio?.isNotifying == true,
              control?.isNotifying == true, !requestedCapabilities else { return }
        requestedCapabilities = true
        write(ATVVProtocol.getCapabilitiesV10)
    }

    private func armIdleTimeout() {
        idle?.cancel()
        guard voice.active, voice.stopDeadline == nil else { return }
        let generation = voice.generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.voice.active, self.voice.generation == generation else { return }
            self.voice.cancel(reason: "audio_timeout", now: self.now)
        }
        idle = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func write(_ data: Data) {
        guard admitted, let peripheral, let transmit else { return }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            onLog?("G9N9N WRITE phase=failed reason=backpressure")
            if data.first != 0x0D { voice.cancel(reason: "write_backpressure", now: now) }
            return
        }
        peripheral.writeValue(data, for: transmit, type: type)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, enabled else { return }
        switch central.state {
        case .poweredOn: discover()
        case .unauthorized: clearConnection(); status = .unauthorized
        default: clearConnection(); status = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        peripheral.discoverServices([Self.dis, Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(central, peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(central, peripheral)
    }

    private func disconnected(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        clearConnection()
        status = .disconnected
        reconnectWork?.cancel()
        let retry = DispatchWorkItem { [weak self, weak central] in
            guard let self, let central, self.enabled, self.central === central else { return }
            self.discover()
        }
        reconnectWork = retry
        // Recover an observed disconnect promptly; keep the 15s poll for sleeping
        // devices that have not reappeared, rather than making each voice press wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: retry)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, peripheral.services?.contains(where: { $0.uuid == Self.service }) == true,
              let dis = peripheral.services?.first(where: { $0.uuid == Self.dis }) else { return }
        peripheral.discoverCharacteristics([CBUUID(string: "2A24"), CBUUID(string: "2A29")], for: dis)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: "2A24"), CBUUID(string: "2A29"):
                peripheral.readValue(for: characteristic)
            case CBUUID(string: ATVVProtocol.transmitUUID): transmit = characteristic
            case CBUUID(string: ATVVProtocol.audioUUID):
                audio = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case CBUUID(string: ATVVProtocol.controlUUID):
                control = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
        negotiate()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if error != nil {
            onLog?("G9N9N LINK phase=failed reason=subscription_failed")
            clearConnection()
            status = .disconnected
        } else { negotiate() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, error != nil else { return }
        onLog?("G9N9N WRITE phase=failed reason=transport_error")
        clearConnection()
        status = .disconnected
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: "2A24"):
            model = String(data: data, encoding: .utf8)
            verifyIdentity()
        case CBUUID(string: "2A29"):
            manufacturer = String(data: data, encoding: .utf8)
            verifyIdentity()
        case CBUUID(string: ATVVProtocol.controlUUID):
            guard admitted else { return }
            if data.first == 0x0B {
                guard voice.capabilities == nil else { return }
                guard requestedCapabilities, voice.acceptCapabilities(data) else {
                    clearConnection()
                    status = .unsupported(reason: "invalid_capabilities")
                    return
                }
                initializationTimeout?.cancel()
                initializationTimeout = nil
                onCapabilities?([.voiceStream, .controlEdges])
                status = .connected(displayName: "G9N9N")
                hid.start()
            } else {
                voice.control(data, now: now)
                armIdleTimeout()
                if let deadline = voice.stopDeadline {
                    tail?.cancel()
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.voice.drain(now: self.now)
                    }
                    tail = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now), execute: item)
                }
            }
        case CBUUID(string: ATVVProtocol.audioUUID):
            guard admitted else { return }
            voice.audio(data, now: now)
            armIdleTimeout()
        default: break
        }
    }
}
