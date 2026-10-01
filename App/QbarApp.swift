import SwiftUI
import AppKit
import Carbon
import QbarCore

@main
struct QbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.tr("Qbar 设置…")) { delegate.showSettings() }.keyboardShortcut(",")
                }
                CommandGroup(replacing: .pasteboard) {
                    Button(L10n.tr("剪切")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
                    Button(L10n.tr("拷贝")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
                    Button(L10n.tr("粘贴")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
                    Divider()
                    Button(L10n.tr("全选")) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct PendingHostRepair {
        let change: MenuHostReplacement
        let mode: DisplayMode
        var attempts = 0
        var nextAttemptAt = Date.distantPast
    }

    // The first scan of a newly hosted extra can precede its AX identity by
    // several seconds. Retry that one host, with room for the user's actions
    // between probes, instead of replaying the entire saved layout.
    private static let hostRepairDelays: [TimeInterval] = [0.5, 1, 2, 3, 4]

    private var model: AppModel!
    private var status: StatusController!
    private var engine: MenuBarEngine!
    private var hotkeys: HotkeyManager!
    private var window: NSWindow?
    private var operation: Task<Void, Never>?
    private var pendingActivations: [(AppDelegate) async -> Void] = []
    private var pendingHostRepairs: [String: PendingHostRepair] = [:]
    private var hostRepairRetry: Task<Void, Never>?
    private var lastHostRepairWait: String?
    private var runtimeHostRepairReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        let savedStartupRules = model.preferences.rules
        let wasManagingOnLaunch = UserDefaults.standard.bool(forKey: "managementEnabled")
        status = StatusController(model: model)
        engine = MenuBarEngine(model: model)
        engine.controller = status
        model.isMenuItemReachable = { [weak self] item in
            self?.engine.isStatusItemReachable(item) ?? false
        }
        hotkeys = HotkeyManager()
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onManagementChanged = { [weak self] enabled in
            guard let self else { return }
            if !enabled {
                self.pendingActivations.removeAll()
                self.pendingHostRepairs.removeAll()
                self.model.setHostRepairWaiting(false)
                self.hostRepairRetry?.cancel()
                self.hostRepairRetry = nil
                self.operation?.cancel()
                self.engine.stop()
            }
            self.status.setEnabled(enabled)
            if enabled && self.runtimeHostRepairReady && self.model.layoutPending {
                let savedRules = self.model.preferences.rules
                self.enqueueActivation { delegate in
                    await delegate.engine.restoreSavedGroupsOnLaunch(savedRules)
                }
            }
        }
        model.onToggle = { [weak self] in self?.status.toggle() }
        model.onCollapse = { [weak self] in self?.status.collapse() }
        model.onShowAlways = { [weak self] in self?.status.toggleAlways() }
        model.classifyFrame = { [weak self] in self?.status.classify($0) ?? .visible }
        model.debugStatus = { [weak self] in self?.status.diagnostics() ?? [:] }
        model.onMove = { [weak self] id, section, next in
            self?.enqueueActivation { delegate in _ = await delegate.engine.move(id, to: section, before: next) }
        }
        model.onActivateItem = { [weak self] id, rightClick in
            self?.enqueueActivation { delegate in await delegate.engine.activate(id, rightClick: rightClick) }
        }
        model.onActivateItemAtPoint = { [weak self] id, rightClick, normalizedX in
            self?.enqueueActivation { delegate in
                await delegate.engine.activate(id, rightClick: rightClick, normalizedX: normalizedX)
            }
        }
        model.onActivateItemFromTray = { [weak self] id, rightClick, anchor in
            self?.enqueueActivation { delegate in
                await delegate.engine.activate(id, rightClick: rightClick, normalizedX: anchor.normalizedX, trayAnchor: anchor)
            }
        }
        model.onApplyLayout = { [weak self] in
            self?.enqueueActivation { delegate in
                await delegate.engine.applyLayout()
                delegate.status.layoutApplicationFinished()
            }
        }
        model.onDiscoverMenuItems = { [weak self] in
            guard let self, self.operation == nil else { return }
            let discovery = Task { await self.engine.warmMenuIconCache() }
            self.operation = discovery
            await discovery.value
            self.operation = nil
            self.drainPendingActivations()
        }
        model.onHostReplacement = { [weak self] change in
            guard let self else { return }
            if change.savedSection == .visible,
               let item = self.model.items.first(where: {
                   $0.id == change.id && $0.bundleID == change.bundleID &&
                       $0.pid == change.pid && $0.windowID == change.newWindowID &&
                       $0.windowOwnerPID == change.ownerPID
               }) {
                let physical = item.observedSection ?? self.status.classify(item.frame)
                if physical != .visible || !self.engine.isStatusItemReachable(item) {
                    // The saved Visible rule must never leave a newly hosted
                    // extra with no reachable entry while its repair is pending.
                    self.model.markVisibleFallback(id: change.id, windowID: change.newWindowID,
                                                   ownerPID: change.ownerPID)
                }
            }
            if let pending = self.pendingHostRepairs[change.id],
               pending.change.newWindowID == change.newWindowID,
               pending.change.pid == change.pid,
               pending.change.ownerPID == change.ownerPID,
               pending.change.savedSection == change.savedSection,
               pending.change.savedOrder == change.savedOrder,
               pending.mode == self.model.preferences.mode {
                // Repeated discovery of the same host cannot reset its retry
                // budget or keep a newer user action waiting indefinitely.
                return
            }
            self.pendingHostRepairs[change.id] = PendingHostRepair(
                change: change, mode: self.model.preferences.mode)
            self.model.trace("HOST queued id=\(change.id) ready=\(self.runtimeHostRepairReady) " +
                             "management=\(self.model.managementEnabled) pending=\(self.model.layoutPending) " +
                             "refreshing=\(self.model.isRefreshing) operation=\(self.operation != nil)")
            self.drainPendingActivations()
        }
        model.onRefreshSettled = { [weak self] in self?.drainPendingActivations() }
        model.onLayoutPendingChanged = { [weak self] in self?.drainPendingActivations() }
        model.onPreferencesChanged = { [weak self] previous in
            guard let self else { return }
            // A user move or imported layout supersedes automatic placement.
            self.pendingHostRepairs = self.pendingHostRepairs.filter { _, pending in
                self.hostRepairStillWanted(pending)
            }
            var oldAppearance = previous, newAppearance = self.model.preferences
            oldAppearance.rules = []; oldAppearance.shortcuts = [:]
            newAppearance.rules = []; newAppearance.shortcuts = [:]
            let glyphChanged = oldAppearance.glyph != newAppearance.glyph
            oldAppearance.glyph = newAppearance.glyph
            if oldAppearance != newAppearance { self.status.configure() }
            else if glyphChanged { self.status.updateMainGlyph() }
            if previous.shortcutBindings != self.model.preferences.shortcutBindings {
                self.model.shortcutErrors = self.hotkeys.register(self.model.preferences)
            }
        }
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            self.model.trace("HOTKEY \(action)")
            switch action {
            case "toggle": self.status.toggle()
            case "always": self.status.toggleAlways()
            case "collapse": self.status.collapse()
            case "settings": self.showSettings()
            default:
                if action.hasPrefix("item:") { self.model.onActivateItem?(String(action.dropFirst(5)), false) }
            }
        }
        model.shortcutErrors = hotkeys.register(model.preferences)
        model.onInitialScanCompleted = { [weak self] in
            guard let self else { return }
            self.model.trace("STARTUP initial scan savedRules=\(savedStartupRules.count) wasManaging=\(wasManagingOnLaunch)")
            self.model.restoreManagementIfAllowed()
            if self.model.managementEnabled {
                self.perform { delegate in
                    defer { delegate.runtimeHostRepairReady = true }
                    await delegate.engine.warmMenuIconCache()
                    delegate.model.trace("STARTUP warm complete enabled=\(delegate.model.managementEnabled) cancelled=\(Task.isCancelled)")
                    guard delegate.model.managementEnabled, !Task.isCancelled else { return }
                    if wasManagingOnLaunch {
                        await delegate.engine.restoreSavedGroupsOnLaunch(savedStartupRules)
                    }
                }
            } else {
                self.runtimeHostRepairReady = true
            }
        }
        model.refresh()
        let launchReason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        if launchReason != keyAELaunchedAsLogInItem { showSettings() }
    }

    private func perform(_ action: @escaping (AppDelegate) async -> Void) {
        guard operation == nil else { model.notice = L10n.tr("正在完成上一次操作，请稍候。"); return }
        operation = Task {
            await action(self)
            operation = nil
            drainPendingActivations()
        }
    }

    private func enqueueActivation(_ action: @escaping (AppDelegate) async -> Void) {
        pendingActivations.append(action)
        drainPendingActivations()
    }

    private func noteHostRepairWait(_ reason: String) {
        guard lastHostRepairWait != reason else { return }
        lastHostRepairWait = reason
        model.trace("HOST waiting reason=\(reason) queued=\(pendingHostRepairs.count) " +
                    "ready=\(runtimeHostRepairReady) management=\(model.managementEnabled) " +
                    "pending=\(model.layoutPending) refreshing=\(model.isRefreshing)")
    }

    private func hostRepairStillWanted(_ pending: PendingHostRepair) -> Bool {
        let change = pending.change
        return model.managementEnabled && model.preferences.mode == pending.mode &&
            model.preferences.rules.contains {
                $0.id == change.id && $0.bundleID == change.bundleID &&
                    $0.section == change.savedSection && $0.order == change.savedOrder
            }
    }

    private func scheduleHostRepairWake(after delay: TimeInterval) {
        guard hostRepairRetry == nil else { return }
        hostRepairRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, delay))) } catch { return }
            guard let self else { return }
            self.hostRepairRetry = nil
            self.drainPendingActivations()
        }
    }

    private func drainPendingActivations() {
        guard operation == nil else {
            if !pendingHostRepairs.isEmpty { noteHostRepairWait("operation") }
            return
        }
        if !pendingActivations.isEmpty {
            if !pendingHostRepairs.isEmpty { noteHostRepairWait("user-activation") }
            perform(pendingActivations.removeFirst())
            return
        }
        guard !pendingHostRepairs.isEmpty else {
            model.setHostRepairWaiting(false)
            lastHostRepairWait = nil
            hostRepairRetry?.cancel()
            hostRepairRetry = nil
            return
        }
        guard runtimeHostRepairReady else { noteHostRepairWait("startup"); return }
        guard model.managementEnabled else {
            model.trace("HOST discarded reason=management-disabled count=\(pendingHostRepairs.count)")
            pendingHostRepairs.removeAll()
            model.setHostRepairWaiting(false)
            lastHostRepairWait = nil
            return
        }
        // A staged layout is authoritative until the user applies or cancels
        // it. Keep the host hint so a later transition can recheck this item.
        guard !model.layoutPending else {
            model.setHostRepairWaiting(false)
            noteHostRepairWait("pending-layout")
            return
        }
        pendingHostRepairs = pendingHostRepairs.filter { _, pending in hostRepairStillWanted(pending) }
        guard !pendingHostRepairs.isEmpty else {
            model.setHostRepairWaiting(false)
            lastHostRepairWait = nil
            return
        }
        // A user's temporary activation and native menu take priority over
        // automatic placement repair. Keep the event queued until they finish.
        let blockers = engine.runtimeHostRepairBlockers
        guard blockers.isEmpty else {
            model.setHostRepairWaiting(false)
            noteHostRepairWait(blockers.joined(separator: ","))
            scheduleHostRepairWake(after: 2)
            return
        }
        let ready = pendingHostRepairs.keys.sorted().first { id in
            guard let pending = pendingHostRepairs[id] else { return false }
            return pending.nextAttemptAt <= Date()
        }
        guard let id = ready, let pending = pendingHostRepairs.removeValue(forKey: id) else {
            model.setHostRepairWaiting(false)
            if let next = pendingHostRepairs.values.map(\.nextAttemptAt).min() {
                scheduleHostRepairWake(after: max(0.1, next.timeIntervalSinceNow))
            }
            noteHostRepairWait("backoff")
            return
        }
        hostRepairRetry?.cancel()
        hostRepairRetry = nil
        lastHostRepairWait = nil
        model.setHostRepairWaiting(true)
        model.trace("HOST dispatch id=\(id) window=\(pending.change.newWindowID) attempt=\(pending.attempts + 1)")
        perform { delegate in
            let outcome = await delegate.engine.repairSavedGroupAfterHostReplacement(
                pending.change, expectedMode: pending.mode)
            guard delegate.hostRepairStillWanted(pending) else {
                delegate.model.trace("HOST discarded id=\(id) reason=layout-changed")
                return
            }
            switch outcome {
            case .settled:
                delegate.model.clearVisibleFallback(id: id)
                delegate.model.trace("HOST completed id=\(id) attempt=\(pending.attempts + 1)")
            case .stale(let reason):
                delegate.model.trace("HOST discarded id=\(id) reason=\(reason)")
            case .retry(let reason):
                // A newer window for the same item may have queued while this
                // attempt was running. Never put the old host back ahead of it.
                guard delegate.pendingHostRepairs[id] == nil else { return }
                guard pending.attempts < Self.hostRepairDelays.count else {
                    delegate.model.trace("HOST retry exhausted id=\(id) reason=\(reason)")
                    await delegate.engine.noteUnresolvedRuntimeHost(pending.change, expectedMode: pending.mode)
                    return
                }
                var retry = pending
                let delay = Self.hostRepairDelays[pending.attempts]
                retry.attempts += 1
                retry.nextAttemptAt = Date().addingTimeInterval(delay)
                delegate.pendingHostRepairs[id] = retry
                delegate.model.trace("HOST retry queued id=\(id) reason=\(reason) " +
                                     "attempt=\(retry.attempts + 1) delay=\(delay)")
            }
        }
    }

    func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1010, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Qbar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 700)
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.setFrameAutosaveName("Qbar.Settings")
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.checkPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model?.checkPermissions() }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        operation?.cancel(); hostRepairRetry?.cancel(); engine?.stop(); hotkeys?.stop(); status?.stop(); model?.save()
    }

    private func installMainMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu(title: "Qbar")
        let settings = NSMenuItem(title: L10n.tr("Qbar 设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.tr("隐藏 Qbar"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: L10n.tr("退出 Qbar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = menu; main.addItem(item)
        let editItem = NSMenuItem(); let edit = NSMenu(title: L10n.tr("编辑"))
        for (title, action, key) in [(L10n.tr("剪切"), #selector(NSText.cut(_:)), "x"), (L10n.tr("拷贝"), #selector(NSText.copy(_:)), "c"), (L10n.tr("粘贴"), #selector(NSText.paste(_:)), "v"), (L10n.tr("全选"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    @objc private func openSettings() { showSettings() }
}
