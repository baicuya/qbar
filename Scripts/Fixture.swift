import AppKit

@MainActor
final class Fixture: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var items: [NSStatusItem] = []
    var window: NSWindow?
    private var diagnosticsTimer: Timer?
    private var diagnosticsPoll = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出测试图标", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        record("LAUNCH pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil") " +
               "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "nil") " +
               "policy=\(NSApp.activationPolicy().rawValue)")
        // Register after AppKit's launch bookkeeping, using the same ordinary
        // application lifecycle as a native macOS menu-bar app.
        DispatchQueue.main.async { [weak self] in self?.createStatusItems() }
        showFixtureWindow()
    }

    private func createStatusItems() {
        for (index, label) in ["A", "B", "C"].enumerated() {
            UserDefaults.standard.set(300 + index * 50, forKey: "NSStatusItem Preferred Position QbarFixture.\(label)")
            let item = NSStatusBar.system.statusItem(withLength: 26)
            item.autosaveName = "QbarFixture.\(label)"
            item.isVisible = true
            item.button?.title = label
            item.button?.setAccessibilityLabel("Qbar Test \(label)")
            item.button?.setAccessibilityIdentifier("QbarFixture.\(label)")
            let menu = NSMenu(title: "Qbar Test \(label)")
            menu.delegate = self
            menu.addItem(withTitle: "Qbar Test \(label) · 菜单已打开", action: nil, keyEquivalent: "")
            let action = NSMenuItem(title: "验证点击 \(label)", action: #selector(verify(_:)), keyEquivalent: "")
            action.tag = index; action.target = self; menu.addItem(action)
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出测试图标", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.menu = menu
            items.append(item)
        }
        recordStatusItems()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.diagnosticsPoll += 1
                self.recordStatusItems()
                if self.diagnosticsPoll >= 8 { self.diagnosticsTimer?.invalidate(); self.diagnosticsTimer = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    private func showFixtureWindow() {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 200, width: 370, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Qbar 功能测试"
        let text = NSTextField(labelWithString: "A / B / C 测试图标已添加到菜单栏。\n它们仅用于测试，不影响其他应用设置。")
        text.frame = NSRect(x: 24, y: 80, width: 320, height: 50)
        window.contentView?.addSubview(text)
        let quit = NSButton(title: "退出测试图标", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.frame = NSRect(x: 24, y: 24, width: 130, height: 32)
        window.contentView?.addSubview(quit)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func recordStatusItems() {
        for item in items {
            record("STATUS name=\(item.autosaveName ?? "nil") visible=\(item.isVisible) " +
                   "length=\(item.length) button=\(item.button?.frame.debugDescription ?? "nil") " +
                   "appKitWindow=\(item.button?.window?.windowNumber ?? -1) " +
                   "appKitFrame=\(item.button?.window?.frame.debugDescription ?? "nil")")
        }
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hosts = rows.filter { row in
            guard row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = row[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"], w > 0, w < 600, h >= 12, h <= 64 else { return false }
            return (row[kCGWindowName as String] as? String)?.hasPrefix("QbarFixture.") == true ||
                row[kCGWindowOwnerPID as String] as? pid_t == ProcessInfo.processInfo.processIdentifier
        }
        record("HOSTS fixture=\(hosts.count) " + hosts.map { row in
            "\(row[kCGWindowNumber as String] ?? "nil"):\(row[kCGWindowOwnerPID as String] ?? "nil"):\(row[kCGWindowBounds as String] ?? "nil")"
        }.joined(separator: ","))
    }
    private func record(_ text: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QbarFixture-events.log")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + "\(Date()): \(text)\n").write(to: url, atomically: true, encoding: .utf8)
    }
    func menuWillOpen(_ menu: NSMenu) { record("OPEN \(menu.title)") }
    func menuDidClose(_ menu: NSMenu) { record("CLOSE \(menu.title)") }
    @objc func verify(_ sender: NSMenuItem) { record("CLICK \(sender.tag)"); sender.title = "✓ 点击已验证" }
}

@main
enum FixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Fixture()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        }
    }
}
