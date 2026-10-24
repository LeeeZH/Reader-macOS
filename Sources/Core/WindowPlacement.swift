import Foundation
import CoreGraphics

/// 主窗口位置/尺寸的**跨平台**存储。
///
/// 原版把窗口位置存在 `.cache.dat` 的 `header.placement`（WINDOWPLACEMENT）里，
/// 所以我们用同一个字段 —— 用户在 Windows 上调好的窗口位置，迁移过来也能用。
///
/// ⚠️ 坐标系不同，必须翻转 y：
///   - Win32：原点是**主屏左上角**，y 轴**向下**
///   - Cocoa：原点是**主屏左下角**，y 轴**向上**
enum WindowPlacement {

    /// 首次运行时的占位值（与 `CacheSchema.defaultHeader()` 的 placement 一致）。
    /// 出现这个值说明用户从没调过窗口，应当**居中**而不是还原到左上角。
    ///
    /// ⚠️ 注意这里用的是 Win32 原始 RECT，不是换算后的 Cocoa frame。
    /// 换算会带上屏高，直接拿 Cocoa 矩形比较永远不相等 —— 之前就在这里踩过坑。
    static let unsetWinRect: (left: Int, top: Int, right: Int, bottom: Int) = (0, 0, 300, 500)

    static func isUnset(left: Int, top: Int, right: Int, bottom: Int) -> Bool {
        left == unsetWinRect.left && top == unsetWinRect.top
            && right == unsetWinRect.right && bottom == unsetWinRect.bottom
    }

    /// Cocoa 窗口 frame → Win32 RECT(left, top, right, bottom)
    static func toWinRect(_ frame: CGRect,
                          primaryScreenHeight: CGFloat) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let left = Int(frame.minX.rounded())
        let right = Int(frame.maxX.rounded())
        let top = Int((primaryScreenHeight - frame.maxY).rounded())
        let bottom = Int((primaryScreenHeight - frame.minY).rounded())
        return (left, top, right, bottom)
    }

    /// Win32 RECT → Cocoa 窗口 frame。宽高非法时返回 nil。
    static func toNSRect(left: Int, top: Int, right: Int, bottom: Int,
                         primaryScreenHeight: CGFloat) -> CGRect? {
        guard right > left, bottom > top else { return nil }
        let w = CGFloat(right - left)
        let h = CGFloat(bottom - top)
        let maxY = primaryScreenHeight - CGFloat(top)
        return CGRect(x: CGFloat(left), y: maxY - h, width: w, height: h)
    }

    /// 是否值得还原。
    ///
    /// 判据不是「窗口有一部分可见」——那样窗口跑到屏幕上方、只剩底部一条边也算数。
    /// 真正的判据是**标题栏必须基本可见**，否则用户根本没法把它拖回来。
    static func isUsable(_ rect: CGRect, screenFrames: [CGRect], minSide: CGFloat = 80) -> Bool {
        guard rect.width >= minSide, rect.height >= minSide,
              rect.width < 20000, rect.height < 20000 else { return false }
        let stripH = min(40, rect.height)
        let titleStrip = CGRect(x: rect.minX, y: rect.maxY - stripH,
                                width: rect.width, height: stripH)
        let stripArea = titleStrip.width * titleStrip.height
        guard stripArea > 0 else { return false }
        for screen in screenFrames {
            let inter = screen.intersection(titleStrip)
            if !inter.isNull, inter.width * inter.height >= stripArea * 0.6 { return true }
        }
        return false
    }
}
