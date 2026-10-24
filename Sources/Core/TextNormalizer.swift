import Foundation

/// 对应原版 Book::GetLine 与 Book::FormatText（Book.cpp:327-468）。
///
/// ⚠️ 这是全项目最关键的一处兼容代码：`item_t.index`（阅读进度）与
/// `item_t.mark[]`（书签）存的是 **FormatText 处理之后** 的 UTF-16 字符偏移。
/// 这里任何行为偏差，都会让 Windows 版用户的进度和书签错位。
///
/// 规则（逐条对应 C 源码）：
///   1. 文件开头空行 → 全部删除
///   2. 正文连续空行 → 最多保留 1 行；被保留的空行会被剥成裸 "\n"
///   3. prefix > 4 且行首为 0x20/0xA0 → 压成 4 个半角空格
///   4. prefix > 2 且行首为 U+3000     → 压成 2 个全角空格
///   5. 其余有内容的行 → 只裁行尾空白，保留原前导空白
///   6. CRLF / LF → 统一为单个 0x0A（孤立 CR 不是换行，原样保留 —— 见下方说明）
enum TextNormalizer {

    /// 对应 Page.h:66 的 is_blank
    @inline(__always)
    static func isBlank(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C || c == 0x3000 || c == 0x00A0
    }

    /// 对应 Page.cpp:1493 的 IsNewLine
    @inline(__always)
    static func isNewLine(_ c: UInt16) -> Bool { c == 0x0A || c == 0x0D }

    struct LineInfo {
        var lineLength: Int          // 不含行尾符
        var lfLength: Int            // 0 / 1 (\n) / 2 (\r\n)
        var isBlankLine: Bool
        var prefixBlankLength: Int
        var suffixBlankLength: Int
    }

    /// 对应 Book::GetLine。
    /// ⚠️ 只认 "\r\n" 与 "\n"；孤立 '\r' **不是**换行（原版如此，刻意保留）。
    static func getLine(_ text: [UInt16], _ start: Int, _ len: Int) -> LineInfo? {
        guard len > 0, start >= 0, start < text.count else { return nil }
        var isPrefix = true
        var isSuffix = false
        var prefix = 0, suffix = 0
        var blank = true
        var i = 0
        while i < len {
            let c = text[start + i]
            if isBlank(c) {
                if isPrefix { prefix += 1 }
                if isSuffix { suffix += 1 }
            } else if !isNewLine(c) {
                isPrefix = false
                isSuffix = true
                suffix = 0
                blank = false
            }
            if i + 1 < len, c == 0x0D, text[start + i + 1] == 0x0A {
                return LineInfo(lineLength: i, lfLength: 2, isBlankLine: blank,
                                prefixBlankLength: prefix, suffixBlankLength: suffix)
            }
            if c == 0x0A {
                return LineInfo(lineLength: i, lfLength: 1, isBlankLine: blank,
                                prefixBlankLength: prefix, suffixBlankLength: suffix)
            }
            i += 1
        }
        return LineInfo(lineLength: len, lfLength: 0, isBlankLine: blank,
                        prefixBlankLength: prefix, suffixBlankLength: suffix)
    }

    /// 对应 Book::FormatText
    static func format(_ input: [UInt16]) -> [UInt16] {
        guard !input.isEmpty else { return [] }
        var out = [UInt16]()
        out.reserveCapacity(input.count)

        var pos = 0
        var blankLineNum = 0
        var isFirstLine = true
        let n = input.count

        while pos < n, let li = getLine(input, pos, n - pos) {
            // --- 两条空行规则 ---
            if li.isBlankLine {
                var skip = false
                if isFirstLine {
                    skip = true                       // 开头空行全删
                } else {
                    blankLineNum += 1                 // 对应 C 的 ++blank_line_num
                    if blankLineNum >= ReaderDefaults.maxBlankLine { skip = true }
                }
                if skip {
                    pos += li.lineLength + li.lfLength
                    continue
                }
            } else {
                blankLineNum = 0
            }
            isFirstLine = false

            // --- 缩进规范化 ---
            let contentLen = li.lineLength - li.prefixBlankLength - li.suffixBlankLength
            if contentLen > 0 {                        // 对应 Book.cpp:358 的 if 守卫
                let first = input[pos]
                if li.prefixBlankLength > 4, first == 0x20 || first == 0xA0 {
                    out.append(contentsOf: [0x20, 0x20, 0x20, 0x20])
                    out.append(contentsOf: input[(pos + li.prefixBlankLength)..<(pos + li.lineLength - li.suffixBlankLength)])
                } else if li.prefixBlankLength > 2, first == 0x3000 {
                    out.append(contentsOf: [0x3000, 0x3000])
                    out.append(contentsOf: input[(pos + li.prefixBlankLength)..<(pos + li.lineLength - li.suffixBlankLength)])
                } else {
                    out.append(contentsOf: input[pos..<(pos + li.lineLength - li.suffixBlankLength)])
                }
            }
            // 被保留的空行在这里只会输出一个 "\n"（其空白内容不复制）
            if li.lfLength > 0 { out.append(0x0A) }

            pos += li.lineLength + li.lfLength
        }
        return out
    }
}
