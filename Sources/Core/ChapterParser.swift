import Foundation

/// 章节锚点。`index` 是 **UTF-16 字符偏移**，单位与
/// 原版 chapter_item_t.index 完全一致（原件用的是 wchar_t 下标）。
struct Chapter {
    var index: Int
    var title: String
    var titleLength: Int
}

enum ChapterRuleKind: Int {
    case `default` = 0
    case keyword = 1
    case regex = 2
}

struct ChapterRule: Equatable {
    var kind: ChapterRuleKind = .default
    var keyword: String = ""
    var regex: String = ""
}

/// 对应 TextBook.cpp:163-362 的三种章节解析模式。
enum ChapterParser {

    /// 对应 TextBook.cpp:6-19 的 m_ValidChapter 白名单
    static let validChapterChars: Set<UInt16> = {
        var s = Set<UInt16>()
        for c in [UInt16(0x20), 0x09] { s.insert(c) }
        for c in UInt16(0x30)...UInt16(0x39) { s.insert(c) }        // 0-9
        let cjk: [Character] = Array("零一二三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟萬億两")
        for ch in cjk {
            for u in String(ch).utf16 { s.insert(u) }
        }
        s.insert(0x3000)
        return s
    }()

    @inline(__always) private static func u(_ s: String) -> UInt16 { Array(s.utf16)[0] }

    /// 对应 TextBook::IsChapter（白名单校验）
    static func isChapter(_ text: [UInt16], _ start: Int, _ len: Int) -> Bool {
        guard len > 0 else { return false }
        for i in 0..<len where !validChapterChars.contains(text[start + i]) { return false }
        return true
    }

    // MARK: - 入口（对应 TextBook::ParserChapters）

    static func parse(_ text: [UInt16], rule: ChapterRule) -> [Chapter] {
        switch rule.kind {
        case .default: return parseDefault(text)
        case .keyword: return parseKeyword(text, keyword: rule.keyword)
        case .regex:   return parseRegex(text, pattern: rule.regex)
        }
    }

    // MARK: - 默认规则（对应 ParserChaptersDefault）

    static func parseDefault(_ text: [UInt16]) -> [Chapter] {
        var chapters = [Chapter]()
        var titleBuf = [UInt16]()
        titleBuf.reserveCapacity(ReaderDefaults.maxChapterLength)

        var pos = 0
        let n = text.count
        while pos < n, let li = TextNormalizer.getLine(text, pos, n - pos) {
            let lineSize = li.lineLength

            var idx1 = -1, idx2 = -1
            var found = false

            var i = 0
            while i < lineSize {
                let c = text[pos + i]
                if c == u("第") { idx1 = i }

                // ⚠️ 原版此处的 && / || 优先级有瑕疵：两个冒号分支绕过了 idx1 > -1 的前提。
                //    这里**刻意照搬**，以保证与原版解析结果一致。
                let isLast = (i + 1 >= lineSize)
                // 越界安全：原版靠缓冲区末尾的 NUL，这里用 0 代替，比较结果等价
                let next: UInt16 = isLast ? 0 : text[pos + i + 1]
                let condB = ((lineSize > i + 1 && (next == 0x20 || next == 0x09))
                             || next == 0x3000
                             || next == 0x00A0
                             || lineSize <= i + 1)
                let hit = (idx1 > -1 && condB) || next == u("：") || next == u(":")

                if hit {
                    if c == u("卷") || c == u("章") || c == u("部") || c == u("节") {
                        idx2 = i
                        found = true
                        break
                    }
                }

                // 「楔子」/「序章」特例。
                // ⚠️ 有意修复原版缺陷：原条件写作 `line_size > i + 2`，导致
                //    **只含「楔子」两字的行永远匹配不上**；而同一行里的
                //    `|| line_size <= i + 1` 与主条件互斥，是永远不成立的死代码。
                //    这里改为「后面是空白 或 正好在行尾」。
                //    章节列表不写入 .cache.dat（每次打开重新解析），
                //    所以此修复**不影响**与 Windows 版的进度/书签兼容性。
                if idx1 == -1, i + 2 <= lineSize {
                    let n2: UInt16 = (i + 2 < lineSize) ? text[pos + i + 2] : 0
                    let atEnd = (i + 2 >= lineSize)
                    let followedByBlank = atEnd || n2 == 0x20 || n2 == 0x09 || n2 == 0x3000
                    if followedByBlank, c == u("楔"), text[pos + i + 1] == u("子") {
                        idx1 = i; idx2 = lineSize - 1; found = true; break
                    }
                    if followedByBlank, c == u("序"), text[pos + i + 1] == u("章") {
                        idx1 = i; idx2 = lineSize - 1; found = true; break
                    }
                }
                i += 1
            }

            if found, idx1 >= 0 {
                let isSpecial = text[pos + idx1] == u("楔") || text[pos + idx1] == u("序")
                if isSpecial || isChapter(text, pos + idx1 + 1, idx2 - idx1 - 1) {
                    let titleLen = min(lineSize - idx1, ReaderDefaults.maxChapterLength - 1)
                    titleBuf = Array(text[(pos + idx1)..<(pos + idx1 + titleLen)])
                    let title = String(decoding: titleBuf, as: UTF16.self)
                    // ★ 原版把 `idx_1 +` 注释掉了（TextBook.cpp:243），
                    //   所以 index 取的是**行首偏移**，不是标题起点。必须照搬。
                    chapters.append(Chapter(index: pos, title: title, titleLength: titleLen))
                }
            }

            pos += lineSize + 1     // FormatText 已把 CRLF 归一为 LF，故 +1 成立
        }
        return chapters
    }

    // MARK: - 关键字规则（对应 ParserChaptersKeyword）

    static func parseKeyword(_ text: [UInt16], keyword: String) -> [Chapter] {
        guard !keyword.isEmpty else { return [] }
        let kw = Array(keyword.utf16)
        var chapters = [Chapter]()

        var pos = 0
        let n = text.count
        while pos < n, let li = TextNormalizer.getLine(text, pos, n - pos) {
            let lineSize = li.lineLength
            if kw.count <= lineSize {
                var hit = -1
                var i = 0
                while i <= lineSize - kw.count {
                    var ok = true
                    for k in 0..<kw.count where text[pos + i + k] != kw[k] { ok = false; break }
                    if ok { hit = i; break }
                    i += 1
                }
                if hit >= 0 {
                    let titleLen = min(lineSize - hit, ReaderDefaults.maxChapterLength - 1)
                    let title = String(decoding: text[(pos + hit)..<(pos + hit + titleLen)], as: UTF16.self)
                    chapters.append(Chapter(index: pos, title: title, titleLength: titleLen))
                }
            }
            pos += lineSize + 1
        }
        return chapters
    }

    // MARK: - 正则规则（对应 ParserChaptersRegex，样例：第.*章\s+.*）

    static func parseRegex(_ text: [UInt16], pattern: String) -> [Chapter] {
        guard !pattern.isEmpty else { return [] }
        let full = String(decoding: text, as: UTF16.self)
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var chapters = [Chapter]()
        // NSRegularExpression 的 NSRange 就是 UTF-16 偏移，与我们的 units 下标一致
        re.enumerateMatches(in: full, range: NSRange(location: 0, length: (full as NSString).length)) { m, _, _ in
            guard let m = m else { return }
            let len = min(m.range.length, ReaderDefaults.maxChapterLength - 1)
            guard len > 0 else { return }
            let sub = (full as NSString).substring(with: NSRange(location: m.range.location, length: len))
            chapters.append(Chapter(index: m.range.location, title: sub, titleLength: len))
        }
        return chapters
    }
}
