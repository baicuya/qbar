import AppKit
import ApplicationServices
import QbarCore

struct MenuItem: Identifiable {
    private struct PackagedIconCacheEntry {
        let image: NSImage?
        let checkedAt: Date
    }

    @MainActor private static var packagedIconCache: [String: PackagedIconCacheEntry] = [:]

    let id: String
    var name: String
    var sourceName: String?
    let bundleID: String
    let pid: pid_t
    let windowID: CGWindowID?
    let windowOwnerPID: pid_t?
    let element: AXUIElement?
    var frame: CGRect
    var image: NSImage?
    var menuImage: NSImage?
    var captureNeedsDarkBackground: Bool?
    var observedSection: ItemSection?
    /// AX can keep reporting a button's former position after the host window
    /// disappears. Its existence remains useful, but only a matched live
    /// WindowServer window provides a verified physical position.
    var verifiedFrame: CGRect? { windowID == nil ? nil : frame }
    var isSystem: Bool { bundleID.hasPrefix("com.apple.") }
    var systemSymbol: String? {
        guard isSystem else { return nil }
        let key = id.lowercased()
        if key.contains("wifi") || key.contains("wi-fi") { return "wifi" }
        if key.contains("battery") { return "battery.100" }
        if key.contains("spotlight") { return "magnifyingglass" }
        if key.contains("clock") { return "clock" }
        if key.contains("siri") || (sourceName ?? name) == "Siri" { return "sparkles" }
        if key.contains("audiovideo") { return "video" }
        if key.contains("bluetooth") { return "antenna.radiowaves.left.and.right" }
        if key.contains("textinput") || key.contains("inputmenu") { return "keyboard" }
        if key.contains("volume") || key.contains("sound") { return "speaker.wave.2" }
        if key.contains("display") || key.contains("screenmirroring") { return "display" }
        if key.contains("bentobox") || key.hasSuffix("|controlcenter") || (sourceName ?? name).hasPrefix("控制中心") { return "switch.2" }
        return "menubar.rectangle"
    }

    static func applicationIcon(pid: pid_t, bundleID: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        let running = NSRunningApplication(processIdentifier: pid)
        if let bundle = applicationBundleURL(pid: pid, bundleID: bundleID) {
            return workspace.icon(forFile: bundle.path)
        }
        return running?.icon
    }

    /// Some Electron menu extras expose a valid AX button but no independent
    /// WindowServer window, so ScreenCaptureKit cannot snapshot their menu-bar
    /// glyph. Use the app's own packaged template image as the fallback. The
    /// bytes are read from the installed app at runtime and are never bundled
    /// with Qbar, which also keeps the glyph in sync when that app updates.
    @MainActor static func packagedStatusIcon(pid: pid_t, bundleID: String) -> NSImage? {
        guard let bundle = applicationBundleURL(pid: pid, bundleID: bundleID) else { return nil }
        let version = Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let cacheKey = bundle.standardizedFileURL.resolvingSymlinksInPath().path + "\u{0}" + version
        if let cached = packagedIconCache[cacheKey],
           cached.image != nil || Date().timeIntervalSince(cached.checkedAt) < 300 {
            return cached.image
        }
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var archives: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "app.asar" {
            archives.append(url)
            if archives.count == 6 { break }
        }
        for archive in archives {
            if let image = statusIcon(inASAR: archive) {
                packagedIconCache[cacheKey] = PackagedIconCacheEntry(image: image, checkedAt: Date())
                return image
            }
        }
        packagedIconCache[cacheKey] = PackagedIconCacheEntry(image: nil, checkedAt: Date())
        return nil
    }

    private static func statusIcon(inASAR archive: URL) -> NSImage? {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 16), prefix.count == 16 else { return nil }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(prefix[offset]) | UInt32(prefix[offset + 1]) << 8 |
                UInt32(prefix[offset + 2]) << 16 | UInt32(prefix[offset + 3]) << 24
        }
        let headerPickleSize = Int(uint32(4))
        let jsonSize = Int(uint32(12))
        guard headerPickleSize >= 8, headerPickleSize <= 32 * 1024 * 1024,
              jsonSize > 0, jsonSize <= headerPickleSize - 8,
              let json = try? handle.read(upToCount: jsonSize), json.count == jsonSize,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let files = root["files"] as? [String: Any] else { return nil }

        struct Candidate {
            let path: String
            let size: Int
            let offset: Int
            let score: Int
        }
        var candidates: [Candidate] = []
        func visit(_ directory: [String: Any], prefix: String) {
            for (name, raw) in directory {
                guard let entry = raw as? [String: Any] else { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if let children = entry["files"] as? [String: Any] {
                    visit(children, prefix: path)
                    continue
                }
                let lower = path.lowercased()
                guard lower.hasSuffix(".png"),
                      lower.contains("template"),
                      lower.contains("statusitem") || lower.contains("tray") || lower.contains("menubar"),
                      entry["unpacked"] == nil,
                      let size = (entry["size"] as? NSNumber)?.intValue,
                      size > 0, size <= 2 * 1024 * 1024 else { continue }
                let offset: Int?
                if let text = entry["offset"] as? String { offset = Int(text) }
                else { offset = (entry["offset"] as? NSNumber)?.intValue }
                guard let offset, offset >= 0 else { continue }
                var score = 0
                if lower.contains("statusitemidleicon") { score += 120 }
                if lower.contains("statusitemicon-0") { score += 110 }
                if lower.contains("statusitemicon") { score += 70 }
                if lower.contains("tray") { score += 35 }
                if lower.contains("@2x") { score += 8 }
                if lower.contains("@3x") { score += 4 }
                if lower.contains("blocked") || lower.contains("update") || lower.contains("spin") { score -= 100 }
                candidates.append(Candidate(path: path, size: size, offset: offset, score: score))
            }
        }
        visit(files, prefix: "")
        guard let candidate = candidates.max(by: {
            $0.score == $1.score ? $0.path > $1.path : $0.score < $1.score
        }) else { return nil }

        do {
            try handle.seek(toOffset: UInt64(8 + headerPickleSize + candidate.offset))
            guard let data = try handle.read(upToCount: candidate.size), data.count == candidate.size,
                  let image = NSImage(data: data) else { return nil }
            image.isTemplate = true
            if candidate.path.lowercased().contains("@2x"), image.size.width > 1, image.size.height > 1 {
                image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
            }
            return image
        } catch {
            return nil
        }
    }

    static func applicationName(pid: pid_t, bundleID: String) -> String? {
        guard let url = applicationBundleURL(pid: pid, bundleID: bundleID) else {
            return NSRunningApplication(processIdentifier: pid)?.localizedName
        }
        let applicationURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let runningApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleURL = application.bundleURL else { return false }
            return enclosingApplicationURL(bundleURL).standardizedFileURL.resolvingSymlinksInPath() == applicationURL
        }
        let mainApplication = runningApplications.first { application in
            application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == applicationURL
        } ?? runningApplications.first
        if let value = mainApplication?.localizedName {
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { return name }
                }
            }
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func applicationBundleURL(pid: pid_t, bundleID: String) -> URL? {
        let running = NSRunningApplication(processIdentifier: pid)

        // Use the exact running bundle when it owns the discovered item. This
        // also chooses the right copy when multiple app versions share an ID.
        if running?.bundleIdentifier == bundleID, let bundle = running?.bundleURL {
            return enclosingApplicationURL(bundle)
        }

        // Menu-bar windows can be hosted by another process, and helpers can
        // restart between discovery and rendering, while the bundle ID remains stable.
        if !bundleID.hasPrefix("process."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return enclosingApplicationURL(url)
        }

        // Input methods and background helpers often live inside their parent app.
        return running?.bundleURL.map { enclosingApplicationURL($0) }
    }

    private static func enclosingApplicationURL(_ bundle: URL) -> URL {
        var enclosing = bundle
        var parent = bundle.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.caseInsensitiveCompare("app") == .orderedSame { enclosing = parent }
            parent.deleteLastPathComponent()
        }
        return enclosing
    }
    var isMovable: Bool {
        !MenuItemPlacement.isFixed(id: id, sourceName: sourceName ?? name)
    }
}

enum AXAccess {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

enum Coordinates {
    static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    static func cocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: desktopTop - point.y) }
    static func quartz(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Reads only status-level windows and the accessibility "extras menu bar".
/// Ordinary application windows and document contents are never collected.
enum MenuScanner {
    private static let scanLock = NSLock()
    private static func isTransientClone(_ name: String?) -> Bool {
        name?.localizedCaseInsensitiveContains("System Status Item Clone") == true
    }

    /// Detects newly created extras without requiring their remote host window
    /// to have appeared yet. A missing PID means its AX query was inconclusive;
    /// only a successful, empty children query reports an empty fingerprint.
    static func statusPresenceFingerprint() -> [pid_t: Set<String>] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var output: [pid_t: Set<String>] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard !Task.isCancelled else { return [:] }
            let pid = app.processIdentifier
            guard pid != ownPID, !app.isTerminated,
                  app.bundleIdentifier != "com.apple.controlcenter",
                  !isTransientClone(app.localizedName) else { continue }

            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.06)
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &barValue) == .success,
                  let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            let bar = barValue as! AXUIElement
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let elements = childrenValue as? [AXUIElement] else { continue }

            var keys = Set<String>()
            var identifierCounts: [String: Int] = [:]
            var complete = true
            for (index, element) in elements.enumerated() {
                guard !Task.isCancelled else { return [:] }
                var identifierValue: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierValue)
                let identifier: String?
                switch error {
                case .success:
                    guard let value = identifierValue as? String else {
                        complete = false
                        identifier = nil
                        break
                    }
                    identifier = value.isEmpty ? nil : value
                case .attributeUnsupported, .noValue:
                    identifier = nil
                default:
                    complete = false
                    identifier = nil
                }
                guard complete else { break }
                guard !isTransientClone(identifier) else { continue }

                // A clone can expose its name only through its label. These
                // attributes belong to the extra, never an ordinary window.
                var clone = false
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    if error == .success {
                        if isTransientClone(value as? String) { clone = true; break }
                    } else if error != .attributeUnsupported && error != .noValue {
                        complete = false
                        break
                    }
                }
                guard complete else { break }
                guard !clone else { continue }

                if let identifier {
                    let occurrence = identifierCounts[identifier, default: 0]
                    identifierCounts[identifier] = occurrence + 1
                    // Length and occurrence preserve duplicate identifiers
                    // without colliding with another identifier's suffix.
                    keys.insert("identifier:\(identifier.utf8.count):\(identifier):\(occurrence)")
                } else {
                    keys.insert("index:\(index)")
                }
            }
            if complete { output[pid] = keys }
        }
        guard !Task.isCancelled else { return [:] }
        return output
    }

    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
    }

    struct StatusObservation {
        let id: String
        let name: String
        let bundle: String
        let pid: pid_t
        let identifier: String?
        let label: String?
        let element: AXUIElement?
        let frame: CGRect
    }

    #if DEBUG
    private static func traceStatusSnapshot(_ axDiagnostics: [String], items: [MenuItem]) {
        let fixturePIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "studio.qbar.fixture"
        }.map(\.processIdentifier))
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var lines = ["\(Date()): SCAN active=\(items.count)"]
        for entry in raw {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let statusCandidate = layer == Int(CGWindowLevelForKey(.statusWindow)) &&
                w > 0 && w < 600 && h >= 12 && h <= 64
            // Ordinary windows are never logged. The fixture is an explicit
            // diagnostic app whose windows let us verify filtering stages.
            guard statusCandidate || fixturePIDs.contains(pid) else { continue }
            let title = (entry[kCGWindowName as String] as? String ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("WINDOW id=\(id) pid=\(pid) layer=\(layer) title=\(title) " +
                         "x=\(bounds["X"] ?? 0) y=\(bounds["Y"] ?? 0) w=\(w) h=\(h) " +
                         "statusCandidate=\(statusCandidate)")
        }
        lines.append(contentsOf: axDiagnostics)
        lines.append("ACTIVE " + items.map { "\($0.id)#\($0.windowID ?? 0)" }.joined(separator: ","))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Qbar/debug-scanner.log")
        let previous = (try? String(contentsOf: support, encoding: .utf8)) ?? ""
        try? (String(previous.suffix(50_000)) + lines.joined(separator: "\n") + "\n")
            .write(to: support, atomically: true, encoding: .utf8)
    }
    #endif

    static func geometricallyMatches(axFrame: CGRect, windowFrame: CGRect) -> Bool {
        let center = CGPoint(x: axFrame.midX, y: axFrame.midY)
        // Menu glyphs are inset in their hosted status window. Comparing only
        // the nearest center lets a stale AX frame claim an adjacent icon.
        return abs(axFrame.midY - windowFrame.midY) <= 6 &&
            windowFrame.insetBy(dx: -0.5, dy: -0.5).contains(center)
    }

    /// AX extras survive after applications disable or remove their status
    /// item. Only a live status-level host proves presence in the active layout.
    /// An item being created will join a later scan when its host appears; its
    /// saved rule remains independent of this active-item snapshot.
    static func hostedItems(observations: [StatusObservation], windows: [Window]) -> [MenuItem] {
        var assignments: [CGWindowID: [StatusObservation]] = [:]
        for observation in observations {
            let frame = observation.frame
            guard frame.width > 0, frame.width < 600, frame.height > 0, frame.height <= 64 else { continue }
            let names = [observation.identifier, observation.label].compactMap { $0?.lowercased() }
            // Modern status windows are hosted by Control Center, so matching
            // must allow a different owner PID while verifying live geometry.
            let geometric = windows.filter { window in
                // Audio/video is a macOS-owned transient status host. During a
                // menu-bar reflow, another app's AX frame can briefly land on
                // it while that app's real host stays parked offscreen. Never
                // attach the transient pixels or window ID to that app.
                guard !MenuItemPlacement.isExcluded(id: "com.apple.controlcenter|\(window.title)") else { return false }
                return geometricallyMatches(axFrame: frame, windowFrame: window.frame)
            }
            let named = geometric.filter { window in
                let title = window.title.lowercased()
                guard !title.isEmpty, !title.hasPrefix("item-") else { return false }
                return names.contains { title == $0 || title.hasSuffix("." + $0) || $0.hasSuffix("." + title) }
            }
            let owned = geometric.filter { $0.pid == observation.pid }
            let window: Window?
            if named.count == 1 { window = named.first }
            else if owned.count == 1 { window = owned.first }
            else if geometric.count == 1 { window = geometric.first }
            else { window = nil }
            guard let window else { continue }
            assignments[window.id, default: []].append(observation)
        }

        return windows.compactMap { window in
            guard let claims = assignments[window.id], !claims.isEmpty else { return nil }
            let appClaims = claims.filter { $0.bundle != "com.apple.controlcenter" }
            let eligible = appClaims.isEmpty ? claims : appClaims
            guard let observation = eligible.first,
                  eligible.dropFirst().allSatisfy({ alias in
                      guard let first = observation.element, let other = alias.element else { return false }
                      return CFEqual(first, other)
                  }) else {
                // Independent AX buttons claiming one host means at least one
                // is stale. Leave the raw host unassigned instead of attaching
                // another application's name, image, or click target.
                return nil
            }
            return MenuItem(id: observation.id, name: observation.name, bundleID: observation.bundle,
                            pid: observation.pid, windowID: window.id, windowOwnerPID: window.pid,
                            element: observation.element, frame: window.frame)
        }
    }

    static func windows(includeDividers: Bool = false) -> [Window] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.statusWindow)),
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 0, h >= 12, h <= 64 else { return nil }
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard !isTransientClone(title), !isTransientClone(entry[kCGWindowOwnerName as String] as? String) else { return nil }
            let ownDivider = title.hasPrefix("Qbar.")
            guard (pid != ownPID && w < 600 && !ownDivider) || (includeDividers && ownDivider) else { return nil }
            return Window(id: id, pid: pid, title: title, frame: .init(x: x, y: y, width: w, height: h))
        }
    }

    static func scan(accessibility: Bool) -> [MenuItem] {
        scanLock.lock()
        defer { scanLock.unlock() }
        struct Candidate {
            let id: String
            let name: String
            let bundle: String
            let pid: pid_t
            let identifier: String?
            let label: String?
            let element: AXUIElement
        }
        var candidates: [Candidate] = []
        var seenIDs: [String: Int] = [:]
        #if DEBUG
        var axDiagnostics: [String] = []
        #endif
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let processes = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        if accessibility {
            for app in processes {
                guard !isTransientClone(app.localizedName) else { continue }
                let pid = app.processIdentifier
                let bundle = app.bundleIdentifier ?? "process.\(app.localizedName ?? String(pid))"
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.12)
                guard let bar = AXAccess.element(application, kAXExtrasMenuBarAttribute) else {
                    #if DEBUG
                    if bundle == "studio.qbar.fixture" {
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &value)
                        axDiagnostics.append("AX fixture pid=\(pid) bundle=\(bundle) extrasUnavailable error=\(error.rawValue)")
                    }
                    #endif
                    continue
                }
                let elements = AXAccess.children(bar)
                #if DEBUG
                if !elements.isEmpty || bundle == "studio.qbar.fixture" {
                    axDiagnostics.append("AX bar pid=\(pid) bundle=\(bundle) children=\(elements.count)")
                }
                #endif
                for (index, element) in elements.enumerated() {
                    let identifier = AXAccess.string(element, kAXIdentifierAttribute).flatMap { $0.isEmpty ? nil : $0 }
                    let label = [AXAccess.string(element, kAXTitleAttribute), AXAccess.string(element, kAXDescriptionAttribute)]
                        .compactMap { $0 }.first { !$0.isEmpty && !$0.hasPrefix("Item-") }
                    guard !isTransientClone(label), !isTransientClone(identifier) else { continue }
                    // Labels can contain live values such as unread counts,
                    // temperatures or network speed. Keep them for matching,
                    // but never make them part of the saved identity.
                    let key = identifier ?? (elements.count == 1 ? "primary" : "item-\(index)")
                    let base = "\(bundle)|\(key)"
                    let count = seenIDs[base, default: 0]
                    seenIDs[base] = count + 1
                    candidates.append(Candidate(id: count == 0 ? base : "\(base)#\(count)",
                                                name: label ?? app.localizedName ?? bundle, bundle: bundle,
                                                pid: pid, identifier: identifier, label: label, element: element))
                }
            }
        }
        // Read geometry after discovery. Launching/closing apps can change the menu bar
        // while AX enumeration is in progress; old window-to-app associations are unsafe.
        let snapshot = windows(includeDividers: true)
        let hiddenBoundary = snapshot.first { $0.title == "Qbar.Hidden" }?.frame
        let alwaysBoundary = snapshot.first { $0.title == "Qbar.AlwaysHidden" }?.frame
        let windows = snapshot.filter { !$0.title.hasPrefix("Qbar.") }
        let observations: [StatusObservation] = candidates.compactMap { candidate in
            let frame = AXAccess.frame(candidate.element)
            #if DEBUG
            axDiagnostics.append("AX item id=\(candidate.id) pid=\(candidate.pid) " +
                                 "frame=\(frame?.debugDescription ?? "nil")")
            #endif
            guard let frame else { return nil }
            return StatusObservation(id: candidate.id, name: candidate.name, bundle: candidate.bundle,
                                     pid: candidate.pid, identifier: candidate.identifier, label: candidate.label,
                                     element: candidate.element, frame: frame)
        }
        var output = hostedItems(observations: observations, windows: windows)
        let seenWindows = Set(output.compactMap(\.windowID))
        for window in windows where !seenWindows.contains(window.id) {
            // Our remote hosted status items must not be listed as external apps.
            if window.title.hasPrefix("Qbar.") { continue }
            let app = NSRunningApplication(processIdentifier: window.pid)
            let bundle = app?.bundleIdentifier ?? "process.\(window.pid)"
            let key = window.title.isEmpty || window.title.hasPrefix("Item-") ? "window-\(window.id)" : window.title
            let labels = ["Clock": L10n.tr("时钟"), "WiFi": "Wi-Fi", "Battery": L10n.tr("电池"), "BentoBox-0": L10n.tr("控制中心"), "AudioVideoModule": L10n.tr("音频与视频"), "Bluetooth": L10n.tr("蓝牙")]
            let name = labels[window.title] ?? (window.title.isEmpty || window.title.hasPrefix("Item-") ? L10n.format("菜单栏图标 %d", window.id) : window.title)
            output.append(MenuItem(id: "\(bundle)|\(key)", name: name, bundleID: bundle, pid: window.pid,
                                   windowID: window.id, windowOwnerPID: window.pid, element: nil, frame: window.frame))
        }
        #if DEBUG
        traceStatusSnapshot(axDiagnostics, items: output)
        #endif
        var uniqueIDs = Set<String>()
        return output.filter {
            !MenuItemPlacement.isExcluded(id: $0.id) && uniqueIDs.insert($0.id).inserted
        }.map { item in
            var item = item
            if item.verifiedFrame != nil, let hidden = hiddenBoundary, let always = alwaysBoundary,
               abs(item.frame.midY - hidden.midY) < 10, abs(item.frame.midY - always.midY) < 10,
               always.maxX <= hidden.maxX {
                if item.frame.maxX <= always.minX + 1 {
                    item.observedSection = .alwaysHidden
                } else if item.frame.minX >= always.maxX - 1,
                          item.frame.maxX <= hidden.minX + 1 {
                    item.observedSection = .hidden
                } else if item.frame.minX >= hidden.maxX - 1 {
                    item.observedSection = .visible
                }
            }
            return item
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
}
