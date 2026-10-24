import Foundation

enum CapsLockOffHoldAction: Equatable {
    case none, restoreOn, turnOff
}

struct CapsLockOffHold {
    static let minimumDuration: TimeInterval = 0.8
    private var pressedAt: TimeInterval?
    private(set) var isProtectingAwake = false

    mutating func update(pressed: Bool, awake: Bool, now: TimeInterval) -> CapsLockOffHoldAction {
        if pressed {
            if pressedAt == nil {
                pressedAt = now
                isProtectingAwake = awake
            }
            return .none
        }

        guard let pressedAt else { return .none }
        defer { cancel() }
        guard isProtectingAwake else { return .none }
        return now - pressedAt >= Self.minimumDuration ? .turnOff : .restoreOn
    }

    mutating func checkHold(now: TimeInterval) -> CapsLockOffHoldAction {
        guard isProtectingAwake, let pressedAt,
              now - pressedAt >= Self.minimumDuration else { return .none }
        isProtectingAwake = false
        return .turnOff
    }

    mutating func cancel() {
        pressedAt = nil
        isProtectingAwake = false
    }
}
