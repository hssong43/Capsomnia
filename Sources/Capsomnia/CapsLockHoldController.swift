import Foundation

final class CapsLockHoldController {
    static let minimumDuration: TimeInterval = 0.8
    typealias SetLED = (Bool, @escaping (CapsLockToggleResult) -> Void) -> Void
    private(set) var requestedAwake: Bool
    private(set) var requestRevision: UInt64 = 0
    private(set) var isSynchronizingLED = false
    private(set) var ledWriteFailed = false
    private let onRequest: (Bool) -> Void
    private let setLED: SetLED
    private var pressedAt: TimeInterval?
    private var awakeAtPress = false
    private var didToggle = false
    private var nextLEDAttemptAt: TimeInterval = 0
    private var ledRevision: UInt64 = 0
    private var ledNeedsWrite = true
    private(set) var lastHoldDuration: TimeInterval?

    init(initialAwake: Bool, onRequest: @escaping (Bool) -> Void, setLED: @escaping SetLED) {
        requestedAwake = initialAwake
        self.onRequest = onRequest
        self.setLED = setLED
    }

    func handle(pressed: Bool, now: TimeInterval) {
        if pressed {
            if pressedAt == nil {
                pressedAt = now
                awakeAtPress = requestedAwake
                didToggle = false
            }
        } else {
            evaluateHold(now: now)
            cancelPress()
            invalidateLED()
        }
    }

    func poll(pressed: Bool, now: TimeInterval) {
        if pressed { evaluateHold(now: now) } else { cancelPress() }
    }

    private func evaluateHold(now: TimeInterval) {
        guard let pressedAt, !didToggle, now - pressedAt >= Self.minimumDuration else { return }
        didToggle = true
        lastHoldDuration = now - pressedAt
        setRequested(!awakeAtPress, preservePress: true)
        onRequest(requestedAwake)
    }

    func cancelPress() {
        pressedAt = nil
        didToggle = false
    }

    func setRequested(_ awake: Bool, preservePress: Bool = false) {
        if !preservePress { cancelPress() }
        requestedAwake = awake
        requestRevision &+= 1
        invalidateLED()
    }

    func completeRequest(_ awake: Bool, revision: UInt64) -> Bool {
        guard requestRevision == revision else { return false }
        setRequested(awake)
        return true
    }

    func invalidateLED() {
        ledRevision &+= 1
        ledNeedsWrite = true
        nextLEDAttemptAt = 0
    }

    func synchronizeLED(physical: Bool?, confirmedAwake: Bool?, pressed: Bool, now: TimeInterval) {
        guard let target = confirmedAwake else { return }
        guard !pressed, !isSynchronizingLED, ledNeedsWrite || physical != target, now >= nextLEDAttemptAt else { return }
        isSynchronizingLED = true
        nextLEDAttemptAt = now + 1
        let revision = ledRevision
        // A native input-source transition or failed LED write cannot change power intent.
        setLED(target) { [weak self] result in
            guard let self else { return }
            self.isSynchronizingLED = false
            if self.ledRevision == revision {
                self.ledWriteFailed = result != .changed(to: target)
                self.ledNeedsWrite = self.ledWriteFailed
            }
        }
    }
}
