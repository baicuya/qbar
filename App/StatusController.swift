import AppKit
import SwiftUI
import QbarCore

/// AX failures leave that process's last successful sample intact. Only a
/// successful sample can report that its extras were removed or added.
struct MenuPresenceTracker {
    private(set) var baseline: [pid_t: Set<String>]?

    mutating func observe(_ snapshot: [pid_t: Set<String>], runningPIDs: Set<pid_t>) -> Bool {
        let current = snapshot.filter { runningPIDs.contains($0.key) }
        guard var previous = baseline else {
            baseline = current
            return false
        }
        previous = previous.filter { runningPIDs.contains($0.key) }
        var added = false
        for (pid, keys) in current {
            if !keys.subtracting(previous[pid] ?? []).isEmpty { added = true }
            previous[pid] = keys
        }
        baseline = previous
        return added
    }
}

@MainActor
final class StatusController: NSObject {
    static let preferredPositionLayoutVersion = 7

    private static let dividerRebuildDelay: TimeInterval = 0.08
    private static let dividerFrameSettleDelay: TimeInterval = 0.10
    private static let maximumNarrowDividerFramePolls = 20
    private static let maximumNarrowDividerAttempts = 6
    private static let maximumParkedDividerFramePolls = 20
    private static let requiredStableParkedFramePolls = 2
    private static let dividerDropInset: CGFloat = 4

    private static let mainAutosaveName = "Qbar.Main"
    private static let hiddenAutosaveName = "Qbar.Hidden"
    private static let alwaysHiddenAutosaveName = "Qbar.AlwaysHidden"
    private static let preferredPositionPrefix = "NSStatusItem Preferred Position "

    private unowned let model: AppModel
    private let mainItem: NSStatusItem
    private var hiddenDivider: NSStatusItem?
    private var alwaysDivider: NSStatusItem?
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var pointerInTrigger = false
    private var revealingForMove = false
    private var layoutBatchActive = false
    private var preservingMarkersForActivation = false
    private var movingTargetSection: ItemSection = .hidden
    private var narrowDividersReadyForMove = false
    private var narrowReadySnapshot: HostedDividerPair?
    private var narrowCandidateSnapshot: HostedDividerPair?
    private var requiredHiddenLaneWidth: Double = 0
    private var settledDividerSnapshot: ParkedDividerPair?
    private var parkedDividersReady = false
    private var discoveringNewItems = false
    private var showingAlways = false
    private var expandAfterLayoutApply = false
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var dividerRebuildWork: DispatchWorkItem?
    private var preferredPositionRestoreWork: DispatchWorkItem?
    private var mainAnchorRestoreWork: DispatchWorkItem?
    private var dividerLifecycleGeneration: UInt64 = 0
    private var dividerWorkRevision: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?
    private var discoveryGeneration: UInt64 = 0
    private var discoveryRequested = false
    private var appPopulationTimer: Timer?
    private var knownApplicationPIDs = Set<pid_t>()
    private var knownMenuHostIDs = Set<CGWindowID>()
    private var menuPresence = MenuPresenceTracker()
    private var presenceAuditTask: Task<Void, Never>?
    private var presenceAuditGeneration: UInt64 = 0
    private var lastPresenceAuditAt = Date()
    private var isStopped = false
    private var directMenuActionPending = false
    private var preservedPreferredPositions: [String: Double] = [:]
    private var staleDividerWindowIDs: [String: Set<CGWindowID>] = [:]
    private var dividerInstances: [String: DividerInstance] = [:]

    private struct DividerInstance {
        let objectID: ObjectIdentifier
        let lifecycleGeneration: UInt64
        var hostedWindowID: CGWindowID?
    }

    private struct HostedDivider {
        let objectID: ObjectIdentifier
        let lifecycleGeneration: UInt64
        let windowID: CGWindowID
        let frame: CGRect

        func hasSameHost(as other: HostedDivider) -> Bool {
            objectID == other.objectID &&
                lifecycleGeneration == other.lifecycleGeneration &&
                windowID == other.windowID
        }
    }

    private struct HostedDividerPair {
        let lifecycleGeneration: UInt64
        let always: HostedDivider
        let hidden: HostedDivider

        func hasSameHosts(as other: HostedDividerPair) -> Bool {
            lifecycleGeneration == other.lifecycleGeneration &&
                always.hasSameHost(as: other.always) &&
                hidden.hasSameHost(as: other.hidden)
        }

        func hasSameFrames(as other: HostedDividerPair) -> Bool {
            hasSameHosts(as: other) && always.frame == other.always.frame && hidden.frame == other.hidden.frame
        }
    }

    /// Parked dividers are deliberately stretched far beyond the visible menu
    /// bar. WindowServer may stop publishing those offscreen hosted windows,
    /// while AppKit still owns a valid current NSStatusItem window. Track the
    /// current objects and their AppKit-backed frames so parked settlement does
    /// not depend on an offscreen CGWindow remaining enumerable.
    private struct ParkedDividerPair {
        let lifecycleGeneration: UInt64
        let alwaysObjectID: ObjectIdentifier
        let hiddenObjectID: ObjectIdentifier
        let alwaysFrame: CGRect
        let hiddenFrame: CGRect

        func hasSameInstances(as other: ParkedDividerPair) -> Bool {
            lifecycleGeneration == other.lifecycleGeneration &&
                alwaysObjectID == other.alwaysObjectID &&
                hiddenObjectID == other.hiddenObjectID
        }

        func hasSameFrames(as other: ParkedDividerPair) -> Bool {
            hasSameInstances(as: other) &&
                alwaysFrame == other.alwaysFrame && hiddenFrame == other.hiddenFrame
        }
    }

    private struct NarrowDividerGeometry {
        let pair: HostedDividerPair
        let mainFrame: CGRect
        let safeArea: CGRect
        let alwaysDrop: CGPoint
        let hiddenDrop: CGPoint
        let visibleDrop: CGPoint
    }

    init(model: AppModel) {
        self.model = model
        Self.seedMissingPreferredPositions(in: .standard)
        Self.repairMainPreferredPosition(in: .standard)
        preservedPreferredPositions = Self.readPreferredPositions(in: .standard)
        mainItem = NSStatusBar.system.statusItem(withLength: 28)
        super.init()
        mainItem.autosaveName = Self.mainAutosaveName
        if let button = mainItem.button {
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Qbar")
        }
        configure()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event); return event }
        let workspace = NSWorkspace.shared.notificationCenter
        knownApplicationPIDs = Self.runningApplicationPIDs()
        knownMenuHostIDs = Self.menuHostIDs()
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applicationPopulationDidChange(forceDiscovery: true) }
        })
        for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isStopped else { return }
                    self.model.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.closePanel()
                self.restoreMainAnchorIfNeeded()
                self.configure()
                self.model.refresh()
            }
        })
        let populationTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applicationPopulationDidChange(forceDiscovery: false) }
        }
        RunLoop.main.add(populationTimer, forMode: .common)
        appPopulationTimer = populationTimer
    }

    func setEnabled(_ enabled: Bool) {
        guard !isStopped else { return }
        let wasRevealingForMove = revealingForMove
        cancelDividerRebuild()
        restoreMainAnchorIfNeeded()
        revealingForMove = false
        hideWork?.cancel(); hideWork = nil
        hoverWork?.cancel(); hoverWork = nil
        cancelDiscovery()
        cancelPresenceAudit()
        pointerInTrigger = false
        if enabled {
            restorePreferredPositions(named: Self.dividerAutosaveNames)
            if hiddenDivider == nil { hiddenDivider = makeDivider(Self.hiddenAutosaveName, label: L10n.tr("Qbar 收纳区分隔符")) }
            if alwaysDivider == nil { alwaysDivider = makeDivider(Self.alwaysHiddenAutosaveName, label: L10n.tr("Qbar 始终隐藏分隔符")) }
        } else {
            closePanel()
            showingAlways = false
            // A move owns a committed snapshot in preservedPreferredPositions.
            // Do not replace it with the temporary narrow-marker geometry when
            // management is switched off while that move is still unwinding.
            if !wasRevealingForMove {
                rememberPreferredPositions(named: Self.dividerAutosaveNames)
            }
            if let hiddenDivider { NSStatusBar.system.removeStatusItem(hiddenDivider) }
            if let alwaysDivider { NSStatusBar.system.removeStatusItem(alwaysDivider) }
            hiddenDivider = nil; alwaysDivider = nil
            restorePreferredPositions(named: Self.dividerAutosaveNames, afterRemoval: true)
        }
        model.isExpanded = false
        configure()
        refreshAfterLayout()
    }

    private func makeDivider(_ name: String, label: String) -> NSStatusItem {
        // A removed status-window can remain in WindowServer briefly under the
        // same autosave title. Remember it so frame reads bind to the new
        // NSStatusItem instance instead of that stale window.
        staleDividerWindowIDs[name] = Set(
            MenuScanner.windows(includeDividers: true)
                .filter { $0.title == name }
                .map(\.id)
        )
        let item = NSStatusBar.system.statusItem(withLength: 16)
        item.autosaveName = name
        if let button = item.button {
            button.setAccessibilityLabel(label)
            button.toolTip = L10n.format("%@ · 按住 ⌘ 拖动图标至此标记左侧", label)
            let view = DividerMark(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
        dividerInstances[name] = DividerInstance(
            objectID: ObjectIdentifier(item),
            lifecycleGeneration: dividerLifecycleGeneration,
            hostedWindowID: nil
        )
        return item
    }

    func configure() {
        let prefs = model.preferences
        hideWork?.cancel(); hideWork = nil
        if !prefs.hoverToShow { hoverWork?.cancel(); hoverWork = nil; pointerInTrigger = false }
        updateMainGlyph()
        guard !revealingForMove, !discoveringNewItems else { return }
        if model.managementEnabled, !(model.isExpanded && prefs.mode == .inline) {
            restoreDividersAfterDiscovery()
        }
        for divider in [hiddenDivider, alwaysDivider] {
            (divider?.button?.subviews.first as? DividerMark)?.visible = prefs.showDividers
        }
        let width = collapsedDividerLength
        let hiddenLength: CGFloat = model.isExpanded && prefs.mode == .inline ? 16 : width
        let alwaysLength: CGFloat = showingAlways ? 16 : width
        if hiddenDivider?.length != hiddenLength { hiddenDivider?.length = hiddenLength }
        if alwaysDivider?.length != alwaysLength { alwaysDivider?.length = alwaysLength }
        if model.managementEnabled, hiddenLength > 64, alwaysLength > 64,
           !parkedDividersReady, dividerRebuildWork == nil {
            scheduleParkedDividerSettlement()
        }
        let appearance: NSAppearance? = switch prefs.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        if panel?.isVisible == true {
            closePanel()
            if prefs.mode == .aggregate { showPanel(always: showingAlways) }
        } else if model.isExpanded && prefs.mode == .aggregate { showPanel(always: showingAlways) }
        scheduleHide()
    }

    func updateMainGlyph() {
        guard let button = mainItem.button else { return }
        // An old saved transparent choice is migrated on load; keep the status
        // item visible even if an in-memory preference bypasses that migration.
        let glyph = model.preferences.glyph == .transparent ? BarGlyph.capsule : model.preferences.glyph
        let image = glyph == .capsule ? QbarBrand.menuImage :
            (NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: "Qbar") ?? QbarBrand.menuImage)
        image.isTemplate = true
        button.image = image
        button.toolTip = L10n.format("Qbar（%@）· 点击展开，右键打开设置，⌥ 点击查看始终隐藏", glyph.title)
        button.needsDisplay = true
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { toggleAlways(); return }
        toggle()
    }

    func toggle() {
        model.trace("TRAY toggle enabled=\(model.managementEnabled) expanded=\(model.isExpanded) " +
                    "moving=\(model.isMoving) discovering=\(discoveringNewItems) " +
                    "pending=\(model.layoutPending) panel=\(panel?.isVisible == true)")
        if !model.managementEnabled {
            if model.layoutPending {
                expandAfterLayoutApply = true
                model.requestApplyLayout()
                if !model.managementEnabled {
                    expandAfterLayoutApply = false
                    model.onShowSettings?()
                }
            } else {
                model.setManagement(true)
                if model.managementEnabled { expand() }
                else { model.onShowSettings?() }
            }
            return
        }
        if model.isExpanded { collapse() } else { expand() }
    }

    func layoutApplicationFinished() {
        guard expandAfterLayoutApply else { return }
        expandAfterLayoutApply = false
        guard model.managementEnabled, !model.layoutPending, model.error == nil else {
            model.onShowSettings?()
            return
        }
        expand()
    }

    func expand() {
        guard model.managementEnabled, !model.isMoving, !discoveringNewItems else {
            model.trace("TRAY expand blocked enabled=\(model.managementEnabled) moving=\(model.isMoving) " +
                        "discovering=\(discoveringNewItems)")
            return
        }
        model.isExpanded = true
        showingAlways = false
        if model.preferences.mode == .aggregate { showPanel(always: false) }
        else { revealInline(always: false) }
        refreshAfterLayout()
        scheduleHide()
    }

    func toggleAlways() {
        guard model.managementEnabled, !model.isMoving, !revealingForMove,
              !discoveringNewItems else { return }
        if showingAlways { collapse(); return }
        showingAlways = true
        model.isExpanded = true
        if model.preferences.mode == .aggregate { showPanel(always: true) }
        else { revealInline(always: true) }
        scheduleHide()
    }

    func collapse() {
        model.trace("TRAY collapse expanded=\(model.isExpanded) panel=\(panel?.isVisible == true) " +
                    "moving=\(model.isMoving) revealing=\(revealingForMove)")
        guard !revealingForMove, !model.isMoving else { return }
        guard model.isExpanded || showingAlways || panel != nil else { return }
        hideWork?.cancel(); hoverWork?.cancel()
        showingAlways = false
        model.isExpanded = false
        closePanel()
        restoreDividersAfterDiscovery()
        configure()
    }

    func closePanel() { panel?.orderOut(nil); panel = nil }

    private func showPanel(always: Bool) {
        model.trace("TRAY showPanel always=\(always) count=\(model.trayItems(in: always ? .alwaysHidden : .hidden).count)")
        closePanel()
        let iconHeight = max(18, min(30, model.preferences.panelIconSize))
        let iconSnapshots = model.trayItems(in: always ? .alwaysHidden : .hidden).reduce(into: [String: TrayIconSnapshot]()) { result, item in
            result[item.id] = TrayReplicaImage.snapshot(for: item, height: iconHeight)
        }
        let pointer = NSEvent.mouseLocation
        let statusPoint = dividerFrame(mainItem).map { frame in
            let cocoa = Coordinates.cocoa(frame)
            return CGPoint(x: cocoa.midX, y: cocoa.midY)
        }
        let screen = model.preferences.panelAnchor == .statusItem
            ? Coordinates.screen(at: statusPoint ?? pointer)
            : Coordinates.screen(at: pointer)
        let size = trayPanelSize(always: always, screen: screen, iconSnapshots: iconSnapshots)
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let content = TrayPanelContentView(model: model, always: always, iconSnapshots: iconSnapshots,
                                           onClose: { [weak self] in self?.collapse() })
        panel.contentView = content
        let anchor: CGFloat
        switch model.preferences.panelAnchor {
        case .pointer: anchor = pointer.x
        case .screenRight: anchor = screen.visibleFrame.maxX - 16
        case .statusItem: anchor = statusPoint?.x ?? screen.visibleFrame.maxX - 16
        }
        panel.setFrameOrigin(trayPanelOrigin(size: size, anchor: anchor, screen: screen))
        self.panel = panel
        panel.onCancel = { [weak self] in self?.collapse() }
        content.onMetricsChanged = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel, panel.isVisible else { return }
            self.resizeTrayPanel(panel, always: always, anchor: anchor, screen: screen,
                                 iconSnapshots: iconSnapshots)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func trayPanelSize(always: Bool, screen: NSScreen,
                               iconSnapshots: [String: TrayIconSnapshot]) -> CGSize {
        let items = model.trayItems(in: always ? .alwaysHidden : .hidden).filter { !model.temporarilyVisible.contains($0.id) }
        let iconHeight = max(18, min(30, model.preferences.panelIconSize))
        let itemWidth = items.reduce(CGFloat.zero) { partial, item in
            partial + (iconSnapshots[item.id]?.displaySize ?? TrayReplicaImage.displaySize(for: item, height: iconHeight)).width
        }
        let width = min(items.isEmpty ? 150 : 32 + itemWidth + CGFloat(max(0, items.count - 1)) * TrayMetrics.iconSpacing,
                        max(100, screen.visibleFrame.width - 24))
        return CGSize(width: width, height: items.isEmpty ? 64 : iconHeight + 20)
    }

    private func trayPanelOrigin(size: CGSize, anchor: CGFloat, screen: NSScreen) -> CGPoint {
        let x = min(max(anchor - size.width / 2, screen.visibleFrame.minX + 12),
                    screen.visibleFrame.maxX - size.width - 12)
        // visibleFrame excludes the menu bar and the camera housing on notched screens.
        return CGPoint(x: x, y: screen.visibleFrame.maxY - size.height - 8)
    }

    private func resizeTrayPanel(_ panel: NSPanel, always: Bool, anchor: CGFloat, screen: NSScreen,
                                 iconSnapshots: [String: TrayIconSnapshot]) {
        let size = trayPanelSize(always: always, screen: screen, iconSnapshots: iconSnapshots)
        let frame = CGRect(origin: trayPanelOrigin(size: size, anchor: anchor, screen: screen), size: size)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func classify(_ frame: CGRect) -> ItemSection {
        guard let hidden = dividerFrame(hiddenDivider), let always = dividerFrame(alwaysDivider) else { return .visible }
        // Screen order is: always-hidden items, Always marker, hidden items,
        // Hidden marker, visible items.  Compare the complete item bounds so
        // an item overlapping a marker while AppKit is reflowing is never
        // mistaken for a neighbouring section.
        if frame.maxX <= always.minX + 1 { return .alwaysHidden }
        if frame.minX >= always.maxX - 1, frame.maxX <= hidden.minX + 1 { return .hidden }
        if frame.minX >= hidden.maxX - 1 { return .visible }

        // During the short reflow between narrow and parked dividers, keep a
        // deterministic answer without assigning an item to the farther lane.
        return frame.midX < hidden.midX ? .hidden : .visible
    }

    func placementBoundaries() -> (always: CGRect, hidden: CGRect)? {
        guard model.managementEnabled,
              let always = dividerFrame(alwaysDivider),
              let hidden = dividerFrame(hiddenDivider),
              always.maxX <= hidden.minX + 1,
              abs(always.midY - hidden.midY) < 8 else { return nil }
        return (always, hidden)
    }

    func destination(for section: ItemSection) -> CGPoint? {
        if revealingForMove {
            guard hasSafeMovingDestinations(), let geometry = narrowDividerGeometry() else { return nil }
            switch section {
            case .visible: return geometry.visibleDrop
            case .hidden: return geometry.hiddenDrop
            case .alwaysHidden: return geometry.alwaysDrop
            }
        }
        switch section {
        case .visible:
            guard let hidden = dividerFrame(hiddenDivider) else { return nil }
            return CGPoint(x: hidden.maxX + Self.dividerDropInset, y: hidden.midY)
        case .hidden:
            guard let always = dividerFrame(alwaysDivider), let hidden = dividerFrame(hiddenDivider),
                  let point = hiddenLaneDropPoint(always: always, hidden: hidden) else { return nil }
            return point
        case .alwaysHidden:
            guard let always = dividerFrame(alwaysDivider) else { return nil }
            return CGPoint(x: always.minX - Self.dividerDropInset, y: always.midY)
        }
    }

    private func dividerFrame(_ item: NSStatusItem?, requireHostedWindow: Bool = false) -> CGRect? {
        guard let item else { return nil }
        let windows = MenuScanner.windows(includeDividers: true)
        if requireHostedWindow {
            return exactHostedDivider(item, generation: dividerLifecycleGeneration, in: windows)?.frame
        }
        if let window = item.button?.window {
            let number = window.windowNumber
            if number > 0,
               let windowID = CGWindowID(exactly: number),
               let exact = windows.first(where: { $0.id == windowID }) {
                return exact.frame
            }
            if let name = item.autosaveName,
               let hosted = currentHostedDivider(named: name, in: windows) {
                return hosted.frame
            }
            // A same-title WindowServer entry can briefly outlive a removed
            // divider. Prefer the current AppKit instance over that stale frame.
            return Coordinates.quartz(window.frame)
        }
        if let name = item.autosaveName,
           let hosted = currentHostedDivider(named: name, in: windows) {
            return hosted.frame
        }
        return nil
    }

    private func exactHostedDivider(
        _ item: NSStatusItem,
        generation: UInt64,
        in windows: [MenuScanner.Window]
    ) -> HostedDivider? {
        guard let name = item.autosaveName,
              var instance = dividerInstances[name],
              instance.objectID == ObjectIdentifier(item),
              instance.lifecycleGeneration == generation,
              generation == dividerLifecycleGeneration else { return nil }

        let exact: MenuScanner.Window
        if let boundID = instance.hostedWindowID {
            // A hosted window binding is immutable for this divider instance.
            // This prevents a late WindowServer entry from an older instance
            // with the same autosave title from replacing the current host.
            guard let bound = windows.first(where: { $0.id == boundID && $0.title == name }) else { return nil }
            exact = bound
        } else if let window = item.button?.window,
                  window.windowNumber > 0,
                  let appKitWindowID = CGWindowID(exactly: window.windowNumber),
                  let appKitExact = windows.first(where: { $0.id == appKitWindowID && $0.title == name }) {
            exact = appKitExact
            instance.hostedWindowID = appKitWindowID
            dividerInstances[name] = instance
        } else {
            // On current macOS releases NSStatusItem can be rendered by a
            // Control Center host whose CGWindow ID differs from AppKit's
            // private NSWindow number. Bind once only when the title identifies
            // one newly-created, non-stale WindowServer entry.
            let stale = staleDividerWindowIDs[name] ?? []
            let candidates = windows.filter { $0.title == name && !stale.contains($0.id) }
            guard candidates.count == 1, let hosted = candidates.first else { return nil }
            exact = hosted
            instance.hostedWindowID = hosted.id
            dividerInstances[name] = instance
        }
        return HostedDivider(
            objectID: instance.objectID,
            lifecycleGeneration: generation,
            windowID: exact.id,
            frame: exact.frame
        )
    }

    private func currentHostedDividerPair(generation: UInt64? = nil) -> HostedDividerPair? {
        let generation = generation ?? dividerLifecycleGeneration
        guard generation == dividerLifecycleGeneration,
              let alwaysDivider, let hiddenDivider else { return nil }
        let windows = MenuScanner.windows(includeDividers: true)
        guard let always = exactHostedDivider(alwaysDivider, generation: generation, in: windows),
              let hidden = exactHostedDivider(hiddenDivider, generation: generation, in: windows) else { return nil }
        return HostedDividerPair(lifecycleGeneration: generation, always: always, hidden: hidden)
    }

    private func currentParkedDividerPair(generation: UInt64? = nil) -> ParkedDividerPair? {
        let generation = generation ?? dividerLifecycleGeneration
        guard generation == dividerLifecycleGeneration,
              let alwaysDivider, let hiddenDivider,
              let alwaysFrame = dividerFrame(alwaysDivider),
              let hiddenFrame = dividerFrame(hiddenDivider) else { return nil }
        return ParkedDividerPair(
            lifecycleGeneration: generation,
            alwaysObjectID: ObjectIdentifier(alwaysDivider),
            hiddenObjectID: ObjectIdentifier(hiddenDivider),
            alwaysFrame: alwaysFrame,
            hiddenFrame: hiddenFrame
        )
    }

    private func hiddenLaneDropPoint(always: CGRect, hidden: CGRect) -> CGPoint? {
        let left = always.maxX + Self.dividerDropInset
        let right = hidden.minX - Self.dividerDropInset
        guard left <= right else { return nil }
        // Aim immediately inside the hidden lane next to its right boundary.
        // This is unambiguous even when the dragged item approaches from the
        // Always Hidden side of the menu bar.
        return CGPoint(x: right, y: (always.midY + hidden.midY) / 2)
    }

    private func currentHostedDivider(named name: String, in windows: [MenuScanner.Window]) -> MenuScanner.Window? {
        let stale = staleDividerWindowIDs[name] ?? []
        let candidates = windows.filter { $0.title == name && !stale.contains($0.id) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func mainItemScreen(frame: CGRect? = nil) -> NSScreen? {
        let frame = frame ?? dividerFrame(mainItem)
        return frame.flatMap { mainFrame in
            let center = CGPoint(x: mainFrame.midX, y: mainFrame.midY)
            return NSScreen.screens.first { Coordinates.quartz($0.frame).contains(center) }
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func mainItemIsAnchored() -> Bool {
        guard let frame = dividerFrame(mainItem),
              let screen = mainItemScreen(frame: frame),
              Self.safeMainPreferredPosition(for: screen) != nil else { return false }
        let screenFrame = Coordinates.quartz(screen.frame)
        let safeArea: CGRect
        if screen.safeAreaInsets.top > 0 {
            guard let right = screen.auxiliaryTopRightArea, !right.isEmpty else { return false }
            safeArea = Coordinates.quartz(right)
        } else {
            safeArea = screenFrame
        }
        // Preferred-position values determine ordering, not an exact pixel
        // coordinate: neighbouring status items can legitimately shift this
        // frame. Keep Main in the trailing portion of the safe menu-bar lane.
        let trailingThreshold = safeArea.minX + safeArea.width * 0.42
        let followsHidden = dividerFrame(hiddenDivider).map { frame.minX >= $0.maxX - 1 } ?? true
        return followsHidden && frame.midX >= trailingThreshold && frame.midX <= safeArea.maxX
    }

    /// Restores Qbar's own status item without removing it or touching either
    /// lane divider. Reassigning the autosave name makes AppKit reread the safe
    /// preferred position for the existing item.
    private func restoreMainAnchorIfNeeded() {
        guard let screen = mainItemScreen(),
              let preferred = Self.safeMainPreferredPosition(for: screen) else { return }
        preservedPreferredPositions[Self.mainAutosaveName] = preferred
        Self.writePreferredPositions([Self.mainAutosaveName: preferred], to: .standard)
        guard !mainItemIsAnchored() else { return }

        mainAnchorRestoreWork?.cancel()
        mainItem.autosaveName = nil
        Self.writePreferredPositions([Self.mainAutosaveName: preferred], to: .standard)
        mainItem.autosaveName = Self.mainAutosaveName
        model.trace("MAIN ANCHOR restoring preferred=\(preferred)")

        // AppKit may persist the pre-reflow coordinate on the following turn.
        // Rewrite only Qbar.Main after that bookkeeping has completed.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.mainAnchorRestoreWork = nil
            guard let screen = self.mainItemScreen(),
                  let latest = Self.safeMainPreferredPosition(for: screen) else { return }
            self.preservedPreferredPositions[Self.mainAutosaveName] = latest
            Self.writePreferredPositions([Self.mainAutosaveName: latest], to: .standard)
        }
        mainAnchorRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func diagnostics() -> [String: String] {
        var result: [String: String] = [:]
        for (name, item) in [("main", mainItem), ("hidden", hiddenDivider), ("always", alwaysDivider)] {
            result[name] = "length=\(item?.length ?? -1), frame=\(item?.button?.window?.frame.debugDescription ?? "nil"), button=\(item?.button?.frame.debugDescription ?? "nil")"
        }
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            let name = entry[kCGWindowName as String] as? String ?? ""
            if name.hasPrefix("Qbar.") { result["window:" + name] = String(describing: entry) }
        }
        return result
    }

    func beginLayoutBatch() {
        layoutBatchActive = true
        closePanel()
    }

    func endLayoutBatch() { layoutBatchActive = false }

    func prepareTemporaryActivationMove() -> Bool {
        guard model.managementEnabled, !revealingForMove, !discoveringNewItems,
              let hiddenDivider, let alwaysDivider else { return false }
        cancelDividerRebuild()
        rebindCurrentDividerInstances()
        preservingMarkersForActivation = true
        revealingForMove = true
        hideWork?.cancel(); hoverWork?.cancel()
        closePanel()
        hiddenDivider.length = 16
        alwaysDivider.length = 16
        scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
            controller.verifyNarrowDividerPlacement(attempt: 1, framePoll: 1)
        }
        return true
    }

    func revealForMoving(targetSection: ItemSection, movingItemID: String) {
        movingTargetSection = targetSection
        if layoutBatchActive, revealingForMove {
            // All moves share the current marker instances. Recreating a
            // marker for every item changes the sibling order we are editing.
            // Each insertion can reflow them; remeasure before the next move,
            // including a newly selected section's own drop point.
            if hiddenDivider != nil, alwaysDivider != nil {
                narrowDividersReadyForMove = false
                narrowReadySnapshot = nil
                narrowCandidateSnapshot = nil
                scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
                    controller.verifyNarrowDividerPlacement(attempt: 1, framePoll: 1)
                }
            }
            return
        }
        // Resizing the same instances preserves every existing app's side of
        // each boundary. Recreating a divider also reorders unrelated apps.
        if prepareTemporaryActivationMove() { return }
        cancelDividerRebuild()
        restoreMainAnchorIfNeeded()
        revealingForMove = true
        let existingHidden = model.items.filter {
            $0.id != movingItemID && model.preferences.section(for: $0.id) == .hidden
        }
        let movingWidth = targetSection == .hidden
            ? model.items.first(where: { $0.id == movingItemID })?.frame.width ?? 0
            : 0
        // Preferred-position distance also includes AppKit's hosted-window
        // padding and inter-item reflow. Reserve the measured item widths plus
        // a modest fixed margin so wide text status items fit between markers.
        requiredHiddenLaneWidth = Double(existingHidden.reduce(movingWidth) { $0 + $1.frame.width }) +
            (targetSection == .hidden || !existingHidden.isEmpty ? 120 : 0)
        if discoveringNewItems {
            // Retry the interrupted discovery after the move has finished.
            cancelDiscovery()
            discoverNewMenuItems()
        }
        hideWork?.cancel(); hoverWork?.cancel()
        constrainDividerPositionsForMoving()
        // constrainDividerPositionsForMoving() has already captured the old
        // values and installed the normalized ones in preserved state. Reading
        // the still-hosted marker positions again here can overwrite those new
        // values with AppKit's stale pre-removal coordinates.
        removeDividers(hidden: true, always: true, rememberCurrentPositions: false)
        scheduleNarrowDividerRebuild(attempt: 1)
    }

    func hasSafeMovingDestinations() -> Bool {
        guard hasStableMovingBoundaries(),
              let geometry = narrowDividerGeometry() else { return false }
        return narrowDividerGeometryIsSafe(geometry)
    }

    func hasStableMovingBoundaries() -> Bool {
        guard revealingForMove, narrowDividersReadyForMove,
              let ready = narrowReadySnapshot,
              let current = currentHostedDividerPair(),
              ready.hasSameFrames(as: current) else { return false }
        return current.always.frame.maxX <= current.hidden.frame.minX + 1 &&
            abs(current.always.frame.midY - current.hidden.frame.midY) < 8
    }

    func movingBoundaryWindow(for section: ItemSection) -> MenuScanner.Window? {
        // Mouse-down itself reflows siblings. Resolve the current bound host
        // throughout that drag; the stable snapshot is only a start barrier.
        guard model.managementEnabled, let pair = currentHostedDividerPair(),
              pair.always.frame.maxX <= pair.hidden.frame.minX + 1,
              abs(pair.always.frame.midY - pair.hidden.frame.midY) < 8 else { return nil }
        let boundary = section == .alwaysHidden ? pair.always : pair.hidden
        return MenuScanner.windows(includeDividers: true).first { $0.id == boundary.windowID }
    }

    /// True only after the current, post-move divider instances have appeared
    /// in WindowServer with stable frames. Callers can wait on this instead of
    /// guessing how long AppKit will take to rebuild a parked layout.
    func hasSettledDividers() -> Bool {
        guard model.managementEnabled, parkedDividersReady,
              let alwaysDivider, let hiddenDivider,
              alwaysDivider.length > 64, hiddenDivider.length > 64 else { return false }
        // Oversized parked dividers may have no enumerable offscreen host.
        // Their current instances and configured lengths remain authoritative.
        return true
    }

    func waitForSettledDividers(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasSettledDividers(), ContinuousClock.now < deadline {
            guard model.managementEnabled, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return hasSettledDividers()
    }

    func finishMoving(wasExpanded: Bool, commitLivePositions: Bool) {
        preservingMarkersForActivation = false
        if commitLivePositions {
            rememberLiveDividerPositions()
        }
        cancelDividerRebuild()
        rebindCurrentDividerInstances()
        model.isExpanded = model.managementEnabled && wasExpanded
        guard model.managementEnabled else {
            revealingForMove = false
            configure()
            refreshAfterLayout()
            return
        }
        // Keep the exact divider instances that participated in the move.
        // Removing and recreating a boundary before macOS has persisted an
        // application's new sibling order can place that application back on
        // the hidden side when the oversized parked divider returns.
        restoreMainAnchorIfNeeded()
        revealingForMove = false
        configure()
        scheduleParkedDividerSettlement()
    }

    private func rebindCurrentDividerInstances() {
        for (name, item) in [
            (Self.hiddenAutosaveName, hiddenDivider),
            (Self.alwaysHiddenAutosaveName, alwaysDivider)
        ] {
            guard let item else { continue }
            dividerInstances[name] = DividerInstance(
                objectID: ObjectIdentifier(item),
                lifecycleGeneration: dividerLifecycleGeneration,
                hostedWindowID: nil
            )
        }
    }

    private var collapsedDividerLength: CGFloat {
        max(10000, NSScreen.screens.reduce(0) { $0 + $1.frame.width } + 2000)
    }

    /// Refresh after launches so new hosted status items are discovered as soon
    /// as they exist. Keep both boundaries in place during these scans.
    private func discoverNewMenuItems() {
        guard !isStopped else { return }
        model.trace("DISCOVERY requested enabled=\(model.managementEnabled) moving=\(model.isMoving)")
        discoveryRequested = true
        guard discoveryTask == nil else { return }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishDiscovery(generation: generation) }

            while self.discoveryRequested {
                self.discoveryRequested = false
                guard await self.waitUntilDiscoveryIsAvailable() else {
                    if !Task.isCancelled { self.model.refresh() }
                    return
                }

                // Scan delayed hosts without unfolding either group. The engine
                // captures only new uncached icons through individual routing.
                for (attempt, delay) in [250, 500, 750, 1_000].enumerated() {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard await self.waitUntilDiscoveryIsAvailable() else { return }
                    if attempt == 0 || attempt == 3 {
                        await self.model.onDiscoverMenuItems?()
                        guard await self.waitUntilDiscoveryIsAvailable() else { return }
                    }
                    self.model.refresh()
                    while self.model.isRefreshing {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                }
            }
        }
    }

    private func waitUntilDiscoveryIsAvailable() async -> Bool {
        while model.isMoving || revealingForMove || nativeMenuIsOpen {
            guard !isStopped, model.managementEnabled, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
        }
        return !isStopped && model.managementEnabled && !Task.isCancelled
    }

    private var nativeMenuIsOpen: Bool {
        if directMenuActionPending || model.isInteractingWithMenu || !model.temporarilyVisible.isEmpty { return true }
        if RunLoop.main.currentMode == .eventTracking || Self.hasOpenSystemMenu() { return true }
        return model.items.contains { item in
            item.element.flatMap { AXAccess.value($0, kAXExpandedAttribute) as? Bool } == true
        }
    }

    private func finishDiscovery(generation: UInt64) {
        guard generation == discoveryGeneration else { return }
        // Narrowing and restoring the same markers can give an existing item
        // a fresh hosted window. Absorb the completed session's hosts so its
        // own reflow cannot trigger another discovery/warm cycle.
        knownMenuHostIDs = Self.menuHostIDs()
        discoveryTask = nil
        discoveryRequested = false
        discoveringNewItems = false
        if !isStopped { model.refresh() }
    }

    private func restoreDividersAfterDiscovery() {
        guard model.managementEnabled else { return }
        restorePreferredPositions(named: Self.dividerAutosaveNames)
        if hiddenDivider == nil {
            hiddenDivider = makeDivider(Self.hiddenAutosaveName, label: L10n.tr("Qbar 收纳区分隔符"))
        }
        if alwaysDivider == nil {
            alwaysDivider = makeDivider(Self.alwaysHiddenAutosaveName, label: L10n.tr("Qbar 始终隐藏分隔符"))
        }
    }

    private func cancelDividerRebuild() {
        dividerLifecycleGeneration &+= 1
        narrowDividersReadyForMove = false
        narrowReadySnapshot = nil
        narrowCandidateSnapshot = nil
        settledDividerSnapshot = nil
        parkedDividersReady = false
        dividerRebuildWork?.cancel()
        dividerRebuildWork = nil
        preferredPositionRestoreWork?.cancel()
        preferredPositionRestoreWork = nil
    }

    private func scheduleDividerRebuild(
        after delay: TimeInterval? = nil,
        _ action: @escaping (StatusController) -> Void
    ) {
        dividerRebuildWork?.cancel()
        dividerWorkRevision &+= 1
        let revision = dividerWorkRevision
        let generation = dividerLifecycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dividerLifecycleGeneration == generation,
                  self.dividerWorkRevision == revision else { return }
            self.dividerRebuildWork = nil
            action(self)
        }
        dividerRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Self.dividerRebuildDelay), execute: work)
    }

    private func scheduleNarrowDividerRebuild(attempt: Int) {
        scheduleDividerRebuild { controller in
            guard controller.model.managementEnabled, controller.revealingForMove else { return }
            // NSStatusBar caches an autosave position past removeStatusItem in
            // the same run-loop turn. Rewrite after the cache has drained, then
            // create fresh narrow marker instances at the constrained positions.
            controller.restorePreferredPositions(named: Self.dividerAutosaveNames)
            controller.restoreDividersAfterDiscovery()
            controller.hiddenDivider?.length = 16
            controller.alwaysDivider?.length = 16
            controller.scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { settled in
                settled.verifyNarrowDividerPlacement(attempt: attempt, framePoll: 1)
            }
        }
    }

    private func scheduleParkedDividerSettlement() {
        let generation = dividerLifecycleGeneration
        settledDividerSnapshot = nil
        parkedDividersReady = false
        scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
            controller.verifyParkedDividerSettlement(
                generation: generation,
                framePoll: 1,
                stablePolls: 0,
                previous: nil
            )
        }
    }

    private func verifyParkedDividerSettlement(
        generation: UInt64,
        framePoll: Int,
        stablePolls: Int,
        previous: ParkedDividerPair?
    ) {
        guard generation == dividerLifecycleGeneration,
              model.managementEnabled,
              !revealingForMove else { return }

        if !mainItemIsAnchored(), (framePoll == 1 || framePoll == 10) {
            restoreMainAnchorIfNeeded()
        }
        guard let current = currentParkedDividerPair(generation: generation),
              parkedDividerFramesMatchConfiguredLengths(current) else {
            if framePoll >= 3, mainItemIsAnchored(),
               let alwaysDivider, let hiddenDivider,
               alwaysDivider.length > 64, hiddenDivider.length > 64 {
                parkedDividersReady = true
                model.trace("MOVE DIVIDERS parked ready generation=\(generation) hosts=offscreen")
                refreshAfterLayout()
                return
            }
            model.trace(
                "MOVE DIVIDERS parked framePoll=\(framePoll) frames=unavailable " +
                "mainAnchored=\(mainItemIsAnchored())"
            )
            guard framePoll < Self.maximumParkedDividerFramePolls else {
                refreshAfterLayout()
                return
            }
            scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
                controller.verifyParkedDividerSettlement(
                    generation: generation,
                    framePoll: framePoll + 1,
                    stablePolls: 0,
                    previous: nil
                )
            }
            return
        }

        let nextStablePolls = previous?.hasSameFrames(as: current) == true ? stablePolls + 1 : 1
        if nextStablePolls >= Self.requiredStableParkedFramePolls, mainItemIsAnchored() {
            settledDividerSnapshot = current
            parkedDividersReady = true
            model.trace(
                "MOVE DIVIDERS parked ready generation=\(generation) " +
                "always=\(current.alwaysFrame.debugDescription) hidden=\(current.hiddenFrame.debugDescription)"
            )
            refreshAfterLayout()
            return
        }

        guard framePoll < Self.maximumParkedDividerFramePolls else {
            model.trace(
                "MOVE DIVIDERS parked unstable generation=\(generation) " +
                "always=\(current.alwaysFrame.debugDescription) hidden=\(current.hiddenFrame.debugDescription)"
            )
            refreshAfterLayout()
            return
        }
        scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
            controller.verifyParkedDividerSettlement(
                generation: generation,
                framePoll: framePoll + 1,
                stablePolls: nextStablePolls,
                previous: current
            )
        }
    }

    private func parkedDividerFramesMatchConfiguredLengths(_ pair: ParkedDividerPair) -> Bool {
        guard let alwaysDivider, let hiddenDivider else { return false }
        func hasExpectedWidth(_ frame: CGRect, for item: NSStatusItem) -> Bool {
            // AppKit adds window padding around a narrow status item and clips a
            // parked 10,000-point item to the available desktop width. The two
            // states still have a clear size boundary, so reject a stable narrow
            // frame while a parked resize has not reached WindowServer yet.
            let expectsParkedFrame = item.length > 64
            return expectsParkedFrame ? frame.width > 64 : frame.width <= 64
        }
        return hasExpectedWidth(pair.alwaysFrame, for: alwaysDivider) &&
            hasExpectedWidth(pair.hiddenFrame, for: hiddenDivider)
    }

    private func verifyNarrowDividerPlacement(attempt: Int, framePoll: Int) {
        guard model.managementEnabled, revealingForMove else { return }
        guard let geometry = narrowDividerGeometry(),
              geometry.pair.always.frame.width <= 64,
              geometry.pair.hidden.frame.width <= 64 else {
            model.trace("MOVE DIVIDERS narrow attempt=\(attempt) framePoll=\(framePoll) frames=unavailable")
            // A newly created NSStatusItem does not receive its hosted window in
            // the same run-loop turn. Keep this instance alive while AppKit lays
            // it out; removing it here restarts the wait indefinitely.
            if framePoll < Self.maximumNarrowDividerFramePolls {
                scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
                    controller.verifyNarrowDividerPlacement(attempt: attempt, framePoll: framePoll + 1)
                }
            } else {
                retryNarrowDividerPlacement(after: attempt)
            }
            return
        }

        let pair = geometry.pair

        // AppKit briefly publishes several clipped hosted-window sizes while a
        // status item is being attached (for example 16, 20, 24, then 32 pt).
        // Those transition frames must not drive preferred-position repairs:
        // rebuilding from one simply starts the same animation again.  Wait for
        // the current instances and their complete frames to be unchanged for
        // two consecutive polls before evaluating or translating the lane.
        guard narrowCandidateSnapshot?.hasSameFrames(as: pair) == true else {
            narrowCandidateSnapshot = pair
            if framePoll < Self.maximumNarrowDividerFramePolls {
                scheduleDividerRebuild(after: Self.dividerFrameSettleDelay) { controller in
                    controller.verifyNarrowDividerPlacement(attempt: attempt, framePoll: framePoll + 1)
                }
            } else {
                retryNarrowDividerPlacement(after: attempt)
            }
            return
        }

        // Window routing addresses each exact host even if the notch covers
        // it. Keep these instances and their sibling order throughout a batch;
        // only a physical pointer drag requires a drop in the visible safe area.
        let ordered = pair.always.frame.maxX <= pair.hidden.frame.minX + 1
        let sameRow = abs(pair.always.frame.midY - pair.hidden.frame.midY) < 8
        if ordered, sameRow {
            narrowDividersReadyForMove = true
            narrowReadySnapshot = pair
            narrowCandidateSnapshot = nil
            model.trace(
                "MOVE DIVIDERS narrow attempt=\(attempt) stable " +
                "covered=\(!narrowDividerGeometryIsSafe(geometry)) " +
                "always=\(pair.always.frame.debugDescription) hidden=\(pair.hidden.frame.debugDescription)"
            )
            return
        }
        narrowCandidateSnapshot = nil
        model.trace("MOVE DIVIDERS narrow attempt=\(attempt) invalid boundary order")
        retryNarrowDividerPlacement(after: attempt)
    }

    private func retryNarrowDividerPlacement(after attempt: Int) {
        guard !preservingMarkersForActivation else { return }
        guard attempt < Self.maximumNarrowDividerAttempts,
              model.managementEnabled, revealingForMove else { return }
        removeDividers(hidden: true, always: true, rememberCurrentPositions: false)
        scheduleNarrowDividerRebuild(attempt: attempt + 1)
    }

    private func narrowDividerGeometry(pair suppliedPair: HostedDividerPair? = nil) -> NarrowDividerGeometry? {
        guard let pair = suppliedPair ?? currentHostedDividerPair(),
              let mainFrame = dividerFrame(mainItem) else { return nil }
        let always = pair.always.frame
        let hidden = pair.hidden.frame
        let mainPoint = CGPoint(x: mainFrame.midX, y: mainFrame.midY)
        guard let screen = NSScreen.screens.first(where: {
            let frame = Coordinates.quartz($0.frame)
            return frame.contains(mainPoint)
        }) else { return nil }

        let safeArea: CGRect
        if screen.safeAreaInsets.top > 0 {
            // On a notched screen, the full display frame includes the camera
            // housing. If AppKit has not supplied the auxiliary area yet, keep
            // the move in the waiting state instead of treating the notch as a
            // valid drag path.
            guard let right = screen.auxiliaryTopRightArea, !right.isEmpty else { return nil }
            safeArea = Coordinates.quartz(right)
        } else {
            safeArea = Coordinates.quartz(screen.frame)
        }
        guard let hiddenDrop = hiddenLaneDropPoint(always: always, hidden: hidden) else { return nil }
        return NarrowDividerGeometry(
            pair: pair,
            mainFrame: mainFrame,
            safeArea: safeArea,
            alwaysDrop: CGPoint(x: always.minX - Self.dividerDropInset, y: always.midY),
            hiddenDrop: hiddenDrop,
            visibleDrop: CGPoint(x: hidden.maxX + Self.dividerDropInset, y: hidden.midY)
        )
    }

    private func narrowDividerGeometryIsSafe(_ geometry: NarrowDividerGeometry) -> Bool {
        let drops = activeNarrowDrops(in: geometry)
        let horizontal = geometry.safeArea.insetBy(dx: 1, dy: 0)
        let vertical = geometry.safeArea.insetBy(dx: 0, dy: -1)
        return geometry.pair.always.frame.maxX <= geometry.pair.hidden.frame.minX &&
            drops.allSatisfy {
                $0.x >= horizontal.minX && $0.x <= horizontal.maxX &&
                    $0.y >= vertical.minY && $0.y <= vertical.maxY
            }
    }

    /// Calibration only constrains the drop used by this operation. An
    /// existing Always Hidden item does not make its left drop a requirement
    /// for a Visible/Hidden operation.
    private func activeNarrowDrops(in geometry: NarrowDividerGeometry) -> [CGPoint] {
        switch movingTargetSection {
        case .alwaysHidden: return [geometry.alwaysDrop]
        case .hidden: return [geometry.hiddenDrop]
        case .visible: return [geometry.visibleDrop]
        }
    }

    private func removeDividers(hidden: Bool, always: Bool, rememberCurrentPositions: Bool = true) {
        guard hidden || always else { return }
        narrowDividersReadyForMove = false
        narrowReadySnapshot = nil
        narrowCandidateSnapshot = nil
        settledDividerSnapshot = nil
        parkedDividersReady = false
        if rememberCurrentPositions {
            rememberPreferredPositions(named: Self.dividerAutosaveNames)
        }
        if hidden, let item = hiddenDivider {
            NSStatusBar.system.removeStatusItem(item)
            if let instance = dividerInstances[Self.hiddenAutosaveName],
               instance.objectID == ObjectIdentifier(item) {
                dividerInstances.removeValue(forKey: Self.hiddenAutosaveName)
            }
            hiddenDivider = nil
        }
        if always, let item = alwaysDivider {
            NSStatusBar.system.removeStatusItem(item)
            if let instance = dividerInstances[Self.alwaysHiddenAutosaveName],
               instance.objectID == ObjectIdentifier(item) {
                dividerInstances.removeValue(forKey: Self.alwaysHiddenAutosaveName)
            }
            alwaysDivider = nil
        }
        restorePreferredPositions(named: Self.dividerAutosaveNames, afterRemoval: true)
    }

    /// AppKit reflows the narrow marker when an item is inserted beside it but
    /// does not consistently persist the marker's new trailing position before
    /// its length changes again. Save the live geometry first so collapsing the
    /// lane preserves enough room for every item that was just moved into it.
    private func rememberLiveDividerPositions() {
        guard let hiddenFrame = dividerFrame(hiddenDivider, requireHostedWindow: true),
              let alwaysFrame = dividerFrame(alwaysDivider, requireHostedWindow: true),
              let screen = NSScreen.screens.first(where: {
                  let frame = Coordinates.quartz($0.frame)
                  return frame.intersects(hiddenFrame) && frame.intersects(alwaysFrame)
              }) else { return }
        let screenRight = Coordinates.quartz(screen.frame).maxX
        let positions = (
            hidden: Double(max(0, screenRight - hiddenFrame.maxX)),
            always: Double(max(0, screenRight - alwaysFrame.maxX))
        )
        preservedPreferredPositions[Self.hiddenAutosaveName] = positions.hidden
        preservedPreferredPositions[Self.alwaysHiddenAutosaveName] = positions.always
        Self.writePreferredPositions([
            Self.hiddenAutosaveName: positions.hidden,
            Self.alwaysHiddenAutosaveName: positions.always
        ], to: .standard)
    }

    private func constrainDividerPositionsForMoving() {
        rememberPreferredPositions(named: Self.dividerAutosaveNames)
        let referenceFrame = dividerFrame(mainItem)
        guard let screen = referenceFrame.flatMap({ frame in
                  NSScreen.screens.first { Coordinates.quartz($0.frame).intersects(frame) }
              }) ?? NSScreen.main,
              screen.safeAreaInsets.top > 0,
              let rightArea = screen.auxiliaryTopRightArea,
              rightArea.width >= 160 else { return }

        let safe = Self.safePreferredPositions(for: screen)
        guard let safeHidden = safe[Self.hiddenAutosaveName],
              let safeAlways = safe[Self.alwaysHiddenAutosaveName] else { return }
        let positions = normalizedMovingDividerPositions(
            hidden: preservedPreferredPositions[Self.hiddenAutosaveName] ?? safeHidden,
            always: preservedPreferredPositions[Self.alwaysHiddenAutosaveName] ?? safeAlways,
            screen: screen
        )
        preservedPreferredPositions[Self.hiddenAutosaveName] = positions.hidden
        preservedPreferredPositions[Self.alwaysHiddenAutosaveName] = positions.always
        Self.writePreferredPositions([
            Self.hiddenAutosaveName: positions.hidden,
            Self.alwaysHiddenAutosaveName: positions.always
        ], to: .standard)
        model.trace("MOVE PREFS constrained hidden=\(positions.hidden) always=\(positions.always)")
    }

    private func normalizedMovingDividerPositions(
        hidden: Double,
        always: Double,
        screen: NSScreen,
        preserveExistingSpan: Bool = true
    ) -> (hidden: Double, always: Double) {
        let existingHidden = preserveExistingSpan
            ? (preservedPreferredPositions[Self.hiddenAutosaveName] ?? hidden)
            : hidden
        let existingAlways = preserveExistingSpan
            ? (preservedPreferredPositions[Self.alwaysHiddenAutosaveName] ?? always)
            : always
        let safe = Self.safePreferredPositions(for: screen)
        let minimumLaneWidth = max(16,
            (safe[Self.alwaysHiddenAutosaveName] ?? 32) - (safe[Self.hiddenAutosaveName] ?? 0))
        var laneWidth = max(minimumLaneWidth, max(existingAlways - existingHidden, always - hidden))
        laneWidth = max(laneWidth, requiredHiddenLaneWidth)
        var rightMarker = preserveExistingSpan ? min(existingHidden, hidden) : hidden

        if screen.safeAreaInsets.top > 0,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.width >= 160,
           let defaultLeftMarker = safe[Self.alwaysHiddenAutosaveName] {
            // Translate the complete marker group to the right of the camera
            // housing. Keep its span so previously accumulated lane capacity is
            // not lost merely because the temporary narrow layout was rebuilt.
            // Always Hidden drops inside the safe area to the left of a
            // 16-point marker. Include the drop inset and the one-point safety
            // margin when placing the marker group beside the camera housing.
            let targetSafeLeftMarker = Double(max(0,
                screen.frame.maxX - (rightArea.minX + 16 + Self.dividerDropInset + 1)))
            let maximumLeftMarker = min(defaultLeftMarker, targetSafeLeftMarker)
            // Main must remain to the right of the Hidden boundary. Reserve its
            // 44-point hosted width plus a small gap in preferred-position
            // space; otherwise visible items dropped before Main are still
            // classified as hidden.
            let mainPreferred = safe[Self.mainAutosaveName] ?? 12
            let minimumRightMarker = Double(max(
                mainPreferred + 52,
                screen.frame.maxX - rightArea.maxX + 2
            ))
            laneWidth = min(laneWidth, max(0, maximumLeftMarker - minimumRightMarker))
            rightMarker = max(minimumRightMarker, min(rightMarker, maximumLeftMarker - laneWidth))
        }
        return (rightMarker, rightMarker + laneWidth)
    }

    private func revealInline(always: Bool) {
        hideWork?.cancel(); hideWork = nil
        hoverWork?.cancel(); hoverWork = nil
        removeDividers(hidden: true, always: always)
    }

    private func cancelDiscovery() {
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryRequested = false
        discoveringNewItems = false
    }

    private func applicationPopulationDidChange(forceDiscovery: Bool) {
        guard !isStopped else { return }
        auditStatusPresenceIfNeeded()
        let current = Self.runningApplicationPIDs()
        let hasNewProcess = !current.subtracting(knownApplicationPIDs).isEmpty
        knownApplicationPIDs = current
        let currentHosts = Self.menuHostIDs()
        let hasNewHost = !currentHosts.subtracting(knownMenuHostIDs).isEmpty
        let hasRemovedHost = !knownMenuHostIDs.subtracting(currentHosts).isEmpty
        knownMenuHostIDs = currentHosts
        let activeDiscoveryOrMove = discoveryTask != nil || model.isMoving ||
            revealingForMove || discoveringNewItems
        // A late status item from an already running app has no launch event.
        // Host changes during our own warm/move are covered by that session's
        // scans, and must not queue a second physical reveal of the same lane.
        guard forceDiscovery || hasNewProcess || (hasNewHost && !activeDiscoveryOrMove) else {
            if hasRemovedHost && !activeDiscoveryOrMove { model.refresh() }
            return
        }
        if model.managementEnabled { discoverNewMenuItems() }
        else { model.refresh() }
    }

    private var statusPresenceAuditAvailable: Bool {
        !BuildChannel.isAppStore && !isStopped && model.managementEnabled && model.accessibilityGranted &&
            !model.isMoving && !revealingForMove &&
            !discoveringNewItems && discoveryTask == nil
    }

    /// A running app may add an extra while the parked spacers prevent it from
    /// acquiring a CG host. Audit AX extras in the background to find that case.
    private func auditStatusPresenceIfNeeded() {
        guard statusPresenceAuditAvailable, presenceAuditTask == nil,
              Date().timeIntervalSince(lastPresenceAuditAt) >= 5 else { return }
        lastPresenceAuditAt = Date()
        presenceAuditGeneration &+= 1
        let generation = presenceAuditGeneration
        presenceAuditTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { MenuScanner.statusPresenceFingerprint() }
            let snapshot = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, generation == self.presenceAuditGeneration else { return }
            defer { self.presenceAuditTask = nil }
            // Do not absorb a sample taken during a temporary reveal. Retry
            // after the operation, when the normal discovery can act on it.
            guard !Task.isCancelled, self.statusPresenceAuditAvailable else { return }
            let added = self.menuPresence.observe(snapshot, runningPIDs: Self.runningApplicationPIDs())
            if added {
                self.model.trace("DISCOVERY new AX extra")
                self.discoverNewMenuItems()
            }
        }
    }

    private func cancelPresenceAudit() {
        presenceAuditGeneration &+= 1
        presenceAuditTask?.cancel()
        presenceAuditTask = nil
    }

    private static func menuHostIDs() -> Set<CGWindowID> {
        // windows() already excludes Qbar's own windows and transient clones.
        // Keep the fixed recording/privacy indicator out of the watcher too.
        Set(MenuScanner.windows().filter { window in
            let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
            return !MenuItemPlacement.isExcluded(id: "\(bundle)|\(window.title)")
        }.map(\.id))
    }

    private static func runningApplicationPIDs() -> Set<pid_t> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return Set(NSWorkspace.shared.runningApplications.lazy
            .map(\.processIdentifier)
            .filter { $0 > 0 && $0 != ownPID })
    }

    private func refreshAfterLayout() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func beginDirectMenuAction() {
        directMenuActionPending = true
        hoverWork?.cancel(); hoverWork = nil
        hideWork?.cancel(); hideWork = nil
    }

    func endDirectMenuAction() {
        directMenuActionPending = false
    }

    private func handle(_ event: NSEvent) {
        guard model.managementEnabled, !model.isMoving, !revealingForMove, !discoveringNewItems else { return }
        let mouse: NSPoint
        if let window = event.window {
            mouse = window.convertPoint(toScreen: event.locationInWindow)
        } else if let cgEvent = event.cgEvent {
            mouse = CGPoint(x: cgEvent.location.x, y: Coordinates.desktopTop - cgEvent.location.y)
        } else {
            mouse = NSEvent.mouseLocation
        }
        let screen = Coordinates.screen(at: mouse)
        let inMenuBar = mouse.y >= screen.frame.maxY - max(24, screen.safeAreaInsets.top) && mouse.y <= screen.frame.maxY
        let inPanel = panel?.frame.contains(mouse) == true
        let inNativeMenu = model.nativeMenuFrames.contains { Coordinates.cocoa($0).contains(mouse) }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if !inMenuBar && !inPanel && !inNativeMenu && !directMenuActionPending && !model.isInteractingWithMenu && model.isExpanded { collapse() }
            else if event.type == .leftMouseDown && model.preferences.clickEmptyToShow &&
                dividerFrame(mainItem).map({ Coordinates.cocoa($0).contains(mouse) }) != true && isEmptyTrigger(mouse) { toggle() }
        }
        if event.type == .scrollWheel && inMenuBar && model.preferences.scrollToShow && abs(event.scrollingDeltaY) > 1 {
            if event.scrollingDeltaY > 0 { expand() } else { collapse() }
        }
        guard event.type == .mouseMoved else { return }
        let trigger = inMenuBar && isEmptyTrigger(mouse)
        if trigger && !pointerInTrigger && model.preferences.hoverToShow && !model.isExpanded {
            hoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.preferences.hoverToShow, self.pointerInTrigger else { return }
                self.expand()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + model.preferences.hoverDelay, execute: work)
        }
        if !trigger { hoverWork?.cancel() }
        pointerInTrigger = trigger
        if inMenuBar || inPanel { hideWork?.cancel() }
        else if model.isExpanded { scheduleHide() }
    }

    private func isEmptyTrigger(_ point: NSPoint) -> Bool {
        if let frame = dividerFrame(mainItem), Coordinates.cocoa(frame).contains(point) { return true }
        guard !BuildChannel.isAppStore else { return false }
        let quartz = Coordinates.quartz(point)
        guard !model.items.contains(where: { $0.frame.contains(quartz) }) else { return false }
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(quartz.x), Float(quartz.y), &element)
        guard result == .success, let element else { return false }
        return AXAccess.string(element, kAXRoleAttribute) == kAXMenuBarRole
    }

    private func scheduleHide() {
        guard canAutoHide, hideWork == nil || hideWork?.isCancelled == true else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.canAutoHide else { return }
            if Self.hasOpenSystemMenu() { self.scheduleHide() }
            else { self.collapse() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.preferences.hideDelay, execute: work)
    }

    private var canAutoHide: Bool {
        let point = NSEvent.mouseLocation
        let screen = Coordinates.screen(at: point)
        let inMenuBar = point.y >= screen.frame.maxY - max(24, screen.safeAreaInsets.top) && screen.frame.contains(point)
        return AutoHidePolicy.shouldSchedule(enabled: model.managementEnabled && model.preferences.autoHide,
            expanded: model.isExpanded, moving: model.isMoving || revealingForMove || discoveringNewItems || model.isInteractingWithMenu || directMenuActionPending,
            pointerInside: inMenuBar || panel?.frame.contains(point) == true)
    }

    static func hasOpenSystemMenu() -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) &&
            ($0[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        add(model.isExpanded ? L10n.tr("收起图标") : L10n.tr("显示收纳区"), #selector(toggleFromMenu))
        add(L10n.tr("临时查看始终隐藏"), #selector(alwaysFromMenu))
        menu.addItem(.separator())
        add(L10n.tr("Qbar 设置…"), #selector(settingsFromMenu), key: ",")
        add(L10n.tr("刷新图标"), #selector(refreshFromMenu))
        menu.addItem(.separator())
        add(L10n.tr("退出 Qbar"), #selector(quitFromMenu), key: "q")
        mainItem.menu = menu
        mainItem.button?.performClick(nil)
        mainItem.menu = nil
    }
    @objc private func toggleFromMenu() { toggle() }
    @objc private func alwaysFromMenu() { toggleAlways() }
    @objc private func settingsFromMenu() { model.onShowSettings?() }
    @objc private func refreshFromMenu() { model.refresh() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    func stop() {
        isStopped = true
        let wasRevealingForMove = revealingForMove
        cancelDividerRebuild()
        revealingForMove = false
        refreshWork?.cancel()
        mainAnchorRestoreWork?.cancel(); mainAnchorRestoreWork = nil
        cancelDiscovery()
        cancelPresenceAudit()
        appPopulationTimer?.invalidate(); appPopulationTimer = nil
        hoverWork?.cancel(); hideWork?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        closePanel()
        if !wasRevealingForMove {
            rememberPreferredPositions(named: Self.dividerAutosaveNames)
        }
        if let main = Self.repairMainPreferredPosition(in: .standard) {
            preservedPreferredPositions[Self.mainAutosaveName] = main
        }
        for item in [hiddenDivider, alwaysDivider, mainItem].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        restorePreferredPositions(named: Self.allAutosaveNames, afterRemoval: true)
    }

    /// NSStatusBar removes the autosaved position when its status item is removed.
    /// Keep a copy so pausing management does not silently reset the divider order.
    private func rememberPreferredPositions(named names: [String]) {
        for name in names where name != Self.mainAutosaveName {
            let key = Self.preferredPositionPrefix + name
            if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
                preservedPreferredPositions[name] = number.doubleValue
            }
        }
    }

    private func restorePreferredPositions(named names: [String], afterRemoval: Bool = false) {
        let positions = preservedPreferredPositions.filter { names.contains($0.key) }
        Self.writePreferredPositions(positions, to: .standard)
        guard afterRemoval, !positions.isEmpty else { return }
        // AppKit can clear an autosave key while the removed item is being torn down.
        // Repeat on the next run-loop turn. A newer lifecycle invalidates the
        // work, and execution reads the newest preserved values rather than a
        // stale captured snapshot.
        preferredPositionRestoreWork?.cancel()
        let generation = dividerLifecycleGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dividerLifecycleGeneration == generation else { return }
            self.preferredPositionRestoreWork = nil
            // Use the newest preserved values. Cancellation is cooperative, so
            // an older queued work item must not restore its captured snapshot.
            let latest = self.preservedPreferredPositions.filter { names.contains($0.key) }
            Self.writePreferredPositions(latest, to: .standard)
        }
        preferredPositionRestoreWork = work
        DispatchQueue.main.async(execute: work)
    }

    static func migratePreferredPositions(in defaults: UserDefaults) {
        let safe = safeDefaultPreferredPositions()
        // Qbar.Main is an application control, not a user-managed menu item.
        // Always repair its anchor on a layout-engine migration while leaving
        // the user's accumulated Hidden/Always lane capacity untouched.
        repairMainPreferredPosition(in: defaults)
        let legacy: [String: Double] = [
            hiddenAutosaveName: 10_000,
            alwaysHiddenAutosaveName: 20_000
        ]
        let largestScreenWidth = Double(NSScreen.screens.map(\.frame.width).max() ?? 2_048)
        let clearlyOffscreen = max(4_096, largestScreenWidth * 2)

        for name in dividerAutosaveNames {
            let key = preferredPositionPrefix + name
            let current = (defaults.object(forKey: key) as? NSNumber)?.doubleValue
            let isLegacy = current.map { abs($0 - (legacy[name] ?? .nan)) < 0.5 } ?? false
            let isInvalid = current.map { !$0.isFinite || $0 < 0 || $0 > clearlyOffscreen } ?? true
            if isLegacy || isInvalid, let replacement = safe[name] {
                defaults.set(replacement, forKey: key)
            }
        }
    }

    @discardableResult
    private static func repairMainPreferredPosition(in defaults: UserDefaults) -> Double? {
        let preferred: Double?
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            preferred = safeMainPreferredPosition(for: screen)
        } else {
            preferred = 220
        }
        guard let preferred else { return nil }
        defaults.set(preferred, forKey: preferredPositionPrefix + mainAutosaveName)
        return preferred
    }

    private static var allAutosaveNames: [String] {
        [mainAutosaveName, hiddenAutosaveName, alwaysHiddenAutosaveName]
    }

    private static var dividerAutosaveNames: [String] {
        [hiddenAutosaveName, alwaysHiddenAutosaveName]
    }

    private static func seedMissingPreferredPositions(in defaults: UserDefaults) {
        let safe = safeDefaultPreferredPositions()
        for name in allAutosaveNames {
            let key = preferredPositionPrefix + name
            if defaults.object(forKey: key) == nil, let position = safe[name] {
                defaults.set(position, forKey: key)
            }
        }
    }

    private static func readPreferredPositions(in defaults: UserDefaults) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: allAutosaveNames.compactMap { name in
            let key = preferredPositionPrefix + name
            guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
            return (name, number.doubleValue)
        })
    }

    private static func writePreferredPositions(_ positions: [String: Double], to defaults: UserDefaults) {
        for (name, position) in positions where position.isFinite && position >= 0 {
            defaults.set(position, forKey: preferredPositionPrefix + name)
        }
    }

    private static func safeDefaultPreferredPositions() -> [String: Double] {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return [mainAutosaveName: 220, hiddenAutosaveName: 400, alwaysHiddenAutosaveName: 432]
        }

        return safePreferredPositions(for: screen)
    }

    private static func safeMainPreferredPosition(for screen: NSScreen) -> Double? {
        if screen.safeAreaInsets.top > 0 {
            guard let auxiliary = screen.auxiliaryTopRightArea,
                  auxiliary.width >= 160 else { return nil }
        }
        return safePreferredPositions(for: screen)[mainAutosaveName]
    }

    private static func safePreferredPositions(for screen: NSScreen) -> [String: Double] {
        let screenFrame = screen.frame
        let rightArea: CGRect
        if screen.safeAreaInsets.top > 0,
           let auxiliary = screen.auxiliaryTopRightArea,
           auxiliary.width >= 160 {
            rightArea = auxiliary
        } else {
            // A screen without a camera housing has no auxiliary area. Reserve a
            // similarly sized trailing region so the same divider topology applies.
            let width = min(max(480, screenFrame.width * 0.45), max(160, screenFrame.width - 48))
            rightArea = CGRect(x: screenFrame.maxX - width, y: screenFrame.maxY - 24,
                               width: width, height: 24)
        }

        // Preferred-position values are measured from the trailing screen edge.
        // In screen order the markers must be Always Hidden, Hidden, then Main.
        let left = rightArea.minX + 12
        let right = rightArea.maxX - 12
        let alwaysX = left
        let hiddenX = min(left + 32, right - 64)
        // Keep the Qbar control at the trailing edge of the application-owned
        // lane. Fixed macOS suffix items (clock/control centre) still remain to
        // its right according to their system ordering.
        let mainX = right
        return [
            mainAutosaveName: Double(max(0, screenFrame.maxX - mainX)),
            hiddenAutosaveName: Double(max(0, screenFrame.maxX - hiddenX)),
            alwaysHiddenAutosaveName: Double(max(0, screenFrame.maxX - alwaysX))
        ]
    }
}

private final class DividerMark: NSView {
    var visible = true { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard visible else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: CGRect(x: bounds.maxX - 9, y: bounds.midY - 6, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
    }
}

private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
