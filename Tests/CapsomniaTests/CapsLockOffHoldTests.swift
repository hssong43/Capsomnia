import XCTest
@testable import Capsomnia

final class CapsLockOffHoldTests: XCTestCase {
    func testShortInputSourcePressRestoresOnWithoutAcceptingOff() {
        var hold = CapsLockOffHold()
        XCTAssertEqual(hold.update(pressed: true, awake: true, now: 10), .none)
        XCTAssertTrue(hold.isProtectingAwake)
        XCTAssertEqual(hold.checkHold(now: 10.4), .none)
        XCTAssertTrue(hold.isProtectingAwake)
        XCTAssertEqual(hold.update(pressed: false, awake: true, now: 10.4), .restoreOn)
        XCTAssertFalse(hold.isProtectingAwake)
        XCTAssertEqual(hold.checkHold(now: 11), .none)
    }

    func testHeldKeyTurnsOffOnceAtThresholdWithoutWaitingForRelease() {
        var hold = CapsLockOffHold()
        _ = hold.update(pressed: true, awake: true, now: 0)
        XCTAssertEqual(hold.checkHold(now: 0.799), .none)
        XCTAssertEqual(hold.checkHold(now: 0.8), .turnOff)
        XCTAssertFalse(hold.isProtectingAwake)
        XCTAssertEqual(hold.checkHold(now: 5), .none)
        XCTAssertEqual(hold.update(pressed: false, awake: false, now: 5), .none)
    }

    func testLongReleaseIsAcceptedEvenWhenPollingHasNotRunYet() {
        var hold = CapsLockOffHold()
        _ = hold.update(pressed: true, awake: true, now: 0)
        XCTAssertEqual(hold.update(pressed: false, awake: true, now: 0.8), .turnOff)
        XCTAssertEqual(hold.update(pressed: false, awake: false, now: 1), .none)
    }

    func testStartingOffLeavesTheExistingNativeTurnOnAlone() {
        var hold = CapsLockOffHold()
        _ = hold.update(pressed: true, awake: false, now: 0)
        XCTAssertFalse(hold.isProtectingAwake)
        XCTAssertEqual(hold.checkHold(now: 2), .none)
        XCTAssertEqual(hold.update(pressed: false, awake: true, now: 2), .none)
    }

    func testRepeatedPressReportsDoNotRestartTheHoldOrChangeItsInitialState() {
        var hold = CapsLockOffHold()
        _ = hold.update(pressed: true, awake: true, now: 0)
        _ = hold.update(pressed: true, awake: false, now: 0.5)
        XCTAssertEqual(hold.checkHold(now: 0.8), .turnOff)
    }

    func testCancellationPreventsDelayedOffAfterAnExplicitActionOrWake() {
        var hold = CapsLockOffHold()
        _ = hold.update(pressed: true, awake: true, now: 0)
        hold.cancel()
        XCTAssertFalse(hold.isProtectingAwake)
        XCTAssertEqual(hold.checkHold(now: 2), .none)
        XCTAssertEqual(hold.update(pressed: false, awake: true, now: 2), .none)
        _ = hold.update(pressed: true, awake: true, now: 3)
        XCTAssertEqual(hold.update(pressed: false, awake: true, now: 3.1), .restoreOn)
    }

    func testSecondShortPressStaysProtectedUntilDelayedRestoresFinish() {
        var actions: [CapsLockOffHoldAction] = []
        var completions: [() -> Void] = []
        let controller = CapsLockOffHoldController { action, completion in
            actions.append(action)
            completions.append(completion)
        }
        controller.update(pressed: true, awake: true, now: 0)
        controller.update(pressed: false, awake: true, now: 0.1)
        XCTAssertTrue(controller.isRestoringOn)
        XCTAssertTrue(controller.isProtectingAwake)
        controller.update(pressed: true, awake: true, now: 0.12)
        controller.update(pressed: false, awake: true, now: 0.2)
        XCTAssertEqual(actions, [.restoreOn])
        XCTAssertTrue(controller.isProtectingAwake)
        completions.removeFirst()()
        XCTAssertEqual(actions, [.restoreOn, .restoreOn])
        XCTAssertTrue(controller.isProtectingAwake)
        completions.removeFirst()()
        XCTAssertFalse(controller.isRestoringOn)
        XCTAssertFalse(controller.isProtectingAwake)
    }

    func testHoldStartedDuringRestoreKeepsItsOwnThresholdAndQueuesOff() {
        var actions: [CapsLockOffHoldAction] = []
        var completions: [() -> Void] = []
        let controller = CapsLockOffHoldController { action, completion in
            actions.append(action)
            completions.append(completion)
        }
        controller.update(pressed: true, awake: true, now: 0)
        controller.update(pressed: false, awake: true, now: 0.1)
        controller.update(pressed: true, awake: true, now: 0.2)
        controller.poll(isPressed: true, now: 0.99)
        XCTAssertEqual(actions, [.restoreOn])
        controller.poll(isPressed: true, now: 1)
        XCTAssertEqual(actions, [.restoreOn])
        completions.removeFirst()()
        XCTAssertEqual(actions, [.restoreOn, .turnOff])
        completions.removeFirst()()
        controller.update(pressed: false, awake: false, now: 1.2)
        XCTAssertEqual(actions, [.restoreOn, .turnOff])
    }

    func testExplicitCancellationDiscardsAQueuedRestore() {
        var actions: [CapsLockOffHoldAction] = []
        var finish: (() -> Void)?
        let controller = CapsLockOffHoldController { action, completion in
            actions.append(action)
            finish = completion
        }
        controller.update(pressed: true, awake: true, now: 0)
        controller.update(pressed: false, awake: true, now: 0.1)
        controller.update(pressed: true, awake: true, now: 0.2)
        controller.update(pressed: false, awake: true, now: 0.3)
        controller.cancel()
        finish?()
        XCTAssertEqual(actions, [.restoreOn])
        XCTAssertFalse(controller.isProtectingAwake)
    }
}
