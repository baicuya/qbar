import Foundation
import QbarCore

enum SpacingManager {
    private static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private static let backupKey = "originalGlobalSpacing"

    static func apply(_ preset: SpacingPreset) throws {
        guard !BuildChannel.isAppStore else { throw SpacingError.sandbox }
        if UserDefaults.standard.dictionary(forKey: backupKey) == nil {
            var original: [String: Any] = [:]
            for key in keys {
                original[key] = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as Any? ?? "absent"
            }
            UserDefaults.standard.set(original, forKey: backupKey)
        }
        if let values = preset.values {
            write(keys[0], value: values.spacing as CFNumber)
            write(keys[1], value: values.padding as CFNumber)
        } else { restore() }
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw SpacingError.writeFailed }
    }

    static func restore() {
        guard !BuildChannel.isAppStore else { return }
        let original = UserDefaults.standard.dictionary(forKey: backupKey) ?? [:]
        for key in keys { write(key, value: original[key] as? NSNumber) }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func write(_ key: String, value: CFPropertyList?) {
        CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    enum SpacingError: LocalizedError {
        case sandbox, writeFailed
        var errorDescription: String? {
            switch self {
            case .sandbox: L10n.tr("Mac App Store 沙盒不允许修改其他应用的全局间距。可调整 Qbar 浮窗的图标大小。")
            case .writeFailed: L10n.tr("系统未能保存间距设置。")
            }
        }
    }
}
