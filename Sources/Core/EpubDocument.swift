import Foundation

/// EPUB 的 XHTML → 段落 / 标题提取（A 档：只用 macOS 自带的 Foundation XML 栈）。
///
/// 为什么从手写扫描器换到这里：真实 EPUB 的 XHTML 很脏（缺闭合、错嵌套、表格排版、
/// 命名空间、各种实体），逐字符扫描会吐错文本。`XMLDocument` 底层就是系统 libxml2，
/// 用 `.documentTidyHTML` 先做一遍 HTML 纠错解析，再用 XPath 取 `<body>` / `<title>` ——
/// 思路和原版 `EpubBook.cpp` 用 `htmlReadMemory` 一样，但**不需要链接任何第三方库**。
///
/// `EpubText.paragraphs` 保留为兜底：DOM 解析失败（极端畸形、libxml2 拒收）时仍能出文本，
/// 不会出现「整本书打不开」。
enum EpubDocument {

    struct Parsed {
        var paragraphs: [EpubText.Paragraph]
        var title: String?
    }

    /// 解析一段 XHTML：优先 DOM，失败退回扫描器。
    static func parse(html: String) -> Parsed {
        if let doc = makeDocument(html) {
            let paragraphs = paragraphs(in: doc)
            if !paragraphs.isEmpty {
                return Parsed(paragraphs: paragraphs, title: titleText(in: doc))
            }
        }
        return Parsed(paragraphs: EpubText.paragraphs(fromHTML: html), title: legacyTitle(html))
    }

    /// 把 XHTML / HTML 变成 DOM。
    ///
    /// 顺序很重要：
    /// 1. **先按严格 XML 解析**（EPUB 规范要求 XHTML 是合法 XML）——这条路上中文 / 命名空间 /
    ///    XPath 全部正常，绝大多数书走这里；
    /// 2. 解析失败（真实书里的脏 HTML：`<br>` 没闭合、标签错嵌套……）再走
    ///    `documentTidyHTML`（libxml2 的 HTML 纠错解析器）。⚠️ HTML 解析器在没有
    ///    `charset` 声明时会把 UTF-8 当 Latin-1（中文全变乱码），所以要显式补一个
    ///    `http-equiv="Content-Type" content="text/html; charset=utf-8"`。
    static func makeDocument(_ html: String) -> XMLDocument? {
        let prepared = preprocessHTMLEntities(html)
        let data = Data(prepared.utf8)
        if let doc = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) {
            return doc
        }
        let tidied = injectUTF8Charset(prepared)
        if let doc = try? XMLDocument(data: Data(tidied.utf8),
                                      options: [.documentTidyHTML, .nodePreserveWhitespace]) {
            return doc
        }
        return nil
    }

    /// 把 XML 不认识的 HTML 具名实体换成字符（`&nbsp;` `&hellip;` …）。
    /// `&amp;` / `&lt;` / `&gt;` / `&quot;` / `&apos;` 和 `&#…;` 是合法 XML，原样保留。
    static func preprocessHTMLEntities(_ html: String) -> String {
        guard html.contains("&") else { return html }
        let keep = ["amp", "lt", "gt", "quot", "apos"]
        var out = ""
        var i = html.startIndex
        while let amp = html[i...].firstIndex(of: "&") {
            out += html[i..<amp]
            guard let semi = html[amp...].firstIndex(of: ";") else {
                out += html[amp...]
                return out
            }
            let body = String(html[html.index(after: amp)..<semi])
            let lower = body.lowercased()
            if !body.hasPrefix("#"), !keep.contains(lower),
               let decoded = EpubText.decodeEntity(body) {
                out += decoded
                i = html.index(after: semi)
            } else {
                out.append("&")
                i = html.index(after: amp)
            }
        }
        out += html[i...]
        return out
    }

    /// 没声明 charset 时补一个 UTF-8 的 `http-equiv`（HTML 解析器只认这种写法）。
    static func injectUTF8Charset(_ html: String) -> String {
        let lower = html.lowercased()
        if lower.contains("http-equiv"), lower.contains("charset") { return html }
        let meta = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>"
        if let head = html.range(of: "<head", options: .caseInsensitive),
           let headGt = html.range(of: ">", range: head.upperBound..<html.endIndex) {
            var copy = html
            copy.insert(contentsOf: meta, at: headGt.upperBound)
            return copy
        }
        if let htmlTag = html.range(of: "<html", options: .caseInsensitive),
           let htmlGt = html.range(of: ">", range: htmlTag.upperBound..<html.endIndex) {
            var copy = html
            copy.insert(contentsOf: "<head>" + meta + "</head>", at: htmlGt.upperBound)
            return copy
        }
        return "<html><head>" + meta + "</head><body>" + html + "</body></html>"
    }

    /// 文档 `<title>`；多空白压成一个空格，没有就 nil。
    static func titleText(in doc: XMLDocument) -> String? {
        for node in elements(doc, "//*[local-name()='title']") {
            let cleaned = EpubText.collapseWhitespace(node.stringValue ?? "")
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// DOM → 段落：块级元素各一段，`<br>` / `<hr>` 断行，注音 / 脚本 / 样式整个跳过。
    /// 行内标签只贡献文字，不切段。
    static func paragraphs(in doc: XMLDocument) -> [EpubText.Paragraph] {
        guard let body = elements(doc, "//*[local-name()='body']").first else { return [] }

        var paragraphs: [EpubText.Paragraph] = []
        var buffer = ""
        var bufferStartsInHeading = false
        var headingDepth = 0

        func append(_ text: String, isHeading: Bool) {
            if buffer.isEmpty { bufferStartsInHeading = isHeading }
            buffer += text
        }

        func flush() {
            let cleaned = EpubText.collapseWhitespace(buffer)
            let wasHeading = bufferStartsInHeading
            buffer = ""
            bufferStartsInHeading = false
            guard !cleaned.isEmpty else { return }
            paragraphs.append(EpubText.Paragraph(text: cleaned, isHeading: wasHeading))
        }

        func walk(_ node: XMLNode) {
            switch node.kind {
            case .text:
                append(node.stringValue ?? "", isHeading: headingDepth > 0)

            case .element:
                guard let element = node as? XMLElement else { return }
                let name = elementName(element)
                if EpubText.skipTags.contains(name) { return }   // script / style / rt / rp / head…
                if name == "br" || name == "hr" {
                    flush()
                    return
                }
                if EpubText.blockTags.contains(name) {
                    flush()
                    if EpubText.headingTags.contains(name) { headingDepth += 1 }
                    for child in element.children ?? [] { walk(child) }
                    flush()
                    if EpubText.headingTags.contains(name) { headingDepth = max(0, headingDepth - 1) }
                    return
                }
                for child in element.children ?? [] { walk(child) }

            default:
                return   // 注释 / 处理指令 / DTD
            }
        }

        walk(body)
        flush()
        return paragraphs
    }

    // MARK: - XML 小工具

    /// 元素本地名：小写、去命名空间前缀（`xhtml:p` → `p`）。
    static func elementName(_ element: XMLElement) -> String {
        if let local = element.localName, !local.isEmpty {
            return local.lowercased()
        }
        return localName(element.name ?? "")
    }

    static func localName(_ qualified: String) -> String {
        let tail = qualified.split(separator: ":").last.map(String.init) ?? qualified
        return tail.lowercased()
    }

    /// XPath 取元素列表（`nodes(forXPath:)` 在 XMLNode 上也可用）。
    static func elements(_ node: XMLNode, _ xpath: String) -> [XMLElement] {
        guard let nodes = try? node.nodes(forXPath: xpath) else { return [] }
        return nodes.compactMap { $0 as? XMLElement }
    }

    /// 属性值（按 `name` 精确查；没有就 nil）。
    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    /// DOM 不可用时，用最朴素的办法抠 `<title>…</title>`（扫描器兜底用）。
    static func legacyTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive,
                                     range: gt.upperBound..<html.endIndex) else { return nil }
        let raw = String(html[gt.upperBound..<close.lowerBound])
        let cleaned = EpubText.collapseWhitespace(EpubText.decodeEntities(raw))
        return cleaned.isEmpty ? nil : cleaned
    }
}
