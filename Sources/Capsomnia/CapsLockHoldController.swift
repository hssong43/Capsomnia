import Foundation

final class CapsLockHoldController {
    static let minimumDuration: TimeInterval = 0.8
    typealias SetLED = (Bool, @escaping (CapsLockToggleResult) -> Void) -> Void
    private(set) var requestedAwake: Bool
    private(set) var requestRevision: UInt64 = 0
    private(set) var isSynchronizingLED = false
    private let onRequest: (Bool) -> Void
    private let setLED: SetLED
    private var pressedAt: TimeInterval?
    private var awakeAtPress = false
    private var didToggle = false
    private var nextLEDAttemptAt: TimeInterval = 0
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
        nextLEDAttemptAt = 0
    }

    func completeRequest(_ awake: Bool, revision: UInt64) -> Bool {
        guard requestRevision == revision else { return false }
        setRequested(awake)
        return true
    }

    func synchronizeLED(physical: Bool?, confirmedAwake: Bool?, pressed: Bool, secureOverride: Bool, now: TimeInterval) {
        let target: Bool
        if secureOverride {
            target = false
        } else if let confirmedAwake {
            target = confirmedAwake
        } else {
            return
        }
        guard !pressed, !isSynchronizingLED, physical != target, now >= nextLEDAttemptAt else { return }
        isSynchronizingLED = true
        nextLEDAttemptAt = now + 1
        // A native input-source transition or failed LED write cannot change power intent.
        setLED(target) { [weak self] _ in
            self?.isSynchronizingLED = false
        }
    }
}
