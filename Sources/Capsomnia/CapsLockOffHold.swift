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

final class CapsLockOffHoldController {
    typealias Apply = (CapsLockOffHoldAction, @escaping () -> Void) -> Void
    private var hold = CapsLockOffHold()
    private let apply: Apply
    private var activeAction = CapsLockOffHoldAction.none
    private var pendingAction = CapsLockOffHoldAction.none
    private var cancelled = false

    init(apply: @escaping Apply) { self.apply = apply }
    var isProtectingAwake: Bool {
        !cancelled && (hold.isProtectingAwake || activeAction == .restoreOn || pendingAction == .restoreOn)
    }
    var isRestoringOn: Bool { !cancelled && activeAction == .restoreOn }

    func update(pressed: Bool, awake: Bool, now: TimeInterval) {
        cancelled = false
        request(hold.update(pressed: pressed, awake: awake, now: now))
    }

    func poll(isPressed: Bool, now: TimeInterval) {
        if hold.isProtectingAwake, !isPressed {
            hold.cancel()
            request(.restoreOn)
        } else {
            request(hold.checkHold(now: now))
        }
    }

    func request(_ action: CapsLockOffHoldAction) {
        guard action != .none else { return }
        cancelled = false
        guard activeAction == .none else {
            pendingAction = action
            return
        }
        activeAction = action
        apply(action) { [weak self] in
            guard let self else { return }
            self.activeAction = .none
            let next = self.pendingAction
            self.pendingAction = .none
            if !self.cancelled { self.request(next) }
        }
    }

    func cancel() {
        hold.cancel()
        pendingAction = .none
        cancelled = true
    }
}
