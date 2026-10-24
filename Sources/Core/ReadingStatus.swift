import Foundation

/// 阅读进度的**唯一定义**。
///
/// 之所以要单独抽一个函数、而且签名强制传入 `offset` + `totalLength`
/// （而不是传一个算好的百分比）：因为「进度」曾经在阅读界面和阅读列表里
/// 用了两套口径 —— 阅读界面按原版的 `(m_Index + m_PageLength) / m_Length`（页末），
/// 阅读列表按存档里的 `item.index`（页首），于是出现「阅读界面 100%、列表 99.7%」。
///
/// 现在只保留一个口径：**当前页起始字符偏移占全书的比例**。
/// 理由是存档里只有页首偏移（这是与 Windows 版互通的前提，不能改），
/// 阅读列表能算出的只有它，所以两边都必须用它。
enum ReadingStatus {

    /// 当前页起始偏移占全书的比例（0...100）
    static func percent(offset: Int, totalLength: Int) -> Double {
        guard totalLength > 0 else { return 0 }
        return min(100.0, max(0.0, Double(offset) / Double(totalLength) * 100))
    }

    /// 触控栏用的紧凑状态：`书名 · 章节标题 · 12.3%`
    static func compact(bookName: String, chapterTitle: String?,
                        offset: Int, totalLength: Int) -> String {
        var parts: [String] = []
        if !bookName.isEmpty { parts.append(bookName) }
        if let t = chapterTitle, !t.isEmpty { parts.append(t) }
        parts.append(String(format: "%.1f%%", percent(offset: offset, totalLength: totalLength)))
        return parts.joined(separator: " · ")
    }

    /// 主窗口状态栏用的完整状态
    static func full(bookName: String, encoding: String, totalLength: Int,
                     chapterIndex: Int?, chapterCount: Int,
                     offset: Int, isLastPage: Bool) -> String {
        var s = "\(bookName) · \(encoding) · \(totalLength) 字"
        if let idx = chapterIndex, chapterCount > 0 {
            s += " · 第 \(idx + 1)/\(chapterCount) 章"
        } else {
            s += " · 未识别到章节"
        }
        s += String(format: " · %.1f%%", percent(offset: offset, totalLength: totalLength))
        // 在末页时进度不会是 100%（百分比按页首算），标一下免得读者以为没读完
        if isLastPage { s += " · 末页" }
        return s
    }

    /// 阅读列表「进度」列的显示文字。
    ///
    /// 与阅读界面共用 `percent()`，所以两边永远一致。
    /// 总字数由后台异步算出，还没算出来时先退回显示偏移。
    static func libraryProgress(offset: Int, totalLength: Int?, isNew: Bool) -> String {
        if offset <= 0, isNew { return "未读" }
        guard let total = totalLength, total > 0 else { return "\(offset) 字" }
        return String(format: "%.1f%%", percent(offset: offset, totalLength: total))
    }
}
