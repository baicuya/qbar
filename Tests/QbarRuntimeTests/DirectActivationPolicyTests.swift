import XCTest
import ApplicationServices
@testable import QbarRuntime

final class DirectActivationPolicyTests: XCTestCase {
    func testLeftClickPrefersPressRegardlessOfAvailableActionOrder() {
        for actions in [[kAXPressAction, kAXShowMenuAction], [kAXShowMenuAction, kAXPressAction]] {
            XCTAssertEqual(MenuBarDirectActivationPolicy.action(rightClick: false, available: actions), kAXPressAction)
        }
    }

    func testLeftClickUsesShowMenuOnlyWhenPressIsUnavailable() {
        XCTAssertEqual(MenuBarDirectActivationPolicy.action(rightClick: false, available: [kAXShowMenuAction]), kAXShowMenuAction)
        XCTAssertEqual(MenuBarDirectActivationPolicy.action(rightClick: false, available: [kAXPressAction]), kAXPressAction)
        XCTAssertNil(MenuBarDirectActivationPolicy.action(rightClick: false, available: []))
        XCTAssertNil(MenuBarDirectActivationPolicy.action(rightClick: false, available: [kAXConfirmAction]))
    }

    func testRightClickUsesOnlyShowMenu() {
        XCTAssertEqual(MenuBarDirectActivationPolicy.action(rightClick: true, available: [kAXPressAction, kAXShowMenuAction]), kAXShowMenuAction)
        XCTAssertEqual(MenuBarDirectActivationPolicy.action(rightClick: true, available: [kAXShowMenuAction]), kAXShowMenuAction)
        XCTAssertNil(MenuBarDirectActivationPolicy.action(rightClick: true, available: [kAXPressAction]))
        XCTAssertNil(MenuBarDirectActivationPolicy.action(rightClick: true, available: []))
    }

    func testSuccessfulOrUncertainAXResultNeverAllowsReplay() {
        let results: [AXError] = [
            .success, .failure, .illegalArgument, .invalidUIElement,
            .invalidUIElementObserver, .cannotComplete, .attributeUnsupported,
            .notificationUnsupported, .notificationAlreadyRegistered,
            .notificationNotRegistered, .apiDisabled, .noValue,
            .parameterizedAttributeUnsupported, .notEnoughPrecision,
        ]
        for result in results {
            XCTAssertFalse(MenuBarDirectActivationPolicy.mayFallback(after: result), "AX result \(result.rawValue) must not replay activation")
        }
    }

    func testOnlyDefiniteUnsupportedActionResultsAllowFallback() {
        XCTAssertTrue(MenuBarDirectActivationPolicy.mayFallback(after: .actionUnsupported))
        XCTAssertTrue(MenuBarDirectActivationPolicy.mayFallback(after: .notImplemented))
    }
}
