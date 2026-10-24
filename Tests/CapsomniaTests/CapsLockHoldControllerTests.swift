import XCTest
@testable import Capsomnia

final class CapsLockHoldControllerTests: XCTestCase {
    func testShortPressWhileOffNeverTurnsPowerOnWhenNativeCapsLockTurnsOn() {
        var requests: [Bool] = []
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { requests.append($0) }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.handle(pressed: true, now: 0)
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: true, now: 0.1)
        controller.handle(pressed: false, now: 0.2)
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: false, now: 0.3)
        XCTAssertEqual(requests, [])
        XCTAssertFalse(controller.requestedAwake)
        XCTAssertEqual(leds, [false])
    }

    func testShortPressWhileOnKeepsPowerOnEvenWhenLEDWriteFails() {
        var requests: [Bool] = []
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { requests.append($0) }) {
            target, completion in leds.append(target); completion(.verificationFailed(target: target, actual: false))
        }
        controller.handle(pressed: true, now: 0)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: true, now: 0.1)
        controller.handle(pressed: false, now: 0.2)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0.3)
        XCTAssertTrue(controller.requestedAwake)
        XCTAssertEqual(requests, [])
        XCTAssertEqual(leds, [true])
    }

    func testHeldPressTurnsOnOnceDespiteNativeOnOffOscillation() {
        var requests: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { requests.append($0) }) { _, _ in }
        controller.handle(pressed: true, now: 0)
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: true, now: 0.3)
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: true, now: 0.5)
        controller.poll(pressed: true, now: 0.799)
        XCTAssertEqual(requests, [])
        controller.poll(pressed: true, now: 0.8)
        controller.poll(pressed: true, now: 2)
        controller.handle(pressed: false, now: 2)
        XCTAssertEqual(requests, [true])
        XCTAssertTrue(controller.requestedAwake)
    }

    func testHeldPressTurnsOffOnceAndReleaseDoesNotTurnItBackOn() {
        var requests: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { requests.append($0) }) { _, _ in }
        controller.handle(pressed: true, now: 0)
        controller.poll(pressed: true, now: 0.8)
        controller.handle(pressed: false, now: 1)
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: false, now: 1.1)
        XCTAssertEqual(requests, [false])
        XCTAssertFalse(controller.requestedAwake)
    }

    func testReleaseAfterThresholdWorksWithoutAnInterveningPoll() {
        var requests: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { requests.append($0) }) { _, _ in }
        controller.handle(pressed: true, now: 0)
        controller.handle(pressed: false, now: 0.8)
        XCTAssertEqual(requests, [true])
    }

    func testRepeatedReportsDoNotRestartTheHold() {
        var requests: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { requests.append($0) }) { _, _ in }
        controller.handle(pressed: true, now: 0)
        controller.handle(pressed: true, now: 0.5)
        controller.poll(pressed: true, now: 0.8)
        XCTAssertEqual(requests, [true])
    }

    func testMissingReleaseAndExplicitOffCancelAnUnfinishedHold() {
        var requests: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { requests.append($0) }) { _, _ in }
        controller.handle(pressed: true, now: 0)
        controller.poll(pressed: false, now: 2)
        controller.handle(pressed: true, now: 3)
        controller.setRequested(false)
        controller.poll(pressed: true, now: 4)
        XCTAssertEqual(requests, [])
        XCTAssertFalse(controller.requestedAwake)
    }

    func testDelayedLEDCompletionCannotUndoANewerLongPress() throws {
        var requests: [Bool] = []
        var leds: [Bool] = []
        var completions: [(CapsLockToggleResult) -> Void] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { requests.append($0) }) {
            target, completion in leds.append(target); completions.append(completion)
        }
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0)
        XCTAssertEqual(leds, [true])
        controller.handle(pressed: true, now: 0.1)
        controller.poll(pressed: true, now: 0.9)
        controller.handle(pressed: false, now: 1)
        let finish = try XCTUnwrap(completions.first)
        finish(.changed(to: true))
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: false, now: 1.1)
        XCTAssertEqual(requests, [false])
        XCTAssertEqual(leds, [true, false])
        XCTAssertFalse(controller.requestedAwake)
    }

    func testLEDFailureRetriesWithoutIssuingAPowerCommand() {
        var requests: [Bool] = []
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { requests.append($0) }) {
            target, completion in leds.append(target); completion(.writeFailed(target: target))
        }
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0.25)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 1)
        XCTAssertEqual(leds, [true, true])
        XCTAssertEqual(requests, [])
        XCTAssertTrue(controller.requestedAwake)
    }

    func testLEDOutputShowsConfirmedAwakeWhileCapsModifierIsSuppressed() {
        var requests: [Bool] = []
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { requests.append($0) }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.synchronizeLED(physical: true, confirmedAwake: true, pressed: false, now: 0)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 1)
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 2)
        XCTAssertEqual(leds, [true, true, true])
        XCTAssertEqual(requests, [])
        XCTAssertTrue(controller.requestedAwake)
    }
    func testFailedPowerOnKeepsLEDOffDespiteRequestedOn() {
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.synchronizeLED(physical: true, confirmedAwake: false, pressed: false, now: 0)
        XCTAssertEqual(leds, [false])
        XCTAssertTrue(controller.requestedAwake)
    }

    func testFailedPowerOffKeepsLEDOnDespiteRequestedOff() {
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { _ in }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0)
        XCTAssertEqual(leds, [true])
        XCTAssertFalse(controller.requestedAwake)
    }

    func testUnknownPowerDoesNotPretendTheLEDTargetIsKnown() {
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) {
            target, _ in leds.append(target)
        }
        controller.synchronizeLED(physical: false, confirmedAwake: nil, pressed: false, now: 0)
        XCTAssertEqual(leds, [])
    }

    func testOldCLIOnCompletionCannotOverwriteNewMenuOff() {
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) { _, _ in }
        let revision = controller.requestRevision
        controller.setRequested(false)
        XCTAssertFalse(controller.completeRequest(true, revision: revision))
        XCTAssertFalse(controller.requestedAwake)
    }

    func testOldAutoOffCompletionCannotOverwriteNewOnRequest() {
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) { _, _ in }
        let revision = controller.requestRevision
        controller.setRequested(true)
        XCTAssertFalse(controller.completeRequest(false, revision: revision))
        XCTAssertTrue(controller.requestedAwake)
    }

    func testCurrentExplicitCompletionIsAccepted() {
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) { _, _ in }
        XCTAssertTrue(controller.completeRequest(false, revision: controller.requestRevision))
        XCTAssertFalse(controller.requestedAwake)
    }
    func testInitialCachedAgreementStillSendsAnExplicitLEDReport() {
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { _ in }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: false, now: 0)
        XCTAssertEqual(leds, [false])
    }

    func testShortReleaseForcesOutputEvenWhenTheLEDCacheAlreadyMatches() {
        var leds: [Bool] = []
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { _ in }) {
            target, completion in leds.append(target); completion(.changed(to: target))
        }
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: false, now: 0)
        controller.handle(pressed: true, now: 1.1)
        controller.handle(pressed: false, now: 1.2)
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: false, now: 1.3)
        XCTAssertEqual(leds, [false, false])
    }

    func testNativeChangeDuringADelayedWriteIsNotClearedByTheOldCompletion() throws {
        var leds: [Bool] = []
        var finish: ((CapsLockToggleResult) -> Void)?
        let controller = CapsLockHoldController(initialAwake: true, onRequest: { _ in }) {
            target, completion in leds.append(target); finish = completion
        }
        controller.synchronizeLED(physical: false, confirmedAwake: true, pressed: false, now: 0)
        controller.invalidateLED()
        try XCTUnwrap(finish)(.changed(to: true))
        controller.synchronizeLED(physical: true, confirmedAwake: true, pressed: false, now: 1.1)
        XCTAssertEqual(leds, [true, true])
        XCTAssertTrue(controller.requestedAwake)
    }
    func testFailedForcedWriteWithMatchingCacheRemainsAnErrorUntilSuccessfulOutput() {
        var attempts = 0
        let controller = CapsLockHoldController(initialAwake: false, onRequest: { _ in }) {
            target, completion in
            attempts += 1
            completion(attempts == 1 ? .writeFailed(target: target) : .changed(to: target))
        }
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: false, now: 0)
        XCTAssertTrue(controller.ledWriteFailed)
        controller.synchronizeLED(physical: false, confirmedAwake: false, pressed: false, now: 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(controller.ledWriteFailed)
    }
}
