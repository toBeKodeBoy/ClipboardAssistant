import CoreGraphics

/**
 * 主面板的首选尺寸，以及把它放进一块屏幕可见区域的计算。
 *
 * 不读鼠标、屏幕或偏好。调用方传入可见区域和指针，测试可以覆盖每一条分支。
 * 尺寸大于可见区域时先缩小再摆放，避免原点被挤出屏幕。
 *
 * @author toBeKodeBoy
 * @date 2026/11/07
 */
enum PanelGeometry {
    static let minimumWidth: Double = 720
    static let minimumHeight: Double = 560
    /// 首次启动采用宽屏布局（1100×560），预览在列表右侧。
    static let defaultWidth: Double = 1100
    static let defaultHeight: Double = 560
    /// 上一版出厂尺寸。宽高都不大于这个框时，视为还没有被用户拉大。
    static let legacyWidth: Double = 640
    static let legacyHeight: Double = 480
    /// 和窗口取整、出厂尺寸比较时允许的误差。
    static let tolerance: Double = 1

    /**
     * 用户记住的面板尺寸和菜单打开时的位置。
     */
    struct Preferred: Equatable {
        var width: Double
        var height: Double
        var placement: PanelPlacement
    }

    /**
     * 一次启动时的尺寸迁移结果。
     *
     * shouldPersist 为 true 时，调用方要把首选值和迁移标记写回偏好。
     * 初始化阶段属性观察器不会触发，不能靠赋值本身持久化。
     */
    struct Migration: Equatable {
        var preferred: Preferred
        var shouldPersist: Bool
    }

    /**
     * 这次实际摆上屏幕的窗口框架。
     *
     * clamped 为 true 表示为了放进可见区域而比首选尺寸更小。
     * 用户没有再拖拽时，关闭面板应保留原来的首选尺寸。
     */
    struct Placement: Equatable {
        var frame: CGRect
        var clamped: Bool
    }

    /**
     * 把仍停在旧默认框里的尺寸升到当前默认，并在那时把「鼠标附近」改为屏幕中心。
     *
     * 已经比 640×480 更大的尺寸保持不变，明确保存的位置也保持不变。
     * 迁移标记已经写过时，只补上缺失或非法的值，不再改用户后来选定的尺寸和位置。
     *
     * @param storedWidth 偏好里的宽度。缺失时为 nil
     * @param storedHeight 偏好里的高度。缺失时为 nil
     * @param storedPlacement 偏好里的位置原始值。缺失或无法识别时按屏幕中心
     * @param alreadyMigrated 这一次升级是否已经做过
     * @return 升级后的首选值，以及是否要写回偏好
     */
    static func migrate(
        storedWidth: Double?,
        storedHeight: Double?,
        storedPlacement: String?,
        alreadyMigrated: Bool
    ) -> Migration {
        let width = finitePositive(storedWidth, fallback: defaultWidth)
        let height = finitePositive(storedHeight, fallback: defaultHeight)
        let placement = PanelPlacement(rawValue: storedPlacement ?? "") ?? .center
        if alreadyMigrated {
            return Migration(
                preferred: Preferred(width: width, height: height, placement: placement),
                shouldPersist: false
            )
        }
        let factory = isFactorySize(width: storedWidth, height: storedHeight)
        let preferred = Preferred(
            width: factory ? defaultWidth : width,
            height: factory ? defaultHeight : height,
            placement: factory && placement == .mouse ? .center : placement
        )
        return Migration(preferred: preferred, shouldPersist: true)
    }

    /**
     * 计算这次打开使用的窗口框架。
     *
     * 首选尺寸先收进可见区域，再按位置计算原点，最后限制在可见区域内。
     * 可见区域比最小尺寸还小时，窗口跟可见区域一样大。
     *
     * @param preferred 用户记住的尺寸。非有限或非正值改用默认尺寸
     * @param placement 这一次的位置
     * @param mouse 指针的屏幕坐标。非有限时改用可见区域中心
     * @param visible 目标屏幕的可见区域
     * @return 窗口框架，以及这次是否为了放进屏幕而缩小
     */
    static func frame(preferred: CGSize, placement: PanelPlacement, mouse: CGPoint, visible: CGRect) -> Placement {
        let safeWidth = finitePositive(preferred.width, fallback: defaultWidth)
        let safeHeight = finitePositive(preferred.height, fallback: defaultHeight)
        let size = CGSize(
            width: fittedLength(preferred: safeWidth, minimum: minimumWidth, visibleLength: visible.width),
            height: fittedLength(preferred: safeHeight, minimum: minimumHeight, visibleLength: visible.height)
        )
        let clamped = size.width + tolerance < safeWidth || size.height + tolerance < safeHeight
        let origin = origin(size: size, placement: placement, mouse: mouse, visible: visible)
        return Placement(frame: CGRect(origin: origin, size: size), clamped: clamped)
    }

    /**
     * 关闭时要不要把当前窗口尺寸写回偏好。
     *
     * 只为适应屏幕而缩小、并且用户没有再拖拽时，保留原来更大的首选尺寸。
     * 用户拖过边缘时记下新尺寸。当前尺寸非法时退回首选尺寸，再不行就用默认尺寸。
     *
     * @param preferred 打开前记住的尺寸
     * @param applied 这次实际摆上屏幕的尺寸
     * @param current 关闭时的窗口尺寸
     * @param clamped 这次是否为了放进屏幕而缩小
     * @return 应写回偏好的尺寸
     */
    static func sizeToRemember(preferred: CGSize, applied: CGSize, current: CGSize, clamped: Bool) -> CGSize {
        let unchanged = nearly(current.width, applied.width) && nearly(current.height, applied.height)
        if clamped && unchanged {
            return CGSize(
                width: finitePositive(preferred.width, fallback: defaultWidth),
                height: finitePositive(preferred.height, fallback: defaultHeight)
            )
        }
        return CGSize(
            width: finitePositive(current.width, fallback: finitePositive(preferred.width, fallback: defaultWidth)),
            height: finitePositive(current.height, fallback: finitePositive(preferred.height, fallback: defaultHeight))
        )
    }

    /**
     * 这次窗口允许缩到的最小尺寸。
     *
     * 屏幕放得下 420×360 时维持这个下限。可见区域更小时，下限跟着可见区域走，
     * 否则系统会把窗口顶回最小尺寸，重新伸出屏幕。
     *
     * @param size 这次准备显示的窗口尺寸
     * @return 应设给窗口的最小尺寸
     */
    static func minimumSize(fitting size: CGSize) -> CGSize {
        CGSize(
            width: windowMinimum(length: size.width, floor: minimumWidth),
            height: windowMinimum(length: size.height, floor: minimumHeight)
        )
    }

    /**
     * 判断保存的宽高是否仍落在旧的出厂框里。
     *
     * 缺失、非有限、非正值都不是出厂尺寸，调用方只替换非法的那一边。
     *
     * @param width 偏好里的宽度
     * @param height 偏好里的高度
     * @return 两边都有值，且都不大于 640×480（允许 1pt 误差）时返回 true
     */
    static func isFactorySize(width: Double?, height: Double?) -> Bool {
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else {
            return false
        }
        return width <= legacyWidth + tolerance && height <= legacyHeight + tolerance
    }

    /**
     * 把一条边收进可见长度。
     *
     * 可见长度足够时，不小于最小尺寸，也不大于可见长度。
     * 可见长度更小时，整条边等于可见长度。可见长度不是正数时，退回不小于最小尺寸的首选值。
     *
     * @param preferred 已经确认过的正首选长度
     * @param minimum 这一条边的最小尺寸
     * @param visibleLength 可见区域在这一条边上的长度
     * @return 实际使用的长度
     */
    static func fittedLength(preferred: Double, minimum: Double, visibleLength: Double) -> Double {
        let preferred = finitePositive(preferred, fallback: minimum)
        guard visibleLength > 0 else { return max(preferred, minimum) }
        if visibleLength >= minimum {
            return min(max(preferred, minimum), visibleLength)
        }
        return visibleLength
    }

    /**
     * 按位置计算原点，再限制在可见区域内。
     *
     * 屏幕中心忽略指针。鼠标附近把窗口上沿对齐指针；指针坐标非法时改用可见区域中心。
     *
     * @param size 已经收进可见区域的窗口尺寸
     * @param placement 这一次的位置
     * @param mouse 指针的屏幕坐标
     * @param visible 目标屏幕的可见区域
     * @return 窗口左下角
     */
    static func origin(size: CGSize, placement: PanelPlacement, mouse: CGPoint, visible: CGRect) -> CGPoint {
        let raw: CGPoint
        if placement == .center {
            raw = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        } else {
            raw = CGPoint(
                x: finite(mouse.x, fallback: visible.midX),
                y: finite(mouse.y, fallback: visible.midY) - size.height
            )
        }
        return clamp(raw, size: size, visible: visible)
    }

    /**
     * 把原点限制在可见区域内。尺寸仍大于可见区域时，贴住可见区域的最小边。
     *
     * @param origin 限制前的左下角
     * @param size 窗口尺寸
     * @param visible 可见区域。宽或高不是正数时，退回该区域的最小边
     * @return 限制后的左下角
     */
    static func clamp(_ origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        guard visible.width > 0, visible.height > 0 else {
            return CGPoint(x: finite(visible.minX, fallback: 0), y: finite(visible.minY, fallback: 0))
        }
        return CGPoint(
            x: limit(finite(origin.x, fallback: visible.minX), low: visible.minX, high: visible.maxX - size.width),
            y: limit(finite(origin.y, fallback: visible.minY), low: visible.minY, high: visible.maxY - size.height)
        )
    }

    /**
     * 有限且大于 0 时保留原值，否则使用后备值。
     *
     * @param value 待检查的数。可以为空
     * @param fallback 非法时使用的数
     * @return 可用于尺寸的正数
     */
    static func finitePositive(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }

    /**
     * 有限时保留原值，否则使用后备值。坐标可以为 0 或负数。
     *
     * @param value 待检查的坐标
     * @param fallback 非有限时使用的坐标
     * @return 有限坐标
     */
    static func finite(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    /**
     * 把值限制在闭区间里。上界小于下界时贴住下界。
     *
     * @param value 待限制的坐标
     * @param low 下界
     * @param high 上界。小于下界时忽略
     * @return 限制后的坐标
     */
    static func limit(_ value: Double, low: Double, high: Double) -> Double {
        min(max(value, low), max(high, low))
    }

    /**
     * 两条边的差是否不超过取整误差。
     *
     * 任一值非有限时视为不同，避免把损坏的尺寸当成用户没有拖拽。
     *
     * @param lhs 比较的一边
     * @param rhs 比较的另一边
     * @return 两边都有限且相差不超过 1pt 时返回 true
     */
    static func nearly(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    /**
     * 窗口最小边。不小于 1pt，也不超过给定下限。
     *
     * @param length 这次窗口在这一条边上的长度
     * @param floor 正常情况下的最小长度
     * @return 应设给窗口的最小长度
     */
    static func windowMinimum(length: Double, floor: Double) -> Double {
        min(floor, max(finitePositive(length, fallback: floor), 1))
    }
}
