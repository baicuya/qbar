import XCTest
import AppKit
import QbarCore
@testable import QbarRuntime

final class EnginePlacementTests: XCTestCase {
    private let always = CGRect(x: 100, y: 0, width: 32, height: 39)
    private let hidden = CGRect(x: 250, y: 0, width: 32, height: 39)

    func testStaleAXFrameCannotProveVisiblePlacementWithoutAHost() {
        let stale = CGRect(x: 300, y: -1, width: 22, height: 24)
        let unrelated = MenuBarPhysicalMember(windowID: 2, frame: stale, isMovable: true)
        XCTAssertNil(MenuBarPlacementPolicy.section(
            windowID: nil, frame: stale, liveMembers: [unrelated], always: always, hidden: hidden
        ))
        XCTAssertNil(MenuBarPlacementPolicy.section(
            windowID: 1, frame: stale, liveMembers: [unrelated], always: always, hidden: hidden
        ))
    }

    func testFrameCrossingDividerIsNotAssignedToEitherLane() {
        let crossing = CGRect(x: 235, y: 0, width: 35, height: 39)
        let member = MenuBarPhysicalMember(windowID: 1, frame: crossing, isMovable: true)
        XCTAssertNil(MenuBarPlacementPolicy.section(
            windowID: 1, frame: crossing, liveMembers: [member], always: always, hidden: hidden
        ))
    }

    func testExactHostedGeometryProvesEachGroupWithoutMainAnchor() {
        for (x, expected) in [(50.0, ItemSection.alwaysHidden), (150.0, .hidden), (300.0, .visible)] {
            let frame = CGRect(x: x, y: 0, width: 30, height: 39)
            let member = MenuBarPhysicalMember(windowID: 1, frame: frame, isMovable: true)
            XCTAssertEqual(MenuBarPlacementPolicy.section(
                windowID: 1, frame: frame, liveMembers: [member], always: always, hidden: hidden
            ), expected)
        }
    }

    func testOldHostedFrameCannotProvePlacementAfterReflow() {
        let old = CGRect(x: 300, y: 0, width: 30, height: 39)
        let current = MenuBarPhysicalMember(windowID: 1, frame: CGRect(x: 200, y: 0, width: 30, height: 39), isMovable: true)
        XCTAssertNil(MenuBarPlacementPolicy.section(
            windowID: 1, frame: old, liveMembers: [current], always: always, hidden: hidden
        ))
    }

    func testAggregatePlanMovesHiddenFirstAndInsertsVisibleInReverseOrder() {
        let rules: [ItemRule] = [
            .init(id: "visible-first", name: "A", bundleID: "a", section: .visible, order: 0),
            .init(id: "hidden-second", name: "B", bundleID: "b", section: .hidden, order: 1),
            .init(id: "visible-last", name: "C", bundleID: "c", section: .visible, order: 2),
            .init(id: "always", name: "D", bundleID: "d", section: .alwaysHidden, order: 0),
            .init(id: "hidden-first", name: "E", bundleID: "e", section: .hidden, order: 0),
        ]
        let plan = MenuBarLayoutPolicy.orderedRules(rules, mode: .aggregate)
        XCTAssertEqual(plan.map(\.id), ["always", "hidden-first", "hidden-second", "visible-last", "visible-first"])
        XCTAssertEqual(Set(plan.map(\.id)), Set(rules.map(\.id)))
        XCTAssertEqual(rules[0].section, .visible)
        XCTAssertEqual(MenuBarLayoutPolicy.orderedRules(rules, mode: .inline).suffix(2).map(\.id), ["visible-first", "visible-last"])
    }

    func testUnrelatedOrAlreadyOpenPopupDoesNotProveNativeClickSucceeded() {
        let existing = MenuBarActivationWindow(id: 1, pid: 20, layer: 101)
        let unrelated = MenuBarActivationWindow(id: 2, pid: 30, layer: 101)
        XCTAssertFalse(MenuBarActivationPolicy.hasNewTargetUI(
            before: [existing], after: [existing, unrelated],
            applicationPID: 10, hostingPID: 20, popupLayer: 101, statusLayer: 25
        ))
        let reflowedHost = MenuBarActivationWindow(id: 3, pid: 20, layer: 25)
        XCTAssertFalse(MenuBarActivationPolicy.hasNewTargetUI(
            before: [], after: [reflowedHost],
            applicationPID: 10, hostingPID: 20, popupLayer: 101, statusLayer: 25
        ))
    }

    func testNewAppPopoverOrHostedTrackingMenuProvesNativeClick() {
        for result in [
            MenuBarActivationWindow(id: 1, pid: 10, layer: 8),
            MenuBarActivationWindow(id: 2, pid: 20, layer: 101),
        ] {
            XCTAssertTrue(MenuBarActivationPolicy.hasNewTargetUI(
                before: [], after: [result],
                applicationPID: 10, hostingPID: 20, popupLayer: 101, statusLayer: 25
            ))
        }
    }

    func testExactWindowDropRemainsAddressableBehindNotchAndOffscreen() {
        for x in [942.0, -3_000.0] {
            let window = MenuBarPhysicalMember(
                windowID: 7, frame: CGRect(x: x, y: 0, width: 32, height: 39), isMovable: false
            )
            XCTAssertTrue(MenuBarRoutedDropPolicy.isAddressable(
                windowID: 7, point: CGPoint(x: x + 1, y: 19.5), liveMembers: [window]
            ))
            XCTAssertTrue(MenuBarRoutedDropPolicy.isAddressable(
                windowID: 7, point: CGPoint(x: x + 31, y: 19.5), liveMembers: [window]
            ))
        }
    }

    func testDragDropRejectsAHostOutsideOriginalMenuRow() {
        let row = CGRect(x: 1_400, y: 0, width: 38, height: 39)
        let valid = CGRect(x: -3_000, y: 0, width: 32, height: 39)
        XCTAssertTrue(MenuBarDragSafetyPolicy.staysOnRow(CGPoint(x: -2_984, y: 19.5), source: row, target: valid))
        let desktop = CGRect(x: 1_400, y: 200, width: 38, height: 39)
        XCTAssertFalse(MenuBarDragSafetyPolicy.staysOnRow(CGPoint(x: 1_419, y: 219.5), source: row, target: desktop))
        XCTAssertFalse(MenuBarDragSafetyPolicy.staysOnRow(CGPoint(x: 20_000, y: 20_000), source: row, target: valid))
        XCTAssertFalse(MenuBarDragSafetyPolicy.staysOnRow(CGPoint(x: 1_419, y: CGFloat.infinity), source: row, target: row))
    }

    func testCancelledDragReturnsToOriginalHostCenter() {
        let original = CGRect(x: -3_000, y: 0, width: 38, height: 39)
        XCTAssertEqual(MenuBarDragSafetyPolicy.cancellationPoint(originalFrame: original), CGPoint(x: -2_981, y: 19.5))
        XCTAssertNil(MenuBarDragSafetyPolicy.cancellationPoint(originalFrame: .zero))
    }

    func testRoutedDropRejectsDisappearedHostOrPointFromOldFrame() {
        let window = MenuBarPhysicalMember(
            windowID: 7, frame: CGRect(x: 942, y: 0, width: 32, height: 39), isMovable: false
        )
        XCTAssertFalse(MenuBarRoutedDropPolicy.isAddressable(
            windowID: 8, point: CGPoint(x: 943, y: 19.5), liveMembers: [window]
        ))
        XCTAssertFalse(MenuBarRoutedDropPolicy.isAddressable(
            windowID: 7, point: CGPoint(x: 1_015, y: 19.5), liveMembers: [window]
        ))
    }

    func testTemporaryRestorationCapturesActualRightNeighbourOrder() {
        let members = [
            MenuBarPhysicalMember(windowID: 4, frame: CGRect(x: 200, y: 0, width: 25, height: 39), isMovable: true),
            MenuBarPhysicalMember(windowID: 1, frame: CGRect(x: 100, y: 0, width: 25, height: 39), isMovable: true),
            MenuBarPhysicalMember(windowID: 3, frame: CGRect(x: 175, y: 0, width: 25, height: 39), isMovable: true),
            MenuBarPhysicalMember(windowID: 2, frame: CGRect(x: 150, y: 0, width: 25, height: 39), isMovable: true),
        ]
        XCTAssertEqual(MenuBarRestorationPolicy.rightNeighbours(of: 2, among: members), [3, 4])
        XCTAssertEqual(MenuBarRestorationPolicy.rightNeighbours(of: 4, among: members), [])
        XCTAssertEqual(MenuBarRestorationPolicy.rightNeighbours(of: 99, among: members), [])
        XCTAssertTrue(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 2, before: 3, among: members))
        XCTAssertFalse(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 2, before: 4, among: members))
    }

    func testPhysicalDragRequiresReliableHitAndOneContiguousSafeArea() {
        let left = CGRect(x: 0, y: 0, width: 900, height: 39)
        let right = CGRect(x: 1_050, y: 0, width: 800, height: 39)
        let source = CGPoint(x: 1_150, y: 19.5)
        XCTAssertTrue(MenuBarMovementPolicy.prefersPhysicalDrag(
            reliableSource: true, source: source, destination: CGPoint(x: 1_300, y: 19.5), usableAreas: [left, right]
        ))
        for destination in [CGPoint(x: 700, y: 19.5), CGPoint(x: 942, y: 19.5), CGPoint(x: -3_000, y: 19.5)] {
            XCTAssertFalse(MenuBarMovementPolicy.prefersPhysicalDrag(
                reliableSource: true, source: source, destination: destination, usableAreas: [left, right]
            ))
        }
        XCTAssertFalse(MenuBarMovementPolicy.prefersPhysicalDrag(
            reliableSource: false, source: source, destination: source, usableAreas: [right]
        ))
        XCTAssertFalse(MenuBarMovementPolicy.prefersPhysicalDrag(
            reliableSource: true, source: nil, destination: source, usableAreas: [right]
        ))
    }

    func testQbarWindowsAndUnverifiedHelperWindowsCannotProveNativeClick() {
        let ownPopup = MenuBarActivationWindow(id: 1, pid: 20, layer: 101)
        let helperPopup = MenuBarActivationWindow(id: 2, pid: 40, layer: 8)
        XCTAssertFalse(MenuBarActivationPolicy.hasNewTargetUI(
            before: [], after: [ownPopup, helperPopup], applicationPID: 10, hostingPID: 20,
            popupLayer: 101, statusLayer: 25, excludedPID: 20
        ))
        XCTAssertEqual(MenuBarActivationPolicy.newTargetUI(
            before: [], after: [ownPopup, helperPopup, MenuBarActivationWindow(id: 3, pid: 10, layer: 8)],
            applicationPID: 10, hostingPID: 20, popupLayer: 101, statusLayer: 25, excludedPID: 20
        ).map(\.id), [3])
    }

    func testVerifiedMainAppPopupIsAcceptedForItsStatusHelper() {
        let mainApp = MenuBarActivationWindow(id: 1, pid: 6_996, layer: 3)
        let unrelatedApp = MenuBarActivationWindow(id: 2, pid: 8_000, layer: 3)
        let reflowedStatus = MenuBarActivationWindow(id: 3, pid: 6_996, layer: 25)
        let ownWindow = MenuBarActivationWindow(id: 4, pid: 9_000, layer: 3)
        XCTAssertEqual(MenuBarActivationPolicy.newTargetUI(
            before: [], after: [mainApp, unrelatedApp, reflowedStatus, ownWindow],
            applicationPID: 7_012, hostingPID: 1_020, popupLayer: 101, statusLayer: 25,
            excludedPID: 9_000, relatedApplicationPIDs: [6_996, 7_012, 9_000]
        ).map(\.id), [1])
        XCTAssertFalse(MenuBarActivationPolicy.hasNewTargetUI(
            before: [mainApp], after: [mainApp, unrelatedApp],
            applicationPID: 7_012, hostingPID: 1_020, popupLayer: 101, statusLayer: 25,
            relatedApplicationPIDs: [6_996, 7_012]
        ))
    }

    func testRelatedAppIdentityUsesExactOutermostAppURL() {
        let main = URL(fileURLWithPath: "/Applications/Feishu.app", isDirectory: true)
        let helper = URL(fileURLWithPath: "/Applications/Feishu.app/Contents/Frameworks/Feishu Helper.app", isDirectory: true)
        let normalizedHelper = URL(fileURLWithPath: "/Applications/Feishu.app/Contents/../Contents/Frameworks/Feishu Helper.app", isDirectory: true)
        XCTAssertEqual(MenuBarApplicationIdentityPolicy.outermostApplicationURL(of: main), main)
        XCTAssertEqual(MenuBarApplicationIdentityPolicy.outermostApplicationURL(of: helper), main)
        XCTAssertEqual(MenuBarApplicationIdentityPolicy.outermostApplicationURL(of: normalizedHelper), main)
        XCTAssertNotEqual(MenuBarApplicationIdentityPolicy.outermostApplicationURL(
            of: URL(fileURLWithPath: "/Applications/Feishu Pro.app/Contents/Helpers/Feishu Helper.app")
        ), main)
        XCTAssertNotEqual(MenuBarApplicationIdentityPolicy.outermostApplicationURL(
            of: URL(fileURLWithPath: "/Users/test/Applications/Feishu.app/Contents/Helpers/Feishu Helper.app")
        ), main)
        XCTAssertNil(MenuBarApplicationIdentityPolicy.outermostApplicationURL(of: URL(fileURLWithPath: "/usr/bin/helper")))
    }
}
