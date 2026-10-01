import XCTest
import AppKit
@testable import QbarRuntime

final class MenuPresenceTests: XCTestCase {
    func testPresenceAuditSeedsWithoutTriggeringDiscovery() {
        var tracker = MenuPresenceTracker()
        XCTAssertFalse(tracker.observe([10: ["a"]], runningPIDs: [10]))
        XCTAssertFalse(tracker.observe([10: ["a"]], runningPIDs: [10]))
        XCTAssertTrue(tracker.observe([10: ["a", "b"]], runningPIDs: [10]))
        XCTAssertFalse(tracker.observe([10: ["a", "b"]], runningPIDs: [10]))
    }

    func testFailedPresenceReadRetainsLastSuccessfulSample() {
        var tracker = MenuPresenceTracker()
        XCTAssertFalse(tracker.observe([10: ["a"]], runningPIDs: [10]))
        XCTAssertFalse(tracker.observe([:], runningPIDs: [10]))
        XCTAssertEqual(tracker.baseline?[10], ["a"])
        XCTAssertFalse(tracker.observe([10: ["a"]], runningPIDs: [10]))
        XCTAssertTrue(tracker.observe([10: ["a", "b"]], runningPIDs: [10]))
    }

    func testSuccessfulEmptyPresenceAndExitedProcessesUpdateBaseline() {
        var tracker = MenuPresenceTracker()
        XCTAssertFalse(tracker.observe([10: ["a"]], runningPIDs: [10]))
        XCTAssertFalse(tracker.observe([10: []], runningPIDs: [10]))
        XCTAssertEqual(tracker.baseline?[10], [])
        XCTAssertTrue(tracker.observe([10: ["a"], 20: ["new"]], runningPIDs: [10, 20]))
        XCTAssertFalse(tracker.observe([20: ["new"]], runningPIDs: [20]))
        XCTAssertNil(tracker.baseline?[10])
    }

    private func observation(id: String = "example.app|primary", bundle: String = "example.app",
                             pid: pid_t = 10, x: CGFloat = 108, y: CGFloat = 8.5,
                             label: String? = nil) -> MenuScanner.StatusObservation {
        .init(id: id, name: "Example", bundle: bundle, pid: pid, identifier: nil, label: label,
              element: nil, frame: CGRect(x: x, y: y, width: 24, height: 22))
    }

    private func window(id: CGWindowID = 1, owner: pid_t = 20, x: CGFloat = 100,
                        title: String = "Item-0") -> MenuScanner.Window {
        .init(id: id, pid: owner, title: title, frame: CGRect(x: x, y: 0, width: 40, height: 39))
    }

    func testGhostAXExtrasDoNotBecomeActiveLayoutItemsWithoutHosts() {
        let ghosts = [
            observation(x: 1770, y: 1147),
            observation(id: "other.app|primary", x: 1470, y: -1)
        ]
        XCTAssertTrue(MenuScanner.hostedItems(observations: ghosts, windows: []).isEmpty)
    }

    func testLateHostAddsNewApplicationWithItsStableIdentity() {
        let launched = observation(id: "new.app|upload-status", bundle: "new.app")
        XCTAssertTrue(MenuScanner.hostedItems(observations: [launched], windows: []).isEmpty)
        let items = MenuScanner.hostedItems(observations: [launched], windows: [window()])
        XCTAssertEqual(items.map(\.id), [launched.id])
        XCTAssertEqual(items.first?.pid, launched.pid)
        XCTAssertEqual(items.first?.windowOwnerPID, 20)
        XCTAssertEqual(items.first?.verifiedFrame, window().frame)
    }

    func testParkedOffscreenHostStillProvesActivePresence() {
        let parked = observation(x: -8992)
        let host = window(x: -9000)
        let items = MenuScanner.hostedItems(observations: [parked], windows: [host])
        XCTAssertEqual(items.map(\.id), [parked.id])
        XCTAssertEqual(items.first?.verifiedFrame, host.frame)
    }

    func testStaleAXOnDifferentVerticalRowCannotClaimNearbyHost() {
        let stale = observation(x: 108, y: -1)
        XCTAssertTrue(MenuScanner.hostedItems(observations: [stale], windows: [window()]).isEmpty)
    }

    func testMatchingTitleCannotOverrideContradictoryGeometry() {
        let stale = observation(x: 300, label: "ExampleStatus")
        let host = window(title: "ExampleStatus")
        XCTAssertTrue(MenuScanner.hostedItems(observations: [stale], windows: [host]).isEmpty)
    }

    func testIndependentApplicationsCannotBothClaimTheSameHost() {
        let first = observation()
        let second = observation(id: "other.app|primary", bundle: "other.app", pid: 30)
        XCTAssertTrue(MenuScanner.hostedItems(observations: [first, second], windows: [window()]).isEmpty)
    }

    func testControlCenterProxyDoesNotReplaceTheRealApplication() {
        let proxy = observation(id: "com.apple.controlcenter|proxy", bundle: "com.apple.controlcenter", pid: 20)
        let real = observation()
        let items = MenuScanner.hostedItems(observations: [proxy, real], windows: [window()])
        XCTAssertEqual(items.map(\.id), [real.id])
        XCTAssertEqual(items.first?.bundleID, real.bundle)
    }

    func testMultipleStatusItemsFromOneApplicationRemainDistinct() {
        let first = observation(id: "example.app|upload", label: "Uploading 3 files")
        let second = observation(id: "example.app|downloads", x: 208, label: "Downloading 8 files")
        let items = MenuScanner.hostedItems(observations: [first, second],
                                           windows: [window(), window(id: 2, x: 200)])
        XCTAssertEqual(items.map(\.id), [first.id, second.id])
        XCTAssertEqual(items.compactMap(\.windowID), [1, 2])
    }
}
