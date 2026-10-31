import Foundation

/// EPUB 的 HTML → 纯文本提取 + 规范化。
///
/// **为什么不复用 `TextNormalizer`（`FormatText`）**：那套规则是为
/// **TXT 与 Windows 存档偏移兼容** 服务的（压缩空行、压前导空白、只认 CRLF/LF……），
/// 硬套到 XHTML 上会把正文弄坏（`<p>` 之间的换行、HTML 实体、注音都会变形）。
/// 所以 EPUB 单独有一套：先提取可读正文，再规范成「一段一行、段间无空行」的纯文本，
/// 交给分页器。坐标仍然是 UTF-16 码元下标（`units`），与 TXT 一致。
///
/// 这不是完整的 HTML 解析器，只做「提取可读正文」这一件事：
/// - 注解 `<ruby><rt>`、`<script>`、`<style>`、`<head>` 整个丢弃（路线图 M7 前置 4）；
/// - 图片（`<img>`）忽略，只保留文字；
/// - 块级元素各算一段；`<br>` / `<hr>` 断行；
/// - 实体解码（`&amp;` `&#x2026;` …）；
/// - 行内换行折叠：中文之间不落空格（否则每行硬折的 XHTML 会被排成一字一空格），
///   西文之间保留一个空格。
enum EpubText {

    struct Paragraph: Equatable {
        var text: String
        var isHeading: Bool
    }

    /// 这些标签各自独占一段
    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl",
        "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption",
        "blockquote", "pre", "section", "article", "header", "footer", "aside",
        "nav", "main", "figure", "figcaption", "address", "body", "html", "center",
    ]

    static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// 内容整个丢弃的标签（脚本 / 样式 / 文件头 / 注音）
    static let skipTags: Set<String> = [
        "script", "style", "head", "rt", "rp", "template", "svg", "math",
    ]

    // MARK: - 段落提取

    /// 把一段 XHTML 提取成段落列表。**非严格解析**：遇到不认识的标签按行内处理。
    static func paragraphs(fromHTML html: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var buffer = ""
        var headingDepth = 0

        func flush() {
            let cleaned = collapseWhitespace(buffer)
            buffer = ""
            guard !cleaned.isEmpty else { return }
            paragraphs.append(Paragraph(text: cleaned, isHeading: headingDepth > 0))
        }

        var i = html.startIndex
        let end = html.endIndex
        while i < end {
            let ch = html[i]

            if ch != "<" {
                guard let nextTag = html[i...].firstIndex(of: "<") else {
                    buffer += decodeEntities(String(html[i...]))
                    break
                }
                buffer += decodeEntities(String(html[i..<nextTag]))
                i = nextTag
                continue
            }

            // 注释
            if html[i...].hasPrefix("<!--") {
                if let close = html.range(of: "-->", range: i..<end) {
                    i = close.upperBound
                } else { break }
                continue
            }
            // CDATA：内容当正文
            if html[i...].hasPrefix("<![CDATA[") {
                if let close = html.range(of: "]]>", range: i..<end) {
                    let inner = html[html.index(i, offsetBy: 9)..<close.lowerBound]
                    buffer += String(inner)
                    i = close.upperBound
                } else { break }
                continue
            }
            // 其它声明（DOCTYPE / 处理指令）
            if html[i...].hasPrefix("<!") || html[i...].hasPrefix("<?") {
                if let close = html.range(of: ">", range: i..<end) { i = close.upperBound } else { break }
                continue
            }

            // 普通标签
            guard let close = html.range(of: ">", range: i..<end) else { break }
            let rawTag = String(html[html.index(after: i)..<close.lowerBound])
            i = close.upperBound

            let isClosing = rawTag.hasPrefix("/")
            var body = isClosing ? String(rawTag.dropFirst()) : rawTag
            let selfClosing = body.hasSuffix("/")
            if selfClosing { body = String(body.dropLast()) }
            let name = tagName(body)

            if isClosing {
                if headingTags.contains(name) {
                    flush()
                    headingDepth = max(0, headingDepth - 1)
                } else if blockTags.contains(name) {
                    flush()
                }
                continue
            }

            // 丢弃型标签：直接跳到闭合处
            if skipTags.contains(name) {
                if !selfClosing, let next = skipPastClose(of: name, in: html, from: i) {
                    i = next
                }
                continue
            }
            if name == "br" || name == "hr" {
                flush()
                continue
            }
            if name == "img" || name == "wbr" || name == "meta" || name == "link" || name == "input" {
                continue
            }
            if blockTags.contains(name) {
                flush()
                if headingTags.contains(name) { headingDepth += 1 }
                if selfClosing { flush() }
                continue
            }
            // 行内标签：不影响文本
        }
        flush()
        return paragraphs
    }

    // MARK: - 空白 / 实体

    /// 取标签名：小写、去命名空间前缀（`xhtml:p` → `p`）、去属性。
    static func tagName(_ raw: String) -> String {
        var name = ""
        for ch in raw {
            if ch.isWhitespace || ch == "/" { break }
            name.append(ch)
        }
        if let colon = name.lastIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        return name.lowercased()
    }

    /// 从 `from` 开始找 `</name`（大小写不敏感），返回闭合标签 `>` 之后的位置。
    static func skipPastClose(of name: String, in html: String, from: String.Index) -> String.Index? {
        let needle = "</" + name
        var search = from
        while search < html.endIndex {
            guard let closeTag = html.range(of: needle, options: [.caseInsensitive],
                                           range: search..<html.endIndex) else { return nil }
            // 确保名字完整（`</script>` 不会匹配 `</scripts>`）
            var after = closeTag.upperBound
            if after < html.endIndex,
               (!html[after].isWhitespace && html[after] != ">") {
                search = after
                continue
            }
            if let gt = html[after...].firstIndex(of: ">") {
                return html.index(after: gt)
            }
            return nil
        }
        return nil
    }

    /// 折叠段内空白：连续空白压成一个空格。
    ///
    /// 关键区分：**源码里换行造成的空白**（XHTML 常见逐行硬折）在中文之间直接丢掉，
    /// 否则每个汉字之间都会被塞一个空格；**同一行里真正的空格**要保留
    /// （「第一章 桃花源记」里的空格是标题的一部分，不能吃）。
    static func collapseWhitespace(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingLineBreak = false
        var last: Unicode.Scalar?

        for scalar in raw.unicodeScalars {
            if scalar == "\u{200B}" || scalar == "\u{FEFF}" { continue }   // 零宽空格 / BOM
            if isSpace(scalar) {
                pendingSpace = true
                if scalar == "\n" || scalar == "\r" { pendingLineBreak = true }
                continue
            }
            if pendingSpace, let prev = last {
                if needsSpace(between: prev, and: scalar, fromLineBreak: pendingLineBreak) {
                    out.append(" ")
                }
            }
            pendingSpace = false
            pendingLineBreak = false
            out.append(scalar)
            last = scalar
        }
        return String(out)
    }

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{00A0}" || scalar == "\u{3000}" { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// CJK 字母 / 假名 / 谚文 / 全角字符（含中文标点）
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF, 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// 两段文字之间要不要落一个空格。
    /// - 源码换行 + 两侧都是中文 → 不落（逐行硬折的 XHTML）；
    /// - 同一行里的空格 → 保留（标题里的词间空格是内容）；
    /// - 中文标点前不落。
    static func needsSpace(between previous: Unicode.Scalar, and next: Unicode.Scalar,
                           fromLineBreak: Bool) -> Bool {
        if fromLineBreak && isCJK(previous) && isCJK(next) { return false }
        if isCJK(next) && isPunctuationSpaceSensitive(next) { return false }
        return true
    }

    /// 中文标点前不需要空格（「，」「。」「：」…）
    static func isPunctuationSpaceSensitive(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65:
            return true
        default:
            return false
        }
    }

    // MARK: - 实体

    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            guard let amp = raw[i...].firstIndex(of: "&") else {
                out += raw[i...]
                break
            }
            if amp > i { out += raw[i..<amp] }
            guard let semi = raw[amp...].firstIndex(of: ";") else {
                out += raw[amp...]
                break
            }
            let body = String(raw[raw.index(after: amp)..<semi])
            if let decoded = decodeEntity(body) {
                out += decoded
                i = raw.index(after: semi)
            } else {
                // 不认识的实体：保留 "&"，从下一个字符继续找
                out.append("&")
                i = raw.index(after: amp)
            }
        }
        return out
    }

    static func decodeEntity(_ body: String) -> String? {
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "mdash": return "—"
        case "ndash": return "–"
        case "hellip": return "…"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        case "middot": return "·"
        case "times": return "×"
        case "emsp": return "\u{2003}"
        case "ensp": return "\u{2002}"
        case "thinsp": return "\u{2009}"
        default: break
        }
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            if let value = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                return String(scalar)
            }
            return nil
        }
        if body.hasPrefix("#") {
            if let value = UInt32(body.dropFirst(1)), let scalar = Unicode.Scalar(value) {
                return String(scalar)
            }
            return nil
        }
        return nil
    }
}
