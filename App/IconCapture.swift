import AppKit
import CryptoKit
import ScreenCaptureKit
import QbarCore

/// The WindowServer host is short-lived, but an app's own status item can be
/// identified across Qbar launches by its AX item ID and exact installed app.
/// A cache hit is only a fallback; a screenshot from the current host wins.
@MainActor
private final class PersistentStatusIconCache {
    private struct Source: Codable, Hashable {
        let itemID: String
        let bundleID: String
        let bundlePath: String
        let bundleVersion: String
        let appearance: String
    }

    private struct Record: Codable {
        let formatVersion: Int
        let source: Source
        let pointWidth: Double
        let pointHeight: Double
        let needsDarkBackground: Bool
        let savedAt: Date
        let png: Data
    }

    private struct Entry {
        var image: NSImage
        var needsDarkBackground: Bool
        var persistedDigest: Data
        var persistedNeedsDarkBackground: Bool
        var persistedSize: NSSize
        var lastCheckedAt: Date
        var lastFreshenedAt: Date
    }

    private let directory: URL
    private var entries: [Source: Entry] = [:]
    private var missing = Set<Source>()
    private var writesSincePrune = 0
    private let maximumImageBytes = 1_000_000

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Qbar/status-icon-cache-v1", isDirectory: true)
        prune()
    }

    func clear() throws {
        entries.removeAll()
        missing.removeAll()
        writesSincePrune = 0
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func source(for item: MenuItem) -> Source? {
        guard item.windowID != nil, item.windowOwnerPID != nil,
              item.pid != ProcessInfo.processInfo.processIdentifier,
              item.bundleID != Bundle.main.bundleIdentifier,
              !item.bundleID.hasPrefix("process."),
              item.id.hasPrefix(item.bundleID + "|") else { return nil }
        let suffix = item.id.dropFirst(item.bundleID.count + 1)
        guard !suffix.isEmpty, !suffix.hasPrefix("window-"), !suffix.contains("#"),
              // An index can refer to a different icon after an app changes
              // how many status items it exposes.
              !suffix.hasPrefix("item-") else { return nil }
        // A raw WindowServer title has no AX identity. It can be reused safely
        // only by its owning process; AX items may be hosted by Control Center.
        guard item.element != nil || item.pid == item.windowOwnerPID else { return nil }
        guard let app = NSRunningApplication(processIdentifier: item.pid),
              !app.isTerminated, app.bundleIdentifier == item.bundleID,
              let bundleURL = app.bundleURL else { return nil }
        let path = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.isEmpty else { return nil }
        let bundle = Bundle(url: bundleURL)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let shortVersion = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? "dark" : "light"
        return Source(itemID: item.id, bundleID: item.bundleID,
                      bundlePath: path, bundleVersion: version + "|" + shortVersion,
                      appearance: appearance)
    }

    private func fileURL(for source: Source) -> URL {
        let identity = Data((source.bundleID + "\u{0}" + source.itemID + "\u{0}" + source.appearance).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    private func loadedEntry(for source: Source) -> Entry? {
        if let entry = entries[source] { return entry }
        guard !missing.contains(source) else { return nil }
        let url = fileURL(for: source)
        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = attributes.fileSize, size > 0, size <= 1_500_000,
              let modifiedAt = attributes.contentModificationDate,
              (-60...7 * 24 * 60 * 60).contains(modifiedAt.timeIntervalSinceNow * -1),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.formatVersion == 1, record.source == source,
              record.pointWidth > 0, record.pointWidth <= 600,
              record.pointHeight > 0, record.pointHeight <= 64,
              !record.png.isEmpty, record.png.count <= maximumImageBytes,
              let bitmap = NSBitmapImageRep(data: record.png),
              bitmap.pixelsWide > 0, bitmap.pixelsWide <= 2_400,
              bitmap.pixelsHigh > 0, bitmap.pixelsHigh <= 256 else {
            missing.insert(source)
            return nil
        }
        let image = NSImage(size: NSSize(width: CGFloat(record.pointWidth), height: CGFloat(record.pointHeight)))
        image.addRepresentation(bitmap)
        image.isTemplate = false
        let digest = Data(SHA256.hash(data: record.png))
        let entry = Entry(image: image, needsDarkBackground: record.needsDarkBackground,
                          persistedDigest: digest, persistedNeedsDarkBackground: record.needsDarkBackground,
                          persistedSize: image.size, lastCheckedAt: modifiedAt,
                          lastFreshenedAt: modifiedAt)
        entries[source] = entry
        return entry
    }

    func restore(_ item: MenuItem) -> MenuItem {
        guard item.menuImage == nil, let source = source(for: item),
              let entry = loadedEntry(for: source) else { return item }
        var restored = item
        restored.menuImage = entry.image
        restored.captureNeedsDarkBackground = entry.needsDarkBackground
        return restored
    }

    func store(_ image: NSImage, needsDarkBackground: Bool, for item: MenuItem) {
        guard let source = source(for: item),
              image.size.width > 0, image.size.width <= 600,
              image.size.height > 0, image.size.height <= 64 else { return }
        let previous = loadedEntry(for: source)
        let now = Date()
        // The normal refresh may revisit every icon every ten seconds. Keep
        // live pixels in memory, but avoid PNG encoding and disk I/O between
        // periodic checks; a new host's live screenshot is still shown now.
        if var previous, (0..<60).contains(now.timeIntervalSince(previous.lastCheckedAt)) {
            previous.image = image
            previous.needsDarkBackground = needsDarkBackground
            entries[source] = previous
            return
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cgImage.width > 0, cgImage.width <= 2_400,
              cgImage.height > 0, cgImage.height <= 256,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              !png.isEmpty, png.count <= maximumImageBytes else { return }
        let digest = Data(SHA256.hash(data: png))
        // Captures run frequently. Keep the newest pixels in memory, but only
        // write a changed image to disk at most once a minute per status item.
        if let previous, previous.persistedDigest == digest,
           previous.persistedNeedsDarkBackground == needsDarkBackground,
           previous.persistedSize == image.size,
           FileManager.default.fileExists(atPath: fileURL(for: source).path) {
            var freshenedAt = previous.lastFreshenedAt
            // Keep a still-live icon eligible for restart recovery without
            // rewriting its unchanged PNG/JSON on every capture. One metadata
            // touch per day is enough for the seven-day expiry window.
            if now.timeIntervalSince(freshenedAt) >= 24 * 60 * 60,
               (try? FileManager.default.setAttributes([.modificationDate: now],
                   ofItemAtPath: fileURL(for: source).path)) != nil {
                freshenedAt = now
            }
            entries[source] = Entry(image: image, needsDarkBackground: needsDarkBackground,
                                    persistedDigest: digest, persistedNeedsDarkBackground: needsDarkBackground,
                                    persistedSize: image.size, lastCheckedAt: now,
                                    lastFreshenedAt: freshenedAt)
            return
        }
        let record = Record(formatVersion: 1, source: source,
                            pointWidth: Double(image.size.width), pointHeight: Double(image.size.height),
                            needsDarkBackground: needsDarkBackground, savedAt: now, png: png)
        guard let data = try? JSONEncoder().encode(record),
              (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: fileURL(for: source), options: .atomic)) != nil else { return }
        entries[source] = Entry(image: image, needsDarkBackground: needsDarkBackground,
                                persistedDigest: digest, persistedNeedsDarkBackground: needsDarkBackground,
                                persistedSize: image.size, lastCheckedAt: now,
                                lastFreshenedAt: now)
        missing.remove(source)
        writesSincePrune += 1
        if writesSincePrune >= 16 {
            writesSincePrune = 0
            prune()
        }
    }

    private func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        let records = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        var kept = 0
        var removed = Set<URL>()
        let now = Date()
        for record in records {
            let age = now.timeIntervalSince(record.1)
            let expired = age > 7 * 24 * 60 * 60 || age < -60
            if expired || kept >= 160 || bytes + record.2 > 24_000_000 {
                if (try? manager.removeItem(at: record.0)) != nil { removed.insert(record.0) }
                continue
            }
            kept += 1
            bytes += record.2
        }
        if !removed.isEmpty {
            // Otherwise a successful capture after eviction can match an old
            // in-memory digest and skip recreating its missing disk record.
            entries = entries.filter { !removed.contains(fileURL(for: $0.key)) }
        }
    }
}

@MainActor
final class IconCapture {
    /// A saved item ID outlives its process and WindowServer window. A capture
    /// from the previous instance must never become the new instance's image.
    private struct CaptureIdentity: Hashable {
        let itemID: String
        let pid: pid_t
        let windowID: CGWindowID
        let windowOwnerPID: pid_t?

        init?(_ item: MenuItem) {
            guard let windowID = item.windowID else { return nil }
            itemID = item.id
            pid = item.pid
            self.windowID = windowID
            windowOwnerPID = item.windowOwnerPID
        }
    }

    private struct CaptureFailure {
        let count: Int
        let retryAfter: Date
    }

    private var updatedAt: [CaptureIdentity: Date] = [:]
    private var failures: [CaptureIdentity: CaptureFailure] = [:]
    private var isCapturing = false
    private let persistentCache = PersistentStatusIconCache()

    func restore(_ item: MenuItem) -> MenuItem { persistentCache.restore(item) }
    func clearCache() throws { try persistentCache.clear() }

    private func recordFailure(for identity: CaptureIdentity) {
        let count = min((failures[identity]?.count ?? 0) + 1, 5)
        let delay = min(60, 5 * (1 << (count - 1)))
        failures[identity] = CaptureFailure(count: count, retryAfter: Date().addingTimeInterval(TimeInterval(delay)))
    }

    func refresh(_ model: AppModel, duringMovement: Bool = false, force: Bool = false) async {
        // A deliberate unfolded-lane capture must not be skipped merely
        // because a background refresh is still finishing its screenshot.
        while isCapturing {
            guard force, !Task.isCancelled, model.screenRecordingGranted else { return }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
        }
        guard !Task.isCancelled, model.screenRecordingGranted,
              !model.isMoving || duringMovement else { return }
        isCapturing = true
        defer { isCapturing = false }
        let liveIdentities = Set(model.items.compactMap(CaptureIdentity.init))
        updatedAt = updatedAt.filter { liveIdentities.contains($0.key) }
        failures = failures.filter { liveIdentities.contains($0.key) }
        let now = Date()
        let pending = model.items.filter { item in
            guard let identity = CaptureIdentity(item) else { return false }
            if force { return true }
            return now.timeIntervalSince(updatedAt[identity] ?? .distantPast) > 10 &&
                now >= (failures[identity]?.retryAfter ?? .distantPast)
        }
        guard !pending.isEmpty else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let windows = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            var captured = 0
            var attempted = 0
            var committed = 0
            var rejected = 0
            var images: [CaptureIdentity: (NSImage, Bool)] = [:]
            func traceFailure(_ item: MenuItem, reason: String) {
                model.trace("CAPTURE reject id=\(item.id) window=\(item.windowID.map(String.init) ?? "nil") " +
                            "pid=\(item.pid) owner=\(item.windowOwnerPID.map(String.init) ?? "nil") reason=\(reason)")
            }
            defer {
                model.trace("CAPTURE pending=\(pending.count) attempted=\(attempted) accepted=\(captured) " +
                            "committed=\(committed) rejected=\(rejected) force=\(force) moving=\(duringMovement)")
            }
            for item in pending {
                guard !Task.isCancelled, model.screenRecordingGranted,
                      !model.isMoving || duringMovement else {
                    traceFailure(item, reason: "capture-aborted")
                    return
                }
                guard let identity = CaptureIdentity(item), let window = windows[identity.windowID] else {
                    rejected += 1
                    if let identity = CaptureIdentity(item) { recordFailure(for: identity) }
                    traceFailure(item, reason: "host-missing-from-shareable-content")
                    continue
                }
                guard window.frame.width > 0, window.frame.height > 0 else {
                    rejected += 1
                    recordFailure(for: identity)
                    traceFailure(item, reason: "empty-host-frame")
                    continue
                }
                guard identity.windowOwnerPID == nil || window.owningApplication?.processID == identity.windowOwnerPID else {
                    rejected += 1
                    recordFailure(for: identity)
                    traceFailure(item, reason: "owner-mismatch-actual-\(window.owningApplication.map { String($0.processID) } ?? "nil")")
                    continue
                }
                // AX geometry can lag a menu-bar reflow. A stale third-party
                // frame must never turn a fixed macOS audio/video host into
                // that app's icon, even if the scanner briefly paired them.
                if window.owningApplication?.bundleIdentifier == "com.apple.controlcenter",
                   MenuItemPlacement.isExcluded(id: "com.apple.controlcenter|\(window.title ?? "")") {
                    rejected += 1
                    recordFailure(for: identity)
                    traceFailure(item, reason: "excluded-system-host-\(window.title ?? "untitled")")
                    continue
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = max(1, Int(window.frame.width * 2))
                config.height = max(1, Int(window.frame.height * 2))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.captureResolution = .best
                attempted += 1
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled, model.screenRecordingGranted,
                          !model.isMoving || duringMovement,
                          model.items.contains(where: { CaptureIdentity($0) == identity }) else {
                        rejected += 1
                        traceFailure(item, reason: "identity-changed-or-capture-cancelled")
                        continue
                    }
                    guard Self.hasVisibleContent(image) else {
                        rejected += 1
                        recordFailure(for: identity)
                        traceFailure(item, reason: "blank-pixels-\(image.width)x\(image.height)")
                        continue
                    }
                    let original = NSImage(cgImage: image, size: window.frame.size)
                    images[identity] = (original, Self.isLightGlyph(image))
                    captured += 1
                } catch {
                    rejected += 1
                    if model.items.contains(where: { CaptureIdentity($0) == identity }) {
                        recordFailure(for: identity)
                    }
                    traceFailure(item, reason: "screenshot-error-\((error as NSError).domain):\((error as NSError).code)")
                }
            }
            guard !Task.isCancelled, model.screenRecordingGranted,
                  !model.isMoving || duringMovement else { return }
            if !images.isEmpty {
                model.items = model.items.map { item in
                    var item = item
                    if let identity = CaptureIdentity(item), let image = images[identity] {
                        model.trace("CAPTURE commit id=\(identity.itemID) window=\(identity.windowID) " +
                                    "pid=\(identity.pid) owner=\(identity.windowOwnerPID.map(String.init) ?? "nil") " +
                                    "size=\(image.0.size.debugDescription) light=\(image.1)")
                        item.menuImage = image.0
                        item.captureNeedsDarkBackground = image.1
                        persistentCache.store(image.0, needsDarkBackground: image.1, for: item)
                        updatedAt[identity] = Date()
                        failures.removeValue(forKey: identity)
                        committed += 1
                    }
                    return item
                }
            }
            for identity in images.keys where !model.items.contains(where: { CaptureIdentity($0) == identity }) {
                model.trace("CAPTURE discard id=\(identity.itemID) window=\(identity.windowID) " +
                            "pid=\(identity.pid) owner=\(identity.windowOwnerPID.map(String.init) ?? "nil") " +
                            "reason=identity-changed-before-commit")
            }
        } catch {
            // Application icons remain usable if a window disappears or capture is denied.
            model.notice = L10n.tr("图标快照暂不可用，当前显示应用图标。可在授权页重新检查录屏权限。")
        }
    }

    private static func hasVisibleContent(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let buffer = bytes.bindMemory(to: UInt8.self)
            var meaningfulPixels = 0
            var minimum = [UInt8](repeating: 255, count: 4)
            var maximum = [UInt8](repeating: 0, count: 4)
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                for channel in 0..<4 {
                    minimum[channel] = min(minimum[channel], buffer[offset + channel])
                    maximum[channel] = max(maximum[channel], buffer[offset + channel])
                }
                if buffer[offset + 3] > 18 {
                    meaningfulPixels += 1
                }
            }
            // Offscreen windows can return an opaque, uniform blank surface.
            // Retain the last good glyph instead of treating that as an icon.
            let containsDetail = (0..<4).contains { Int(maximum[$0]) - Int(minimum[$0]) > 12 }
            return meaningfulPixels >= 4 && containsDetail
        }
    }

    private static func isLightGlyph(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let luminance: Double = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            var light: Double = 0, weight: Double = 0
            let buffer = bytes.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                let alpha = Double(buffer[offset + 3]) / 255
                guard alpha > 0.2 else { continue }
                light += (Double(buffer[offset]) * 0.2126 + Double(buffer[offset + 1]) * 0.7152 + Double(buffer[offset + 2]) * 0.0722) / 255
                weight += alpha
            }
            return weight > 0 ? light / weight : 1
        }
        return luminance > 0.55
    }
}
