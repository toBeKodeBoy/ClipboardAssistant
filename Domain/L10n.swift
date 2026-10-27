import Foundation

enum L10n {
    static func text(_ zh: String, _ en: String) -> String {
        let language = Locale.preferredLanguages.first ?? "zh-Hans"
        return language.hasPrefix("zh") ? zh : en
    }
}
