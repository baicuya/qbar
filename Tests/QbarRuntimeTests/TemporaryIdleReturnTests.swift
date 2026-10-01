import XCTest
import QbarCore
@testable import QbarRuntime

final class TemporaryIdleReturnTests: XCTestCase {
    func testTemporaryMoveOnlyChangesSelectedGroup() {
        XCTAssertTrue(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .hidden, 2: .hidden, 3: .alwaysHidden, 4: .visible],
            after: [1: .visible, 2: .hidden, 3: .alwaysHidden, 4: .visible], selectedWindowID: 1))
        XCTAssertTrue(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .visible, 2: .hidden], after: [1: .hidden, 2: .hidden], selectedWindowID: 1))
    }

    func testExposingAnotherHiddenItemIsRejected() {
        XCTAssertFalse(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .hidden, 2: .hidden], after: [1: .visible, 2: .visible], selectedWindowID: 1))
        XCTAssertFalse(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .visible, 2: .hidden], after: [1: .hidden, 2: .alwaysHidden], selectedWindowID: 1))
    }

    func testExitedOrNewItemsDoNotTriggerSiblingLayout() {
        XCTAssertFalse(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .hidden, 2: .hidden], after: [1: .visible, 3: .visible], selectedWindowID: 1))
        XCTAssertTrue(MenuBarTemporaryMovePolicy.preservesOtherGroups(
            before: [1: .hidden, 2: .hidden], after: [1: .visible, 2: .hidden, 3: .visible], selectedWindowID: 1))
    }

    func testNilLaunchDateUsesStableKernelBirthTime() {
        let first = MenuItemSnapshotCache.ProcessInstance.resolved(
            bundleID: "com.apple.controlcenter", launchDate: nil, birthSeconds: 1234, birthMicroseconds: 5678)
        let second = MenuItemSnapshotCache.ProcessInstance.resolved(
            bundleID: "com.apple.controlcenter", launchDate: nil, birthSeconds: 1234, birthMicroseconds: 5678)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        let replaced = MenuItemSnapshotCache.ProcessInstance.resolved(
            bundleID: "com.apple.controlcenter", launchDate: nil, birthSeconds: 1235, birthMicroseconds: 5678)
        XCTAssertNotEqual(first, replaced)
        XCTAssertNil(MenuItemSnapshotCache.ProcessInstance.resolved(
            bundleID: nil, launchDate: nil, birthSeconds: 0, birthMicroseconds: 0))
    }

    func testDefaultReturnsAfterTenSeconds() {
        XCTAssertTrue(Preferences().rehideTemporary)
        XCTAssertEqual(Preferences().temporaryDelay, 10)
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 9.99, inputIdle: 30, delay: 10, buttonDown: false))
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 30, inputIdle: 9.99, delay: 10, buttonDown: false))
        XCTAssertTrue(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 10, inputIdle: 10, delay: 10, buttonDown: false))
    }

    func testAnotherInputRestartsIdleCountdown() {
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 45, inputIdle: 0, delay: 10, buttonDown: false))
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 45, inputIdle: 7, delay: 10, buttonDown: false))
        XCTAssertTrue(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 55, inputIdle: 10, delay: 10, buttonDown: false))
    }

    func testHeldMouseButtonPreventsReturnDuringDragging() {
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 50, inputIdle: 20, delay: 10, buttonDown: true))
    }

    func testInvalidTimesNeverTriggerReturn() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: value, inputIdle: 10, delay: 10, buttonDown: false))
            XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 10, inputIdle: value, delay: 10, buttonDown: false))
            XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 10, inputIdle: 10, delay: value, buttonDown: false))
        }
    }

    func testConfiguredDelayIsRespected() {
        XCTAssertFalse(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 20, inputIdle: 20, delay: 30, buttonDown: false))
        XCTAssertTrue(MenuBarTemporaryIdlePolicy.shouldRestore(exposedFor: 30, inputIdle: 30, delay: 30, buttonDown: false))
    }
}
