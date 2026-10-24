import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Tracks key presses, not the Caps Lock LED or modifier state.
struct HIDCapsLockPressTracker {
    private var pressedDevices: Set<UInt64> = []
    var isPressed: Bool { !pressedDevices.isEmpty }

    mutating func handle(
        deviceID: UInt64,
        usagePage: UInt32,
        usage: UInt32,
        value: Int
    ) -> Bool {
        guard usagePage == 0x07, usage == 0x39 else { return false }
        switch value {
        case 1:
            return pressedDevices.insert(deviceID).inserted
        case 0:
            return pressedDevices.remove(deviceID) != nil
        default:
            return false
        }
    }

    mutating func removeDevice(_ deviceID: UInt64) {
        pressedDevices.remove(deviceID)
    }
}

/// Observes physical Caps input and writes its LED on the MacBook keyboard.
/// Raw long-press timing needs Input Monitoring; events are never consumed here.
final class HIDCapsLockMonitor {
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
    static var uptime: TimeInterval { Double(mach_absolute_time()) * secondsPerTick }
    enum State {
        case inactive, active, permissionRequired, unavailable
    }

    var onChange: (() -> Void)?
    private(set) var state: State = .inactive
    private var manager: IOHIDManager?
    private var tracker = HIDCapsLockPressTracker()
    private var devices: Set<UInt64> = []
    private(set) var lastEventTime: TimeInterval = 0

    var isActive: Bool { state == .active && !devices.isEmpty }
    var isPressed: Bool { isActive && tracker.isPressed }

    private var capsLockLEDOutputs: [IOHIDElement] {
        guard let manager, let keyboards = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return keyboards.filter(Self.isInternalKeyboard).flatMap { device in
            let matching = [kIOHIDElementUsagePageKey: 8, kIOHIDElementUsageKey: 2] as CFDictionary
            let elements = IOHIDDeviceCopyMatchingElements(device, matching, 0) as? [IOHIDElement] ?? []
            return elements.filter { IOHIDElementGetType($0) == kIOHIDElementTypeOutput }
        }
    }

    var capsLockLEDReportedState: Bool? {
        let elements = capsLockLEDOutputs
        guard !elements.isEmpty else { return nil }
        var states: Set<Bool> = []
        for element in elements {
            let reported: Bool? = withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { value in
                guard IOHIDDeviceGetValue(IOHIDElementGetDevice(element), element, value.baseAddress!) == kIOReturnSuccess else { return nil }
                return IOHIDValueGetIntegerValue(value[0].takeUnretainedValue()) != 0
            }
            guard let reported else {
                return nil
            }
            states.insert(reported)
        }
        return states.count == 1 ? states.first : nil
    }

    func setCapsLockLED(_ target: Bool) -> CapsLockToggleResult {
        let elements = capsLockLEDOutputs
        guard !elements.isEmpty else { return .unavailable }
        var succeeded = true
        for element in elements {
            let value = IOHIDValueCreateWithIntegerValue(
                kCFAllocatorDefault, element, mach_absolute_time(), target ? 1 : 0
            )
            if IOHIDDeviceSetValue(IOHIDElementGetDevice(element), element, value) != kIOReturnSuccess {
                succeeded = false
            }
        }
        guard succeeded else { return .writeFailed(target: target) }
        let reported = capsLockLEDReportedState
        return reported == target ? .changed(to: target) : .verificationFailed(target: target, actual: reported)
    }

    deinit { stop() }

    @discardableResult
    func start(promptForPermission: Bool = false) -> State {
        guard CGPreflightListenEventAccess()
                || (promptForPermission && CGRequestListenEventAccess()) else {
            stop()
            state = .permissionRequired
            return state
        }
        if manager != nil { return state }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 1,
            kIOHIDDeviceUsageKey: 6
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: 0x07,
            kIOHIDElementUsageKey: 0x39
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<HIDCapsLockMonitor>.fromOpaque(context).takeUnretainedValue()
                .handle(value)
        }, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<HIDCapsLockMonitor>.fromOpaque(context).takeUnretainedValue()
                .addDevice(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context, let id = HIDCapsLockMonitor.deviceID(device) else { return }
            let monitor = Unmanaged<HIDCapsLockMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.devices.remove(id)
            monitor.tracker.removeDevice(id)
        }, context)
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            stop()
            state = .unavailable
            return state
        }
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            devices.forEach(addDevice)
        }
        state = .active
        return state
    }

    func stop() {
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        devices.removeAll()
        tracker = HIDCapsLockPressTracker()
        state = .inactive
    }

    private func addDevice(_ device: IOHIDDevice) {
        guard Self.isInternalKeyboard(device), let id = Self.deviceID(device),
              let elements = IOHIDDeviceCopyMatchingElements(device, [
                kIOHIDElementUsagePageKey: 0x07,
                kIOHIDElementUsageKey: 0x39
              ] as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
              !elements.isEmpty else { return }
        devices.insert(id)
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let id = Self.deviceID(device), devices.contains(id) else { return }
        if tracker.handle(
            deviceID: id,
            usagePage: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            value: IOHIDValueGetIntegerValue(value)
        ) {
            let timestamp = Double(IOHIDValueGetTimeStamp(value)) * Self.secondsPerTick
            lastEventTime = timestamp > 0 ? min(timestamp, Self.uptime) : Self.uptime
            onChange?()
        }
    }

    private static func deviceID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS else {
            return nil
        }
        return id
    }

    private static func isInternalKeyboard(_ device: IOHIDDevice) -> Bool {
        (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .hasPrefix("Apple Internal Keyboard") == true
    }
}
