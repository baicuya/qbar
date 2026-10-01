import AppKit
import ApplicationServices
import QbarCore

private final class QbarEventTap {
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate let handler: Handler
    private(set) var callbackCount = 0
    private(set) var disabledCount = 0

    var isValid: Bool { port.map(CFMachPortIsValid) ?? false }
    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init?(pid: pid_t? = nil, location: CGEventTapLocation? = nil,
          placement: CGEventTapPlacement = .tailAppendEventTap,
          options: CGEventTapOptions, type: CGEventType, handler: @escaping Handler) {
        self.handler = handler
        let mask = CGEventMask(1) << type.rawValue
        let info = Unmanaged.passUnretained(self).toOpaque()
        if let pid {
            port = CGEvent.tapCreateForPid(pid: pid, place: placement, options: options,
                                           eventsOfInterest: mask, callback: qbarEventTapCallback, userInfo: info)
        } else if let location {
            port = CGEvent.tapCreate(tap: location, place: placement, options: options,
                                     eventsOfInterest: mask, callback: qbarEventTapCallback, userInfo: info)
        }
        // tapCreateForPid can return a Mach port that is already invalid (for
        // example when its target disappeared between discovery and creation).
        // A non-nil port alone therefore does not mean the tap can receive the
        // barrier event.
        guard let port, CFMachPortIsValid(port),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        runLoopSource = source
    }

    @discardableResult
    func start() -> Bool {
        guard let port, let runLoopSource, CFMachPortIsValid(port) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    func stop() {
        guard let port else { return }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        self.port = nil
        runLoopSource = nil
    }

    deinit { stop() }

    fileprivate func receive(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        callbackCount += 1
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disabledCount += 1
            if let port, CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        }
        return handler(type, event).map(Unmanaged.passUnretained)
    }
}

private func qbarEventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                 _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<QbarEventTap>.fromOpaque(info).takeUnretainedValue()
    return tap.receive(type, event: event)
}

private final class QbarEventRouteState {
    var entryReceived = false
    var forwarded = false
    var returned = false
    var completed = false
    var windowMismatch = false
}

struct MenuBarPhysicalMember: Equatable {
    let windowID: CGWindowID
    let frame: CGRect
    let isMovable: Bool
}

/// Pure ordering rules shared by live movement and unit tests. Menu bar rows are
/// ordered from left to right. Each section has a Qbar-owned right boundary;
/// appending beside another app would displace that boundary on every move.
enum MenuBarOrderingPolicy {
    static func sorted(_ members: [MenuBarPhysicalMember]) -> [MenuBarPhysicalMember] {
        members.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.windowID < $1.windowID
        }
    }

    static func endBoundaryName(for section: ItemSection) -> String {
        switch section {
        case .visible: "Qbar.Hidden"
        case .hidden: "Qbar.Hidden"
        case .alwaysHidden: "Qbar.AlwaysHidden"
        }
    }

    static func usesEndBoundary(beforeNextIsMovable nextIsMovable: Bool?) -> Bool {
        nextIsMovable != true
    }

    static func isSatisfied(
        movingWindowID: CGWindowID,
        before targetWindowID: CGWindowID?,
        among members: [MenuBarPhysicalMember]
    ) -> Bool {
        let ordered = sorted(members)
        guard let movingIndex = ordered.firstIndex(where: { $0.windowID == movingWindowID }) else { return false }
        if let targetWindowID {
            guard let targetIndex = ordered.firstIndex(where: { $0.windowID == targetWindowID }) else { return false }
            return movingIndex + 1 == targetIndex
        }
        return ordered.last(where: \.isMovable)?.windowID == movingWindowID
    }
}

/// Temporarily exposing a status item must retain its physical neighbours,
/// independently of the popup's saved logical ordering.
enum MenuBarRestorationPolicy {
    static func rightNeighbours(of windowID: CGWindowID, among members: [MenuBarPhysicalMember]) -> [CGWindowID] {
        let ordered = MenuBarOrderingPolicy.sorted(members)
        guard let index = ordered.firstIndex(where: { $0.windowID == windowID }) else { return [] }
        return ordered.dropFirst(index + 1).map(\.windowID)
    }
}

/// A temporary click owns one status item. Other live items must retain their
/// physical group; their saved layout is never reapplied during activation.
enum MenuBarTemporaryMovePolicy {
    static func preservesOtherGroups(
        before: [CGWindowID: ItemSection], after: [CGWindowID: ItemSection], selectedWindowID: CGWindowID
    ) -> Bool {
        before.allSatisfy { windowID, section in
            windowID == selectedWindowID || after[windowID] == section
        }
    }
}

enum MenuBarMovementPolicy {
    static func prefersPhysicalDrag(
        reliableSource: Bool, source: CGPoint?, destination: CGPoint, usableAreas: [CGRect]
    ) -> Bool {
        guard reliableSource, let source else { return false }
        return usableAreas.contains { area in
            guard area.width > 2, area.height > 2 else { return false }
            let tolerant = area.insetBy(dx: -1, dy: -1)
            return tolerant.contains(source) && tolerant.contains(destination)
        }
    }
}

enum MenuBarDragSafetyPolicy {
    static func staysOnRow(_ point: CGPoint, source: CGRect, target: CGRect) -> Bool {
        source.height > 0 && target.height > 0 &&
            point.x.isFinite && point.y.isFinite && source.midY.isFinite && target.midY.isFinite &&
            abs(source.midY - target.midY) <= 2 &&
            point.y > source.minY && point.y < source.maxY &&
            point.y > target.minY && point.y < target.maxY
    }

    static func cancellationPoint(originalFrame: CGRect) -> CGPoint? {
        guard originalFrame.width > 0, originalFrame.height > 0,
              originalFrame.midX.isFinite, originalFrame.midY.isFinite else { return nil }
        // A dragged host can follow a synthetic mouse-down outside the screen.
        // Its current frame must never become the cancellation release point.
        return CGPoint(x: originalFrame.midX, y: originalFrame.midY)
    }
}

/// A live AX frame alone is not evidence that a status item occupies a lane.
/// Some apps retain the last AX frame after WindowServer drops their host.
enum MenuBarPlacementPolicy {
    static func section(
        windowID: CGWindowID?, frame: CGRect,
        liveMembers: [MenuBarPhysicalMember], always: CGRect?, hidden: CGRect?
    ) -> ItemSection? {
        guard let windowID,
              let live = liveMembers.first(where: { $0.windowID == windowID }),
              abs(frame.minX - live.frame.minX) <= 1,
              abs(frame.minY - live.frame.minY) <= 1,
              abs(frame.width - live.frame.width) <= 1,
              abs(frame.height - live.frame.height) <= 1,
              let always, let hidden,
              always.maxX <= hidden.minX + 1,
              abs(frame.midY - always.midY) < 8,
              abs(frame.midY - hidden.midY) < 8 else { return nil }
        if frame.maxX <= always.minX + 1 { return .alwaysHidden }
        if frame.minX >= always.maxX - 1, frame.maxX <= hidden.minX + 1 { return .hidden }
        if frame.minX >= hidden.maxX - 1 { return .visible }
        return nil
    }
}

enum MenuBarLayoutPolicy {
    static func orderedRules(_ rules: [ItemRule], mode: DisplayMode) -> [ItemRule] {
        func rank(_ section: ItemSection) -> Int {
            switch section {
            case .alwaysHidden: 0
            case .hidden: 1
            case .visible: 2
            }
        }
        return rules.sorted { lhs, rhs in
            if lhs.section != rhs.section { return rank(lhs.section) < rank(rhs.section) }
            if lhs.order != rhs.order {
                return lhs.section == .visible && mode == .aggregate
                    ? lhs.order > rhs.order : lhs.order < rhs.order
            }
            return lhs.id < rhs.id
        }
    }
}

struct MenuBarActivationWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
}

enum MenuBarApplicationIdentityPolicy {
    static func outermostApplicationURL(of bundleURL: URL) -> URL? {
        guard bundleURL.isFileURL else { return nil }
        let components = bundleURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "app"
        }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(appIndex + 1))),
                   isDirectory: true).standardizedFileURL
    }
}

enum MenuBarActivationPolicy {
    static func newTargetUI(
        before: [MenuBarActivationWindow], after: [MenuBarActivationWindow],
        applicationPID: pid_t, hostingPID: pid_t?, popupLayer: Int, statusLayer: Int,
        excludedPID: pid_t? = nil, relatedApplicationPIDs: Set<pid_t> = []
    ) -> [MenuBarActivationWindow] {
        let oldIDs = Set(before.map(\.id))
        return after.filter { window in
            guard !oldIDs.contains(window.id), window.layer != statusLayer,
                  window.pid != excludedPID else { return false }
            if window.pid == applicationPID || relatedApplicationPIDs.contains(window.pid) { return true }
            return window.pid == hostingPID && window.layer == popupLayer
        }
    }

    static func hasNewTargetUI(
        before: [MenuBarActivationWindow], after: [MenuBarActivationWindow],
        applicationPID: pid_t, hostingPID: pid_t?, popupLayer: Int, statusLayer: Int,
        excludedPID: pid_t? = nil, relatedApplicationPIDs: Set<pid_t> = []
    ) -> Bool {
        !newTargetUI(before: before, after: after, applicationPID: applicationPID,
                     hostingPID: hostingPID, popupLayer: popupLayer, statusLayer: statusLayer,
                     excludedPID: excludedPID, relatedApplicationPIDs: relatedApplicationPIDs).isEmpty
    }
}

/// A routed drop addresses a concrete WindowServer host. Its point need not be
/// physically reachable beside a notch; it must still belong to that live host.
enum MenuBarDirectActivationPolicy {
    static func action(rightClick: Bool, available: [String]) -> String? {
        let preferred = rightClick ? [kAXShowMenuAction] : [kAXPressAction, kAXShowMenuAction]
        return preferred.first { available.contains($0) }
    }

    static func mayFallback(after result: AXError) -> Bool {
        result == .actionUnsupported || result == .notImplemented
    }
}

enum MenuBarTemporaryIdlePolicy {
    static func shouldRestore(exposedFor: TimeInterval, inputIdle: TimeInterval,
                              delay: TimeInterval, buttonDown: Bool) -> Bool {
        guard exposedFor.isFinite, inputIdle.isFinite, delay.isFinite,
              delay > 0, !buttonDown else { return false }
        return exposedFor >= delay && inputIdle >= delay
    }
}

enum MenuBarRoutedDropPolicy {
    static func isAddressable(windowID: CGWindowID, point: CGPoint, liveMembers: [MenuBarPhysicalMember]) -> Bool {
        guard let target = liveMembers.first(where: { $0.windowID == windowID }),
              point.x.isFinite, point.y.isFinite,
              target.frame.width > 2, target.frame.height > 2 else { return false }
        return target.frame.insetBy(dx: -1, dy: -1).contains(point)
    }
}

@MainActor
final class MenuBarEngine {
    enum RuntimeHostRepairOutcome {
        case settled
        case retry(String)
        case stale(String)
    }
    private enum MoveFailure {
        case targetUnavailable
    }

    private struct DropTarget: Equatable {
        let point: CGPoint
        let windowID: CGWindowID
    }

    private struct EventRoute: Equatable {
        enum Kind: String { case hostedOwner = "hosted-owner", application = "application" }
        let pid: pid_t
        let kind: Kind
    }

    private unowned let model: AppModel
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastMoveFailure: MoveFailure?
    private var layoutBatchActive = false
    private var restoringSavedGroups = false
    private var movingImagesCaptured = false
    private struct TemporaryActivation {
        let token = UUID()
        let item: MenuItem
        let originalSection: ItemSection
        let rightNeighbours: [MenuItem]
        var shownAt: TimeInterval?
        var lastInteractionAt: TimeInterval?
        var menuWindowBaseline: [MenuBarActivationWindow] = []
    }

    private var temporaryActivations: [String: TemporaryActivation] = [:]
    private var activationCleanupTask: Task<Void, Never>?
    private var activationCleanupGeneration: UInt64 = 0
    private var temporaryMotionBusy = false
    private var temporaryClickMonitor: Any?
    private var lastTemporaryStatusClick: (id: String, at: TimeInterval)?
    private var activeTemporaryMenuOwnerID: String?
    private var directMenuTrackingTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    weak var controller: StatusController?

    init(model: AppModel) { self.model = model }

    private func displayName(for item: MenuItem) -> String {
        if let displayed = model.items.first(where: { $0.id == item.id })?.name { return displayed }
        if let rule = model.preferences.rules.first(where: { $0.id == item.id }) {
            return rule.alias ?? rule.name
        }
        if !item.isSystem,
           let application = MenuItem.applicationName(pid: item.pid, bundleID: item.bundleID) {
            return application
        }
        return item.name
    }

    private func eventRoutes(for item: MenuItem) -> [EventRoute] {
        var seen = Set<pid_t>()
        return [
            item.windowOwnerPID.map { EventRoute(pid: $0, kind: .hostedOwner) },
            item.pid > 0 ? EventRoute(pid: item.pid, kind: .application) : nil,
        ].compactMap { route in
            guard let route, route.pid > 0, seen.insert(route.pid).inserted else { return nil }
            return route
        }
    }

    /// `observedSection` is derived from the same WindowServer snapshot as the
    /// item's frame. Falling back to the controller is only needed when that
    /// scan could not assign the frame unambiguously (for example during reflow).
    private func verifiedSection(of item: MenuItem, controller: StatusController) -> ItemSection {
        item.observedSection ?? controller.classify(item.frame)
    }

    private func physicalSection(of item: MenuItem, in windows: [MenuScanner.Window]? = nil) -> ItemSection? {
        let snapshot = windows ?? MenuScanner.windows(includeDividers: true)
        let currentBoundaries = controller?.placementBoundaries()
        return MenuBarPlacementPolicy.section(
            windowID: item.windowID, frame: item.frame,
            liveMembers: snapshot.map {
                MenuBarPhysicalMember(windowID: $0.id, frame: $0.frame, isMovable: true)
            },
            always: currentBoundaries?.always ?? snapshot.first(where: { $0.title == "Qbar.AlwaysHidden" })?.frame,
            hidden: currentBoundaries?.hidden ?? snapshot.first(where: { $0.title == "Qbar.Hidden" })?.frame
        )
    }

    private func hasCurrentHost(for item: MenuItem) -> Bool {
        guard let id = item.windowID,
              let live = MenuScanner.windows().first(where: { $0.id == id }) else { return false }
        return abs(live.frame.minX - item.frame.minX) <= 1 &&
            abs(live.frame.minY - item.frame.minY) <= 1 &&
            abs(live.frame.width - item.frame.width) <= 1 &&
            abs(live.frame.height - item.frame.height) <= 1
    }

    #if DEBUG
    private func traceMoveVerification(
        stage: String,
        id: String,
        item: MenuItem?,
        expected: ItemSection,
        verified: ItemSection?,
        controller: StatusController
    ) {
        let windows = MenuScanner.windows(includeDividers: true)
        let dividers = windows
            .filter { $0.title.hasPrefix("Qbar.") }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { "\($0.title)#\($0.id)=\($0.frame.debugDescription)" }
            .joined(separator: ", ")
        let neighbours: String
        if let item {
            neighbours = windows
                .filter { !$0.title.hasPrefix("Qbar.") && abs($0.frame.midX - item.frame.midX) < 160 }
                .sorted { $0.frame.minX < $1.frame.minX }
                .prefix(8)
                .map { "\($0.title.isEmpty ? "<untitled>" : $0.title)#\($0.id)=\($0.frame.debugDescription)" }
                .joined(separator: ", ")
        } else {
            neighbours = "missing"
        }
        model.trace(
            "MOVE VERIFY stage=\(stage) id=\(id) expected=\(expected.rawValue) " +
            "frame=\(item?.frame.debugDescription ?? "missing") " +
            "observed=\(item?.observedSection?.rawValue ?? "nil") " +
            "verified=\(verified?.rawValue ?? "missing") " +
            "live=\(item.map { controller.classify($0.frame).rawValue } ?? "missing") " +
            "dividers=[\(dividers)] neighbours=[\(neighbours)]"
        )
    }

    private func traceWindowAssociation(
        stage: String,
        requestedID: String,
        item: MenuItem,
        candidates: [MenuItem]
    ) {
        let axFrame = item.element.flatMap(AXAccess.frame)?.debugDescription ?? "nil"
        let sameBundle = candidates.filter { $0.bundleID == item.bundleID }.map {
            "\($0.id){window=\($0.windowID.map(String.init) ?? "nil"),frame=\($0.frame.debugDescription)," +
                "ax=\($0.element.flatMap(AXAccess.frame)?.debugDescription ?? "nil")}"
        }.joined(separator: ", ")
        let rawWindows = MenuScanner.windows(includeDividers: true)
            .filter {
                $0.title.hasPrefix("Qbar.") || $0.pid == item.pid ||
                    abs($0.frame.midX - item.frame.midX) < 260
            }
            .sorted { $0.frame.minX < $1.frame.minX }
            .prefix(24)
            .map {
                "\($0.title.isEmpty ? "<untitled>" : $0.title)#\($0.id){pid=\($0.pid),frame=\($0.frame.debugDescription)}"
            }
            .joined(separator: ", ")
        model.trace(
            "MOVE WINDOW stage=\(stage) id=\(requestedID) bundle=\(item.bundleID) pid=\(item.pid) " +
            "window=\(item.windowID.map(String.init) ?? "nil") scanFrame=\(item.frame.debugDescription) " +
            "axFrame=\(axFrame) sameBundle=[\(sameBundle)] rawWindows=[\(rawWindows)]"
        )
    }
    #endif

    func move(_ id: String, to section: ItemSection, before next: String? = nil, persist: Bool = true) async -> Bool {
        if persist, !(await finishPendingActivation()) { return false }
        guard !model.isInteractingWithMenu else {
            model.notice = L10n.tr("请先关闭当前原生菜单，再调整布局。")
            return false
        }
        lastMoveFailure = nil
        guard id != next else { return true }
        guard let controller, model.managementEnabled, !model.isMoving || layoutBatchActive else { return false }
        let originalItem = model.items.first { $0.id == id }
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore

        // A move already proven by its current hosted window is a no-op. Saved
        // grouping or an AX-only offscreen frame does not prove physical placement.
        if model.preferences.mode == .aggregate, !layoutBatchActive, next == nil {
            let collapsedScan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            guard model.managementEnabled, !Task.isCancelled else { return false }
            if let current = matchingTarget(requestedID: id, reference: originalItem, in: collapsedScan) {
                let physicallyInLane = physicalSection(of: current) == section
                if physicallyInLane {
                    if persist { model.preferences.move(id, to: section, before: next) }
                    model.refresh()
                    return true
                }
            }
        }
        let ownsMovingSession = !layoutBatchActive
        if ownsMovingSession { model.isMoving = true; movingImagesCaptured = false }
        defer { if ownsMovingSession { model.isMoving = false } }
        let wasExpanded = model.isExpanded
        controller.revealForMoving(targetSection: section, movingItemID: id)
        var finishedMoving = false
        defer {
            if ownsMovingSession, !finishedMoving {
                controller.finishMoving(wasExpanded: wasExpanded, commitLivePositions: false)
            }
        }
        // A freshly recreated NSStatusItem receives its hosted window
        // asynchronously. Wait for the controller's measured-frame calibration
        // instead of assuming a fixed AppKit layout delay.
        let dividerDeadline = ContinuousClock.now.advanced(by: .seconds(7))
        while !controller.hasStableMovingBoundaries(), ContinuousClock.now < dividerDeadline {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
            guard model.managementEnabled, !Task.isCancelled else { return false }
        }
        guard controller.hasStableMovingBoundaries() else {
            model.error = L10n.tr("菜单栏落点尚未稳定，本次布局未完成；分组设置已保留。")
            return false
        }
        if !movingImagesCaptured {
            let captureSnapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            guard model.managementEnabled, !Task.isCancelled else { return false }
            model.acceptMovementSnapshot(captureSnapshot)
            await model.refreshIcons(duringMovement: true, force: true)
            movingImagesCaptured = true
            guard model.managementEnabled, !Task.isCancelled else { return false }
        }

        var fresh = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return false }
        guard var item = matchingTarget(requestedID: id, reference: originalItem, in: fresh) else {
            model.error = L10n.tr("该图标已退出或改变，请刷新后重试。")
            return false
        }
        let itemName = originalItem?.name ?? displayName(for: item)
        guard item.isMovable else { model.error = L10n.tr("macOS 固定的系统图标不能移动。"); return false }
        var hasStableWindowAssociation = hasCurrentHost(for: item)
        if !hasStableWindowAssociation {
            #if DEBUG
            traceWindowAssociation(stage: "initial-missing", requestedID: id, item: item, candidates: fresh)
            #endif
            // Recreating and narrowing status items causes a short WindowServer
            // reflow. During that interval AX can already expose the item at its
            // new frame while CGWindowList still reports the previous geometry,
            // so the scanner deliberately refuses to associate the two. Require
            // two consecutive matching window snapshots before deciding that the
            // item is available, with a bounded wait for genuinely clipped items.
            let associationDeadline = ContinuousClock.now.advanced(by: .milliseconds(1_200))
            var stableWindowID: CGWindowID?
            var stableFrame: CGRect?
            var stableSamples = 0
            while ContinuousClock.now < associationDeadline {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
                guard model.managementEnabled, !Task.isCancelled else { return false }
                guard controller.hasStableMovingBoundaries() else {
                    stableWindowID = nil
                    stableFrame = nil
                    stableSamples = 0
                    continue
                }
                let retry = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
                guard model.managementEnabled, !Task.isCancelled else { return false }
                fresh = retry
                guard let candidate = matchingTarget(requestedID: id, reference: item, in: retry) else {
                    stableWindowID = nil
                    stableFrame = nil
                    stableSamples = 0
                    continue
                }
                item = candidate
                guard let windowID = candidate.windowID, hasCurrentHost(for: candidate) else {
                    stableWindowID = nil
                    stableFrame = nil
                    stableSamples = 0
                    continue
                }
                let sameFrame = stableFrame.map {
                    abs($0.minX - candidate.frame.minX) <= 1 &&
                        abs($0.minY - candidate.frame.minY) <= 1 &&
                        abs($0.width - candidate.frame.width) <= 1 &&
                        abs($0.height - candidate.frame.height) <= 1
                } ?? false
                if stableWindowID == windowID, sameFrame {
                    stableSamples += 1
                } else {
                    stableWindowID = windowID
                    stableFrame = candidate.frame
                    stableSamples = 1
                }
                if stableSamples >= 2 {
                    hasStableWindowAssociation = true
                    #if DEBUG
                    traceWindowAssociation(stage: "recovered-stable", requestedID: id, item: candidate, candidates: retry)
                    #endif
                    break
                }
            }
            #if DEBUG
            if item.windowID == nil || stableSamples < 2 {
                traceWindowAssociation(stage: "association-timeout", requestedID: id, item: item, candidates: fresh)
            }
            #endif
        }
        // A stale AX frame can overlap an unrelated live icon. Only a concrete
        // WindowServer host is allowed to initiate and verify a physical move.
        guard item.windowID != nil && hasStableWindowAssociation else {
            lastMoveFailure = .targetUnavailable
            model.error = L10n.format("已识别到 %@，但当前菜单栏没有足够空间显示它。请先收纳一个其他图标，再重新应用布局。", itemName)
            return false
        }

        var nextReference: MenuItem?
        if let next {
            let savedReference = model.items.first { $0.id == next }
            guard let liveReference = matchingTarget(requestedID: next, reference: savedReference, in: fresh),
                  liveReference.windowID != nil,
                  verifiedSection(of: liveReference, controller: controller) == section else {
                model.error = L10n.format("用于排序的目标图标已退出或不在%@，本次移动已取消。", section.title)
                return false
            }
            nextReference = liveReference
        }

        let resolveTarget = makeTargetResolver(
            moving: item,
            to: section,
            // Movable siblings provide an exact insertion point. Fixed system
            // items instead use the section's own stable boundary.
            before: MenuBarOrderingPolicy.usesEndBoundary(beforeNextIsMovable: nextReference?.isMovable)
                ? nil : nextReference,
            controller: controller
        )
        guard let initialTarget = resolveTarget() else {
            model.error = next == nil
                ? L10n.tr("菜单栏分隔符尚未就绪，请稍后重试。")
                : L10n.tr("用于排序的目标图标已退出或位置不安全，本次移动已取消。")
            return false
        }

        var latestScan = fresh
        var latestItem = item
        var placementSatisfied = placementIsSatisfied(
            requestedID: id,
            reference: item,
            section: section,
            nextID: next,
            nextReference: nextReference,
            in: fresh,
            controller: controller
        )

        if !placementSatisfied {
            #if DEBUG
            model.trace(
                "MOVE \(id) window=\(item.windowID ?? 0) -> \(initialTarget.point) " +
                "targetWindow=\(initialTarget.windowID) section=\(section) before=\(next ?? "end")"
            )
            model.trace("DIVIDERS \(controller.diagnostics().filter { ["main", "hidden", "always"].contains($0.key) })")
            #endif

            func verifySettledPlacement(stage: String) async -> Bool {
                // Hosted views can expose their new AX frame before their live
                // CGWindow geometry settles. Wait briefly before another drag.
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                repeat {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
                    guard model.managementEnabled, !Task.isCancelled else { return false }
                    latestScan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
                    guard model.managementEnabled, !Task.isCancelled else { return false }
                    if let refreshed = matchingTarget(requestedID: id, reference: latestItem, in: latestScan) {
                        latestItem = refreshed
                    }
                    placementSatisfied = placementIsSatisfied(
                        requestedID: id, reference: latestItem, section: section,
                        nextID: next, nextReference: nextReference,
                        in: latestScan, controller: controller
                    )
                    if placementSatisfied { break }
                } while ContinuousClock.now < deadline
                #if DEBUG
                let result = matchingTarget(requestedID: id, reference: latestItem, in: latestScan)
                traceMoveVerification(
                    stage: stage, id: id, item: result, expected: section,
                    verified: result.map { verifiedSection(of: $0, controller: controller) }, controller: controller
                )
                model.trace("MOVE ORDER stage=\(stage) id=\(id) satisfied=\(placementSatisfied)")
                #endif
                return placementSatisfied
            }

            // Exact window routing remains available when either source or
            // destination is under the notch or outside the clickable screen.
            if !placementSatisfied {
                for route in eventRoutes(for: latestItem) {
                    guard model.managementEnabled, !Task.isCancelled,
                          let routeInitialTarget = resolveTarget() else { break }
                    #if DEBUG
                    model.trace("MOVE ROUTED id=\(id) route=\(route.kind.rawValue) pid=\(route.pid)")
                    #endif
                    model.error = nil
                    _ = await routedMoveToBoundary(
                        latestItem, initialTarget: routeInitialTarget,
                        resolvingTarget: resolveTarget, via: route
                    )
                    guard model.managementEnabled, !Task.isCancelled else { return false }
                    // A failed delivery barrier can still follow a real move;
                    // always audit placement before sending another route.
                    if await verifySettledPlacement(stage: "routed-\(route.kind.rawValue)") { break }
                }
            }

            guard placementSatisfied else {
                model.layoutPending = true
                if layoutBatchActive {
                    model.error = L10n.format("%@ 没有到达指定位置，已保留它的分组设置。", itemName)
                    return false
                }
                controller.finishMoving(wasExpanded: wasExpanded, commitLivePositions: false)
                finishedMoving = true
                model.setManagement(false)
                model.error = L10n.format("%@ 没有到达指定位置。Qbar 已暂停菜单栏管理，避免图标停在错误区域；分组设置仍保留。", itemName)
                return false
            }
        }

        // The batch owns its divider instances until every item has been
        // arranged and audited. Collapsing per item changes sibling positions.
        if layoutBatchActive { model.error = nil; return true }

        controller.finishMoving(wasExpanded: wasExpanded, commitLivePositions: true)
        finishedMoving = true
        guard await controller.waitForSettledDividers(timeout: .seconds(2)) else {
            model.layoutPending = true
            model.setManagement(false)
            model.error = L10n.format("Qbar 分隔符在移动 %@ 后没有稳定下来。菜单栏管理已暂停；分组设置仍保留。", itemName)
            return false
        }
        guard model.managementEnabled, !Task.isCancelled else { return false }
        let settledScan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return false }
        let settled = matchingTarget(requestedID: id, reference: latestItem, in: settledScan)
        let settledSection = settled.map { verifiedSection(of: $0, controller: controller) }
        let settledPlacement = placementIsSatisfied(
            requestedID: id,
            reference: latestItem,
            section: section,
            nextID: next,
            nextReference: nextReference,
            in: settledScan,
            controller: controller
        )
        #if DEBUG
        traceMoveVerification(stage: "settled", id: id, item: settled, expected: section,
                              verified: settledSection, controller: controller)
        model.trace("MOVE ORDER stage=settled id=\(id) satisfied=\(settledPlacement)")
        #endif
        guard settled != nil, settledSection == section, settledPlacement else {
            model.layoutPending = true
            model.setManagement(false)
            model.error = L10n.format("%@ 在收起菜单栏后未留在指定位置。Qbar 已暂停管理；分组设置仍保留。", itemName)
            return false
        }
        if persist {
            model.preferences.move(id, to: section, before: next)
        }
        model.refresh()
        model.error = nil
        return true
    }

    func activate(_ id: String, rightClick: Bool, normalizedX: CGFloat? = nil,
                  trayAnchor: TrayActivationAnchor? = nil) async {
        guard model.managementEnabled else { model.error = L10n.tr("请先启用菜单栏管理。"); return }
        guard await beginTemporaryMotion() else { return }
        defer { temporaryMotionBusy = false }
        guard !Task.isCancelled, let original = model.items.first(where: { $0.id == id }) else { return }
        if temporaryActivations[id] != nil {
            controller?.collapse()
            model.notice = L10n.format("%@ 已临时显示在 Mac 菜单栏。", displayName(for: original))
            return
        }
        if temporaryActivations.isEmpty { resetNativeMenuTracking() }
        model.error = nil
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        let scanned = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled,
              let item = activationTarget(for: original, in: scanned) else {
            model.error = L10n.format("%@ 已退出或菜单栏图标发生变化，请刷新后重试。", displayName(for: original))
            return
        }
        if model.preferences.section(for: id) != .visible {
            await exposeForTemporaryActivation(item, in: scanned, rightClick: rightClick, normalizedX: normalizedX)
            return
        }
        if trayAnchor != nil,
           physicalSection(of: item) != .visible || !isStatusItemReachable(item) {
            // A newly launched app can acquire its host behind a parked
            // divider before the background repair settles. Its saved Visible
            // choice remains authoritative: selecting the tray fallback moves
            // only this real host into the Mac menu bar and leaves it there.
            model.trace("TRAY visible fallback id=\(id) actual=\(physicalSection(of: item)?.rawValue ?? "unknown")")
            let moved = await moveForTemporaryActivation(id, to: .visible,
                                                         requiringReachableVisible: true)
            guard model.managementEnabled, !Task.isCancelled else { return }
            let verified = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            guard moved,
                  let current = activationTarget(for: item, in: verified),
                  physicalSection(of: current) == .visible,
                  isStatusItemReachable(current) else {
                model.error = L10n.format("%@ 尚未移到可点击的菜单栏位置。请先将其他图标收纳，腾出右侧空间后重试。", displayName(for: item))
                return
            }
            controller?.collapse()
            model.error = nil
            model.clearVisibleFallback(id: id)
            model.notice = L10n.format("%@ 已显示在 Mac 菜单栏。", displayName(for: item))
            model.trace("TRAY visible restored id=\(id) window=\(current.windowID ?? 0)")
            return
        }
        controller?.collapse()
        if trayAnchor != nil { model.clearVisibleFallback(id: id) }
        model.notice = L10n.format("%@ 已在 Mac 菜单栏，请直接在那里操作。", displayName(for: item))
    }

    private func resetNativeMenuTracking() {
        activationGeneration &+= 1
        directMenuTrackingTask?.cancel()
        directMenuTrackingTask = nil
        model.isInteractingWithMenu = false
        model.nativeMenuFrames = []
    }

    private func exposeForTemporaryActivation(_ item: MenuItem, in candidates: [MenuItem],
                                             rightClick: Bool, normalizedX: CGFloat?) async {
        guard let controller, let windowID = item.windowID, item.isMovable, hasCurrentHost(for: item) else {
            model.error = L10n.format("%@ 的菜单栏控件暂未就绪。", displayName(for: item))
            return
        }
        let section = model.preferences.section(for: item.id)
        let members = physicalMembers(in: candidates, section: section, controller: controller)
        let rightIDs = MenuBarRestorationPolicy.rightNeighbours(of: windowID, among: members)
        let pending = TemporaryActivation(
            item: item, originalSection: section,
            rightNeighbours: rightIDs.compactMap { id in candidates.first { $0.windowID == id } }
        )
        temporaryActivations[item.id] = pending
        model.trace("TEMP SHOW begin id=\(item.id) saved=\(section)")
        let moved = await moveForTemporaryActivation(item.id, to: .visible)
        guard moved, model.managementEnabled, !Task.isCancelled else {
            let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
            let snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            if let current = activationTarget(for: item, in: snapshot),
               physicalSection(of: current) == .visible, model.managementEnabled {
                // The move may have reached macOS even if its final receipt
                // failed. Keep this genuine host tracked so it can return.
                model.temporarilyVisible.insert(item.id)
                controller.collapse()
                markTemporaryActivationReady(pending)
                ensureIdleRestorationTask()
            } else {
                clearTemporaryActivation(pending)
            }
            model.error = L10n.format("%@ 暂未移到菜单栏，分组设置已保留。", displayName(for: item))
            return
        }
        // Keep the tray still until the real host has reached the menu bar.
        // Closing it on the initial click leaves a visible gap while macOS
        // processes the status-item move and makes the transition look like a
        // jump followed by a delayed appearance.
        controller.collapse()
        model.temporarilyVisible.insert(item.id)
        markTemporaryActivationReady(pending)
        ensureIdleRestorationTask()
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        let snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard let exposed = activationTarget(for: item, in: snapshot),
              physicalSection(of: exposed) == .visible else {
            model.notice = L10n.format("%@ 已临时显示，请在 Mac 菜单栏点击；空闲后自动收回。", displayName(for: item))
            return
        }
        // The user's click only restores this item's original menu-bar host.
        // Subsequent clicks are made by the user in macOS, so Qbar never moves
        // the pointer to the host or synthesizes a second click.
        model.notice = L10n.format("%@ 已在 Mac 菜单栏，连续无操作 %d 秒后收回。", displayName(for: item), Int(model.preferences.temporaryDelay))
        model.trace("TEMP SHOW ready id=\(item.id) window=\(exposed.windowID ?? 0) idleDelay=\(model.preferences.temporaryDelay)")
    }

    private func beginTemporaryMotion() async -> Bool {
        while temporaryMotionBusy || model.isMoving || hasNativeMenuTracking {
            guard model.managementEnabled, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        guard model.managementEnabled, !Task.isCancelled else { return false }
        temporaryMotionBusy = true
        return true
    }

    private func markTemporaryActivationReady(_ pending: TemporaryActivation) {
        guard var current = temporaryActivations[pending.item.id], current.token == pending.token else { return }
        let now = ProcessInfo.processInfo.systemUptime
        current.shownAt = now
        current.lastInteractionAt = now
        current.menuWindowBaseline = activationWindows()
        temporaryActivations[pending.item.id] = current
    }

    private func ensureIdleRestorationTask() {
        if temporaryClickMonitor == nil {
            temporaryClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let point = event.cgEvent?.location else { return }
                Task { @MainActor [weak self] in self?.recordTemporaryStatusClick(at: point) }
            }
        }
        guard activationCleanupTask == nil, !temporaryActivations.isEmpty else { return }
        activationCleanupGeneration &+= 1
        let generation = activationCleanupGeneration
        activationCleanupTask = Task { [weak self] in
            guard let self else { return }
            while self.model.managementEnabled, !Task.isCancelled, !self.temporaryActivations.isEmpty {
                await self.restoreDueTemporaryActivations()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            if self.activationCleanupGeneration == generation { self.activationCleanupTask = nil }
        }
    }

    private func recordTemporaryStatusClick(at point: CGPoint) {
        guard !model.isMoving else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for entry in temporaryActivations.values {
            guard entry.shownAt != nil,
                  let item = model.items.first(where: { $0.id == entry.item.id }),
                  item.frame.contains(point),
                  var current = temporaryActivations[entry.item.id],
                  current.token == entry.token else { continue }
            current.lastInteractionAt = now
            temporaryActivations[item.id] = current
            lastTemporaryStatusClick = (item.id, now)
            break
        }
    }

    private func restoreDueTemporaryActivations() async {
        guard model.preferences.rehideTemporary, !temporaryMotionBusy, !model.isMoving else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let anyInput = CGEventType(rawValue: UInt32.max)!
        let recentInput = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput) < 0.5
        let pointer = Coordinates.quartz(NSEvent.mouseLocation)
        let liveWindows = activationWindows()
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let popupOwners = Set(temporaryActivations.values.compactMap { entry -> String? in
            guard entry.shownAt != nil else { return nil }
            let popups = MenuBarActivationPolicy.newTargetUI(
                before: entry.menuWindowBaseline, after: liveWindows,
                applicationPID: entry.item.pid, hostingPID: entry.item.windowOwnerPID,
                popupLayer: popupLayer, statusLayer: statusLayer,
                excludedPID: getpid(), relatedApplicationPIDs: relatedApplicationPIDs(for: entry.item)
            ).filter { $0.layer > Int(CGWindowLevelForKey(.normalWindow)) }
            return popups.isEmpty ? nil : entry.item.id
        })
        let menuOpen = hasNativeMenuTracking || !popupOwners.isEmpty
        let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right)
        let ordered = temporaryActivations.values.sorted { ($0.shownAt ?? .infinity) < ($1.shownAt ?? .infinity) }
        let expandedOwners = Set(ordered.compactMap { entry -> String? in
            guard let item = model.items.first(where: { $0.id == entry.item.id }),
                  item.element.flatMap({ AXAccess.value($0, kAXExpandedAttribute) as? Bool }) == true else { return nil }
            return entry.item.id
        })
        if menuOpen {
            let candidates = expandedOwners.isEmpty ? popupOwners : expandedOwners
            if let clicked = lastTemporaryStatusClick,
               candidates.contains(clicked.id), now - clicked.at < 30 {
                activeTemporaryMenuOwnerID = clicked.id
            } else if candidates.count == 1 {
                activeTemporaryMenuOwnerID = candidates.first
            } else if activeTemporaryMenuOwnerID == nil,
                      let clicked = lastTemporaryStatusClick, now - clicked.at < 3 {
                activeTemporaryMenuOwnerID = clicked.id
            }
        } else if let ownerID = activeTemporaryMenuOwnerID {
            if var owner = temporaryActivations[ownerID] {
                owner.lastInteractionAt = now
                temporaryActivations[ownerID] = owner
            }
            activeTemporaryMenuOwnerID = nil
        }
        for entry in ordered {
            guard var current = temporaryActivations[entry.item.id], current.token == entry.token,
                  let shownAt = current.shownAt else { continue }
            let liveItem = model.items.first { $0.id == current.item.id }
            let ownMenuOpen = liveItem?.element.flatMap {
                AXAccess.value($0, kAXExpandedAttribute) as? Bool
            } == true
            if ownMenuOpen || activeTemporaryMenuOwnerID == current.item.id ||
                (recentInput && liveItem?.frame.contains(pointer) == true) {
                current.lastInteractionAt = now
                temporaryActivations[current.item.id] = current
            }
            // A native popup can share its host process with another icon.
            // Never move an item or send Escape while any popup is tracking.
            guard !menuOpen, !buttonDown, !temporaryMotionBusy, !model.isMoving else { continue }
            let lastUse = current.lastInteractionAt ?? shownAt
            guard now - lastUse >= model.preferences.temporaryDelay else { continue }
            model.trace("TEMP IDLE due id=\(current.item.id) ownIdle=\(now - lastUse) delay=\(model.preferences.temporaryDelay)")
            await restoreTemporaryActivation(current)
        }
    }

    private func finishPendingActivation() async -> Bool {
        let ordered = temporaryActivations.values.sorted { ($0.shownAt ?? .infinity) < ($1.shownAt ?? .infinity) }
        for pending in ordered {
            await restoreTemporaryActivation(pending)
            if temporaryActivations[pending.item.id]?.token == pending.token {
                model.notice = L10n.tr("请先关闭当前原生菜单，再调整布局。")
                return false
            }
        }
        return temporaryActivations.isEmpty
    }

    private func nativeClickEvents(
        for item: MenuItem, at point: CGPoint, rightClick: Bool
    ) -> (move: CGEvent, down: CGEvent, up: CGEvent)? {
        guard let windowID = item.windowID,
              let window = MenuScanner.windows().first(where: { $0.id == windowID }),
              window.frame.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        let button: CGMouseButton = rightClick ? .right : .left
        let downType: CGEventType = rightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightClick ? .rightMouseUp : .leftMouseUp
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else { return nil }
        for event in [move, down, up] {
            event.flags = []
        }
        // At the HID entry point WindowServer owns hit testing and remote-view
        // dispatch. Pinning a host PID here bypasses the application's view.
        // Keep explicit PID/window routing in routedClick only.
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        return (move, down, up)
    }

    private func performNativeClick(_ item: MenuItem, at point: CGPoint, rightClick: Bool) async -> Bool {
        guard model.managementEnabled, !Task.isCancelled else { return false }
        if let root = item.element {
            let children = AXAccess.children(root).flatMap { [$0] + AXAccess.children($0) }
            let candidates = children + [root]
            for element in candidates {
                guard let frame = AXAccess.frame(element), frame.width <= 64,
                      frame.insetBy(dx: -1, dy: -1).contains(point) else { continue }
                var names: CFArray?
                guard AXUIElementCopyActionNames(element, &names) == .success,
                      let action = MenuBarDirectActivationPolicy.action(rightClick: rightClick,
                                                                       available: names as? [String] ?? []) else { continue }
                let result = AXUIElementPerformAction(element, action as CFString)
                model.trace("CLICK AX visible id=\(item.id) action=\(action) result=\(result.rawValue)")
                // An uncertain result may already have opened the native menu.
                // Never replay that click and inadvertently close it again.
                if !MenuBarDirectActivationPolicy.mayFallback(after: result) { return true }
                break
            }
        }
        guard let events = nativeClickEvents(for: item, at: point, rightClick: rightClick) else { return false }
        let originalCursor = CGEvent(source: nil)?.location
        let cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        guard cursorHidden else { return false }
        defer {
            if let originalCursor { CGWarpMouseCursorPosition(originalCursor) }
            if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }
        // WindowServer and the app's tracking areas must see the pointer arrive
        // before mouse-down. A bare down/up coordinate can leave remote-hosted
        // controls using the pointer's previous window and silently ignore it.
        CGWarpMouseCursorPosition(point)
        events.move.post(tap: .cghidEventTap)
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        guard model.managementEnabled, !Task.isCancelled,
              let windowID = item.windowID,
              let window = MenuScanner.windows().first(where: { $0.id == windowID }),
              window.frame.insetBy(dx: -1, dy: -1).contains(point) else { return false }
        events.down.post(tap: .cghidEventTap)
        // Always release after mouse-down, including an interrupted operation.
        try? await Task.sleep(for: .milliseconds(45))
        events.up.post(tap: .cghidEventTap)
        model.trace("CLICK PHYSICAL synchronized id=\(item.id) window=\(windowID) point=\(point) right=\(rightClick)")
        return true
    }

    private func nativeMenuPoint(for item: MenuItem, normalizedX: CGFloat?) -> CGPoint? {
        guard hasReliableGrabPoint(for: item), let intersection = grabIntersection(for: item) else { return nil }
        if let normalizedX, normalizedX.isFinite {
            let mapped = item.frame.minX + min(max(normalizedX, 0), 1) * item.frame.width
            return CGPoint(
                x: min(max(mapped, intersection.minX + 1), intersection.maxX - 1),
                y: intersection.midY
            )
        }
        // Shortcuts and the layout editor have no image-relative point. Prefer
        // a concrete primary AX status button when the application provides it.
        if let element = item.element {
            let children = AXAccess.children(element).flatMap { child in
                [child] + AXAccess.children(child)
            }
            let buttons = children.compactMap { child -> CGRect? in
                let role = AXAccess.string(child, kAXRoleAttribute)
                guard role == kAXButtonRole || role == kAXMenuBarItemRole,
                      let frame = AXAccess.frame(child), frame.width <= 48,
                      intersection.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
                return frame
            }
            if let first = buttons.min(by: { $0.minX < $1.minX }) {
                return CGPoint(x: first.midX, y: first.midY)
            }
        }
        return CGPoint(x: intersection.midX, y: intersection.midY)
    }

    private func activationWindows() -> [MenuBarActivationWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return MenuBarActivationWindow(id: id, pid: pid, layer: layer)
        }
    }

    private func relatedApplicationPIDs(for item: MenuItem) -> Set<pid_t> {
        func applicationRoot(_ application: NSRunningApplication) -> URL? {
            guard let bundleURL = application.bundleURL,
                  let root = MenuBarApplicationIdentityPolicy.outermostApplicationURL(
                    of: bundleURL.standardizedFileURL.resolvingSymlinksInPath()
                  ),
                  Bundle(url: root)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
            else { return nil }
            return root
        }
        guard let sourceApplication = NSRunningApplication(processIdentifier: item.pid),
              let sourceRoot = applicationRoot(sourceApplication) else { return [] }
        // A helper's bundle identifier is not sufficient to establish ownership.
        // Its actual outer app bundle must be the same installed package as the
        // candidate's, including its canonical path and symlink destination.
        return Set(NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.processIdentifier != getpid(),
                  applicationRoot(application) == sourceRoot else { return nil }
            return application.processIdentifier
        })
    }

    private func waitForNativeUI(for item: MenuItem, before: [MenuBarActivationWindow]) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let oldIDs = Set(before.map(\.id))
        var loggedCandidates = Set<CGWindowID>()
        let relatedPIDs = relatedApplicationPIDs(for: item)
        model.trace("CLICK UI family id=\(item.id) appPID=\(item.pid) relatedPIDs=\(relatedPIDs.sorted())")
        repeat {
            guard model.managementEnabled, !Task.isCancelled else { return false }
            let after = activationWindows()
            let confirmed = MenuBarActivationPolicy.newTargetUI(
                before: before, after: after, applicationPID: item.pid, hostingPID: item.windowOwnerPID,
                popupLayer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                statusLayer: Int(CGWindowLevelForKey(.statusWindow)), excludedPID: getpid(),
                relatedApplicationPIDs: relatedPIDs
            )
            let confirmedIDs = Set(confirmed.map(\.id))
            for candidate in after where !oldIDs.contains(candidate.id) && loggedCandidates.insert(candidate.id).inserted {
                model.trace(
                    "CLICK UI candidate id=\(item.id) window=\(candidate.id) pid=\(candidate.pid) " +
                    "layer=\(candidate.layer) appPID=\(item.pid) hostPID=\(item.windowOwnerPID ?? 0) " +
                    "self=\(candidate.pid == getpid()) accepted=\(confirmedIDs.contains(candidate.id))"
                )
            }
            if !confirmed.isEmpty {
                model.trace("CLICK UI confirmed id=\(item.id) windows=\(confirmed.map(\.id))")
                return true
            }
            if let element = item.element,
               AXAccess.value(element, kAXExpandedAttribute) as? Bool == true {
                model.trace("CLICK UI expanded id=\(item.id)")
                return true
            }
            if ContinuousClock.now >= deadline { break }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
        } while true
        model.trace("CLICK UI timeout id=\(item.id) appPID=\(item.pid) hostPID=\(item.windowOwnerPID ?? 0) candidates=\(loggedCandidates.sorted())")
        return false
    }

    private func moveForTemporaryActivation(_ id: String, to section: ItemSection,
                                            before next: String? = nil,
                                            requiringReachableVisible: Bool = false) async -> Bool {
        guard let controller, model.managementEnabled, !model.isMoving, !layoutBatchActive else { return false }
        let reference = model.items.first(where: { $0.id == id })
        model.isMoving = true
        defer { model.isMoving = false }
        // Keep the oversized markers parked throughout this operation. Shrinking
        // them would expose every hidden app before moving the selected one.
        guard await controller.waitForSettledDividers(timeout: .seconds(2)) else { return false }
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        var snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled,
              let original = reference,
              var item = activationTarget(for: original, in: snapshot),
              let windowID = item.windowID, item.isMovable, hasCurrentHost(for: item) else { return false }
        let beforeWindows = MenuScanner.windows(includeDividers: true)
        func groups(_ items: [MenuItem], windows: [MenuScanner.Window]) -> [CGWindowID: ItemSection] {
            Dictionary(items.compactMap { candidate in
                guard let windowID = candidate.windowID,
                      let section = physicalSection(of: candidate, in: windows) else { return nil }
                return (windowID, section)
            }, uniquingKeysWith: { first, _ in first })
        }
        let beforeGroups = groups(snapshot, windows: beforeWindows)
        let nextReference = next.flatMap { next in snapshot.first(where: { $0.id == next }) }
        if next != nil, nextReference?.windowID == nil { return false }
        let resolveTarget = makeTargetResolver(moving: item, to: section, before: nextReference,
                                               controller: controller,
                                               requiringReachableVisible: requiringReachableVisible)
        var placed = placementIsSatisfied(requestedID: id, reference: item, section: section,
                                          nextID: next, nextReference: nextReference, in: snapshot,
                                          controller: controller,
                                          requiringReachableVisible: requiringReachableVisible)
        let markerDiagnostics = controller.diagnostics().filter { ["hidden", "always"].contains($0.key) }
        model.trace("TEMP SINGLE begin id=\(id) section=\(section) parked=\(markerDiagnostics)")
        if !placed {
            // Exact hosted-window routing supports offscreen sources and parked
            // boundaries. There is deliberately no physical cursor-drag fallback.
            for route in eventRoutes(for: item) {
                guard model.managementEnabled, !Task.isCancelled, let target = resolveTarget() else { return false }
                model.trace("TEMP SINGLE route id=\(id) pid=\(route.pid) kind=\(route.kind.rawValue)")
                _ = await routedMoveToBoundary(item, initialTarget: target, resolvingTarget: resolveTarget, via: route)
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
                repeat {
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
                    guard model.managementEnabled, !Task.isCancelled else { return false }
                    snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
                    if let current = activationTarget(for: original, in: snapshot) { item = current }
                    placed = placementIsSatisfied(requestedID: id, reference: item, section: section,
                                                  nextID: next, nextReference: nextReference, in: snapshot,
                                                  controller: controller,
                                                  requiringReachableVisible: requiringReachableVisible)
                    if placed { break }
                } while ContinuousClock.now < deadline
                // A missing delivery receipt can follow a successful move. The
                // measured placement decides whether another route is needed.
                if placed { break }
            }
        }
        guard placed else {
            model.trace("TEMP SINGLE failed id=\(id)")
            return false
        }
        // AX may temporarily omit unrelated extras while WindowServer reflows.
        // Verify the same concrete hosted windows directly before concluding
        // that another item crossed a boundary or disappeared.
        var afterGroups: [CGWindowID: ItemSection] = [:]
        let groupDeadline = ContinuousClock.now.advanced(by: .milliseconds(1_500))
        repeat {
            guard model.managementEnabled, !Task.isCancelled,
                  let boundaries = controller.placementBoundaries() else { return false }
            let liveWindows = MenuScanner.windows(includeDividers: true)
            let members = liveWindows.map {
                MenuBarPhysicalMember(windowID: $0.id, frame: $0.frame, isMovable: true)
            }
            afterGroups = Dictionary(beforeGroups.keys.compactMap { id -> (CGWindowID, ItemSection)? in
                guard let host = liveWindows.first(where: { $0.id == id }),
                      let actual = MenuBarPlacementPolicy.section(
                        windowID: id, frame: host.frame, liveMembers: members,
                        always: boundaries.always, hidden: boundaries.hidden
                      ) else { return nil }
                return (id, actual)
            }, uniquingKeysWith: { first, _ in first })
            if MenuBarTemporaryMovePolicy.preservesOtherGroups(before: beforeGroups, after: afterGroups,
                                                              selectedWindowID: windowID) { break }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
        } while ContinuousClock.now < groupDeadline
        guard MenuBarTemporaryMovePolicy.preservesOtherGroups(before: beforeGroups, after: afterGroups,
                                                            selectedWindowID: windowID) else {
            model.trace("TEMP SINGLE unexpected sibling change id=\(id) before=\(beforeGroups) after=\(afterGroups)")
            return false
        }
        model.acceptMovementSnapshot(snapshot)
        model.error = nil
        model.trace("TEMP SINGLE verified id=\(id) section=\(section) otherGroupsPreserved=true")
        model.refresh()
        return true
    }

    private func restoreTemporaryActivation(_ pending: TemporaryActivation) async {
        guard temporaryActivations[pending.item.id]?.token == pending.token,
              model.managementEnabled, !Task.isCancelled else { return }
        guard await beginTemporaryMotion() else { return }
        defer { temporaryMotionBusy = false }
        guard temporaryActivations[pending.item.id]?.token == pending.token,
              !hasNativeMenuTracking else { return }
        let section = model.preferences.section(for: pending.item.id, fallback: pending.originalSection)
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        let snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled else { model.layoutPending = true; return }
        guard matchingTarget(requestedID: pending.item.id, reference: pending.item, in: snapshot) != nil else {
            clearTemporaryActivation(pending)
            model.refresh()
            return
        }
        let next: MenuItem?
        if model.preferences.mode == .aggregate {
            // The tray's saved ordering is authoritative. Park the item at its
            // lane boundary; no hidden sibling reorder is needed for returning.
            next = nil
        } else if section == pending.originalSection {
            // Keep the original physical right neighbour even if its title or
            // saved logical order changed while the native menu was open. If
            // it exited, use the next surviving neighbour in that same lane.
            next = pending.rightNeighbours.lazy.compactMap { reference -> MenuItem? in
                guard let current = self.matchingTarget(requestedID: reference.id, reference: reference, in: snapshot),
                      self.physicalSection(of: current) == section else { return nil }
                return current
            }.first
        } else {
            let ordered = model.preferences.rules.filter { $0.section == section }.sorted { $0.order < $1.order }
            let following = ordered.firstIndex(where: { $0.id == pending.item.id }).map {
                Array(ordered.dropFirst($0 + 1))
            } ?? []
            next = following.lazy.compactMap { rule -> MenuItem? in
                guard let current = snapshot.first(where: { $0.id == rule.id }),
                      self.physicalSection(of: current) == section else { return nil }
                return current
            }.first
        }
        if await moveForTemporaryActivation(pending.item.id, to: section, before: next?.id) {
            clearTemporaryActivation(pending)
            let name = displayName(for: pending.item)
            let temporaryNotices = [
                L10n.format("%@ 已临时显示在 Mac 菜单栏。", name),
                L10n.format("%@ 已在 Mac 菜单栏，请直接在那里操作。", name),
                L10n.format("%@ 已临时显示，请在 Mac 菜单栏点击；空闲后自动收回。", name),
                L10n.format("%@ 已在 Mac 菜单栏，连续无操作 %d 秒后收回。", name, Int(model.preferences.temporaryDelay))
            ]
            if let notice = model.notice, temporaryNotices.contains(notice) {
                model.notice = nil
            }
            model.trace("TEMP RETURN restored id=\(pending.item.id) section=\(section) before=\(next?.id ?? "boundary")")
        } else {
            model.layoutPending = true
            model.error = L10n.format("%@ 的收纳位置尚未恢复，原分组设置已保留。", displayName(for: pending.item))
            model.trace("TEMP RETURN failed id=\(pending.item.id) section=\(section)")
        }
    }

    private func clearTemporaryActivation(_ pending: TemporaryActivation) {
        guard temporaryActivations[pending.item.id]?.token == pending.token else { return }
        temporaryActivations.removeValue(forKey: pending.item.id)
        model.temporarilyVisible.remove(pending.item.id)
        if temporaryActivations.isEmpty {
            if let temporaryClickMonitor { NSEvent.removeMonitor(temporaryClickMonitor) }
            temporaryClickMonitor = nil
            lastTemporaryStatusClick = nil
            activeTemporaryMenuOwnerID = nil
            resetNativeMenuTracking()
        }
    }

    private func activationWindowFrames() -> [CGWindowID: CGRect] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var frames: [CGWindowID: CGRect] = [:]
        for entry in list {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            frames[id] = CGRect(x: x, y: y, width: width, height: height)
        }
        return frames
    }

    private func nativeMenuDidOpen(_ item: MenuItem, before: [MenuBarActivationWindow],
                                   anchor: TrayActivationAnchor?, generation: UInt64) async {
        let related = relatedApplicationPIDs(for: item)
        model.isInteractingWithMenu = true
        directMenuTrackingTask = Task { [weak self] in
            guard let self else { return }
            var lastSeen = ContinuousClock.now
            while !Task.isCancelled, generation == self.activationGeneration, self.model.managementEnabled {
                let popups = MenuBarActivationPolicy.newTargetUI(
                    before: before, after: self.activationWindows(), applicationPID: item.pid,
                    hostingPID: item.windowOwnerPID, popupLayer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                    statusLayer: Int(CGWindowLevelForKey(.statusWindow)), excludedPID: getpid(), relatedApplicationPIDs: related
                ).filter { $0.layer > Int(CGWindowLevelForKey(.normalWindow)) }
                let ids = Set(popups.map(\.id))
                let frames = self.activationWindowFrames().filter { ids.contains($0.key) }.map(\.value)
                self.model.nativeMenuFrames = frames
                if !frames.isEmpty { lastSeen = .now }
                if frames.isEmpty && ContinuousClock.now - lastSeen > .seconds(2) { break }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { break }
            }
            guard generation == self.activationGeneration else { return }
            self.model.isInteractingWithMenu = false
            self.model.nativeMenuFrames = []
            self.directMenuTrackingTask = nil
        }
    }

    /// Menu-bar titles can change between the popup scan and the click scan
    /// (for example a network-speed or temperature item). Prefer the stable
    /// item ID, then the underlying window, and only fall back to the app when
    /// it owns exactly one status item so we never click a sibling icon.
    private func matchingTarget(requestedID: String, reference: MenuItem?, in candidates: [MenuItem]) -> MenuItem? {
        if let exact = candidates.first(where: { $0.id == requestedID }) { return exact }
        guard let reference else { return nil }
        if let windowID = reference.windowID,
           let sameWindow = candidates.first(where: { $0.windowID == windowID }) { return sameWindow }
        let sameApplication = candidates.filter { $0.bundleID == reference.bundleID }
        return sameApplication.count == 1 ? sameApplication[0] : nil
    }

    private func physicalMembers(
        in candidates: [MenuItem],
        section: ItemSection,
        controller: StatusController
    ) -> [MenuBarPhysicalMember] {
        candidates.compactMap { candidate in
            guard let windowID = candidate.windowID,
                  physicalSection(of: candidate) == section else { return nil }
            return MenuBarPhysicalMember(windowID: windowID, frame: candidate.frame, isMovable: candidate.isMovable)
        }
    }

    private func endBoundaryWindow(
        for section: ItemSection,
        controller: StatusController,
        in windows: [MenuScanner.Window]
    ) -> MenuScanner.Window? {
        guard let boundary = controller.movingBoundaryWindow(for: section) else { return nil }
        return windows.first(where: { $0.id == boundary.id })
    }

    private func placementIsSatisfied(
        requestedID: String,
        reference: MenuItem,
        section: ItemSection,
        nextID: String?,
        nextReference: MenuItem?,
        in candidates: [MenuItem],
        controller: StatusController,
        requiringReachableVisible: Bool = false
    ) -> Bool {
        guard let moved = matchingTarget(requestedID: requestedID, reference: reference, in: candidates),
              physicalSection(of: moved) == section else { return false }
        if requiringReachableVisible, section == .visible, !isStatusItemReachable(moved) { return false }
        // Aggregate mode renders hidden items from saved rules, so their
        // physical sibling order behind an oversized divider is irrelevant.
        // Once an item is in the correct lane, avoid another hazardous drag
        // merely to reproduce the popup's logical order. A concrete, live host
        // remains required even when the popup supplies the logical order.
        if model.preferences.mode == .aggregate, !restoringSavedGroups, nextID == nil { return true }
        guard let movedWindowID = moved.windowID else { return false }
        let usesEndBoundary = MenuBarOrderingPolicy.usesEndBoundary(
            beforeNextIsMovable: nextID == nil ? nil : nextReference?.isMovable
        )
        let targetWindowID: CGWindowID?
        if let nextID, !usesEndBoundary {
            guard let target = matchingTarget(requestedID: nextID, reference: nextReference, in: candidates),
                  let windowID = target.windowID,
                  verifiedSection(of: target, controller: controller) == section else { return false }
            targetWindowID = windowID
        } else {
            targetWindowID = nil
        }
        let members = physicalMembers(in: candidates, section: section, controller: controller)
        guard MenuBarOrderingPolicy.isSatisfied(
            movingWindowID: movedWindowID,
            before: targetWindowID,
            among: members
        ) else { return false }
        guard usesEndBoundary else { return true }
        // Visible items have no fixed right boundary. Qbar.Main is a trigger
        // that can sit anywhere in this lane and must never decide membership.
        if section == .visible { return true }

        // The last external movable item must sit immediately to the left of the
        // section's Qbar boundary. Merely being the last scanned app is not enough:
        // an earlier implementation let Qbar.Main drift left of the whole group.
        let windows = MenuScanner.windows(includeDividers: true)
        guard let boundary = endBoundaryWindow(for: section, controller: controller, in: windows),
              let movedWindow = windows.first(where: { $0.id == movedWindowID }) else { return false }
        let row = windows.filter {
            (!$0.title.hasPrefix("Qbar.") || $0.id == boundary.id) &&
            abs($0.frame.midY - movedWindow.frame.midY) < 8 &&
                $0.frame.maxX >= min(movedWindow.frame.minX, boundary.frame.minX) &&
                $0.frame.minX <= max(movedWindow.frame.maxX, boundary.frame.maxX)
        }.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id < $1.id
        }
        guard let movedIndex = row.firstIndex(where: { $0.id == movedWindowID }),
              let boundaryIndex = row.firstIndex(where: { $0.id == boundary.id }) else { return false }
        return movedIndex + 1 == boundaryIndex
    }

    private func makeTargetResolver(
        moving item: MenuItem,
        to section: ItemSection,
        before next: MenuItem?,
        controller: StatusController,
        requiringReachableVisible: Bool = false
    ) -> () -> DropTarget? {
        if let next {
            guard item.windowID != nil else { return { nil } }
            guard let targetWindowID = next.windowID else { return { nil } }
            return { [weak controller] in
                guard let controller,
                      let window = MenuScanner.windows(includeDividers: true).first(where: { $0.id == targetWindowID }),
                      controller.classify(window.frame) == section else { return nil }
                return DropTarget(
                    point: CGPoint(x: window.frame.minX + 1, y: window.frame.midY),
                    windowID: window.id
                )
            }
        }

        // Keep the chosen real host for the duration of one routed drag.
        // Mouse-down reflows menu-bar frames and can briefly change lane
        // classification; switching or dropping the target mid-drag turns a
        // valid single-item move into a false "target disappeared" error.
        var siblingTarget: (windowID: CGWindowID, rightEdge: Bool)?
        return { [weak controller] in
            guard let controller else { return nil }
            let windows = MenuScanner.windows(includeDividers: true)
            if let siblingTarget {
                guard let host = windows.first(where: { $0.id == siblingTarget.windowID }),
                      controller.classify(host.frame) == section else { return nil }
                return DropTarget(
                    point: CGPoint(x: siblingTarget.rightEdge ? host.frame.maxX - 1 : host.frame.minX + 1,
                                   y: host.frame.midY),
                    windowID: host.id
                )
            }
            // A parked divider can be too far offscreen for WindowServer to
            // publish its hosted window. Route a single-item reveal through a
            // real, still-enumerated status host in the destination lane.
            if section == .visible {
                let candidates = windows.filter {
                    $0.id != item.windowID && !$0.title.hasPrefix("Qbar.") &&
                        controller.classify($0.frame) == .visible
                }
                let scan = self.model.items
                let knownMovable = candidates.filter { window in
                    scan.contains {
                        $0.windowID == window.id && $0.isMovable &&
                            (!requiringReachableVisible || self.isStatusItemReachable($0))
                    }
                }
                // Apple system extras near the clock can rehost their windows
                // on mouse-down. Prefer an ordinary app host that stays put.
                let stableApps = knownMovable.filter { window in
                    scan.contains { $0.windowID == window.id && !$0.isSystem }
                }
                if let last = (stableApps.isEmpty ? knownMovable : stableApps)
                    .max(by: { $0.frame.maxX < $1.frame.maxX }) {
                    siblingTarget = (last.id, true)
                    #if DEBUG
                    self.model.trace("TEMP TARGET selected id=\(item.id) section=visible host=\(last.id)")
                    #endif
                    return DropTarget(
                        point: CGPoint(x: last.frame.maxX - 1, y: last.frame.midY),
                        windowID: last.id
                    )
                }
            } else if self.model.preferences.mode == .aggregate && !self.layoutBatchActive {
                // In aggregate mode the tray's saved order is authoritative.
                // Any live sibling in this lane is a safe return target while
                // the oversized divider itself remains parked offscreen.
                let candidates = windows.filter {
                    $0.id != item.windowID && !$0.title.hasPrefix("Qbar.") &&
                        controller.classify($0.frame) == section
                }
                let scan = self.model.items
                let knownMovable = candidates.filter { window in
                    scan.contains { $0.windowID == window.id && $0.isMovable }
                }
                let stableApps = knownMovable.filter { window in
                    scan.contains { $0.windowID == window.id && !$0.isSystem }
                }
                if let sibling = (stableApps.isEmpty ? knownMovable : stableApps)
                    .max(by: { $0.frame.maxX < $1.frame.maxX }) {
                    siblingTarget = (sibling.id, false)
                    #if DEBUG
                    self.model.trace("TEMP TARGET selected id=\(item.id) section=\(section) host=\(sibling.id)")
                    #endif
                    return DropTarget(
                        point: CGPoint(x: sibling.frame.minX + 1, y: sibling.frame.midY),
                        windowID: sibling.id
                    )
                }
            }
            // A same-lane reorder must use a reachable sibling. An offscreen
            // divider can place the item in Visible while leaving it behind the
            // camera housing, which would falsely report success.
            if section == .visible && requiringReachableVisible { return nil }
            guard let boundary = self.endBoundaryWindow(for: section, controller: controller, in: windows) else { return nil }
            return DropTarget(
                point: CGPoint(
                    x: section == .visible ? boundary.frame.maxX - 1 : boundary.frame.minX + 1,
                    y: boundary.frame.midY
                ),
                windowID: boundary.id
            )
        }
    }

    private func activationTarget(for original: MenuItem, in candidates: [MenuItem]) -> MenuItem? {
        guard let candidate = matchingTarget(requestedID: original.id, reference: original, in: candidates) else { return nil }
        if candidate.element == nil, candidate.pid == candidate.windowOwnerPID,
           candidate.windowID == original.windowID, candidate.windowOwnerPID == original.windowOwnerPID,
           let element = original.element, AXAccess.string(element, kAXRoleAttribute) != nil,
           NSRunningApplication(processIdentifier: original.pid)?.bundleIdentifier == original.bundleID {
            // The same proven host can briefly lose its AX association during
            // reflow. Keep its real app identity for action and popup ownership.
            var retained = original
            retained.frame = candidate.frame
            retained.observedSection = candidate.observedSection
            return retained
        }
        return candidate
    }

    func applyLayout(
        movingOnly movingIDs: Set<String>? = nil,
        auditingOnly auditingIDs: Set<String>? = nil,
        startupRestore: Bool = false
    ) async {
        guard await finishPendingActivation() else { return }
        guard !model.isInteractingWithMenu else {
            model.notice = L10n.tr("请先关闭当前原生菜单，再应用布局。")
            return
        }
        model.repairFixedItemRules()
        guard !model.isMoving else { return }
        let references = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        let liveRules = model.preferences.rules.filter { references[$0.id]?.isMovable == true }
        let rules = liveRules.filter { movingIDs?.contains($0.id) ?? true }
        let auditedRules = liveRules.filter { auditingIDs?.contains($0.id) ?? true }
        // Fixed-only layouts need no physical movement (including offline
        // imported configurations that only repaired a stale fixed rule).
        guard !auditedRules.isEmpty else {
            model.layoutPending = false
            return
        }
        guard let controller, model.managementEnabled else { return }
        model.layoutPending = true
        model.error = nil
        model.notice = nil
        model.isMoving = true
        layoutBatchActive = true
        movingImagesCaptured = false
        let wasExpanded = model.isExpanded
        controller.beginLayoutBatch()
        var finishedMoving = false
        defer {
            if !finishedMoving {
                controller.finishMoving(wasExpanded: wasExpanded, commitLivePositions: false)
            }
            controller.endLayoutBatch()
            layoutBatchActive = false
            model.isMoving = false
        }

        // Move whole groups within the same marker instances. Hidden groups
        // append on their marker's left; aggregate Visible inserts on Hidden's
        // right, so descending order produces the saved left-to-right order.
        let ordered = MenuBarLayoutPolicy.orderedRules(rules, mode: model.preferences.mode)
        let audited = MenuBarLayoutPolicy.orderedRules(auditedRules, mode: model.preferences.mode)
        var unresolved = Set<String>()
        var deferred: [ItemRule] = []
        for rule in ordered {
            guard model.managementEnabled, !Task.isCancelled else { return }
            if await move(rule.id, to: rule.section, persist: false) { continue }
            unresolved.insert(rule.id)
            if lastMoveFailure == .targetUnavailable { deferred.append(rule) }
            // An individual app can be missing its hosted window. Continue the
            // other rules without changing either this rule or the user's groups.
            model.trace("LAYOUT pending id=\(rule.id) reason=\(model.error ?? "unknown")")
            model.error = nil
        }

        // One retry after the other groups released space. This stays inside
        // the same physical session and never parks/recreates the markers.
        for rule in deferred {
            guard model.managementEnabled, !Task.isCancelled else { return }
            if await move(rule.id, to: rule.section, persist: false) {
                unresolved.remove(rule.id)
            } else {
                model.trace("LAYOUT still-pending id=\(rule.id) reason=\(model.error ?? "unknown")")
                model.error = nil
            }
        }

        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        var snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return }
        // Calibrating a boundary or moving a wide item may have exposed a real
        // mismatch. Repair each concrete mismatch once while this batch remains
        // open, instead of a chain of repeated collapse/reveal repair passes.
        let concreteMismatches = audited.filter { rule in
            guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: snapshot),
                  let actual = physicalSection(of: item) else { return false }
            return actual != rule.section
        }
        for rule in concreteMismatches {
            if await move(rule.id, to: rule.section, persist: false) {
                unresolved.remove(rule.id)
            } else {
                unresolved.insert(rule.id)
                model.error = nil
            }
        }
        snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return }
        var visibleStillMisplaced = false
        let liveWindows = MenuScanner.windows(includeDividers: true)
        for rule in audited {
            guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: snapshot),
                  let actual = physicalSection(of: item, in: liveWindows) else {
                unresolved.insert(rule.id)
                continue
            }
            if actual == rule.section { unresolved.remove(rule.id) }
            else {
                unresolved.insert(rule.id)
                if rule.section == .visible { visibleStillMisplaced = true }
            }
        }

        controller.finishMoving(wasExpanded: wasExpanded, commitLivePositions: true)
        finishedMoving = true
        guard await controller.waitForSettledDividers(timeout: .seconds(3)),
              model.managementEnabled, !Task.isCancelled else {
            model.error = L10n.tr("菜单栏布局尚未稳定，分组设置已保留。")
            return
        }
        let settled = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return }
        let settledWindows = MenuScanner.windows(includeDividers: true)
        // Only the final parked layout decides whether a Visible item is
        // misplaced. An intermediate narrow-marker position can still settle.
        visibleStillMisplaced = false
        for rule in audited {
            guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: settled),
                  let actual = physicalSection(of: item, in: settledWindows) else {
                unresolved.insert(rule.id)
                continue
            }
            if actual == rule.section { unresolved.remove(rule.id) }
            else {
                unresolved.insert(rule.id)
                if rule.section == .visible { visibleStillMisplaced = true }
            }
        }
        if visibleStillMisplaced {
            // Never leave a proven Visible rule behind a parked divider. Pause
            // physical hiding to expose all icons; the saved rules remain intact.
            model.setManagement(false)
            model.error = L10n.tr("部分始终显示图标未留在菜单栏。Qbar 已展开图标并暂停收纳，分组设置已保留。")
            return
        }
        model.refresh()
        if !unresolved.isEmpty {
            let names = audited.filter { unresolved.contains($0.id) }
                .map { references[$0.id]?.name ?? $0.name }
            model.error = L10n.format("%@ 的菜单栏位置尚未确认；其他布局已应用，分组设置已保留。", names.joined(separator: L10n.tr("、")))
            return
        }
        model.layoutPending = false
        model.error = nil
        model.notice = startupRestore ? nil : L10n.tr("菜单栏布局已应用。")
    }

    /// Recreated external status hosts may return on the opposite side of a
    /// saved divider. Restore only proven mismatches among the pre-launch rules;
    /// a missing application can be handled when its status host appears later.
    func restoreSavedGroupsOnLaunch(_ savedRules: [ItemRule]) async {
        model.trace("STARTUP probe enabled=\(model.managementEnabled) moving=\(model.isMoving) " +
                    "pending=\(model.layoutPending) rules=\(savedRules.count) " +
                    "temporary=\(!temporaryActivations.isEmpty) menu=\(hasNativeMenuTracking)")
        guard let controller, model.managementEnabled, !model.isMoving,
              !Task.isCancelled, !savedRules.isEmpty,
              temporaryActivations.isEmpty, !model.isInteractingWithMenu, !hasNativeMenuTracking else { return }
        // Wait for the initial parked markers before pairing AX identities with
        // hosted windows. Startup recovery also keeps both markers oversized.
        guard await controller.waitForSettledDividers(timeout: .seconds(3)),
              model.managementEnabled, !Task.isCancelled, !model.isMoving,
              temporaryActivations.isEmpty, !model.isInteractingWithMenu, !hasNativeMenuTracking else { return }
        let references = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        var initial = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        func snapshotsAgree(_ previous: [MenuItem], _ current: [MenuItem]) -> Bool {
            guard previous.count == current.count else { return false }
            let oldItems = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            return current.allSatisfy { item in
                guard let old = oldItems[item.id], old.pid == item.pid,
                      old.bundleID == item.bundleID, old.windowID == item.windowID,
                      old.windowOwnerPID == item.windowOwnerPID else { return false }
                return abs(old.frame.minX - item.frame.minX) <= 1 &&
                    abs(old.frame.minY - item.frame.minY) <= 1 &&
                    abs(old.frame.width - item.frame.width) <= 1 &&
                    abs(old.frame.height - item.frame.height) <= 1
            }
        }
        let scanDeadline = ContinuousClock.now.advanced(by: .milliseconds(1_200))
        var stableSnapshot = false
        repeat {
            guard model.managementEnabled, !Task.isCancelled, !model.isMoving,
                  temporaryActivations.isEmpty, !model.isInteractingWithMenu, !hasNativeMenuTracking else { return }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let next = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            stableSnapshot = snapshotsAgree(initial, next)
            initial = next
            if stableSnapshot { break }
        } while ContinuousClock.now < scanDeadline
        guard stableSnapshot else {
            model.trace("STARTUP groups skipped reason=unstable-host-identity")
            return
        }
        guard model.managementEnabled, !Task.isCancelled,
              !model.isMoving, temporaryActivations.isEmpty, !model.isInteractingWithMenu, !hasNativeMenuTracking else { return }
        model.repairFixedItemRules()
        let originalPreferences = model.preferences
        let initialWindows = MenuScanner.windows(includeDividers: true)
        let eligible = savedRules.filter { rule in
            guard model.preferences.rules.contains(where: {
                $0.id == rule.id && $0.section == rule.section && $0.order == rule.order
            }),
                  let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: initial),
                  item.isMovable, physicalSection(of: item, in: initialWindows) != nil else { return false }
            return true
        }
        let mismatches = eligible.filter { rule in
            guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: initial) else { return false }
            return physicalSection(of: item, in: initialWindows) != rule.section
        }
        model.trace("STARTUP groups eligible=\(eligible.count) mismatch=\(mismatches.map(\.id))")
        guard !mismatches.isEmpty else {
            if eligible.count > 0 { model.layoutPending = false }
            model.trace("STARTUP groups verified mismatch=0 hosted=\(eligible.count)")
            return
        }

        func canContinue() -> Bool {
            let groupsUnchanged = model.preferences.mode == originalPreferences.mode &&
                eligible.allSatisfy { saved in
                    model.preferences.rules.contains {
                        $0.id == saved.id && $0.section == saved.section && $0.order == saved.order
                    }
                }
            return model.managementEnabled && !Task.isCancelled && !model.isMoving &&
                groupsUnchanged && temporaryActivations.isEmpty &&
                !model.isInteractingWithMenu && !hasNativeMenuTracking
        }
        func hostedRules(in scan: [MenuItem], references: [String: MenuItem]) -> [ItemRule] {
            let windows = MenuScanner.windows(includeDividers: true)
            return eligible.filter { rule in
                guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: scan),
                      item.isMovable else { return false }
                return physicalSection(of: item, in: windows) != nil
            }
        }
        func verifiedMismatches(in scan: [MenuItem], references: [String: MenuItem]) -> [ItemRule] {
            let windows = MenuScanner.windows(includeDividers: true)
            return hostedRules(in: scan, references: references).filter { rule in
                guard let item = matchingTarget(requestedID: rule.id, reference: references[rule.id], in: scan),
                      let actual = physicalSection(of: item, in: windows) else { return false }
                return actual != rule.section
            }
        }

        var remaining = mismatches
        var scan = initial
        var currentReferences = references
        for pass in 1...2 {
            guard canContinue() else { return }
            let hosted = hostedRules(in: scan, references: currentReferences)
            let requested = verifiedMismatches(in: scan, references: currentReferences)
            guard !requested.isEmpty else { remaining = []; break }
            model.trace("STARTUP batch pass=\(pass) moving=\(requested.map(\.id)) auditing=\(hosted.map(\.id))")
            // The parked marker is not a reliable drop destination for a
            // visible-to-hidden restoration. Use the same narrow-marker batch
            // that succeeds when the user applies a layout manually.
            await applyLayout(movingOnly: Set(requested.map(\.id)),
                              auditingOnly: Set(hosted.map(\.id)), startupRestore: true)
            guard canContinue() else { return }
            scan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
            guard canContinue() else { return }
            model.acceptMovementSnapshot(scan)
            currentReferences = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
            remaining = verifiedMismatches(in: scan, references: currentReferences)
            model.trace("STARTUP batch result pass=\(pass) remaining=\(remaining.map(\.id))")
            if remaining.isEmpty { break }
            // A host can change while the first batch parks its markers. One
            // bounded retry uses only concrete mismatches in the new snapshot.
            if pass == 1 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard canContinue() else { return }
                scan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
                guard canContinue() else { return }
            }
        }

        if !remaining.isEmpty {
            model.layoutPending = true
            model.notice = L10n.tr("个别图标的菜单栏位置尚未恢复，分组设置已保留。")
        } else {
            model.layoutPending = false
            model.error = nil
            model.notice = nil
        }
        model.trace("STARTUP groups restored remaining=\(remaining.map(\.id)) hosted=\(eligible.count)")
        model.refresh()
    }

    /// Saved status hosts can first appear or reappear across a parked divider
    /// while Qbar is running. A host change is only a hint: wait for two stable
    /// live snapshots, then move that one saved item without replaying a layout.
    var canAttemptRuntimeHostRepair: Bool {
        runtimeHostRepairBlockers.isEmpty
    }

    var runtimeHostRepairBlockers: [String] {
        var blockers: [String] = []
        if controller == nil { blockers.append("controller") }
        if !model.managementEnabled { blockers.append("management") }
        if model.layoutPending { blockers.append("pending-layout") }
        if model.isMoving { blockers.append("moving") }
        if model.isRefreshing { blockers.append("refreshing") }
        if layoutBatchActive { blockers.append("layout-batch") }
        if temporaryMotionBusy { blockers.append("temporary-motion") }
        if !temporaryActivations.isEmpty { blockers.append("temporary-activation") }
        if !model.temporarilyVisible.isEmpty { blockers.append("temporary-visible") }
        if hasNativeMenuTracking { blockers.append("native-menu") }
        if NSEvent.pressedMouseButtons != 0 { blockers.append("mouse-down") }
        return blockers
    }

    func repairSavedGroupAfterHostReplacement(
        _ change: MenuHostReplacement, expectedMode: DisplayMode
    ) async -> RuntimeHostRepairOutcome {
        guard model.managementEnabled, !Task.isCancelled else { return .stale("management-ended") }
        guard let saved = model.preferences.rules.first(where: { $0.id == change.id }),
              saved.bundleID == change.bundleID, saved.section == change.savedSection,
              saved.order == change.savedOrder else { return .stale("rule-changed") }
        guard model.preferences.mode == expectedMode else { return .stale("mode-changed") }
        let mode = expectedMode
        func ruleIsCurrent() -> Bool {
            model.preferences.mode == mode && model.preferences.rules.contains {
                $0.id == change.id && $0.bundleID == change.bundleID &&
                    $0.section == change.savedSection && $0.order == change.savedOrder
            }
        }
        model.trace("HOST probe id=\(change.id) blockers=\(runtimeHostRepairBlockers)")
        guard let controller else { return .retry("controller-unavailable") }
        guard canAttemptRuntimeHostRepair else {
            return .retry("blocked-\(runtimeHostRepairBlockers.joined(separator: ","))")
        }
        guard await controller.waitForSettledDividers(timeout: .seconds(2)) else {
            return .retry("dividers-unsettled")
        }
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        guard canAttemptRuntimeHostRepair else {
            return .retry("blocked-after-divider-wait")
        }

        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        func hostWasReplaced(in snapshot: [MenuItem]) -> Bool {
            guard let item = snapshot.first(where: { $0.id == change.id }) else { return false }
            return item.bundleID != change.bundleID || item.pid != change.pid ||
                (item.windowID != nil && item.windowID != change.newWindowID) ||
                (item.windowOwnerPID != nil && item.windowOwnerPID != change.ownerPID)
        }
        func verifiedHost(in snapshot: [MenuItem], windows: [MenuScanner.Window], stage: String)
            -> (MenuItem, ItemSection)? {
            func unavailable(_ reason: String) -> (MenuItem, ItemSection)? {
                model.trace("HOST probe ended id=\(change.id) stage=\(stage) reason=\(reason)")
                return nil
            }
            // A parked divider may not have an enumerable WindowServer host.
            // physicalSection also checks its current AppKit instance, while
            // still requiring the target's exact live window and frame.
            guard change.oldWindowID.map({ oldID in !windows.contains(where: { $0.id == oldID }) }) ?? true else {
                return unavailable("old-host-still-live")
            }
            guard let item = snapshot.first(where: { $0.id == change.id }) else {
                return unavailable("ax-identity-missing")
            }
            guard item.bundleID == change.bundleID, item.pid == change.pid else {
                return unavailable("process-changed")
            }
            guard item.windowID == change.newWindowID,
                  item.windowOwnerPID == change.ownerPID, item.isMovable else {
                return unavailable("host-identity-unsettled")
            }
            guard let host = windows.first(where: { $0.id == change.newWindowID && $0.pid == change.ownerPID }) else {
                return unavailable("live-host-missing")
            }
            guard abs(host.frame.minX - item.frame.minX) <= 1,
                  abs(host.frame.minY - item.frame.minY) <= 1,
                  abs(host.frame.width - item.frame.width) <= 1,
                  abs(host.frame.height - item.frame.height) <= 1 else {
                return unavailable("ax-window-reflow")
            }
            guard let section = physicalSection(of: item, in: windows) else {
                return unavailable("section-unverified-boundaries-\(controller.placementBoundaries() != nil)")
            }
            return (item, section)
        }

        let firstScan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        guard !hostWasReplaced(in: firstScan) else { return .stale("host-replaced") }
        let firstWindows = MenuScanner.windows(includeDividers: true)
        guard let (first, firstSection) = verifiedHost(in: firstScan, windows: firstWindows, stage: "first-snapshot") else {
            return .retry("first-snapshot-unsettled")
        }
        if firstSection == change.savedSection,
           change.savedSection != .visible || isStatusItemReachable(first) { return .settled }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return .stale("cancelled") }
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        guard canAttemptRuntimeHostRepair else { return .retry("blocked-before-second-snapshot") }
        let secondScan = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        guard !hostWasReplaced(in: secondScan) else { return .stale("host-replaced") }
        guard canAttemptRuntimeHostRepair else { return .retry("blocked-after-second-snapshot") }
        let secondWindows = MenuScanner.windows(includeDividers: true)
        guard let (item, section) = verifiedHost(in: secondScan, windows: secondWindows, stage: "second-snapshot") else {
            return .retry("second-snapshot-unsettled")
        }
        if section == change.savedSection,
           change.savedSection != .visible || isStatusItemReachable(item) { return .settled }
        guard section == firstSection,
              abs(item.frame.minX - first.frame.minX) <= 1,
              abs(item.frame.minY - first.frame.minY) <= 1,
              abs(item.frame.width - first.frame.width) <= 1,
              abs(item.frame.height - first.frame.height) <= 1 else {
            model.trace("HOST probe ended id=\(change.id) stage=second-snapshot reason=reflow")
            return .retry("second-snapshot-reflow")
        }

        // Preserve the changed item's former physical right neighbour when it
        // is still in the saved lane. Other icons retain their relative order.
        let next = (change.savedSection == .visible ||
                    (mode == .aggregate && change.savedSection != .visible))
            ? nil : change.rightNeighbours.lazy.compactMap { id -> MenuItem? in
            guard let peer = secondScan.first(where: { $0.id == id }),
                  peer.isMovable,
                  self.physicalSection(of: peer, in: secondWindows) == change.savedSection else { return nil }
            return peer
        }.first
        model.trace("HOST repair id=\(change.id) old=\(change.oldWindowID.map(String.init) ?? "none") " +
                    "new=\(change.newWindowID) " +
                    "actual=\(section) saved=\(change.savedSection) before=\(next?.id ?? "boundary")")
        let repaired = await moveForTemporaryActivation(change.id, to: change.savedSection,
                                                        before: next?.id,
                                                        requiringReachableVisible: change.savedSection == .visible)
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        let settled = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled, ruleIsCurrent() else { return .stale("rule-or-app-ended") }
        let windows = MenuScanner.windows(includeDividers: true)
        if let current = settled.first(where: { $0.id == change.id }),
           current.windowID == change.newWindowID,
           physicalSection(of: current, in: windows) == change.savedSection,
           change.savedSection != .visible || isStatusItemReachable(current) {
            model.trace("HOST repaired id=\(change.id) section=\(change.savedSection)")
            return .settled
        }
        model.trace("HOST repair retry id=\(change.id) moved=\(repaired)")
        return .retry(repaired ? "settlement-unverified" : "move-unverified")
    }

    func noteUnresolvedRuntimeHost(_ change: MenuHostReplacement, expectedMode: DisplayMode) async {
        guard model.managementEnabled, !Task.isCancelled,
              model.preferences.mode == expectedMode,
              let saved = model.preferences.rules.first(where: { $0.id == change.id }),
              saved.bundleID == change.bundleID, saved.section == change.savedSection,
              saved.order == change.savedOrder else { return }
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        let snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled,
              let current = snapshot.first(where: { $0.id == change.id }),
              current.bundleID == change.bundleID, current.pid == change.pid,
              current.windowID == change.newWindowID,
              current.windowOwnerPID == change.ownerPID,
              hasCurrentHost(for: current) else { return }
        let section = physicalSection(of: current)
        guard section != change.savedSection ||
                (change.savedSection == .visible && !isStatusItemReachable(current)) else {
            model.clearVisibleFallback(id: change.id)
            return
        }
        if change.savedSection == .visible,
           section != .visible || !isStatusItemReachable(current) {
            model.markVisibleFallback(id: change.id, windowID: change.newWindowID, ownerPID: change.ownerPID)
        }
        if change.savedSection == .visible {
            model.notice = L10n.format("%@ 暂未进入可点击的菜单栏位置；可从 Qbar 收纳区打开，或先收纳其他图标腾出空间。", saved.alias ?? saved.name)
        } else {
            model.notice = section == nil
                ? L10n.format("%@ 的菜单栏位置暂无法确认；请稍候或重新打开该应用。", saved.alias ?? saved.name)
                : L10n.format("%@ 的菜单栏位置尚未恢复，分组设置已保留。", saved.alias ?? saved.name)
        }
        model.trace("HOST unresolved id=\(change.id) actual=\(section?.rawValue ?? "unknown") saved=\(change.savedSection)")
        model.refresh()
    }

    private var hasNativeMenuTracking: Bool {
        model.isInteractingWithMenu || StatusController.hasOpenSystemMenu() || RunLoop.main.currentMode == .eventTracking ||
            model.items.contains { item in
                item.element.flatMap { AXAccess.value($0, kAXExpandedAttribute) as? Bool } == true
            }
    }

    func warmMenuIconCache() async {
        guard let controller, model.managementEnabled, !model.isMoving,
              !Task.isCancelled, temporaryActivations.isEmpty, !model.isInteractingWithMenu else { return }
        guard !hasNativeMenuTracking else {
            model.trace("ICON warm skipped reason=native-menu-tracking")
            return
        }
        guard await controller.waitForSettledDividers(timeout: .seconds(3)) else { return }
        let useAX = model.accessibilityGranted && !BuildChannel.isAppStore
        let snapshot = await Task.detached { MenuScanner.scan(accessibility: useAX) }.value
        guard model.managementEnabled, !Task.isCancelled else { return }
        model.acceptMovementSnapshot(snapshot)
        await model.refreshIcons()
        // A missing screenshot never authorizes moving an existing hidden app.
        // Its original status image can be recaptured when the user selects it.
    }

    func stop() {
        // Disabling management removes the dividers. A temporarily exposed
        // host then needs a saved-group reconciliation when management resumes.
        if !temporaryActivations.isEmpty { model.layoutPending = true }
        if let temporaryClickMonitor { NSEvent.removeMonitor(temporaryClickMonitor) }
        temporaryClickMonitor = nil
        lastTemporaryStatusClick = nil
        activeTemporaryMenuOwnerID = nil
        temporaryActivations.removeAll()
        activationCleanupGeneration &+= 1
        activationCleanupTask?.cancel()
        activationCleanupTask = nil
        model.temporarilyVisible.removeAll()
        activationGeneration &+= 1
        directMenuTrackingTask?.cancel()
        directMenuTrackingTask = nil
        model.isInteractingWithMenu = false
        model.nativeMenuFrames = []
    }

    private var usableMenuAreas: [CGRect] {
        NSScreen.screens.flatMap { screen -> [CGRect] in
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               screen.safeAreaInsets.top > 0 {
                return [Coordinates.quartz(left), Coordinates.quartz(right)]
            }
            return [Coordinates.quartz(screen.frame)]
        }
    }

    private func grabIntersection(for item: MenuItem) -> CGRect? {
        // Tahoe's hosted window includes padding that is not part of its clickable
        // button. Prefer the live AX button bounds so a narrow sliver beside the
        // camera housing is still grabbed inside the actual control.
        let hitFrame: CGRect
        if let element = item.element, let axFrame = AXAccess.frame(element),
           item.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: axFrame.midX, y: axFrame.midY)) {
            hitFrame = axFrame.insetBy(dx: 1, dy: 1)
        } else if #available(macOS 26, *) {
            hitFrame = item.frame.insetBy(dx: min(7, max(0, (item.frame.width - 4) / 2)), dy: 4)
        } else {
            hitFrame = item.frame
        }
        let intersections = usableMenuAreas.map { $0.intersection(hitFrame) }
            .filter { !$0.isNull && $0.width >= 2 && $0.height >= 3 }
        return intersections.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func grabPoint(for item: MenuItem) -> CGPoint? {
        grabIntersection(for: item).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func hasReliableGrabPoint(for item: MenuItem) -> Bool {
        guard let intersection = grabIntersection(for: item) else { return false }
        let expectedWidth = item.element.flatMap(AXAccess.frame)?.width ?? item.frame.width
        return intersection.width >= min(18, max(8, expectedWidth * 0.55))
    }

    /// Whether the original status control has enough unobscured width for a
    /// person to use it beside a notch. This is deliberately independent of
    /// the saved group: an item can be in the Visible lane yet covered by the
    /// camera housing or pushed out of the usable menu bar.
    func isStatusItemReachable(_ item: MenuItem) -> Bool {
        item.windowID != nil && hasReliableGrabPoint(for: item)
    }

    private func canDragPhysically(_ item: MenuItem, to target: DropTarget) -> Bool {
        hasCurrentHost(for: item) && MenuBarMovementPolicy.prefersPhysicalDrag(
            reliableSource: hasReliableGrabPoint(for: item), source: grabPoint(for: item),
            destination: target.point, usableAreas: usableMenuAreas
        )
    }

    private func target(_ proposed: DropTarget, constrainedTo area: CGRect) -> DropTarget? {
        let edgeTolerance: CGFloat = 1
        let tolerantArea = area.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
        guard area.width > edgeTolerance * 2, area.height > edgeTolerance * 2,
              tolerantArea.contains(proposed.point) else { return nil }
        return DropTarget(
            point: CGPoint(
                x: min(max(proposed.point.x, area.minX + edgeTolerance), area.maxX - edgeTolerance),
                y: min(max(proposed.point.y, area.minY + edgeTolerance), area.maxY - edgeTolerance)
            ),
            windowID: proposed.windowID
        )
    }

    private func dragInSafeArea(
        _ item: MenuItem,
        from point: CGPoint?,
        to target: DropTarget,
        resolvingTarget: @escaping () -> DropTarget?
    ) async -> Bool {
        guard let point else {
            model.error = L10n.format("%@ 暂未响应窗口路由，本次移动未完成。", displayName(for: item))
            return false
        }
        guard let commonArea = usableMenuAreas.first(where: { area in
            area.insetBy(dx: -1, dy: -1).contains(point) && area.insetBy(dx: -1, dy: -1).contains(target.point)
        }), let initialSafeTarget = self.target(target, constrainedTo: commonArea) else {
            model.error = L10n.tr("本次窗口路由未完成，物理拖动落点也无法确认；分组设置已保留。")
            return false
        }
        let screenRects = NSScreen.screens.map { Coordinates.quartz($0.frame) }
        guard screenRects.contains(where: { $0.contains(point) && $0.contains(initialSafeTarget.point) }) else {
            model.error = L10n.format("%@ 暂未响应窗口路由，分组设置已保留。", displayName(for: item))
            return false
        }
        #if DEBUG
        if initialSafeTarget != target {
            model.trace("SAFE TARGET \(item.id) \(target.point) -> \(initialSafeTarget.point)")
        }
        #endif
        return await drag(item, from: point, to: initialSafeTarget) { [weak self] in
            guard let self, let current = resolvingTarget() else { return nil }
            return self.target(current, constrainedTo: commonArea)
        }
    }

    private func routedMoveToBoundary(
        _ item: MenuItem,
        initialTarget: DropTarget,
        resolvingTarget: @escaping () -> DropTarget?,
        via route: EventRoute
    ) async -> Bool {
        // Source and destination are both addressed by exact hosted-window ID.
        // A physical notch is irrelevant to this event route, just as an
        // offscreen source is. Changing markers to make the point reachable
        // would instead move unrelated apps across their saved group boundary.
        guard let originalFrame = item.verifiedFrame else { return false }
        func addressable(_ target: DropTarget) -> DropTarget? {
            let members = MenuScanner.windows(includeDividers: true).map {
                MenuBarPhysicalMember(windowID: $0.id, frame: $0.frame, isMovable: true)
            }
            guard let host = members.first(where: { $0.windowID == target.windowID }),
                  MenuBarDragSafetyPolicy.staysOnRow(target.point, source: originalFrame, target: host.frame)
            else { return nil }
            return MenuBarRoutedDropPolicy.isAddressable(
                windowID: target.windowID, point: target.point, liveMembers: members
            ) ? target : nil
        }
        guard let liveInitialTarget = addressable(initialTarget) else {
            model.error = L10n.tr("目标菜单栏窗口已变化，本次移动已取消；分组设置已保留。")
            return false
        }
        #if DEBUG
        if !usableMenuAreas.contains(where: { $0.contains(initialTarget.point) }) {
            model.trace("MOVE ROUTED occluded-target id=\(item.id) point=\(initialTarget.point) window=\(initialTarget.windowID)")
        }
        #endif
        return await routedMove(item, to: liveInitialTarget, via: route) {
            guard let current = resolvingTarget() else {
                #if DEBUG
                self.model.trace("MOVE ROUTED resolver-nil id=\(item.id) initialWindow=\(initialTarget.windowID)")
                #endif
                return nil
            }
            let accepted = addressable(current)
            #if DEBUG
            if accepted == nil {
                let live = MenuScanner.windows(includeDividers: true).first { $0.id == current.windowID }
                self.model.trace("MOVE ROUTED target-rejected id=\(item.id) targetWindow=\(current.windowID) " +
                            "targetPoint=\(current.point) liveFrame=\(live?.frame.debugDescription ?? "nil") " +
                            "sourceFrame=\(originalFrame.debugDescription)")
            }
            #endif
            return accepted
        }
    }

    private func routeMenuBarEvent(_ event: CGEvent, to processID: pid_t) async -> Bool {
        guard processID > 0 else {
            model.trace("EVENT ROUTE invalid pid=\(processID) type=\(event.type.rawValue)")
            return false
        }
        let processIsLive = kill(processID, 0) == 0 || errno == EPERM
        guard processIsLive else {
            model.trace("EVENT ROUTE dead pid=\(processID) type=\(event.type.rawValue)")
            return false
        }
        guard let entry = CGEvent(source: nil), let exit = CGEvent(source: nil),
              let windowField = CGEventField(rawValue: 0x33) else { return false }
        let eventToken = Int64.random(in: 1...Int64.max)
        let entryToken = Int64.random(in: 1...Int64.max)
        let exitToken = Int64.random(in: 1...Int64.max)
        event.setIntegerValueField(.eventSourceUserData, value: eventToken)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(processID))
        entry.setIntegerValueField(.eventSourceUserData, value: entryToken)
        exit.setIntegerValueField(.eventSourceUserData, value: exitToken)
        let state = QbarEventRouteState()
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .mouseEventWindowUnderMousePointer,
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            windowField,
        ]
        func matches(_ incoming: CGEvent) -> Bool {
            fields.allSatisfy { incoming.getIntegerValueField($0) == event.getIntegerValueField($0) }
        }
        guard let processBarrierTap = QbarEventTap(
            pid: processID, placement: .tailAppendEventTap, options: .defaultTap, type: .null,
            handler: { _, incoming in
                let token = incoming.getIntegerValueField(.eventSourceUserData)
                if token == entryToken {
                    state.entryReceived = true
                    event.post(tap: .cgSessionEventTap)
                    return nil
                }
                if token == exitToken {
                    state.completed = true
                    return nil
                }
                return incoming
            }
        ), let sessionTap = QbarEventTap(
            location: .cgSessionEventTap, placement: .tailAppendEventTap,
            options: .listenOnly, type: event.type,
            handler: { _, incoming in
                guard incoming.getIntegerValueField(.eventSourceUserData) == eventToken else { return incoming }
                guard matches(incoming) else {
                    state.windowMismatch = true
                    return incoming
                }
                if !state.forwarded {
                    state.forwarded = true
                    event.postToPid(processID)
                }
                return incoming
            }
        ), let processReceiptTap = QbarEventTap(
            pid: processID, placement: .tailAppendEventTap,
            options: .listenOnly, type: event.type,
            handler: { _, incoming in
                guard !state.returned, matches(incoming) else { return incoming }
                state.returned = true
                exit.postToPid(processID)
                return incoming
            }
        ) else {
            model.trace("EVENT ROUTE unavailable pid=\(processID) type=\(event.type.rawValue)")
            return false
        }
        let barrierStarted = processBarrierTap.start()
        let sessionStarted = sessionTap.start()
        let receiptStarted = processReceiptTap.start()
        defer {
            processBarrierTap.stop()
            sessionTap.stop()
            processReceiptTap.stop()
        }
        guard barrierStarted, sessionStarted, receiptStarted else {
            model.trace(
                "EVENT ROUTE tap-start failed pid=\(processID) " +
                "post=\(CGPreflightPostEventAccess()) listen=\(CGPreflightListenEventAccess()) " +
                "barrier=\(barrierStarted)/\(processBarrierTap.isValid)/\(processBarrierTap.isEnabled) " +
                "session=\(sessionStarted)/\(sessionTap.isValid)/\(sessionTap.isEnabled) " +
                "receipt=\(receiptStarted)/\(processReceiptTap.isValid)/\(processReceiptTap.isEnabled)"
            )
            return false
        }
        // Give WindowServer one run-loop turn to register all three taps before
        // the entry barrier is posted. A just-created PID tap can otherwise miss
        // the first event on Tahoe.
        try? await Task.sleep(for: .milliseconds(20))
        entry.postToPid(processID)
        var repostedAfterDisable = false
        for _ in 0..<100 {
            if state.completed { return true }
            if !state.entryReceived, !repostedAfterDisable,
               processBarrierTap.disabledCount > 0 || !processBarrierTap.isEnabled {
                repostedAfterDisable = true
                if processBarrierTap.start() { entry.postToPid(processID) }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        model.trace(
            "EVENT ROUTE timeout pid=\(processID) type=\(event.type.rawValue) " +
            "entry=\(state.entryReceived) forwarded=\(state.forwarded) returned=\(state.returned) " +
            "mismatch=\(state.windowMismatch) " +
            "barrier=\(processBarrierTap.callbackCount)/\(processBarrierTap.disabledCount)/\(processBarrierTap.isValid)/\(processBarrierTap.isEnabled) " +
            "session=\(sessionTap.callbackCount)/\(sessionTap.disabledCount)/\(sessionTap.isValid)/\(sessionTap.isEnabled) " +
            "receipt=\(processReceiptTap.callbackCount)/\(processReceiptTap.disabledCount)/\(processReceiptTap.isValid)/\(processReceiptTap.isEnabled)"
        )
        return false
    }

    private func routedMove(
        _ item: MenuItem,
        to initialTarget: DropTarget,
        via route: EventRoute,
        resolveTarget: @escaping () -> DropTarget?
    ) async -> Bool {
        guard model.managementEnabled, !Task.isCancelled,
              CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
              let sourceWindowID = item.windowID,
              let windowField = CGEventField(rawValue: 0x33),
              let routedSource = CGEventSource(stateID: .hidSystemState) else { return false }
        let permitted: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        routedSource.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateRemoteMouseDrag)
        routedSource.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateSuppressionInterval)
        routedSource.localEventsSuppressionInterval = 0

        func make(_ type: CGEventType, at point: CGPoint, windowID: CGWindowID, flags: CGEventFlags) -> CGEvent? {
            guard let event = CGEvent(
                mouseEventSource: routedSource,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return nil }
            event.flags = flags
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(route.pid))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            event.setIntegerValueField(windowField, value: Int64(windowID))
            return event
        }

        guard let initialFrame = MenuScanner.windows(includeDividers: true).first(where: { $0.id == sourceWindowID })?.frame,
              let safeReleasePoint = MenuBarDragSafetyPolicy.cancellationPoint(originalFrame: initialFrame) else { return false }
        // Keep the probe on the original menu row even though the exact-window
        // route deliberately places its x outside the physical display.
        let startPoint = CGPoint(x: 20_000, y: safeReleasePoint.y)
        guard let down = make(.leftMouseDown, at: startPoint, windowID: sourceWindowID, flags: .maskCommand) else { return false }
        let originalCursor = CGEvent(source: nil)?.location
        let cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        var syntheticReleasePoint: CGPoint?
        defer {
            // A routed event may move the system cursor to its synthetic
            // coordinate. Restore it only in that case. If the user moved the
            // pointer during the route, warping to its old position makes the
            // pointer visibly snap backwards after the icon appears.
            if let originalCursor, let current = CGEvent(source: nil)?.location {
                let syntheticPoints = [startPoint, safeReleasePoint, syntheticReleasePoint].compactMap { $0 }
                if syntheticPoints.contains(where: { hypot(current.x - $0.x, current.y - $0.y) <= 3 }) {
                    CGWarpMouseCursorPosition(originalCursor)
                }
            }
            if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()) }
        }

        func cancelDrag() async {
            if let release = make(.leftMouseUp, at: safeReleasePoint, windowID: sourceWindowID, flags: []) {
                // The operation may already be cancelled. A fresh task allows
                // the release to finish its event receipt barrier regardless.
                let cleanup = Task {
                    if !(await self.routeMenuBarEvent(release, to: route.pid)) {
                        release.postToPid(route.pid)
                    }
                }
                await cleanup.value
                model.trace("MOVE ROUTED safe-release id=\(item.id) point=\(safeReleasePoint)")
            }
        }

        guard await routeMenuBarEvent(down, to: route.pid) else {
            // A missing receipt does not prove the mouse-down was never sent.
            await cancelDrag()
            return false
        }
        var responded = false
        for _ in 0..<100 {
            guard model.managementEnabled, !Task.isCancelled else {
                await cancelDrag()
                return false
            }
            if let current = MenuScanner.windows(includeDividers: true).first(where: { $0.id == sourceWindowID }),
               current.frame.origin != initialFrame.origin {
                responded = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard responded else {
            model.trace("MOVE ROUTED no source response id=\(sourceWindowID) route=\(route.kind.rawValue)")
            await cancelDrag()
            return false
        }

        // Do not retain the pre-mouse-down coordinate. Re-resolve the live marker
        // or sibling and cancel with a source-window mouse-up if it disappeared.
        // AppKit can momentarily unpublish a status host while mouse-down
        // reflows the row. Reacquire the same locked host for a short bounded
        // interval instead of cancelling on the first transient frame.
        let targetDeadline = ContinuousClock.now.advanced(by: .milliseconds(350))
        var resolvedTarget = resolveTarget()
        while resolvedTarget == nil && ContinuousClock.now < targetDeadline {
            guard model.managementEnabled, !Task.isCancelled else {
                await cancelDrag()
                return false
            }
            do { try await Task.sleep(for: .milliseconds(35)) } catch {
                await cancelDrag()
                return false
            }
            resolvedTarget = resolveTarget()
        }
        guard let liveTarget = resolvedTarget else {
            #if DEBUG
            let liveIDs = MenuScanner.windows(includeDividers: true).map(\.id)
            model.trace("MOVE ROUTED missing-target id=\(item.id) initialWindow=\(initialTarget.windowID) " +
                        "initialPoint=\(initialTarget.point) targetStillListed=\(liveIDs.contains(initialTarget.windowID)) " +
                        "liveWindows=\(liveIDs)")
            #endif
            model.error = L10n.tr("移动过程中目标图标或分隔符已消失，本次移动已安全取消。")
            await cancelDrag()
            return false
        }
        #if DEBUG
        if liveTarget != initialTarget {
            model.trace("LIVE TARGET \(item.id) \(initialTarget.point) -> \(liveTarget.point) window=\(liveTarget.windowID)")
        }
        #endif
        guard let up = make(.leftMouseUp, at: liveTarget.point, windowID: liveTarget.windowID, flags: []),
              await routeMenuBarEvent(up, to: route.pid) else {
            await cancelDrag()
            return false
        }
        syntheticReleasePoint = liveTarget.point
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }

    private func drag(
        _ item: MenuItem,
        from start: CGPoint,
        to initialTarget: DropTarget,
        resolveEnd: @escaping () -> DropTarget?
    ) async -> Bool {
        guard model.managementEnabled, !Task.isCancelled, CGPreflightPostEventAccess(), let source,
              let originalFrame = item.verifiedFrame,
              MenuBarDragSafetyPolicy.staysOnRow(start, source: originalFrame, target: originalFrame),
              MenuBarDragSafetyPolicy.staysOnRow(initialTarget.point, source: originalFrame, target: originalFrame)
        else { return false }
        let original = CGEvent(source: nil)?.location
        defer { if let original { CGWarpMouseCursorPosition(original) } }
        let commandWasDown = CGEventSource.keyState(.combinedSessionState, key: 55) || CGEventSource.keyState(.combinedSessionState, key: 54)
        if !commandWasDown {
            let command = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
            command?.flags = .maskCommand
            command?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(80))
        }
        defer {
            if !commandWasDown {
                let release = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
                release?.flags = []
                release?.post(tap: .cghidEventTap)
            }
        }
        guard model.managementEnabled, !Task.isCancelled else { return false }
        let windowField = CGEventField(rawValue: 0x33)
        func event(_ type: CGEventType, point: CGPoint, windowID: CGWindowID?) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            if let windowID {
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                if let windowField { event?.setIntegerValueField(windowField, value: Int64(windowID)) }
            }
            return event
        }
        guard let down = event(.leftMouseDown, point: start, windowID: item.windowID) else { return false }
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(100))
        guard model.managementEnabled, !Task.isCancelled else { return false }
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(120))
        // Once mouse-down is sent, always release even if cancellation arrives.
        var lastPoint = start
        guard var liveTarget = resolveEnd(),
              MenuBarDragSafetyPolicy.staysOnRow(liveTarget.point, source: originalFrame, target: originalFrame) else {
            event(.leftMouseUp, point: start, windowID: item.windowID)?.post(tap: .cghidEventTap)
            model.error = L10n.tr("移动过程中目标图标或分隔符已消失，本次移动已安全取消。")
            return false
        }
        #if DEBUG
        if liveTarget != initialTarget {
            model.trace("LIVE TARGET \(item.id) \(initialTarget.point) -> \(liveTarget.point) window=\(liveTarget.windowID)")
        }
        #endif
        var aborted = false
        for step in 1...24 {
            try? await Task.sleep(for: .milliseconds(18))
            guard model.managementEnabled, !Task.isCancelled else { aborted = true; break }
            guard let refreshedTarget = resolveEnd(),
                  MenuBarDragSafetyPolicy.staysOnRow(refreshedTarget.point, source: originalFrame, target: originalFrame) else {
                model.error = L10n.tr("移动过程中目标图标或分隔符已消失，本次移动已安全取消。")
                aborted = true
                break
            }
            liveTarget = refreshedTarget
            let t = CGFloat(step) / 24
            let point = CGPoint(
                x: start.x + (liveTarget.point.x - start.x) * t,
                y: start.y + (liveTarget.point.y - start.y) * t
            )
            lastPoint = point
            event(.leftMouseDragged, point: point, windowID: item.windowID)?.post(tap: .cghidEventTap)
        }
        if aborted {
            // Return to the source before releasing so a vanished target cannot
            // leave the item at the last valid but now unrelated coordinate.
            event(.leftMouseDragged, point: start, windowID: item.windowID)?.post(tap: .cghidEventTap)
            event(.leftMouseUp, point: start, windowID: item.windowID)?.post(tap: .cghidEventTap)
        } else {
            event(.leftMouseUp, point: lastPoint, windowID: liveTarget.windowID)?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(120))
        return !aborted && model.managementEnabled && !Task.isCancelled
    }
}
