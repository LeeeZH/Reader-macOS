import Foundation

/// 一条全文搜索结果（「查找」面板里的一行）。
///
/// `index` / `length` 的单位是**UTF-16 码元**，与 `book.units` 的下标完全一致 ——
/// 也就是和阅读进度、书签、章节锚点同一套坐标，跳转时直接 `readingView.jump(to: index)`。
struct SearchHit: Equatable {
    /// 命中起点（`book.units` 下标）
    let index: Int
    /// 命中长度（UTF-16 码元数，不是字数）
    let length: Int
    /// 命中落在第几章（`chapters` 数组下标；没识别出章节时为 0）
    let chapterIndex: Int
    /// 列表里显示的上下文片段（换行/制表已折成空格，两端用「…」表示被裁掉）
    let excerpt: String
}

/// 一次全文搜索的结果。
struct SearchResults: Equatable {
    let query: String
    let hits: [SearchHit]
    /// 命中数超过上限、只收了前面一部分（界面要提示「结果太多」）
    let truncated: Bool

    static let empty = SearchResults(query: "", hits: [], truncated: false)

    var isEmpty: Bool { hits.isEmpty }
}

/// 全文搜索内核（「查找」面板用）。
///
/// 为什么要单独抽成纯逻辑：
///   · 搜索框每敲一个键就要对全文重扫一遍，性能与正确性都容易被界面代码搅乱；
///   · 「大小写不敏感」「非重叠」「结果上限」这些语义必须能用单测钉死；
///   · 偏移口径是自研分页的地基，错一位就会让跳转落到别的地方。
///
/// ⚠️ 为什么用 `NSString.range(of:options:range:)` 而不是自己写大小写折叠后再匹配：
///   折叠会把串**变长**（ß → ss、İ → i̇ 等），折叠串的下标就不再等于原文偏移，
///   拿它去 `jump(to:)` 会越落越偏。NSString 的比较在 UTF-16 上扬，返回的 NSRange
///   天然就是我们要的坐标；大小写折叠交给系统实现，既不重复造轮子也不会跑偏。
enum TextSearch {

    /// 单次搜索最多收集多少条命中。
    ///
    /// 「的」这种字在几 MB 的长篇里能有几十万处：全收下来既占内存，
    /// 列表也没人看得完。到上限就停，并用 `truncated` 让界面说明「只列前 N 处」。
    static let defaultLimit = 2000

    /// 片段两侧各保留多少个码元的上下文
    static let excerptContext = 18

    /// 在 `haystack` 里找出 `query` 的所有（非重叠）出现位置。
    ///
    /// - `caseSensitive == false` 时用 Unicode 大小写折叠比较（中文不受影响）；
    /// - 命中按位置升序返回；
    /// - 超过 `limit` 时截断并置 `truncated`。
    static func find(query: String,
                     haystack: NSString,
                     chapters: [Chapter],
                     caseSensitive: Bool = false,
                     limit: Int = defaultLimit) -> SearchResults {
        guard !query.isEmpty, limit > 0 else {
            return SearchResults(query: query, hits: [], truncated: false)
        }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let total = haystack.length
        var hits: [SearchHit] = []
        var truncated = false
        var cursor = 0

        while cursor < total {
            let window = NSRange(location: cursor, length: total - cursor)
            let r = haystack.range(of: query, options: options, range: window)
            if r.location == NSNotFound { break }
            // 空匹配保护：query 非空时不该出现，但真出现会死循环，宁可跳一个字
            if r.length == 0 { cursor = r.location + 1; continue }

            hits.append(SearchHit(index: r.location,
                                  length: r.length,
                                  chapterIndex: chapterIndex(of: r.location, in: chapters),
                                  excerpt: excerpt(haystack: haystack,
                                                   index: r.location, length: r.length)))

            if hits.count >= limit {
                // 已经收满，往后探一下还有没有下一条 —— 据此决定要不要提示「结果太多」
                let rest = NSRange(location: r.location + r.length,
                                   length: total - (r.location + r.length))
                truncated = rest.length > 0
                    && haystack.range(of: query, options: options, range: rest).location != NSNotFound
                break
            }
            cursor = r.location + r.length       // 非重叠：跳过本条命中继续找
        }

        return SearchResults(query: query, hits: hits, truncated: truncated)
    }

    /// 便捷入口：直接拿规范化后的码元数组搜索（单测、离线工具用）。
    static func find(query: String,
                     units: [UInt16],
                     chapters: [Chapter] = [],
                     caseSensitive: Bool = false,
                     limit: Int = defaultLimit) -> SearchResults {
        find(query: query,
             haystack: String(decoding: units, as: UTF16.self) as NSString,
             chapters: chapters,
             caseSensitive: caseSensitive,
             limit: limit)
    }

    /// 命中起点所在的章节下标（最后一个 `index <= offset` 的章节）。
    /// 与 `TextBook.chapterIndex(at:)` 同一语义，这里用二分是因为每次搜索都可能调用上千次。
    static func chapterIndex(of offset: Int, in chapters: [Chapter]) -> Int {
        guard !chapters.isEmpty else { return 0 }
        var lo = 0
        var hi = chapters.count - 1
        var best = 0
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            if chapters[mid].index <= offset {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// 裁一段上下文做列表显示：前后各 `context` 个码元，换行/制表折成空格，
    /// 且**不切断**代理对（裁到半个 emoji 会显示成乱码方块）。
    static func excerpt(haystack: NSString, index: Int, length: Int,
                        context: Int = excerptContext) -> String {
        let total = haystack.length
        guard total > 0 else { return "" }
        var start = max(0, index - context)
        var end = min(total, index + length + context)
        // 起点落在低代理项上 = 这一刀切在代理对中间，跳过这个孤立的半个字符；
        // 终点落在低代理项上 = 前一个码元是高代理项，回退一个把整对留在外面。
        if start > 0, isLowSurrogate(haystack.character(at: start)) { start += 1 }
        if end < total, isLowSurrogate(haystack.character(at: end)) { end -= 1 }

        let raw = haystack.substring(with: NSRange(location: start, length: max(0, end - start)))
        let folded = foldWhitespace(raw)
        return (start > 0 ? "…" : "") + folded + (end < total ? "…" : "")
    }

    // MARK: - 命中之间的前后移动（面板的上一个 / 下一个）

    /// 从 `offset` 开始（含）的第一条命中，用于「搜索后从当前阅读位置往下找」。
    static func firstIndex(atOrAfter offset: Int, hits: [SearchHit]) -> Int? {
        hits.firstIndex { $0.index >= offset }
    }

    /// `offset` 及之前（含）的最后一条命中，用于「往回找上一处」。
    static func lastIndex(atOrBefore offset: Int, hits: [SearchHit]) -> Int? {
        hits.lastIndex { $0.index <= offset }
    }

    /// 严格在 `hitIndex` 之后的一条；`wrap` 时回到第一条。
    static func index(after hitIndex: Int, hits: [SearchHit], wrap: Bool = true) -> Int? {
        guard !hits.isEmpty else { return nil }
        if hitIndex + 1 < hits.count { return hitIndex + 1 }
        return wrap ? 0 : nil
    }

    /// 严格在 `hitIndex` 之前的一条；`wrap` 时回到最后一条。
    static func index(before hitIndex: Int, hits: [SearchHit], wrap: Bool = true) -> Int? {
        guard !hits.isEmpty else { return nil }
        if hitIndex > 0 { return hitIndex - 1 }
        return wrap ? hits.count - 1 : nil
    }

    // MARK: - 内部

    private static func isLowSurrogate(_ u: unichar) -> Bool { u >= 0xDC00 && u <= 0xDFFF }

    /// 把换行、回车、制表折成空格，并把连续空白压成一个 —— 列表里一行放得下，
    /// 也不会因为原文里的空行显得一段全白。
    static func foldWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            let isSpace = ch == "\n" || ch == "\r" || ch == "\t" || ch == " "
            if isSpace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
