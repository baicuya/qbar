import Foundation

enum BuildChannel {
    static var isAppStore: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }
    static var label: String { L10n.tr(isAppStore ? "Mac App Store 构建" : "本地开发构建") }
}

/// UI language follows the preferred localization chosen by macOS for Qbar.
/// Chinese source strings are stable keys so existing UI text also serves as
/// the fallback when a translation has not yet been installed.
enum L10n {
    static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }
}
