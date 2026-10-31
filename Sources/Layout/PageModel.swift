import Foundation

/// 对应原版 Page.h 的 char_info_t：一个待绘制字符的度量结果。
/// 注意 `x` 不存储 —— 绘制时累加，与原版一致（Page.cpp:217-230）。
struct CharBox {
    var index: Int          // 绝对字符偏移
    var advance: CGFloat
    var cluster: Int        // 码元簇长度（1，或代理对为 2）
}

/// 这一行该用哪套字体度量。
///
/// 对应原版 `Page::SelectFont(hdc, index, is_title)` 选出来的 `dc_idx`：
/// `use_same_font == 1` 时原版把所有行都归到 dc 0（正文），
/// 只有 `use_same_font == 0` 且本行属于章节标题段落时才用 dc 1。
enum LineStyle {
    case body
    case title
}

/// 对应原版 Page.h 的 line_info_t
struct LineBox {
    var start: Int          // 逻辑起点（绝对字符偏移）
    var length: Int         // 逻辑长度（含被消费的换行符）
    var chars: [CharBox]    // 实际绘制的字符
    var indent: CGFloat     // 行首缩进偏移
    var height: CGFloat
    var gap: CGFloat        // 本行之后的间距：LINE_GAP / PART_GAP / 0(空行)
    /// 本行的字体/颜色归属。标题行用标题度量时行高也会跟着变。
    var style: LineStyle = .body
}

/// 对应原版 Page.h 的 page_info_t
/// ★ 这是整个移植的地基：一页 = 一个字符区间 + 一个行数组。
///   进度、书签、章节跳转全部建立在这个模型上，不能换成「交给系统排版」。
struct PageBox {
    var start: Int          // 页首绝对字符偏移（= 存档坐标）
    var length: Int         // 本页覆盖的字符数
    var lines: [LineBox]

    var end: Int { start + length }
    static let empty = PageBox(start: 0, length: 0, lines: [])

    /// 本页内容在竖直方向占用的总高度（含最后一行之后的间距）。
    ///
    /// 平滑滚动靠它做两件事：
    ///   1. 判断「滚过去了没有」——偏移超过它就翻到下一页；
    ///   2. 把下一页接在当前页下方连续绘制，因为两页在文本上是首尾相接的。
    var flowHeight: CGFloat {
        lines.reduce(0) { $0 + $1.height + $1.gap }
    }
}
