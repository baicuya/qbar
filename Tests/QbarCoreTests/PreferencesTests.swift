import XCTest
@testable import QbarCore

final class PreferencesTests: XCTestCase {
    func testImportedFixedSystemIconsAreRemovedOrRestoredWithoutChangingAppGroups() throws {
        XCTAssertEqual(Preferences().panelIconSize, 24)
        var prefs = Preferences()
        prefs.rules = [
            .init(id: "com.apple.controlcenter|AudioVideoModule", name: "AudioVideoModule", bundleID: "com.apple.controlcenter", section: .alwaysHidden),
            .init(id: "com.apple.controlcenter|Qbar.Main", name: "Qbar.Main", bundleID: "com.apple.controlcenter", section: .alwaysHidden),
            .init(id: "com.apple.controlcenter|window-1234", name: "菜单栏图标 1234", bundleID: "com.apple.controlcenter", section: .hidden),
            .init(id: "com.apple.controlcenter|com.apple.menuextra.clock", name: "时钟", bundleID: "com.apple.controlcenter", section: .hidden),
            .init(id: "com.sogou.inputmethod.sogou|primary", name: "搜狗输入法", bundleID: "com.sogou.inputmethod.sogou", section: .hidden),
            .init(id: "com.electron.dockerdesktop|primary", name: "Docker Desktop", bundleID: "com.electron.dockerdesktop", section: .hidden)
        ]
        let restored = try ConfigurationFile.decode(JSONEncoder().encode(ConfigurationFile(preferences: prefs)))
        XCTAssertEqual(restored.rules.map(\.section), [.visible, .hidden, .hidden])
        XCTAssertFalse(restored.rules.contains { $0.id.contains("AudioVideo") })
        XCTAssertFalse(restored.rules.contains { MenuItemPlacement.isTransientRule(id: $0.id, bundleID: $0.bundleID) })
        XCTAssertTrue(MenuItemPlacement.isExcluded(id: "com.apple.controlcenter|com.apple.menuextra.audiovideo"))
        XCTAssertFalse(MenuItemPlacement.isExcluded(id: "com.west2online.ClashXPro|primary"))
    }

    func testInputSwitchingShortcutIsNotRegisteredOrRestoredFromOldConfig() throws {
        XCTAssertTrue(Preferences().shortcuts.isEmpty)
        let reserved = Shortcut(keyCode: 49, modifiers: 0x1800, label: "⌃⌥Space")
        XCTAssertFalse(reserved.isValid)
        var prefs = Preferences()
        let custom = Shortcut(keyCode: 4, modifiers: 0x900, label: "⌘⌥H")
        prefs.shortcuts = ["toggle": reserved, "settings": custom]
        prefs.rules = [.init(id: "a", name: "A", bundleID: "app", shortcut: reserved)]
        let restored = try ConfigurationFile.decode(JSONEncoder().encode(ConfigurationFile(preferences: prefs)))
        XCTAssertNil(restored.shortcuts["toggle"])
        XCTAssertEqual(restored.shortcuts["settings"], custom)
        XCTAssertNil(restored.rules[0].shortcut)
    }
    func testEveryAppearanceAndBehaviorOptionRoundTrips() throws {
        for glyph in BarGlyph.allCases {
            for theme in AppTheme.allCases {
                var prefs = Preferences()
                prefs.glyph = glyph; prefs.theme = theme
                prefs.hoverToShow = true; prefs.clickEmptyToShow = true; prefs.scrollToShow = true
                prefs.autoHide = false; prefs.rehideTemporary = false; prefs.showNames = false
                prefs.showDividers = false; prefs.panelAnchor = .pointer; prefs.panelIconSize = 40
                XCTAssertEqual(try ConfigurationFile.decode(JSONEncoder().encode(ConfigurationFile(preferences: prefs))), prefs)
            }
        }
    }

    func testSelfDropAndUnknownItemDoNotReorderLayout() {
        var prefs = Preferences()
        prefs.rules = [.init(id: "a", name: "A", bundleID: "app", order: 0), .init(id: "b", name: "B", bundleID: "app", order: 1)]
        let original = prefs
        prefs.move("a", to: .hidden, before: "a")
        XCTAssertEqual(prefs, original)
        prefs.move("missing", to: .hidden)
        XCTAssertEqual(prefs, original)
    }

    func testNormalizationIsIdempotentAndLimitsImportedValues() {
        var prefs = Preferences()
        prefs.panelIconSize = 900; prefs.temporaryDelay = -10; prefs.hoverDelay = .nan
        prefs.shortcuts["unknownAction"] = .init(keyCode: 0, modifiers: 0x900, label: "Unknown")
        prefs.rules = [.init(id: "a", name: "A", bundleID: "app", order: -5, alias: String(repeating: "x", count: 100))]
        prefs.normalize()
        XCTAssertEqual(prefs.panelIconSize, 40); XCTAssertEqual(prefs.temporaryDelay, 1)
        XCTAssertEqual(prefs.hoverDelay, 0.5); XCTAssertNil(prefs.shortcuts["unknownAction"])
        XCTAssertEqual(prefs.rules[0].order, 0); XCTAssertEqual(prefs.rules[0].alias?.count, 80)
        let normalized = prefs; prefs.normalize(); XCTAssertEqual(prefs, normalized)
    }

    func testWrongFormatAndTruncatedJSONAreRejected() throws {
        var file = ConfigurationFile(preferences: .init()); file.format = "another-app"
        XCTAssertThrowsError(try ConfigurationFile.decode(JSONEncoder().encode(file)))
        XCTAssertThrowsError(try ConfigurationFile.decode(Data("{broken".utf8)))
    }
    func testAliasesAreOptionalForOlderConfigurationsAndNormalized() throws {
        let legacy = Data(#"{"id":"a","name":"A","bundleID":"app","section":"hidden","order":0}"#.utf8)
        let oldRule = try JSONDecoder().decode(ItemRule.self, from: legacy)
        XCTAssertNil(oldRule.alias)
        var prefs = Preferences()
        prefs.rules = [oldRule, .init(id: "b", name: "B", bundleID: "app", alias: "  My icon  ")]
        prefs.normalize()
        XCTAssertEqual(prefs.rules[1].alias, "My icon")
        let restored = try ConfigurationFile.decode(JSONEncoder().encode(ConfigurationFile(preferences: prefs)))
        XCTAssertEqual(restored.rules[1].alias, "My icon")
    }
    func testConfigRoundTripPreservesAllSettings() throws {
        var prefs = Preferences()
        prefs.mode = .inline
        prefs.glyph = .transparent
        prefs.rules = [.init(id: "app|one", name: "One", bundleID: "app", section: .alwaysHidden)]
        let data = try JSONEncoder().encode(ConfigurationFile(preferences: prefs))
        XCTAssertEqual(try ConfigurationFile.decode(data), prefs)
    }

    func testUnsupportedConfigCannotBeApplied() throws {
        var file = ConfigurationFile(preferences: .init())
        file.version = 99
        XCTAssertThrowsError(try ConfigurationFile.decode(JSONEncoder().encode(file)))
        XCTAssertThrowsError(try ConfigurationFile.decode(Data(repeating: 0, count: 1_048_577)))
    }

    func testImportSanitizesTimesDuplicateIDsAndShortcutConflicts() {
        var prefs = Preferences()
        prefs.hideDelay = .infinity
        prefs.hoverDelay = -4
        let hotkey = Shortcut(keyCode: 38, modifiers: 0x1800, label: "⌃⌥J")
        prefs.shortcuts["toggle"] = hotkey
        prefs.rules = [
            .init(id: "a", name: "A", bundleID: "a", shortcut: hotkey),
            .init(id: "a", name: "Duplicate", bundleID: "a"),
            .init(id: "b", name: "B", bundleID: "b", shortcut: .init(keyCode: 0, modifiers: 0, label: "A"))
        ]
        prefs.normalize()
        XCTAssertEqual(prefs.hideDelay, 3)
        XCTAssertEqual(prefs.hoverDelay, 0.1)
        XCTAssertEqual(prefs.rules.count, 2)
        XCTAssertTrue(prefs.rules.allSatisfy { $0.shortcut == nil })
    }

    func testMovingAcrossSectionsPreservesOtherRulesAndExactOrder() {
        var prefs = Preferences()
        prefs.rules = [
            .init(id: "a", name: "A", bundleID: "a", order: 0),
            .init(id: "b", name: "B", bundleID: "b", section: .hidden, order: 0),
            .init(id: "c", name: "C", bundleID: "c", section: .hidden, order: 1)
        ]
        prefs.move("a", to: .hidden, before: "c")
        XCTAssertEqual(prefs.rules.sorted { $0.order < $1.order }.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(prefs.section(for: "a"), .hidden)
        prefs.move("b", to: .alwaysHidden)
        XCTAssertEqual(prefs.section(for: "b"), .alwaysHidden)
        XCTAssertEqual(prefs.section(for: "unknown"), .visible)
    }

    func testShortcutValidationRequiresARealModifierAndHardwareKey() {
        XCTAssertFalse(Shortcut(keyCode: 4, modifiers: 0x200, label: "⇧H").isValid)
        XCTAssertFalse(Shortcut(keyCode: 999, modifiers: 0x100, label: "⌘?").isValid)
        XCTAssertTrue(Shortcut(keyCode: 4, modifiers: 0x900, label: "⌘⌥H").isValid)
    }
}
