import XCTest
import AppKit
import QbarCore
@testable import QbarRuntime

final class MenuItemSnapshotCacheTests: XCTestCase {
    private let launchedAt = Date(timeIntervalSince1970: 100)
    private var processes: [pid_t: MenuItemSnapshotCache.ProcessInstance] {
        [10: .init(bundleID: "example.app", launchedAt: launchedAt),
         20: .init(bundleID: "com.apple.controlcenter", launchedAt: Date(timeIntervalSince1970: 50))]
    }

    private func real(id: String = "example.app|primary", pid: pid_t = 10,
                      window: CGWindowID = 1, owner: pid_t = 20,
                      image: NSImage? = nil) -> MenuItem {
        MenuItem(id: id, name: "Example", bundleID: "example.app", pid: pid,
                 windowID: window, windowOwnerPID: owner, element: nil,
                 frame: CGRect(x: 1_400, y: 0, width: 38, height: 39),
                 menuImage: image, captureNeedsDarkBackground: image == nil ? nil : true,
                 observedSection: .hidden)
    }

    private func anonymous(window: CGWindowID = 1) -> MenuItem {
        MenuItem(id: "com.apple.controlcenter|window-\(window)", name: "菜单栏图标",
                 bundleID: "com.apple.controlcenter", pid: 20,
                 windowID: window, windowOwnerPID: 20, element: nil,
                 frame: CGRect(x: -3_000, y: 0, width: 38, height: 39), observedSection: .hidden)
    }

    func testRealAnonymousRealTransitionKeepsPixelsIdentityAndSavedGroup() {
        var cache = MenuItemSnapshotCache()
        let image = NSImage(size: NSSize(width: 24, height: 24))
        let initial = cache.reconcile([real(image: image)], previous: [], processes: processes)
        let parked = anonymous()
        var intermediate = cache.reconcile([parked], previous: initial, processes: processes)
        XCTAssertEqual(intermediate.first?.id, initial.first?.id)
        XCTAssertEqual(intermediate.first?.pid, 10)
        XCTAssertEqual(intermediate.first?.bundleID, "example.app")
        XCTAssertEqual(intermediate.first?.frame, parked.frame)
        XCTAssertTrue(intermediate.first?.menuImage === image)
        XCTAssertEqual(intermediate.first?.captureNeedsDarkBackground, true)
        var prefs = Preferences()
        prefs.rules = [.init(id: initial[0].id, name: "Example", bundleID: "example.app", section: .hidden)]
        XCTAssertEqual(prefs.section(for: intermediate[0].id), .hidden)

        // The cache is independent of the currently published items. Even an
        // empty replacement or failed capture cannot destroy the saved pixels.
        intermediate[0].menuImage = nil
        intermediate[0].captureNeedsDarkBackground = nil
        var fresh = real()
        fresh.frame = parked.frame
        let restored = cache.reconcile([fresh], previous: intermediate, processes: processes)
        XCTAssertEqual(restored.first?.id, initial.first?.id)
        XCTAssertTrue(restored.first?.menuImage === image)
        XCTAssertEqual(restored.first?.captureNeedsDarkBackground, true)
        XCTAssertEqual(prefs.section(for: restored[0].id), .hidden)
    }

    func testCaptureCompletedAfterDiscoveryIsRetainedOnFirstAnonymousScan() {
        var cache = MenuItemSnapshotCache()
        var discovered = cache.reconcile([real()], previous: [], processes: processes)
        let image = NSImage(size: NSSize(width: 24, height: 24))
        discovered[0].menuImage = image
        discovered[0].captureNeedsDarkBackground = true
        let retained = cache.reconcile([anonymous()], previous: discovered, processes: processes)
        XCTAssertEqual(retained.first?.id, "example.app|primary")
        XCTAssertTrue(retained.first?.menuImage === image)
        XCTAssertEqual(retained.first?.captureNeedsDarkBackground, true)
    }

    func testNewApplicationPIDCannotReceivePreviousCapture() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        var current = processes
        current[11] = .init(bundleID: "example.app", launchedAt: Date(timeIntervalSince1970: 200))
        let result = cache.reconcile([real(pid: 11)], previous: initial, processes: current)
        XCTAssertEqual(result.first?.pid, 11)
        XCTAssertNil(result.first?.menuImage)
        XCTAssertNil(result.first?.captureNeedsDarkBackground)
    }

    func testReusedApplicationPIDWithNewLaunchDateInvalidatesCapture() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        var current = processes
        current[10] = .init(bundleID: "example.app", launchedAt: Date(timeIntervalSince1970: 200))
        let result = cache.reconcile([anonymous()], previous: initial, processes: current)
        XCTAssertEqual(result.first?.id, anonymous().id)
        XCTAssertNil(result.first?.menuImage)
    }

    func testNewWindowInvalidatesCaptureEvenWhileOldHostStillExists() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        let result = cache.reconcile([anonymous(), real(window: 2)], previous: initial, processes: processes)
        XCTAssertEqual(result.map(\.id), [anonymous().id, "example.app|primary"])
        XCTAssertTrue(result.allSatisfy { $0.menuImage == nil })
    }

    func testNewOwnerPIDAndReusedOwnerPIDInvalidateCapture() {
        for changePID in [false, true] {
            var cache = MenuItemSnapshotCache()
            let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
            var current = processes
            let owner: pid_t = changePID ? 21 : 20
            current[owner] = .init(bundleID: "com.apple.controlcenter", launchedAt: Date(timeIntervalSince1970: 200))
            let result = cache.reconcile([real(owner: owner)], previous: initial, processes: current)
            XCTAssertNil(result.first?.menuImage)
        }
    }

    func testAnotherKnownItemOnSameHostCannotReceivePreviousCapture() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        let result = cache.reconcile([real(id: "example.app|secondary")], previous: initial, processes: processes)
        XCTAssertNil(result.first?.menuImage)
    }

    func testExitedApplicationCannotKeepIdentityThroughAnonymousHost() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        var current = processes
        current.removeValue(forKey: 10)
        let result = cache.reconcile([anonymous()], previous: initial, processes: current)
        XCTAssertEqual(result.first?.id, anonymous().id)
        XCTAssertNil(result.first?.menuImage)
    }

    func testDisappearedHostPrunesCaptureBeforeWindowIDCanBeReused() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        let empty = cache.reconcile([], previous: initial, processes: processes)
        XCTAssertEqual(cache.count, 0)
        let later = cache.reconcile([real()], previous: empty, processes: processes)
        XCTAssertNil(later.first?.menuImage)
    }

    func testAmbiguousHostDoesNotRestoreAnOldApplicationIdentity() {
        var cache = MenuItemSnapshotCache()
        let initial = cache.reconcile([real(image: NSImage(size: NSSize(width: 24, height: 24)))], previous: [], processes: processes)
        var duplicate = anonymous()
        duplicate.name = "Duplicate"
        let result = cache.reconcile([anonymous(), duplicate], previous: initial, processes: processes)
        XCTAssertTrue(result.allSatisfy { $0.id == anonymous().id && $0.menuImage == nil })
        XCTAssertEqual(cache.count, 0)
    }

    func testFirstAnonymousCaptureMayFollowItsExactHostToRealIdentity() {
        var cache = MenuItemSnapshotCache()
        let image = NSImage(size: NSSize(width: 24, height: 24))
        var raw = anonymous()
        raw.menuImage = image
        raw.captureNeedsDarkBackground = true
        let initial = cache.reconcile([raw], previous: [], processes: processes)
        let result = cache.reconcile([real()], previous: initial, processes: processes)
        XCTAssertEqual(result.first?.id, "example.app|primary")
        XCTAssertTrue(result.first?.menuImage === image)
        XCTAssertEqual(result.first?.captureNeedsDarkBackground, true)
    }

    func testCacheIsBoundedAndClearPreventsOldCaptureFromReturning() {
        var cache = MenuItemSnapshotCache(capacity: 2)
        let image = NSImage(size: NSSize(width: 24, height: 24))
        let source = (1...3).map { real(id: "example.app|item-\($0)", window: CGWindowID($0), image: image) }
        let initial = cache.reconcile(source, previous: [], processes: processes)
        XCTAssertEqual(cache.count, 2)
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        let result = cache.reconcile([real(id: source[0].id)], previous: initial, processes: processes)
        XCTAssertNil(result.first?.menuImage)
    }
}
