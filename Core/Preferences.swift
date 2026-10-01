import Foundation

private func preferenceTitle(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

public enum DisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case aggregate, inline
    public var id: String { rawValue }
    public var title: String { preferenceTitle(self == .aggregate ? "聚合浮窗" : "普通折叠") }
}

public enum ItemSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case visible, hidden, alwaysHidden
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .visible: preferenceTitle("始终显示")
        case .hidden: preferenceTitle("收纳区")
        case .alwaysHidden: preferenceTitle("始终隐藏")
        }
    }
}

public enum MenuItemPlacement {
    public static func isTransientRule(id: String, bundleID: String) -> Bool {
        let lowerID = id.lowercased()
        let lowerBundle = bundleID.lowercased()
        return lowerID.hasPrefix("com.apple.controlcenter|qbar.") ||
            (lowerBundle == "com.apple.controlcenter" && lowerID.hasPrefix("com.apple.controlcenter|window-"))
    }

    public static func isExcluded(id: String) -> Bool {
        let lowerID = id.lowercased()
        guard lowerID.hasPrefix("com.apple.controlcenter|") else { return false }
        return ["audiovideo", "audiovideomodule"].contains {
            lowerID.hasSuffix("|" + $0) || lowerID.hasSuffix(".menuextra." + $0)
        }
    }

    public static func isFixed(id: String, sourceName: String? = nil) -> Bool {
        let lowerID = id.lowercased()
        let fixedKeys = ["clock", "controlcenter", "audiovideo", "audiovideomodule", "bentobox-0"]
        return lowerID.hasPrefix("com.apple.controlcenter|window-") ||
            fixedKeys.contains { lowerID.hasSuffix("|" + $0) || lowerID.hasSuffix(".menuextra." + $0) }
    }
}

public enum BarGlyph: String, Codable, CaseIterable, Identifiable, Sendable {
    // Keep the legacy case decodable so saved "transparent" preferences can be migrated.
    case capsule, chevron, dots, grid, leaf, star, transparent
    public static var allCases: [BarGlyph] { [.capsule, .chevron, .dots, .grid, .leaf, .star] }
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .capsule: "rectangle.split.2x1"
        case .chevron: "chevron.left.chevron.right"
        case .dots: "ellipsis"
        case .grid: "square.grid.2x2"
        case .leaf: "leaf"
        case .star: "sparkle"
        case .transparent: "circle.dashed"
        }
    }
    public var title: String {
        switch self {
        case .capsule: "Qbar"
        case .chevron: preferenceTitle("箭头")
        case .dots: preferenceTitle("圆点")
        case .grid: preferenceTitle("方格")
        case .leaf: preferenceTitle("叶片")
        case .star: preferenceTitle("星光")
        case .transparent: preferenceTitle("透明")
        }
    }
}

public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { switch self { case .system: preferenceTitle("跟随系统"); case .light: preferenceTitle("浅色"); case .dark: preferenceTitle("深色") } }
}

public enum PanelAnchor: String, Codable, CaseIterable, Identifiable, Sendable {
    case statusItem, pointer, screenRight
    public var id: String { rawValue }
    public var title: String { switch self { case .statusItem: preferenceTitle("Qbar图标下方"); case .pointer: preferenceTitle("鼠标所在位置"); case .screenRight: preferenceTitle("屏幕右侧") } }
}

public enum SpacingPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, comfortable, compact, minimal
    public var id: String { rawValue }
    public var title: String { switch self { case .system: preferenceTitle("系统默认"); case .comfortable: preferenceTitle("较小间距"); case .compact: preferenceTitle("紧凑间距"); case .minimal: preferenceTitle("无间距") } }
    public var values: (spacing: Int, padding: Int)? {
        switch self { case .system: nil; case .comfortable: (8, 6); case .compact: (4, 3); case .minimal: (0, 0) }
    }
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public var conflictsWithInputSwitching: Bool { keyCode == 49 && modifiers == 0x1800 }
    public var isValid: Bool { keyCode <= 127 && modifiers & 0x1900 != 0 && modifiers & ~UInt32(0x1B00) == 0 && !conflictsWithInputSwitching }
    public var registrationKey: String { "\(modifiers):\(keyCode)" }
}

public struct ItemRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundleID: String
    public var section: ItemSection
    public var order: Int
    public var shortcut: Shortcut?
    public var alias: String?
    public init(id: String, name: String, bundleID: String, section: ItemSection = .visible, order: Int = 0, shortcut: Shortcut? = nil, alias: String? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.section = section; self.order = order; self.shortcut = shortcut
        self.alias = alias
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var mode: DisplayMode = .aggregate
    public var hoverToShow = false
    public var clickEmptyToShow = false
    public var scrollToShow = false
    public var hoverDelay: Double = 0.5
    public var autoHide = true
    public var hideDelay: Double = 3
    public var rehideTemporary = true
    public var temporaryDelay: Double = 10
    public var glyph: BarGlyph = .capsule
    public var theme: AppTheme = .system
    public var panelAnchor: PanelAnchor = .statusItem
    public var panelIconSize: Double = 24
    public var showNames = true
    public var spacing: SpacingPreset = .system
    public var showDividers = true
    public var shortcuts: [String: Shortcut] = [:]
    public var rules: [ItemRule] = []

    public init() {}

    public var shortcutBindings: [String: Shortcut] {
        var bindings = shortcuts
        for rule in rules { if let shortcut = rule.shortcut { bindings["item:" + rule.id] = shortcut } }
        return bindings
    }

    public mutating func normalize() {
        if glyph == .transparent { glyph = .capsule }
        hoverDelay = Self.finite(hoverDelay, fallback: 0.5, range: 0.1...3)
        hideDelay = Self.finite(hideDelay, fallback: 3, range: 0.5...60)
        temporaryDelay = Self.finite(temporaryDelay, fallback: 10, range: 1...120)
        panelIconSize = Self.finite(panelIconSize, fallback: 24, range: 16...40)
        var seen = Set<String>()
        rules = rules.prefix(1000).filter {
            !$0.id.isEmpty && !MenuItemPlacement.isExcluded(id: $0.id) &&
                !MenuItemPlacement.isTransientRule(id: $0.id, bundleID: $0.bundleID) &&
                seen.insert($0.id).inserted
        }
        var shortcutsSeen = Set<String>()
        for key in shortcuts.keys.sorted() {
            guard ["toggle", "always", "collapse", "settings"].contains(key), let value = shortcuts[key], value.isValid,
                  shortcutsSeen.insert(value.registrationKey).inserted else { shortcuts[key] = nil; continue }
        }
        for index in rules.indices {
            if MenuItemPlacement.isFixed(id: rules[index].id, sourceName: rules[index].name) {
                rules[index].section = .visible
            }
            if let alias = rules[index].alias {
                let clean = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                rules[index].alias = clean.isEmpty ? nil : clean
            }
            rules[index].order = min(max(rules[index].order, 0), 10000)
            if let shortcut = rules[index].shortcut,
               !shortcut.isValid || !shortcutsSeen.insert(shortcut.registrationKey).inserted { rules[index].shortcut = nil }
        }
    }

    public func section(for id: String, fallback: ItemSection = .visible) -> ItemSection {
        rules.first { $0.id == id }?.section ?? fallback
    }

    public mutating func move(_ id: String, to section: ItemSection, before target: String? = nil) {
        guard target != id else { return }
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].section = section
        var ordered = rules.filter { $0.section == section && $0.id != id }.sorted { $0.order < $1.order }
        let item = rules[index]
        if let target, let destination = ordered.firstIndex(where: { $0.id == target }) { ordered.insert(item, at: destination) }
        else { ordered.append(item) }
        for (order, rule) in ordered.enumerated() {
            if let position = rules.firstIndex(where: { $0.id == rule.id }) { rules[position].order = order }
        }
    }

    private static func finite(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

public struct ConfigurationFile: Codable, Sendable {
    public var format = "studio.qbar.configuration"
    public var version = 1
    public var preferences: Preferences
    public init(preferences: Preferences) { self.preferences = preferences }
    public static func decode(_ data: Data) throws -> Preferences {
        guard data.count <= 1_048_576 else { throw ConfigurationError.tooLarge }
        let file = try JSONDecoder().decode(Self.self, from: data)
        guard file.format == "studio.qbar.configuration", file.version == 1 else { throw ConfigurationError.unsupported }
        var preferences = file.preferences
        preferences.normalize()
        return preferences
    }
}

public enum ConfigurationError: LocalizedError {
    case tooLarge, unsupported
    public var errorDescription: String? { preferenceTitle(self == .tooLarge ? "配置文件不能超过 1 MB。" : "不支持此配置文件或版本。") }
}
