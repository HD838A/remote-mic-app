import CoreBluetooth
import Darwin
import Foundation
import ObjectiveC

/// One compatibility boundary for an undocumented macOS option. Never modifies
/// pairing, global Bluetooth power, device flags or system preferences.
/// The callback confirms this central's disconnection, not a physical-link guarantee.
protocol RemoteSleepConnectionTransport: AnyObject {
    func isolate(_ identifier: UUID, completion: @escaping (Bool) -> Void)
    func cancelPendingIsolation()
    func restore()
}

final class RemoteSleepConnectionAdapter: NSObject, CBCentralManagerDelegate, RemoteSleepConnectionTransport {
    static var isSupported: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2),
              "CBCancelPeripheralConnectionOptionDoNotAutoConnectBuiltInServices") != nil &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CBCancelPeripheralConnectionOptionForce") != nil &&
        CBCentralManager.instancesRespond(to: NSSelectorFromString("cancelPeripheralConnection:options:"))
    }

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var identifier: UUID?
    private var completion: ((Bool) -> Void)?
    private var isolationRequested = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func isolate(_ identifier: UUID, completion: @escaping (Bool) -> Void) {
        // A new request cannot silently replace another device's operation.
        guard self.identifier == nil, Self.isSupported else { completion(false); return }
        self.identifier = identifier
        self.completion = completion
        isolationRequested = true
        beginIfReady()
    }

    private func beginIfReady() {
        guard isolationRequested, completion != nil, target == nil,
              let identifier, central.state == .poweredOn else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            finish(false)
            return
        }
        target = peripheral
        // Required to own a connection before cancelling its built-in services.
        central.connect(peripheral, options: nil)
    }

    func cancelPendingIsolation() {
        isolationRequested = false
        completion = nil
        if let target { central.cancelPeripheralConnection(target) }
    }

    func restore() {
        isolationRequested = false
        completion = nil
        // Relinquish our session. The application's existing bridge owns recovery.
        if let target { central.cancelPeripheralConnection(target) }
        target = nil
        identifier = nil
    }

    private func finish(_ success: Bool) {
        let callback = completion
        completion = nil
        callback?(success)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting { finish(false) }
            return
        }
        beginIfReady()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === target, isolationRequested else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // Late/spontaneous connects must be cancelled too. Never start a new
        // connection cycle merely because a controller-state callback arrived.
        let selector = NSSelectorFromString("cancelPeripheralConnection:options:")
        guard let method = class_getInstanceMethod(CBCentralManager.self, selector),
              let denySymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                  "CBCancelPeripheralConnectionOptionDoNotAutoConnectBuiltInServices"),
              let forceSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                  "CBCancelPeripheralConnectionOptionForce") else { finish(false); return }
        let deny = denySymbol.assumingMemoryBound(to: NSString.self).pointee
        let force = forceSymbol.assumingMemoryBound(to: NSString.self).pointee
        typealias Cancel = @convention(c) (AnyObject, Selector, CBPeripheral, NSDictionary) -> Void
        let cancel = unsafeBitCast(method_getImplementation(method), to: Cancel.self)
        cancel(central, selector, peripheral, [deny: true, force: true])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === target, isolationRequested else { return }
        finish(error == nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === target else { return }
        finish(false)
    }
}
