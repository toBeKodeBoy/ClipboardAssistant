import Foundation

/**
 * 主面板列表和预览的排列。
 *
 * 宽度小于 720 时预览放在列表下方，否则放在右侧。默认面板宽 640，因此首次打开是上下排列。
 *
 * @author toBeKodeBoy
 * @date 2026/11/02
 */
enum HistoryPanelLayout {
    /** 达到该宽度后，预览回到列表右侧。 */
    static let sideBySideMinWidth: Double = 720
    /** 窄面板里预览希望占剩余高度的比例。 */
    static let previewFraction: Double = 0.42
    /** 窄面板预览的最低高度。剩余空间不够时会再压低。 */
    static let previewMinHeight: Double = 140
    /** 窄面板预览最多占剩余高度的比例，避免把列表挤没。 */
    static let previewMaxFraction: Double = 0.55

    /**
     * 判断当前宽度是否要把预览放在列表下方。
     *
     * @param containerWidth 列表和预览共用区域的宽度
     * @return 小于 720 时返回 true
     */
    static func placesPreviewBelowList(containerWidth: Double) -> Bool {
        containerWidth < sideBySideMinWidth
    }

    /**
     * 计算窄面板中预览区的高度。
     *
     * 先按 42% 取高度，再限制在 140 和剩余高度的 55% 之间。剩余高度不足 140 时，不超过 55%。
     *
     * @param containerHeight 列表和预览共用区域的高度
     * @return 预览区高度
     */
    static func previewHeight(in containerHeight: Double) -> Double {
        let proposed = containerHeight * previewFraction
        let upper = containerHeight * previewMaxFraction
        let lower = min(previewMinHeight, upper)
        return min(max(proposed, lower), upper)
    }
}
