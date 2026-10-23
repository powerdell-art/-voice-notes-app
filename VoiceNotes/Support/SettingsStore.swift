import Foundation

/// 用户设置（当前主要是识别语言），用 UserDefaults 持久化
final class SettingsStore: ObservableObject {

    /// v1 支持的识别语言
    static let supportedLocales = ["zh-CN", "en-US"]

    @Published var localeIdentifier: String {
        didSet {
            UserDefaults.standard.set(localeIdentifier, forKey: Keys.locale)
        }
    }

    private enum Keys {
        static let locale = "recognitionLocale"
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: Keys.locale),
           Self.supportedLocales.contains(saved) {
            localeIdentifier = saved
        } else {
            // 默认跟随系统语言：中文系统默认普通话，其他默认美式英语
            let code = Locale.current.language.languageCode?.identifier
            localeIdentifier = (code == "zh") ? "zh-CN" : "en-US"
        }
    }
}
