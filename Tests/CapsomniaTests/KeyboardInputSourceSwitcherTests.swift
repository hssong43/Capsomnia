import XCTest
@testable import Capsomnia
final class KeyboardInputSourceSwitcherTests: XCTestCase {
    func testABCAndTwoSetAlternateWithoutChangingOtherSources() {
        let enabled: Set<String> = ["com.apple.keylayout.ABC", "com.apple.inputmethod.Korean.2SetKorean"]
        XCTAssertEqual(KeyboardInputSourcePair.next(current: "com.apple.keylayout.ABC", enabled: enabled), "com.apple.inputmethod.Korean.2SetKorean")
        XCTAssertEqual(KeyboardInputSourcePair.next(current: "com.apple.inputmethod.Korean.2SetKorean", enabled: enabled), "com.apple.keylayout.ABC")
        XCTAssertNil(KeyboardInputSourcePair.next(current: "other.input", enabled: enabled))
    }
    func testMissingSourceFailsWithoutSelectingAnUnrelatedLayout() {
        XCTAssertNil(KeyboardInputSourcePair.next(current: "com.apple.keylayout.ABC", enabled: ["com.apple.keylayout.ABC"]))
    }
}
