import XCTest
import AppKit
import QbarCore
@testable import QbarRuntime

private actor ScanQueue {
    private var continuations: [CheckedContinuation<[MenuItem], Never>] = []
    private(set) var count = 0
    func scan() async -> [MenuItem] {
        count += 1
        return await withCheckedContinuation { continuations.append($0) }
    }
    func complete(_ items: [MenuItem]) { continuations.removeFirst().resume(returning: items) }
}

final class RuntimeTests: XCTestCase {
    @MainActor
    private func model(scanner: @escaping @Sendable (Bool) async -> [MenuItem] = { _ in [] }) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QbarTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "studio.qbar.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        return AppModel(storageURL: directory.appendingPathComponent("preferences.json"), defaults: defaults, scanner: scanner, capture: { _ in })
    }

    private func item(_ name: String, id: String = "example.app|primary", bundle: String = "example.app") -> MenuItem {
        MenuItem(id: id, name: name, bundleID: bundle, pid: -1, windowID: nil, windowOwnerPID: nil, element: nil, frame: CGRect(x: 100, y: 0, width: 24, height: 24))
    }

    @MainActor
    private func eventually(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    @MainActor
    func testQueuedRefreshDiscardsStaleSnapshotAndRunsLatestRequest() async throws {
        let queue = ScanQueue()
        let model = try model(scanner: { _ in await queue.scan() })
        model.refresh()
        try await eventually { await queue.count == 1 }
        model.refresh(); model.refresh()
        await queue.complete([item("Stale")])
        try await eventually { await queue.count == 2 }
        XCTAssertTrue(model.items.isEmpty)
        await queue.complete([item("Latest")])
        try await eventually { !model.isRefreshing }
        XCTAssertEqual(model.items.map(\.name), ["Latest"])
        let count = await queue.count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testAudioVideoControlIsNeverListedOrAddedToLayout() async throws {
        let audio = item("音频与视频控制", id: "com.apple.controlcenter|com.apple.menuextra.audiovideo", bundle: "com.apple.controlcenter")
        let app = item("ClashX Pro", id: "com.west2online.ClashXPro|primary", bundle: "com.west2online.ClashXPro")
        let model = try model(scanner: { _ in [audio, app] })
        model.refresh()
        try await eventually { !model.isRefreshing }
        XCTAssertEqual(model.items.map(\.id), [app.id])
        XCTAssertFalse(model.preferences.rules.contains { $0.id == audio.id })
    }

    @MainActor
    func testPausingManagementPreservesPendingAppGroups() throws {
        let model = try model()
        let docker = item("Docker Desktop", id: "com.electron.dockerdesktop|primary", bundle: "com.electron.dockerdesktop")
        model.preferences.rules = [.init(id: docker.id, name: docker.name, bundleID: docker.bundleID, section: .hidden)]
        model.layoutPending = true
        model.managementEnabled = true
        model.setManagement(false)
        XCTAssertFalse(model.managementEnabled)
        XCTAssertTrue(model.layoutPending)
        XCTAssertEqual(model.preferences.section(for: docker.id), .hidden)
    }

    @MainActor
    func testMovementInvalidatesInFlightRefreshAndDefersNextScan() async throws {
        let queue = ScanQueue()
        let model = try model(scanner: { _ in await queue.scan() })
        model.refresh()
        try await eventually { await queue.count == 1 }
        model.isMoving = true
        await queue.complete([item("Old position")])
        try await eventually { !model.isRefreshing }
        XCTAssertTrue(model.items.isEmpty)
        var count = await queue.count
        XCTAssertEqual(count, 1)
        model.isMoving = false
        try await eventually { await queue.count == 2 }
        await queue.complete([item("New position")])
        try await eventually { !model.isRefreshing }
        XCTAssertEqual(model.items.first?.name, "New position")
        count = await queue.count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testRenamedMovableSystemIconKeepsSymbol() async throws {
        let model = try model()
        let siri = item("Siri", id: "com.apple.systemuiserver|primary", bundle: "com.apple.systemuiserver")
        model.items = [siri]
        model.preferences.rules = [.init(id: siri.id, name: siri.name, bundleID: siri.bundleID)]
        model.isMoving = true // Keep the asynchronous refresh queued during this assertion.
        model.rename(siri.id, to: "我的助手")
        XCTAssertEqual(model.items.first?.name, "我的助手")
        XCTAssertEqual(model.items.first?.systemSymbol, "sparkles")
        XCTAssertEqual(model.items.first?.isMovable, true)
        model.rename(siri.id, to: "")
        XCTAssertEqual(model.items.first?.name, "Siri")
    }

    @MainActor
    func testFixedItemCannotBeStagedByDragAndSelfDropIsNoOp() throws {
        let model = try model()
        let clock = item("时钟", id: "com.apple.controlcenter|com.apple.menuextra.clock", bundle: "com.apple.controlcenter")
        model.items = [clock]
        model.preferences.rules = [.init(id: clock.id, name: clock.name, bundleID: clock.bundleID)]
        let original = model.preferences
        model.move(clock.id, to: .hidden)
        XCTAssertEqual(model.preferences, original)
        XCTAssertFalse(model.layoutPending)
        XCTAssertNotNil(model.error)
        model.error = nil
        model.move(clock.id, to: .visible, before: clock.id)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.preferences, original)
    }

    @MainActor
    func testImportUpdatesNamesImmediatelyAndCancelRemovesStagedSections() throws {
        let model = try model()
        let app = item("Original")
        model.items = [app]
        model.isMoving = true
        var imported = Preferences()
        imported.rules = [.init(id: app.id, name: app.name, bundleID: app.bundleID, section: .hidden, alias: "Imported")]
        try model.applyImportedConfiguration(JSONEncoder().encode(ConfigurationFile(preferences: imported)))
        XCTAssertEqual(model.items.first?.name, "Imported")
        XCTAssertTrue(model.layoutPending)
        XCTAssertEqual(model.section(model.items[0]), .hidden)
        model.discardPendingLayout()
        XCTAssertFalse(model.layoutPending)
        XCTAssertEqual(model.preferences.section(for: app.id), .visible)
        // Starting a new offline edit must not revive cancelled imported sections.
        model.layoutPending = true
        XCTAssertEqual(model.section(model.items[0]), .visible)
    }

    @MainActor
    func testInvalidImportDoesNotMutateExistingPreferencesOrPendingState() throws {
        let model = try model()
        let original = model.preferences
        XCTAssertThrowsError(try model.applyImportedConfiguration(Data("{broken".utf8)))
        XCTAssertEqual(model.preferences, original)
        XCTAssertFalse(model.layoutPending)
    }

    @MainActor
    func testApplyingLayoutRepairsStaleFixedSystemRule() async throws {
        let model = try model()
        let clock = item("时钟", id: "com.apple.controlcenter|com.apple.menuextra.clock", bundle: "com.apple.controlcenter")
        model.items = [clock]
        model.preferences.rules = [.init(id: clock.id, name: clock.name, bundleID: clock.bundleID, section: .hidden)]
        await MenuBarEngine(model: model).applyLayout()
        XCTAssertEqual(model.preferences.section(for: clock.id), .visible)
        XCTAssertFalse(model.layoutPending)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testStagedLayoutCanBeAppliedWhenManagementIsOff() throws {
        let model = try model()
        let app = item("Example")
        model.items = [app]
        model.preferences.rules = [.init(id: app.id, name: app.name, bundleID: app.bundleID)]
        model.move(app.id, to: .hidden)
        XCTAssertFalse(model.managementEnabled)
        XCTAssertTrue(model.layoutPending)
        XCTAssertTrue(model.canApplyLayout)
        model.isMoving = true
        XCTAssertFalse(model.canApplyLayout)
    }

    @MainActor
    func testApplyRequestPreservesStagedGroupsAndDispatchesOnce() throws {
        let model = try model()
        let app = item("Example")
        model.items = [app]
        model.preferences.rules = [.init(id: app.id, name: app.name, bundleID: app.bundleID, section: .hidden)]
        model.managementEnabled = true
        var calls = 0
        model.onApplyLayout = {
            calls += 1
            XCTAssertTrue(model.layoutPending)
            XCTAssertEqual(model.preferences.section(for: app.id), .hidden)
        }
        model.requestApplyLayout()
        XCTAssertEqual(calls, 1)
        model.isMoving = true
        model.requestApplyLayout()
        XCTAssertEqual(calls, 1)
        let empty = try self.model()
        XCTAssertFalse(empty.canApplyLayout)
    }

    func testAutoHideRequiresOutsidePointerAndCurrentEnabledState() {
        XCTAssertTrue(AutoHidePolicy.shouldSchedule(enabled: true, expanded: true, moving: false, pointerInside: false))
        XCTAssertFalse(AutoHidePolicy.shouldSchedule(enabled: false, expanded: true, moving: false, pointerInside: false))
        XCTAssertFalse(AutoHidePolicy.shouldSchedule(enabled: true, expanded: false, moving: false, pointerInside: false))
        XCTAssertFalse(AutoHidePolicy.shouldSchedule(enabled: true, expanded: true, moving: true, pointerInside: false))
        XCTAssertFalse(AutoHidePolicy.shouldSchedule(enabled: true, expanded: true, moving: false, pointerInside: true))
    }

    @MainActor
    func testPreferredPositionMigrationRepairsOnlyMainAnchorWhenLanePositionsAreValid() {
        let suite = "studio.qbar.tests.positions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "NSStatusItem Preferred Position "
        defaults.set(999.0, forKey: prefix + "Qbar.Main")
        defaults.set(333.0, forKey: prefix + "Qbar.Hidden")
        defaults.set(777.0, forKey: prefix + "Qbar.AlwaysHidden")

        StatusController.migratePreferredPositions(in: defaults)

        XCTAssertNotEqual(defaults.double(forKey: prefix + "Qbar.Main"), 999.0)
        XCTAssertEqual(defaults.double(forKey: prefix + "Qbar.Hidden"), 333.0)
        XCTAssertEqual(defaults.double(forKey: prefix + "Qbar.AlwaysHidden"), 777.0)
    }

    func testBeforePlacementRequiresExactPhysicalAdjacency() {
        let members = [
            MenuBarPhysicalMember(windowID: 1, frame: CGRect(x: 100, y: 0, width: 20, height: 24), isMovable: true),
            MenuBarPhysicalMember(windowID: 2, frame: CGRect(x: 140, y: 0, width: 20, height: 24), isMovable: true),
            MenuBarPhysicalMember(windowID: 3, frame: CGRect(x: 180, y: 0, width: 20, height: 24), isMovable: true),
        ]
        XCTAssertFalse(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 1, before: 3, among: members))
        XCTAssertTrue(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 2, before: 3, among: members))
        XCTAssertFalse(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 2, before: 99, among: members))
    }

    func testEndPlacementUsesLastMovableItemBeforeFixedSystemSuffix() {
        let members = [
            MenuBarPhysicalMember(windowID: 1, frame: CGRect(x: 100, y: 0, width: 20, height: 24), isMovable: true),
            MenuBarPhysicalMember(windowID: 2, frame: CGRect(x: 140, y: 0, width: 20, height: 24), isMovable: true),
            MenuBarPhysicalMember(windowID: 90, frame: CGRect(x: 180, y: 0, width: 20, height: 24), isMovable: false),
            MenuBarPhysicalMember(windowID: 91, frame: CGRect(x: 220, y: 0, width: 20, height: 24), isMovable: false),
        ]
        XCTAssertFalse(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 1, before: nil, among: members))
        XCTAssertTrue(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 2, before: nil, among: members))
    }

    func testEverySectionAppendsAtItsOwnedRightBoundary() {
        let members = [
            MenuBarPhysicalMember(windowID: 1, frame: CGRect(x: 100, y: 0, width: 20, height: 24), isMovable: true),
            MenuBarPhysicalMember(windowID: 90, frame: CGRect(x: 180, y: 0, width: 20, height: 24), isMovable: false),
        ]
        XCTAssertTrue(MenuBarOrderingPolicy.isSatisfied(movingWindowID: 1, before: nil, among: members))
        XCTAssertEqual(MenuBarOrderingPolicy.endBoundaryName(for: .visible), "Qbar.Hidden")
        XCTAssertEqual(MenuBarOrderingPolicy.endBoundaryName(for: .hidden), "Qbar.Hidden")
        XCTAssertEqual(MenuBarOrderingPolicy.endBoundaryName(for: .alwaysHidden), "Qbar.AlwaysHidden")
        XCTAssertTrue(MenuBarOrderingPolicy.usesEndBoundary(beforeNextIsMovable: nil))
        XCTAssertTrue(MenuBarOrderingPolicy.usesEndBoundary(beforeNextIsMovable: false))
        XCTAssertFalse(MenuBarOrderingPolicy.usesEndBoundary(beforeNextIsMovable: true))
    }
}
