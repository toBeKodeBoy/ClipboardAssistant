import Foundation

/**
 * 界面文案。
 *
 * 按系统首选语言在简体中文和英文之间选择，调用处同时给出两种文案。
 *
 * @author toBeKodeBoy
 * @date 2026/10/27
 */
enum L10n {
    /**
     * 按首选语言返回对应文案。
     *
     * 首选语言以 zh 开头时返回中文，其余返回英文。
     *
     * @param zh 简体中文
     * @param en 英文
     * @return 当前语言下应显示的文案
     */
    static func text(_ zh: String, _ en: String) -> String {
        let language = Locale.preferredLanguages.first ?? "zh-Hans"
        return language.hasPrefix("zh") ? zh : en
    }
}
