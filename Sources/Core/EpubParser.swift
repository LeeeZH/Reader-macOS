import Foundation

/// EPUB 解析错误（都要能直接展示给用户，所以 description 写人话）。
enum EpubParseError: Error, CustomStringConvertible {
    case missingContainer
    case malformedXML(String)
    case missingRootfile
    case malformedPackage
    case emptySpine
    case unreadableEntry(String)

    var description: String {
        switch self {
        case .missingContainer:
            return "这不是一本标准的 EPUB：缺少 META-INF/container.xml"
        case .malformedXML(let name):
            return "EPUB 里的 \(name) 不是合法 XML"
        case .missingRootfile:
            return "EPUB 里找不到 OPF 包定义（container.xml 的 rootfile）"
        case .malformedPackage:
            return "EPUB 的包定义（OPF）解析失败"
        case .emptySpine:
            return "这本 EPUB 没有可读的正文（spine 是空的）"
        case .unreadableEntry(let name):
            return "EPUB 里的 \(name) 读不出来"
        }
    }
}

/// EPUB 书籍（原型）。正文 / 章节 / 偏移语义与 `TextBook` 完全一致：
/// - `units` 是规范化后的 UTF-16 码元，进度 / 书签 / 章节锚点都用它的下标；
/// - 一个 spine 条目 = 一章（合并该 XHTML 的正文），`titleLength` 取第一条标题的字符数，
///   这样开头的 `<h1>` 会按「章节标题」的字体 / 颜色渲染（和 TXT 一致）。
///
/// 原型限制（路线图 M7 前置 4 明确允许）：图片 / 样式 / 注音忽略；
/// 章节标题只认 spine 文档里的 `<h1>`–`<h6>`，没有标题时用「第 N 节」；
/// TXT 的章节规则（`ChapterRule`）对 EPUB 不生效。
final class EpubBook: Book {
    let fileURL: URL
    let displayName: String
    /// 状态栏「编码」位置显示格式名
    let encodingName = "EPUB"
    let units: [UInt16]
    let chapters: [Chapter]
    /// 章节表建立后再不变（EPUB 没有 TXT 那种可重解析的章节规则）
    let chapterParseGeneration = 1
    let chapterRule = ChapterRule()
    let supportsEditing = false

    /// 全文搜索用的字符串视图，下标与 `units` 一致（构建成本必须是一次 memcpy）。
    lazy var findText: NSString = units.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress, buf.count > 0 else { return "" as NSString }
        return NSString(characters: base, length: buf.count)
    }

    init(fileURL: URL, displayName: String, units: [UInt16], chapters: [Chapter]) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.units = units
        self.chapters = chapters
    }

    /// EPUB 的章节来自 spine，TXT 的章节规则对它没有意义 —— no-op。
    func applyChapterRule(_ rule: ChapterRule) {}
}

/// EPUB 读取原型（路线图 M7 前置条件 2 / 3 / 4）。
///
/// 流程：`ditto` 解包到临时目录（`ZipArchive`）→ `META-INF/container.xml`
/// → OPF（manifest + spine）→ 逐个 spine 文档用 `EpubText` 提取正文 → 拼成
/// `units` + 章节表。**不引入任何第三方依赖，也不改 `.cache.dat`**。
enum EpubParser {

    /// - Parameters:
    ///   - extractedRoot: 已解包的 EPUB 根目录
    ///   - bookURL: 原始 .epub 路径（存进书籍模型 / 书架用）
    static func load(extractedRoot: URL, bookURL: URL) throws -> EpubBook {
        let containerURL = try ZipArchive.requireEntry(extractedRoot, "META-INF/container.xml")
        let opfURL = try rootfileURL(container: containerURL, root: extractedRoot)
        let package = try readPackage(opf: opfURL)

        let opfDir = opfURL.deletingLastPathComponent()
        var units: [UInt16] = []
        var chapters: [Chapter] = []

        for idref in package.spine {
            guard let item = package.manifest[idref] else { continue }
            let mediaType = item.mediaType.lowercased()
            // 只读文本型 spine 条目；图片 / 字体等直接跳过
            guard mediaType.contains("xhtml") || mediaType.contains("html") else { continue }
            guard let fileURL = resolve(root: extractedRoot, baseDir: opfDir, href: item.href),
                  FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let html = try readText(fileURL)
            let paragraphs = EpubText.paragraphs(fromHTML: html)
            guard !paragraphs.isEmpty else { continue }

            var chapterText = ""
            var title = "第 \(chapters.count + 1) 节"
            var titleLength = 0
            for (index, paragraph) in paragraphs.enumerated() {
                if index == 0, paragraph.isHeading {
                    title = paragraph.text
                    titleLength = paragraph.text.utf16.count
                }
                // 段间留一个空行：上一段结尾的 "\n" + 这里的 "\n"，和 TXT 版排版后的观感一致
                if index > 0 { chapterText += "\n" }
                chapterText += paragraph.text
                chapterText += "\n"
            }
            guard !chapterText.isEmpty else { continue }

            let chapterIndex = units.count
            units.append(contentsOf: chapterText.utf16)
            chapters.append(Chapter(index: chapterIndex, title: title, titleLength: titleLength))
        }

        guard !units.isEmpty, !chapters.isEmpty else { throw EpubParseError.emptySpine }

        let title = package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty
            ? bookURL.deletingPathExtension().lastPathComponent
            : title
        return EpubBook(fileURL: bookURL, displayName: name, units: units, chapters: chapters)
    }

    // MARK: - container.xml → OPF

    private static func rootfileURL(container: URL, root: URL) throws -> URL {
        guard let data = try? Data(contentsOf: container) else {
            throw EpubParseError.missingContainer
        }
        let parser = ContainerXMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse(), let path = parser.rootfilePath else {
            throw EpubParseError.malformedXML("META-INF/container.xml")
        }
        guard let url = resolve(root: root, baseDir: root, href: path),
              FileManager.default.fileExists(atPath: url.path) else {
            throw EpubParseError.missingRootfile
        }
        return url
    }

    // MARK: - OPF（manifest + spine + 书名）

    private static func readPackage(opf: URL) throws -> EpubPackage {
        guard let data = try? Data(contentsOf: opf) else {
            throw EpubParseError.missingRootfile
        }
        let parser = PackageXMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw EpubParseError.malformedXML("content.opf") }
        return parser.package
    }

    // MARK: - 路径 / 文件

    /// 把 EPUB 内部的相对路径解析成磁盘路径，并保证不越出解包目录。
    static func resolve(root: URL, baseDir: URL, href: String) -> URL? {
        var relative = href
        if let hash = relative.firstIndex(of: "#") { relative = String(relative[..<hash]) }
        if let query = relative.firstIndex(of: "?") { relative = String(relative[..<query]) }
        relative = relative.removingPercentEncoding ?? relative
        guard !relative.isEmpty else { return nil }
        let candidate = baseDir.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let path = candidate.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    private static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw EpubParseError.unreadableEntry(url.lastPathComponent)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // EPUB 规范要求 UTF-8；现实里有 GBK 存盘的，兜底一下
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - XMLParser 代理

/// OPF 解析出来的包定义
fileprivate struct EpubPackageItem {
    var href: String
    var mediaType: String
}

fileprivate struct EpubPackage {
    var title = ""
    var manifest: [String: EpubPackageItem] = [:]
    var spine: [String] = []
}

private final class ContainerXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard rootfilePath == nil else { return }
        guard localName(elementName) == "rootfile",
              let path = attributeDict["full-path"], !path.isEmpty else { return }
        rootfilePath = path
    }
}

private final class PackageXMLParser: NSObject, XMLParserDelegate {
    private(set) var package = EpubPackage()
    private var inMetadata = false
    private var inManifest = false
    private var inSpine = false
    private var capturingTitle = false
    private var titleBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "metadata":
            inMetadata = true
        case "title" where inMetadata:
            capturingTitle = true
            titleBuffer = ""
        case "manifest":
            inManifest = true
        case "spine":
            inSpine = true
        case "item" where inManifest:
            guard let id = attributeDict["id"], let href = attributeDict["href"] else { return }
            package.manifest[id] = EpubPackageItem(
                href: href, mediaType: attributeDict["media-type"] ?? "")
        case "itemref" where inSpine:
            if let idref = attributeDict["idref"] {
                package.spine.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "title" where capturingTitle:
            package.title = titleBuffer
            capturingTitle = false
        case "metadata":
            inMetadata = false
        case "manifest":
            inManifest = false
        case "spine":
            inSpine = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTitle { titleBuffer += string }
    }
}

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}
