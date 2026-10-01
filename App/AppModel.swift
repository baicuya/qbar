import AppKit
import Darwin
import ApplicationServices
import Combine
import ServiceManagement
import UniformTypeIdentifiers
import QbarCore

/// A snapshot of the replica's location, in Cocoa global screen coordinates.
/// Passing values keeps a native action independent of the hosting view's life.
struct TrayActivationAnchor {
    let screenFrame: CGRect
    let screenPoint: CGPoint
    let normalizedX: CGFloat?
}

/// A saved item's verified host appeared or changed. The engine must recheck
/// live placement before acting on this hint.
struct MenuHostReplacement {
    let id: String
    let bundleID: String
    let pid: pid_t
    let ownerPID: pid_t
    let oldWindowID: CGWindowID?
    let newWindowID: CGWindowID
    let savedSection: ItemSection
    let savedOrder: Int
    let rightNeighbours: [String]
}

/// Keeps a proven status item's identity and last good pixels while its AX
/// geometry catches up with a still-live WindowServer host after reflow.
/// Process launch dates distinguish a reused PID from the original instance.
struct MenuItemSnapshotCache {
    struct ProcessInstance: Hashable {
        let bundleID: String?
        let launchedAt: Date

        static func resolved(bundleID: String?, launchDate: Date?,
                             birthSeconds: UInt64, birthMicroseconds: UInt64) -> ProcessInstance? {
            if let launchDate { return .init(bundleID: bundleID, launchedAt: launchDate) }
            guard birthSeconds > 0, birthMicroseconds < 1_000_000 else { return nil }
            return .init(bundleID: bundleID, launchedAt: Date(timeIntervalSince1970:
                Double(birthSeconds) + Double(birthMicroseconds) / 1_000_000))
        }
    }

    private struct HostIdentity: Hashable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let owner: ProcessInstance

        init?(_ item: MenuItem, processes: [pid_t: ProcessInstance]) {
            guard let windowID = item.windowID, let ownerPID = item.windowOwnerPID,
                  let owner = processes[ownerPID] else { return nil }
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.owner = owner
        }
    }

    private struct CaptureIdentity: Hashable {
        let id: String
        let bundleID: String
        let pid: pid_t
        let process: ProcessInstance
        let host: HostIdentity

        init?(_ item: MenuItem, processes: [pid_t: ProcessInstance]) {
            guard let process = processes[item.pid],
                  process.bundleID == item.bundleID ||
                    (process.bundleID == nil && item.bundleID.hasPrefix("process.")),
                  let host = HostIdentity(item, processes: processes) else { return nil }
            id = item.id
            bundleID = item.bundleID
            pid = item.pid
            self.process = process
            self.host = host
        }
    }

    private struct Entry {
        var item: MenuItem
        var sequence: UInt64
    }

    private let capacity: Int
    private var entries: [CaptureIdentity: Entry] = [:]
    private var previousProcesses: [pid_t: ProcessInstance] = [:]
    private var sequence: UInt64 = 0
    var count: Int { entries.count }

    init(capacity: Int = 256) { self.capacity = max(0, capacity) }

    mutating func clear() {
        entries.removeAll()
        previousProcesses.removeAll()
    }

    private static func isAnonymousHost(_ item: MenuItem) -> Bool {
        item.element == nil && item.windowID != nil && item.pid == item.windowOwnerPID
    }

    mutating func reconcile(_ discovered: [MenuItem], previous: [MenuItem],
                            processes: [pid_t: ProcessInstance]) -> [MenuItem] {
        sequence &+= 1
        let hostCounts = discovered.reduce(into: [HostIdentity: Int]()) { result, item in
            if let host = HostIdentity(item, processes: processes) { result[host, default: 0] += 1 }
        }
        let identified = discovered.filter { !Self.isAnonymousHost($0) }
        let identifiedByID = Dictionary(grouping: identified, by: \.id)
        let identifiedByHost = identified.reduce(into: [HostIdentity: [MenuItem]]()) { result, item in
            if let host = HostIdentity(item, processes: processes) { result[host, default: []].append(item) }
        }

        // Captures finish between scans. Bind old pixels to the process tokens
        // observed with that old metadata, never to today's possibly reused PID.
        for old in previous {
            guard let identity = CaptureIdentity(old, processes: previousProcesses),
                  processes[identity.pid] == identity.process,
                  hostCounts[identity.host] == 1 else { continue }
            var item = old
            if item.menuImage == nil, let cached = entries[identity]?.item {
                item.menuImage = cached.menuImage
                item.captureNeedsDarkBackground = cached.captureNeedsDarkBackground
            }
            entries[identity] = Entry(item: item, sequence: sequence)
        }
        entries = entries.filter { identity, entry in
            guard hostCounts[identity.host] == 1,
                  processes[identity.pid] == identity.process else { return false }
            if !Self.isAnonymousHost(entry.item) {
                // Fresh, identified metadata is authoritative. A replacement
                // window or another app claiming this host invalidates the old
                // ownership rather than receiving that app's cached pixels.
                if let current = identifiedByID[identity.id],
                   !current.contains(where: { CaptureIdentity($0, processes: processes) == identity }) { return false }
                if let current = identifiedByHost[identity.host],
                   !current.contains(where: { CaptureIdentity($0, processes: processes) == identity }) { return false }
            }
            return true
        }

        let normalized = discovered.map { discoveredItem -> MenuItem in
            var item = discoveredItem
            guard let identity = CaptureIdentity(item, processes: processes),
                  hostCounts[identity.host] == 1 else { return item }
            if Self.isAnonymousHost(item) {
                let origins = entries.filter {
                    $0.key.host == identity.host && !Self.isAnonymousHost($0.value.item)
                }
                if origins.count == 1, let original = origins.first?.value.item {
                    // Keep the saved id, source PID/bundle, and AX reference.
                    // Only the current host's measured geometry is replaced.
                    item = original
                    item.frame = discoveredItem.frame
                    item.observedSection = discoveredItem.observedSection
                    return item
                }
            }
            var capture = entries[identity]?.item
            if capture?.menuImage == nil, !Self.isAnonymousHost(item) {
                let anonymous = entries.filter {
                    $0.key.host == identity.host && Self.isAnonymousHost($0.value.item) && $0.value.item.menuImage != nil
                }
                if anonymous.count == 1 { capture = anonymous.first?.value.item }
            }
            if item.menuImage == nil {
                item.menuImage = capture?.menuImage
                item.captureNeedsDarkBackground = capture?.captureNeedsDarkBackground
            }
            return item
        }

        // Only the current, continuously present hosts survive this scan. This
        // also drops an anonymous origin after its real identity is established.
        entries = normalized.reduce(into: [:]) { result, item in
            if let identity = CaptureIdentity(item, processes: processes), hostCounts[identity.host] == 1 {
                result[identity] = Entry(item: item, sequence: sequence)
            }
        }
        if entries.count > capacity {
            let kept = entries.sorted {
                if ($0.value.item.menuImage != nil) != ($1.value.item.menuImage != nil) {
                    return $0.value.item.menuImage != nil
                }
                if $0.value.sequence != $1.value.sequence { return $0.value.sequence > $1.value.sequence }
                if $0.key.id != $1.key.id { return $0.key.id < $1.key.id }
                return $0.key.host.windowID < $1.key.host.windowID
            }.prefix(capacity)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        let trackedPIDs = Set(entries.keys.flatMap { [$0.pid, $0.host.ownerPID] })
        previousProcesses = processes.filter { trackedPIDs.contains($0.key) }
        return normalized
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// A live host that was verified outside Visible after its bounded repair
    /// failed. Keep its saved group intact while exposing a way to find it.
    private struct VisibleFallbackHost: Equatable {
        let windowID: CGWindowID
        let ownerPID: pid_t
    }

    private struct LastMenuHost {
        let bundleID: String
        let pid: pid_t
        let ownerPID: pid_t
        let windowID: CGWindowID
        let process: MenuItemSnapshotCache.ProcessInstance
        let ownerProcess: MenuItemSnapshotCache.ProcessInstance
        let section: ItemSection?
        let rightNeighbours: [String]
    }

    @Published var preferences: Preferences {
        didSet {
            save()
            if oldValue != preferences { onPreferencesChanged?(oldValue) }
        }
    }
    @Published var items: [MenuItem] = []
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var managementEnabled = false
    @Published var isExpanded = false
    @Published var isRefreshing = false
    @Published var isMoving = false {
        didSet {
            if isMoving {
                refreshGeneration &+= 1
                refreshQueued = true
            } else { startRefreshIfNeeded() }
        }
    }
    @Published var notice: String?
    @Published var error: String?
    @Published var conflicts: [String] = []
    @Published var shortcutErrors: [String: String] = [:]
    @Published var loginEnabled = false
    @Published var layoutPending = false {
        didSet {
            defaults.set(layoutPending, forKey: "layoutPending")
            if oldValue != layoutPending {
                trace("LAYOUT pending changed old=\(oldValue) new=\(layoutPending)")
                onLayoutPendingChanged?()
            }
        }
    }
    @Published var selectedPage: SettingsPage = .overview

    var onPreferencesChanged: ((Preferences) -> Void)?
    var onManagementChanged: ((Bool) -> Void)?
    var onToggle: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onMove: ((String, ItemSection, String?) -> Void)?
    var onActivateItem: ((String, Bool) -> Void)?
    var onActivateItemAtPoint: ((String, Bool, CGFloat?) -> Void)?
    var onActivateItemFromTray: ((String, Bool, TrayActivationAnchor) -> Void)?
    var onShowAlways: (() -> Void)?
    var onApplyLayout: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var classifyFrame: ((CGRect) -> ItemSection)?
    var debugStatus: (() -> [String: String])?
    var onInitialScanCompleted: (() -> Void)?
    var onDiscoverMenuItems: (() async -> Void)?
    var onHostReplacement: ((MenuHostReplacement) -> Void)?
    var isMenuItemReachable: ((MenuItem) -> Bool)?
    var onRefreshSettled: (() -> Void)?
    var onLayoutPendingChanged: (() -> Void)?
    @Published var temporarilyVisible = Set<String>()
    @Published private var visibleFallbackHosts: [String: VisibleFallbackHost] = [:]
    var nativeMenuFrames: [CGRect] = []
    var isInteractingWithMenu = false
    private var hasScanned = false
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var refreshQueued = false
    private var hostRepairWaiting = false
    private let defaults: UserDefaults
    private let scanMenuItems: @Sendable (Bool) async -> [MenuItem]
    private let captureMenuIcons: (@MainActor (AppModel) async -> Void)?
    private var storageURL: URL
    private var unreadableConfigurationNeedsBackup = false
    private var didCheckScreenRecording = false
    private let iconCapture = IconCapture()
    private var snapshotCache = MenuItemSnapshotCache()
    private var lastMenuHosts: [String: LastMenuHost] = [:]

    func trace(_ message: String) {
        #if DEBUG
        let url = storageURL.deletingLastPathComponent().appendingPathComponent("debug-events.log")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (String(previous.suffix(50_000)) + "\(Date()): \(message)\n").write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    init(storageURL: URL? = nil, defaults: UserDefaults = .standard,
         scanner: @escaping @Sendable (Bool) async -> [MenuItem] = { granted in
             await Task.detached(priority: .userInitiated) { MenuScanner.scan(accessibility: granted) }.value
         }, capture: (@MainActor (AppModel) async -> Void)? = nil) {
        self.defaults = defaults
        scanMenuItems = scanner
        captureMenuIcons = capture
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("Qbar/preferences.json")
        let savedData = try? Data(contentsOf: self.storageURL)
        let decoded = savedData.flatMap { try? ConfigurationFile.decode($0) }
        preferences = decoded ?? Preferences()
        unreadableConfigurationNeedsBackup = savedData != nil && decoded == nil
        if !defaults.bool(forKey: "temporaryIdleReturnVersion1") {
            preferences.rehideTemporary = true
            preferences.temporaryDelay = 10
            defaults.set(true, forKey: "temporaryIdleReturnVersion1")
        }
        if !defaults.bool(forKey: "trayVisualV3") {
            if preferences.panelIconSize == 22 || preferences.panelIconSize == 30 { preferences.panelIconSize = 24 }
            defaults.set(true, forKey: "trayVisualV3")
        }
        layoutPending = defaults.bool(forKey: "layoutPending")
        if defaults.integer(forKey: "layoutEngineVersion") < StatusController.preferredPositionLayoutVersion {
            // Repair only Qbar's status-item coordinates. Saved item rules and a
            // staged layout remain untouched so migration cannot erase user groups.
            StatusController.migratePreferredPositions(in: defaults)
            defaults.set(StatusController.preferredPositionLayoutVersion, forKey: "layoutEngineVersion")
        }
        checkPermissions()
        if unreadableConfigurationNeedsBackup {
            notice = L10n.tr("原有设置文件无法读取，Qbar 已保留原件。请检查或重新导入配置。")
        } else if savedData != nil { save() }
    }

    var hiddenCount: Int { items.filter { section($0) == .hidden }.count }
    var visibleCount: Int { items.filter { section($0) == .visible }.count }
    var alwaysCount: Int { items.filter { section($0) == .alwaysHidden }.count }

    func section(_ item: MenuItem) -> ItemSection {
        guard item.isMovable else { return .visible }
        guard managementEnabled || layoutPending else { return .visible }
        let saved = preferences.section(for: item.id, fallback: .visible)
        // The aggregate popup is a logical view of the user's saved groups.
        // Physical status windows can briefly cross a divider while AppKit
        // reflows the menu bar; rendering that transient geometry here adds an
        // unrelated icon to the popup or drops one the user explicitly stored.
        if preferences.mode == .aggregate { return saved }
        // While a layout is staged, its saved groups are the editor's source of
        // truth. After the layout has been applied, render the actual physical
        // section first so an offscreen item cannot appear back in Visible just
        // because its saved identity changed during a scanner refresh.
        if layoutPending || item.windowID == nil { return saved }
        return classifyFrame?(item.frame) ?? item.observedSection ?? saved
    }

    func sortedItems(in section: ItemSection) -> [MenuItem] {
        items.filter { self.section($0) == section }.sorted {
            return order($0.id) < order($1.id)
        }
    }

    /// The tray normally mirrors saved Hidden items. A saved Visible host may
    /// still be physically parked behind a divider when a new app appears. The
    /// engine adds that exact host here while placement repair is pending or
    /// unresolved; the editor and saved rules continue to say Visible.
    func trayItems(in section: ItemSection) -> [MenuItem] {
        let grouped = sortedItems(in: section).filter { !temporarilyVisible.contains($0.id) }
        guard section == .hidden, preferences.mode == .aggregate,
              managementEnabled, !layoutPending else { return grouped }
        let stranded = items.filter { item in
            guard item.isMovable, !temporarilyVisible.contains(item.id),
                  let host = visibleFallbackHosts[item.id],
                  item.windowID == host.windowID, item.windowOwnerPID == host.ownerPID,
                  preferences.rules.first(where: { $0.id == item.id })?.section == .visible else { return false }
            let physical = item.observedSection ?? item.verifiedFrame.flatMap { classifyFrame?($0) }
            return physical != .visible || isMenuItemReachable?(item) == false
        }.sorted { order($0.id) < order($1.id) }
        return grouped + stranded
    }

    func markVisibleFallback(id: String, windowID: CGWindowID, ownerPID: pid_t) {
        guard managementEnabled, !layoutPending, preferences.mode == .aggregate,
              preferences.rules.first(where: { $0.id == id })?.section == .visible else { return }
        let host = VisibleFallbackHost(windowID: windowID, ownerPID: ownerPID)
        guard visibleFallbackHosts[id] != host else { return }
        visibleFallbackHosts[id] = host
        trace("TRAY visible fallback id=\(id) window=\(windowID) owner=\(ownerPID)")
    }

    func clearVisibleFallback(id: String) {
        guard visibleFallbackHosts.removeValue(forKey: id) != nil else { return }
        trace("TRAY visible fallback cleared id=\(id)")
    }

    private func pruneVisibleFallbackHosts() {
        let active = visibleFallbackHosts.filter { id, host in
            // A host can disappear for a single reflow scan. Keep the marker
            // until a replacement or a verified Visible position disproves it.
            guard let item = items.first(where: { $0.id == id }) else { return true }
            guard item.isMovable,
                  item.windowID == host.windowID, item.windowOwnerPID == host.ownerPID,
                  preferences.rules.first(where: { $0.id == id })?.section == .visible else { return false }
            let physical = item.observedSection ?? item.verifiedFrame.flatMap { classifyFrame?($0) }
            return physical != .visible || isMenuItemReachable?(item) == false
        }
        if active != visibleFallbackHosts { visibleFallbackHosts = active }
    }

    private func order(_ id: String) -> Int { preferences.rules.first { $0.id == id }?.order ?? 10000 }

    func checkPermissions() {
        accessibilityGranted = CGPreflightPostEventAccess()
        let recordingGranted = CGPreflightScreenCaptureAccess()
        if !recordingGranted && (!didCheckScreenRecording || screenRecordingGranted) {
            do { try iconCapture.clearCache() }
            catch { self.error = L10n.format("图标缓存清除失败：%@", error.localizedDescription) }
            snapshotCache.clear()
            if items.contains(where: { $0.captureNeedsDarkBackground != nil }) {
                items = items.map { old in
                    var item = old
                    if item.captureNeedsDarkBackground != nil {
                        item.menuImage = nil
                        item.captureNeedsDarkBackground = nil
                    }
                    return item
                }
            }
        }
        screenRecordingGranted = recordingGranted
        didCheckScreenRecording = true
        loginEnabled = SMAppService.mainApp.status == .enabled
        let managers: Set<String> = ["cn.better365.iBar", "cn.better365.iBarPro", "com.surteesstudios.Bartender", "com.surteesstudios.Bartender5", "com.jordanbaird.Ice", "com.dwarvesv.minimalbar"]
        conflicts = NSWorkspace.shared.runningApplications.filter { managers.contains($0.bundleIdentifier ?? "") }.compactMap(\.localizedName)
        if managementEnabled && !accessibilityGranted { setManagement(false) }
    }

    func requestAccessibility() {
        accessibilityGranted = CGRequestPostEventAccess()
        openPrivacy("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        screenRecordingGranted = CGRequestScreenCaptureAccess()
        if !screenRecordingGranted { openPrivacy("Privacy_ScreenCapture") }
        notice = L10n.tr("授权后点击“重新检查”。如果系统要求，请退出并重新打开 Qbar。")
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func setManagement(_ enabled: Bool) {
        if enabled {
            checkPermissions()
            guard accessibilityGranted else { selectedPage = .permissions; error = L10n.tr("请先在系统设置中允许 Qbar 使用辅助功能。"); return }
            guard conflicts.isEmpty else { error = L10n.format("请先退出 %@，然后点击“重新检查”。", conflicts.joined(separator: L10n.tr("、"))); return }
        }
        managementEnabled = enabled
        if !enabled {
            snapshotCache.clear()
            lastMenuHosts.removeAll()
            visibleFallbackHosts.removeAll()
        }
        defaults.set(enabled, forKey: "managementEnabled")
        refreshGeneration &+= 1
        refreshQueued = true
        onManagementChanged?(enabled)
    }

    func restoreManagementIfAllowed() {
        if defaults.bool(forKey: "managementEnabled") && accessibilityGranted && conflicts.isEmpty { setManagement(true) }
    }

    func refresh() {
        refreshGeneration &+= 1
        refreshQueued = true
        startRefreshIfNeeded()
    }

    /// Let the current scan finish, then leave a quiet interval for one saved
    /// host repair. Discovery can otherwise keep refreshIcons running across
    /// every queue retry and prevent the verified move from ever starting.
    func setHostRepairWaiting(_ waiting: Bool) {
        guard hostRepairWaiting != waiting else { return }
        hostRepairWaiting = waiting
        if !waiting { startRefreshIfNeeded() }
    }

    private func startRefreshIfNeeded() {
        guard refreshQueued, !isRefreshing, !isMoving, !hostRepairWaiting else { return }
        refreshQueued = false
        isRefreshing = true
        checkPermissions()
        let generation = refreshGeneration
        let granted = accessibilityGranted && !BuildChannel.isAppStore
        refreshTask = Task {
            defer {
                self.isRefreshing = false
                self.onRefreshSettled?()
                self.startRefreshIfNeeded()
            }
            let discovered = await self.scanMenuItems(granted).filter { !MenuItemPlacement.isExcluded(id: $0.id) }
            guard !Task.isCancelled, generation == self.refreshGeneration, !self.isMoving else { return }
            let scannedNames = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0.name) })
            self.acceptMovementSnapshot(discovered)
            let displayItems = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0) })
            #if DEBUG
            let diagnostics: [[String: Any]] = discovered.map {
                ["id": $0.id, "name": $0.name, "pid": $0.pid, "window": $0.windowID ?? 0,
                 "x": $0.frame.minX, "y": $0.frame.minY, "w": $0.frame.width, "h": $0.frame.height,
                 "ax": $0.element != nil, "axFrame": $0.element.flatMap { AXAccess.frame($0)?.debugDescription } ?? "nil",
                 "actualSection": ($0.observedSection ?? $0.verifiedFrame.flatMap { self.classifyFrame?($0) })?.rawValue ?? "unknown"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.storageURL.deletingLastPathComponent().appendingPathComponent("debug-items.json"), options: .atomic)
            }
            if let data = try? JSONSerialization.data(withJSONObject: self.debugStatus?() ?? [:], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.storageURL.deletingLastPathComponent().appendingPathComponent("debug-status.json"), options: .atomic)
            }
            #endif
            // Stable saved rules survive application restarts and temporarily missing items.
            var prefs = self.preferences
            var newRuntimeItems: [MenuItem] = []
            for (index, item) in self.items.enumerated()
                where (self.accessibilityGranted || self.screenRecordingGranted) &&
                !MenuItemPlacement.isTransientRule(id: item.id, bundleID: item.bundleID) &&
                !prefs.rules.contains(where: { $0.id == item.id }) {
                // Once management is running, a new app should begin in Visible.
                // The parked dividers can make macOS create its first status host
                // in Always Hidden; that position is not the user's saved choice.
                let isNewRuntimeItem = self.hasScanned && self.managementEnabled && item.isMovable
                let initialSection: ItemSection = isNewRuntimeItem || item.windowID == nil
                    ? .visible
                    : (self.classifyFrame?(item.frame) ?? item.observedSection ?? .visible)
                let automaticName = displayItems[item.id]?.sourceName ?? item.name
                prefs.rules.append(.init(id: item.id, name: automaticName, bundleID: item.bundleID,
                                        section: item.isMovable ? initialSection : .visible, order: index))
                if isNewRuntimeItem { newRuntimeItems.append(item) }
            }
            // Rule names are automatic metadata, so refresh them even while a
            // layout is staged. Preserve real aliases while removing old live
            // labels that were mirrored into both automatic and alias fields.
            for item in self.items {
                if let index = prefs.rules.firstIndex(where: { $0.id == item.id }) {
                    let automaticName = item.sourceName ?? item.name
                    if let alias = prefs.rules[index].alias,
                       alias != automaticName,
                       alias == prefs.rules[index].name || scannedNames[item.id] == alias {
                        prefs.rules[index].alias = nil
                    }
                    prefs.rules[index].name = automaticName
                    prefs.rules[index].bundleID = item.bundleID
                }
            }
            // Older scans and imported files can contain impossible rules for fixed system items.
            for item in self.items where !item.isMovable {
                if let index = prefs.rules.firstIndex(where: { $0.id == item.id }) {
                    prefs.rules[index].section = .visible
                }
            }
            // Saved groups are authoritative while management is active. A
            // status item can briefly cross a divider or lose its CGWindow as
            // AppKit reflows the bar; writing that transient geometry back here
            // corrupts the user's layout. Explicit moves and imports update the
            // rules, while “取消待应用布局” remains the deliberate way to adopt
            // the current physical arrangement.
            if prefs != self.preferences { self.preferences = prefs }
            if !self.layoutPending, NSEvent.pressedMouseButtons == 0 {
                for item in newRuntimeItems {
                    guard let windowID = item.windowID, let ownerPID = item.windowOwnerPID,
                          item.observedSection != .visible,
                          let rule = self.preferences.rules.first(where: { $0.id == item.id }) else { continue }
                    self.trace("HOST new rule id=\(item.id) window=\(windowID) " +
                               "observed=\(item.observedSection?.rawValue ?? "unknown")")
                    self.onHostReplacement?(MenuHostReplacement(
                        id: item.id, bundleID: item.bundleID, pid: item.pid,
                        ownerPID: ownerPID, oldWindowID: nil, newWindowID: windowID,
                        savedSection: rule.section, savedOrder: rule.order,
                        rightNeighbours: []
                    ))
                }
            }
            // Capture before inserting folding spacers on startup. Off-screen status
            // windows may stop drawing, so their last visible image must be retained.
            await self.refreshIcons()
            if !self.hasScanned { self.hasScanned = true; self.onInitialScanCompleted?() }
        }
    }

    /// Adopts measured metadata while the engine has the lane unfolded. A
    /// normal refresh is paused during moves, so the engine calls this before
    /// capturing to bind pixels to the fresh AX identity rather than an older
    /// anonymous Control Center host.
    func acceptMovementSnapshot(_ discovered: [MenuItem]) {
        let measured = discovered.filter { !MenuItemPlacement.isExcluded(id: $0.id) }
        let processes = NSWorkspace.shared.runningApplications.reduce(into: [pid_t: MenuItemSnapshotCache.ProcessInstance]()) { result, app in
            guard !app.isTerminated else { return }
            var process = proc_bsdinfo()
            let read = proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &process,
                                    Int32(MemoryLayout<proc_bsdinfo>.stride))
            result[app.processIdentifier] = MenuItemSnapshotCache.ProcessInstance.resolved(
                bundleID: app.bundleIdentifier, launchDate: app.launchDate,
                birthSeconds: read > 0 ? process.pbi_start_tvsec : 0,
                birthMicroseconds: read > 0 ? process.pbi_start_tvusec : 0
            )
        }
        let active = snapshotCache.reconcile(measured, previous: items, processes: processes)
        let oldItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (raw, retained) in zip(measured, active) where raw.id != retained.id {
            let window = raw.windowID.map(String.init) ?? "nil"
            let owner = raw.windowOwnerPID.map(String.init) ?? "nil"
            trace("ICON preserve original=\(retained.id) raw=\(raw.id) window=\(window) owner=\(owner)")
        }
        items = active.map { item in
            var item = item
            let automaticName = item.isSystem
                ? item.name
                : (MenuItem.applicationName(pid: item.pid, bundleID: item.bundleID) ?? item.name)
            let rule = preferences.rules.first(where: { $0.id == item.id })
            let alias = rule?.alias.flatMap { saved -> String? in
                let mirrorsSavedName = rule.map { $0.name == saved } ?? false
                return saved != automaticName && (mirrorsSavedName || saved == item.name) ? nil : saved
            }
            item.sourceName = automaticName
            item.name = alias ?? automaticName
            item.image = MenuItem.applicationIcon(pid: item.pid, bundleID: item.bundleID)

            let previous = oldItems[item.id]
            if previous?.menuImage != nil, item.menuImage == nil {
                trace("ICON reset id=\(item.id) oldPid=\(previous?.pid ?? -1) newPid=\(item.pid) " +
                      "oldWindow=\(previous?.windowID.map(String.init) ?? "nil") " +
                      "newWindow=\(item.windowID.map(String.init) ?? "nil") " +
                      "oldOwner=\(previous?.windowOwnerPID.map(String.init) ?? "nil") " +
                      "newOwner=\(item.windowOwnerPID.map(String.init) ?? "nil")")
            }
            // A verified current host may be offscreen before ScreenCaptureKit
            // can paint it. Restore its last native glyph from the same app
            // installation, then let a new live screenshot replace it.
            if item.menuImage == nil, screenRecordingGranted {
                let restored = iconCapture.restore(item)
                if restored.menuImage != nil {
                    trace("ICON disk-cache restored id=\(item.id) window=\(item.windowID ?? 0)")
                }
                item = restored
            }
            if item.menuImage == nil,
               active.filter({ $0.bundleID == item.bundleID }).count == 1 {
                item.menuImage = MenuItem.packagedStatusIcon(pid: item.pid, bundleID: item.bundleID)
            }
            return item
        }
        pruneVisibleFallbackHosts()
        // Keep the last identified host through a scan that temporarily omits
        // the item. Reflow can remove the old window before the new AX host is
        // ready; comparing only adjacent scans would miss that replacement.
        let ordered = items.sorted { $0.frame.minX < $1.frame.minX }
        for item in ordered {
            guard let windowID = item.windowID, let ownerPID = item.windowOwnerPID,
                  let process = processes[item.pid], let ownerProcess = processes[ownerPID] else { continue }
            let section = item.observedSection
            let rightNeighbours = ordered.filter {
                $0.id != item.id && $0.frame.minX > item.frame.minX &&
                    $0.observedSection == section && section != nil
            }.map(\.id)
            let old = lastMenuHosts[item.id]
            let sameProcess = old.map {
                $0.bundleID == item.bundleID && $0.pid == item.pid &&
                    $0.ownerPID == ownerPID && $0.process == process &&
                    $0.ownerProcess == ownerProcess
            } ?? false
            let changedWindow = old?.windowID != windowID
            let replaced = sameProcess && changedWindow
            let newlyPresent = oldItems[item.id] == nil && changedWindow
            let restarted = old != nil && !sameProcess
            if let rule = preferences.rules.first(where: { $0.id == item.id }),
               rule.bundleID == item.bundleID,
               ((replaced && old?.section == rule.section) || newlyPresent || restarted),
               item.isMovable, managementEnabled, hasScanned,
               !isMoving, !layoutPending, NSEvent.pressedMouseButtons == 0 {
                trace("HOST appeared id=\(item.id) old=\(old.map { String($0.windowID) } ?? "none") " +
                      "new=\(windowID) saved=\(rule.section) observed=\(section?.rawValue ?? "unknown")")
                onHostReplacement?(MenuHostReplacement(
                    id: item.id, bundleID: item.bundleID, pid: item.pid,
                    ownerPID: ownerPID, oldWindowID: replaced ? old?.windowID : nil,
                    newWindowID: windowID, savedSection: rule.section,
                    savedOrder: rule.order,
                    rightNeighbours: replaced ? (old?.rightNeighbours ?? []) : []
                ))
            }
            lastMenuHosts[item.id] = LastMenuHost(
                bundleID: item.bundleID, pid: item.pid, ownerPID: ownerPID,
                windowID: windowID, process: process, ownerProcess: ownerProcess,
                section: section, rightNeighbours: rightNeighbours
            )
        }
    }

    func refreshIcons(duringMovement: Bool = false, force: Bool = false) async {
        if let captureMenuIcons { await captureMenuIcons(self) }
        else { await iconCapture.refresh(self, duringMovement: duringMovement, force: force) }
    }

    func rename(_ id: String, to name: String) {
        guard let index = preferences.rules.firstIndex(where: { $0.id == id }) else { return }
        let alias = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        preferences.rules[index].alias = alias.isEmpty ? nil : alias
        updateDisplayNames()
        refresh()
    }

    var canApplyLayout: Bool { !isMoving && !items.isEmpty }

    func requestApplyLayout() {
        guard canApplyLayout else { return }
        // Preserve staged groups while enabling dividers triggers a fresh scan.
        layoutPending = true
        repairFixedItemRules()
        error = nil
        notice = nil
        if !managementEnabled { setManagement(true) }
        guard managementEnabled else { return }
        onApplyLayout?()
    }

    func repairFixedItemRules() {
        var corrected = preferences
        for item in items where !item.isMovable {
            if let index = corrected.rules.firstIndex(where: { $0.id == item.id }) {
                corrected.rules[index].section = .visible
            }
        }
        if corrected != preferences { preferences = corrected }
    }

    func move(_ id: String, to section: ItemSection, before: String? = nil) {
        guard !isMoving, id != before, let item = items.first(where: { $0.id == id }) else { return }
        guard item.isMovable else { error = L10n.tr("macOS 固定的系统图标不能移动。"); return }
        if managementEnabled { onMove?(id, section, before) }
        else {
            preferences.move(id, to: section, before: before)
            layoutPending = true
            notice = L10n.tr("布局已保存。点击“应用布局”即可开启管理并使其生效。")
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                notice = L10n.tr("请在系统设置的“登录项”中允许 Qbar。")
            }
        } catch { self.error = L10n.format("无法修改开机启动：%@", error.localizedDescription) }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if unreadableConfigurationNeedsBackup {
                // Preserve a corrupt or newer-version configuration before any
                // edit can replace it with defaults. Keep refusing to overwrite
                // the original if creating the recovery copy fails.
                let backup = storageURL.deletingLastPathComponent()
                    .appendingPathComponent("preferences-recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: storageURL, to: backup)
                unreadableConfigurationNeedsBackup = false
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ConfigurationFile(preferences: preferences)).write(to: storageURL, options: .atomic)
        } catch { self.error = L10n.format("设置保存失败：%@", error.localizedDescription) }
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Qbar-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ConfigurationFile(preferences: preferences)).write(to: url, options: .atomic)
            notice = L10n.tr("配置已导出。")
        } catch { self.error = error.localizedDescription }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? Int ?? 0) <= 1_048_576 else { throw ConfigurationError.tooLarge }
            try applyImportedConfiguration(Data(contentsOf: url))
            notice = L10n.tr("配置已导入。布局需点击“应用布局”，系统间距需单独应用。")
        } catch { self.error = L10n.format("导入失败：%@", error.localizedDescription) }
    }

    func resetPreferences() {
        setManagement(false)
        do { try iconCapture.clearCache() }
        catch { self.error = L10n.format("图标缓存清除失败：%@", error.localizedDescription) }
        snapshotCache.clear()
        preferences = Preferences()
        layoutPending = false
        notice = L10n.tr("应用设置已重置。系统间距和登录项可在对应页面单独恢复。")
        refresh()
    }

    func discardPendingLayout() {
        var actual = preferences
        for (order, item) in items.enumerated() {
            if let index = actual.rules.firstIndex(where: { $0.id == item.id }) {
                actual.rules[index].section = managementEnabled
                    ? (item.observedSection ?? item.verifiedFrame.flatMap { classifyFrame?($0) } ?? .visible)
                    : .visible
                actual.rules[index].order = order
            }
        }
        preferences = actual
        layoutPending = false
        notice = L10n.tr("已取消待应用布局，列表重新显示菜单栏的实际位置。")
        refresh()
    }

    func applyImportedConfiguration(_ data: Data) throws {
        let imported = try ConfigurationFile.decode(data)
        layoutPending = true
        preferences = imported
        updateDisplayNames()
        refresh()
    }

    private func updateDisplayNames() {
        items = items.map { item in
            var item = item
            let automatic = item.sourceName ?? item.name
            item.sourceName = automatic
            item.name = preferences.rules.first(where: { $0.id == item.id })?.alias ?? automatic
            return item
        }
    }
}
