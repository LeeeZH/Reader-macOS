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
/// - 一个 spine 条目 = 一章（合并该 XHTML 的正文）；
/// - 章节标题优先级：`nav.xhtml`（EPUB3）/ `toc.ncx`（EPUB2）→ 文档 `<title>` →
///   正文开头的 `<h1>`–`<h6>` → 「第 N 节」；
/// - `titleLength` 取正文开头标题行的字符数，这样标题字体 / 颜色对 EPUB 也生效。
///
/// 原型限制（路线图 M7 前置 4 明确允许）：图片 / 样式 / 注音忽略，封面暂不显示；
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

/// EPUB 读取（路线图 M7）。
///
/// 流程：`ZipArchive` 内存解包（A 档：`ZipReader` 读中央目录 + 系统 zlib；不支持时回退
/// `ditto`）→ `META-INF/container.xml` → OPF（manifest / spine / 书名）→
/// 读 `toc.ncx` / `nav.xhtml` 建「文件 → 章节标题」映射 → 逐个 spine 文档用
/// `EpubDocument` 提取正文（`XMLDocument` + XPath，系统 libxml2）→ 拼成 `units` + 章节表。
/// **不引入第三方依赖，也不改 `.cache.dat`**。
enum EpubParser {

    // MARK: - 入口

    /// 从「内部路径 → 内容」的文件映射解析（内存解包路径）。
    ///
    /// - Parameters:
    ///   - files: 路径统一用 `/` 分隔，如 `OEBPS/ch1.xhtml`
    ///   - bookURL: 原始 .epub 路径（存进书籍模型 / 书架用）
    static func load(files: [String: Data], bookURL: URL) throws -> EpubBook {
        let store = FileStore(files)
        guard let containerData = store.data(at: "META-INF/container.xml") else {
            throw EpubParseError.missingContainer
        }
        let opfPath = try rootfilePath(containerData: containerData)
        guard let opfData = store.data(at: opfPath) else {
            throw EpubParseError.missingRootfile
        }
        let package = try readPackage(data: opfData)
        let opfDir = directory(of: opfPath)
        let navigationTitles = readNavigationTitles(package: package, store: store, opfDir: opfDir)

        var units: [UInt16] = []
        var chapters: [Chapter] = []

        for idref in package.spine {
            guard let item = package.manifest[idref] else { continue }
            let mediaType = item.mediaType.lowercased()
            // 只读文本型 spine 条目；图片 / 字体等直接跳过
            guard mediaType.contains("xhtml") || mediaType.contains("html") else { continue }
            guard let path = resolve(baseDir: opfDir, href: item.href),
                  let htmlData = store.data(at: path) else { continue }

            let html = decodeText(htmlData)
            let parsed = EpubDocument.parse(html: html)
            guard !parsed.paragraphs.isEmpty else { continue }

            var chapterText = ""
            for (index, paragraph) in parsed.paragraphs.enumerated() {
                // 段间留一个空行：上一段结尾的 "\n" + 这里的 "\n"，和 TXT 版排版后的观感一致
                if index > 0 { chapterText += "\n" }
                chapterText += paragraph.text
                chapterText += "\n"
            }
            guard !chapterText.isEmpty else { continue }

            let navTitle = navigationTitles[path]
            var title = navTitle ?? parsed.title ?? "第 \(chapters.count + 1) 节"
            var titleLength = 0
            if let first = parsed.paragraphs.first, first.isHeading {
                // 没有 nav / <title> 时，正文开头的 h1 就是标题
                if navTitle == nil, parsed.title == nil { title = first.text }
                titleLength = first.text.utf16.count
            }

            let chapterIndex = units.count
            units.append(contentsOf: chapterText.utf16)
            chapters.append(Chapter(index: chapterIndex, title: title, titleLength: titleLength))
        }

        guard !units.isEmpty, !chapters.isEmpty else { throw EpubParseError.emptySpine }

        let rawTitle = package.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawTitle.isEmpty
            ? bookURL.deletingPathExtension().lastPathComponent
            : rawTitle
        return EpubBook(fileURL: bookURL, displayName: name, units: units, chapters: chapters)
    }

    /// 给单测 / 调试用：从已经解包的目录读（走 `ZipArchive.readTree` 变成内存映射）。
    static func load(extractedRoot: URL, bookURL: URL) throws -> EpubBook {
        try load(files: try ZipArchive.readTree(extractedRoot), bookURL: bookURL)
    }

    // MARK: - 文件映射

    /// 内存里的 EPUB：路径 → 内容。路径大小写不一致的书不少，这里做不区分大小写兜底。
    private struct FileStore {
        let map: [String: Data]
        private let lowerIndex: [String: String]

        init(_ map: [String: Data]) {
            self.map = map
            var index: [String: String] = [:]
            for key in map.keys where index[key.lowercased()] == nil {
                index[key.lowercased()] = key
            }
            self.lowerIndex = index
        }

        func data(at path: String) -> Data? {
            if let data = map[path] { return data }
            if let actual = lowerIndex[path.lowercased()] { return map[actual] }
            return nil
        }
    }

    // MARK: - container.xml → OPF

    private static func rootfilePath(containerData: Data) throws -> String {
        guard let doc = try? XMLDocument(data: containerData, options: [.nodePreserveWhitespace]) else {
            throw EpubParseError.malformedXML("META-INF/container.xml")
        }
        guard let rootfile = EpubDocument.elements(doc, "//*[local-name()='rootfile']").first,
              let fullPath = EpubDocument.attribute(rootfile, "full-path"),
              let path = normalize(fullPath) else {
            throw EpubParseError.missingRootfile
        }
        return path
    }

    // MARK: - OPF（manifest + spine + 书名）

    private struct PackageItem {
        var href: String
        var mediaType: String
        var properties: String
    }

    private struct Package {
        var title = ""
        var manifest: [String: PackageItem] = [:]
        var spine: [String] = []
        var spineTOC: String?
    }

    private static func readPackage(data: Data) throws -> Package {
        guard let doc = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            throw EpubParseError.malformedXML("content.opf")
        }

        var package = Package()
        package.title = EpubDocument
            .elements(doc, "//*[local-name()='metadata']//*[local-name()='title']")
            .first?.stringValue ?? ""

        for item in EpubDocument.elements(doc, "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let id = EpubDocument.attribute(item, "id"),
                  let href = EpubDocument.attribute(item, "href") else { continue }
            package.manifest[id] = PackageItem(
                href: href,
                mediaType: EpubDocument.attribute(item, "media-type") ?? "",
                properties: EpubDocument.attribute(item, "properties") ?? "")
        }

        for itemref in EpubDocument.elements(doc, "//*[local-name()='spine']/*[local-name()='itemref']") {
            if let idref = EpubDocument.attribute(itemref, "idref"), !idref.isEmpty {
                package.spine.append(idref)
            }
        }
        if let spine = EpubDocument.elements(doc, "//*[local-name()='spine']").first {
            package.spineTOC = EpubDocument.attribute(spine, "toc")
        }

        guard !package.manifest.isEmpty, !package.spine.isEmpty else {
            throw EpubParseError.malformedPackage
        }
        return package
    }

    // MARK: - 目录（nav.xhtml / toc.ncx）

    /// 返回「spine 文档路径 → 章节标题」。
    /// 先读 NCX（EPUB2），再用 nav.xhtml（EPUB3）覆盖：现代书两者都有时以 nav 为准。
    private static func readNavigationTitles(package: Package, store: FileStore,
                                             opfDir: String) -> [String: String] {
        var titles: [String: String] = [:]

        var ncxItem: PackageItem?
        if let tocID = package.spineTOC {
            ncxItem = package.manifest[tocID]
        }
        if ncxItem == nil {
            ncxItem = package.manifest.values.first {
                $0.mediaType.lowercased() == "application/x-dtbncx+xml"
            }
        }
        if let item = ncxItem,
           let path = resolve(baseDir: opfDir, href: item.href),
           let data = store.data(at: path) {
            for (key, value) in parseNCX(data: data, baseDir: directory(of: path)) {
                titles[key] = value
            }
        }

        let navItem = package.manifest.values.first { item in
            item.properties.split(whereSeparator: { $0.isWhitespace }).contains("nav")
        }
        if let item = navItem,
           let path = resolve(baseDir: opfDir, href: item.href),
           let data = store.data(at: path) {
            for (key, value) in parseNavDocument(data: data, baseDir: directory(of: path)) {
                titles[key] = value
            }
        }
        return titles
    }

    /// NCX：`navPoint/content@src` → `navLabel` 文本。
    private static func parseNCX(data: Data, baseDir: String) -> [String: String] {
        guard let doc = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            return [:]
        }
        var titles: [String: String] = [:]

        for navPoint in EpubDocument.elements(doc, "//*[local-name()='navPoint']") {
            guard let content = EpubDocument.elements(navPoint, ".//*[local-name()='content']").first,
                  let src = EpubDocument.attribute(content, "src"),
                  let path = resolve(baseDir: baseDir, href: src),
                  let label = EpubDocument.elements(navPoint, ".//*[local-name()='navLabel']").first
            else { continue }
            let cleaned = EpubText.collapseWhitespace(label.stringValue ?? "")
            guard !cleaned.isEmpty else { continue }
            titles[path] = cleaned
        }
        return titles
    }

    /// EPUB3 `nav.xhtml`：只认 `epub:type="toc"` 的 nav（landmarks 里的 "Text" 之类不能当章节名）。
    private static func parseNavDocument(data: Data, baseDir: String) -> [String: String] {
        guard let doc = EpubDocument.makeDocument(decodeText(data)) else { return [:] }

        var navs = EpubDocument.elements(doc, "//*[local-name()='nav']")
        let tocNavs = navs.filter(isTOCNav)
        if !tocNavs.isEmpty { navs = tocNavs } else if navs.count > 1 { navs = [] }

        var titles: [String: String] = [:]
        for nav in navs {
            for anchor in EpubDocument.elements(nav, ".//*[local-name()='a']") {
                guard let href = EpubDocument.attribute(anchor, "href"),
                      let path = resolve(baseDir: baseDir, href: href) else { continue }
                let cleaned = EpubText.collapseWhitespace(anchor.stringValue ?? "")
                guard !cleaned.isEmpty, titles[path] == nil else { continue }
                titles[path] = cleaned
            }
        }
        return titles
    }

    private static func isTOCNav(_ nav: XMLElement) -> Bool {
        let type = EpubDocument.attribute(nav, "epub:type")
            ?? EpubDocument.attribute(nav, "type")
        if let type, type.lowercased().contains("toc") { return true }
        if let id = EpubDocument.attribute(nav, "id"), id.lowercased() == "toc" { return true }
        return false
    }

    // MARK: - 路径 / 文本

    /// 把 EPUB 内部的相对路径解析成「文件映射里的路径」。
    /// 会去掉 `#fragment` / `?query`、解码百分号转义、规范化 `.` / `..`；
    /// 越出书根（`..` 太多）返回 nil —— 与原来基于磁盘路径的防穿越检查等价。
    static func resolve(baseDir: String, href: String) -> String? {
        var relative = href
        if let hash = relative.firstIndex(of: "#") { relative = String(relative[..<hash]) }
        if let query = relative.firstIndex(of: "?") { relative = String(relative[..<query]) }
        relative = relative.removingPercentEncoding ?? relative
        guard !relative.isEmpty else { return nil }
        var components: [String] = []
        if !baseDir.isEmpty {
            components.append(contentsOf: baseDir.split(separator: "/").map(String.init))
        }
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
                continue
            }
            components.append(String(component))
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    /// 去掉最后一段（`OEBPS/content.opf` → `OEBPS`；根目录 → `""`）。
    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// 规范化 `container.xml` 里的 `full-path`（只做路径规范化，不解析相对片段）。
    private static func normalize(_ path: String) -> String? {
        resolve(baseDir: "", href: path)
    }

    private static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // EPUB 规范要求 UTF-8；现实里有 GBK 存盘的，兜底一下
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
