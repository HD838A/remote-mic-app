import Foundation
import IOKit.hid
import IOKit.hidsystem

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { monitor.deviceDidMatch(result: result, device: device) }
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { monitor.deviceDidRemove(device: device) }
}

private func hidInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
    let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
    let data = Data(bytes: report, count: reportLength)
    DispatchQueue.main.async {
        monitor.handleReport(reportID: reportID, data: data)
    }
}

final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let eventSuppressor = KeyboardEventSuppressor()
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var repeatTimers: [UInt16: DispatchSourceTimer] = [:]
    private var permissionMonitor: DispatchSourceTimer?
    private(set) var status = "按键映射未启用"
    var onStatus: ((String) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    static var isInputMonitoringGranted: Bool {
        inputMonitoringAccess == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        stop()
        guard settings.customMappingEnabled else {
            updateStatus("按键由 macOS 原生处理")
            return
        }
        let inputGranted = Self.isInputMonitoringGranted
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            mappingEnabled: settings.customMappingEnabled,
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted
        ) else {
            if !inputGranted {
                updateStatus("需要输入监控权限；未读取遥控器按键")
            } else {
                updateStatus("需要辅助功能权限；未发送映射动作")
            }
            return
        }

        let suppressionReady = eventSuppressor.start()
        AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: 0x2717,
            kIOHIDProductIDKey as String: 0x32B8,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, hidInputReport, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            eventSuppressor.stop()
            updateStatus("无法读取遥控器（错误 \(result)）")
            return
        }
        self.manager = manager
        startPermissionMonitor()
        updateStatus("等待 RC003 按键设备")
        AppLogger.shared.write("HID START mode=adaptive")
    }

    func stop() {
        permissionMonitor?.cancel()
        permissionMonitor = nil
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        activeUsages.removeAll()
        eventSuppressor.stop()
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            activeDeviceIsSeized = false
        }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            updateStatus("RC003 HID 打开失败")
            return
        }
        guard activeDevice == nil else { return }
        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        if seizeResult == kIOReturnSuccess {
            activeDevice = device
            activeDeviceIsSeized = true
            updateStatus("RC003 按键映射已连接（独占模式）")
            AppLogger.shared.write("HID CONNECTED mode=seized")
            return
        }

        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            updateStatus("无法读取 RC003（错误 \(monitorResult)）")
            AppLogger.shared.write(
                "HID DEVICE OPEN FAILED seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return
        }

        activeDevice = device
        activeDeviceIsSeized = false
        let suffix = eventSuppressor.isRunning ? "兼容模式" : "兼容模式；系统原动作可能保留"
        updateStatus("RC003 按键映射已连接（\(suffix)）")
        AppLogger.shared.write("HID CONNECTED mode=monitored seize_error=\(seizeResult)")
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        self.activeDevice = nil
        activeDeviceIsSeized = false
        activeUsages.removeAll()
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        updateStatus("RC003 按键设备已断开")
        AppLogger.shared.write("HID DISCONNECTED")
    }

    fileprivate func handleReport(reportID: UInt32, data: Data) {
        guard manager != nil, settings.customMappingEnabled else { return }
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return
        }
        guard let usages = RemoteHIDReportParser.usages(reportID: reportID, data: data) else {
            return
        }
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        activeUsages = usages

        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            let action = settings.action(for: button)
            if !activeDeviceIsSeized {
                eventSuppressor.arm(button: button, edge: .down)
            }
            if !KeyboardInjector.send(action) {
                stop()
                updateStatus("辅助功能权限已失效；已释放遥控器")
                return
            }
            startRepeatIfNeeded(usage: usage, button: button, action: action)
            AppLogger.shared.write("HID BUTTON down=\(button.rawValue) action=\(action.rawValue)")
        }

        for usage in released {
            if !activeDeviceIsSeized, let button = RemoteButton.usageMap[usage] {
                eventSuppressor.arm(button: button, edge: .up)
            }
            repeatTimers.removeValue(forKey: usage)?.cancel()
        }
    }

    private func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction
    ) {
        let repeatable: Set<RemoteButton> = [
            .up, .down, .left, .right, .back, .volumeUp, .volumeDown,
        ]
        guard repeatable.contains(button), action != .disabled else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval: DispatchTimeInterval = button == .back ? .milliseconds(50) : .milliseconds(100)
        timer.schedule(deadline: .now() + .milliseconds(350), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeUsages.contains(usage) else { return }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            if !self.activeDeviceIsSeized {
                self.eventSuppressor.arm(button: button, edge: .down)
            }
            if !KeyboardInjector.send(action) {
                self.releaseForRevokedPermissions()
            }
        }
        repeatTimers[usage] = timer
        timer.resume()
    }

    private func runtimePermissionsAreValid() -> Bool {
        Self.inputMonitoringAccess == kIOHIDAccessTypeGranted &&
            KeyboardInjector.isAccessibilityTrusted
    }

    private func startPermissionMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.manager != nil else { return }
            if !self.runtimePermissionsAreValid() {
                self.releaseForRevokedPermissions()
            }
        }
        permissionMonitor = timer
        timer.resume()
    }

    private func releaseForRevokedPermissions() {
        stop()
        updateStatus("系统权限已失效；已释放遥控器")
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    private func updateStatus(_ value: String) {
        status = value
        onStatus?(value)
    }
}
