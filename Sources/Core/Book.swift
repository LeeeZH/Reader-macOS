import Foundation

/// 书籍的**只读**抽象。
///
/// 为什么要有这一层（M7 前置，见 docs/ROADMAP.md「M7 EPUB」）：
/// - 阅读视图、查找 / 章节搜索 / 书签面板、书架只依赖「正文 + 章节表 + 字符偏移」，
///   不该知道背后是 TXT 还是 EPUB。换成别的格式时这些界面一行都不用改。
/// - **坐标语义不变**：`units` 的下标就是进度 / 书签 / 章节锚点 / 搜索命中的那套
///   UTF-16 码元偏移（与 Windows 版存档互通的前提）。任何新格式都必须先把正文
///   规范化成同样的 `[UInt16]`，而不是引入页码 / 百分比当坐标。
/// - 存档（`.cache.dat`）只存路径 + 字符偏移，本来就与格式无关，所以协议里
///   不出现任何「文件怎么解析」的东西。
///
/// TXT 的实现是 `TextBook`；EPUB 接入时新增一个 `EpubBook: Book`，
/// 再把 `BookLoader` 的分发补上即可，`ReadingView` / 书架 / 存档都不用动。
protocol Book: AnyObject {
    /// 书籍文件路径（书架「重新定位」、导出存档都用它）
    var fileURL: URL { get }
    /// 书名（默认取文件名；EPUB 用 OPF 里的 title）
    var displayName: String { get }
    /// 状态栏显示的编码 / 格式名（TXT 是 UTF-8 等；EPUB 会是 "EPUB"）
    var encodingName: String { get }
    /// 规范化后的 UTF-16 码元。**所有字符偏移都以这个数组下标为准。**
    var units: [UInt16] { get }
    /// 全文搜索用的字符串视图，下标与 `units` 一致（各格式自己缓存）
    var findText: NSString { get }
    /// 章节表（按文件顺序；`titleLength` 是该标题在 `units` 里的字符区间长度）
    var chapters: [Chapter] { get }
    /// 章节表版本号：每重新解析一次 +1（自检据此断言「改字号不该重解析全书」）
    var chapterParseGeneration: Int { get }
    /// 当前章节规则（TXT 用；其它格式返回默认即可）
    var chapterRule: ChapterRule { get }
    /// 正文总长度（= `units.count`）
    var totalLength: Int { get }
    /// 这个格式支持「编辑模式」吗（目前只有 TXT）
    var supportsEditing: Bool { get }

    /// 应用新的章节规则（TXT 会重新解析；其它格式可以 no-op）
    func applyChapterRule(_ rule: ChapterRule)

    func chapterIndex(at offset: Int) -> Int
    func isChapterStart(at offset: Int) -> Bool
    func isChapterTitle(at offset: Int) -> Bool
    func chapterTitle(at offset: Int) -> String?
}

// MARK: - 默认实现

/// 这些偏移逻辑对所有格式都一样，放在协议扩展里只写一遍。
/// `TextBook` 为了性能覆写了前四个（章节起点集合 / 短路空表），语义与这里一致。
extension Book {
    var totalLength: Int { units.count }
    var supportsEditing: Bool { false }

    /// 返回最后一个 `index <= offset` 的章节号（对应原版 `Book::GetCurChapterIndex`）。
    /// 用二分：搜索 / 排版里可能每页调用上千次。
    func chapterIndex(at offset: Int) -> Int {
        guard !chapters.isEmpty else { return 0 }
        var lo = 0, hi = chapters.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chapters[mid].index <= offset { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }

    /// offset 是否正好是某一章的开头（章前分页用）
    func isChapterStart(at offset: Int) -> Bool {
        guard !chapters.isEmpty else { return false }
        return chapters[chapterIndex(at: offset)].index == offset
    }

    /// offset 是否落在某个章节标题的字符区间内（决定这一行用标题字体）
    func isChapterTitle(at offset: Int) -> Bool {
        guard !chapters.isEmpty else { return false }
        let ch = chapters[chapterIndex(at: offset)]
        return offset >= ch.index && offset < ch.index + ch.titleLength
    }

    func chapterTitle(at offset: Int) -> String? {
        guard !chapters.isEmpty else { return nil }
        return chapters[chapterIndex(at: offset)].title
    }
}

// MARK: - 格式分发

/// 书籍加载的唯一入口。目前只有 TXT；EPUB（M7）接在这里，
/// 这样 AppDelegate / 书架就不需要各自 `if 后缀 == "txt"`。
enum BookLoader {
    /// 这个路径是不是我们支持的格式。以后支持 EPUB 时在这里加。
    static func supports(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "txt"
    }

    /// 把已解码的文本做成书（解码本身留在 AppDelegate：打开耗时要分阶段打点）。
    static func makeBook(url: URL, decoded: DecodedText, chapterRule: ChapterRule) -> Book {
        TextBook(fileURL: url, rawText: decoded.text,
                 encodingName: decoded.encodingName, chapterRule: chapterRule)
    }

    /// 只为了书架百分比而算总字数（不解章节、不建搜索缓存）。
    /// 口径必须和 `ReadingView` 一致：`FormatText` 之后的 UTF-16 码元数。
    static func totalLength(ofFileAt url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? TextDecoder.decode(data) else { return nil }
        return TextNormalizer.format(Array(decoded.text.utf16)).count
    }
}

/// TXT 书籍。对应原版 TextBook + Book 基类的可移植部分。
final class TextBook: Book {
    let fileURL: URL
    let encodingName: String
    let rawText: String
    /// 规范化后的 UTF-16 码元数组。
    /// ★ 所有「字符偏移」（进度 / 书签 / 章节锚点）都以这个数组的下标为准，
    ///   与 Windows 版的 wchar_t 下标语义一致。
    let units: [UInt16]
    private(set) var chapters: [Chapter]

    /// 全文搜索用的字符串视图。
    ///
    /// `units` 是 `let`，所以这份「一次构建、反复搜索」的缓存永远和正文一致。
    ///
    /// ⚠️ 一定要用 `NSString(characters:length:)`，**不要**写成
    /// `String(decoding: units, as: UTF16.self) as NSString`：
    ///   · 后者会把 UTF-16 逐字重编码成 Swift String 的 UTF-8 存储，
    ///     6.4M 码元实测 **617ms**（而且多占约 1.5 倍内存）；
    ///   · 前者只是一次 12MB 的 memcpy，实测 **0.6ms**。
    /// 差出来的半秒正好卡在「第一次按 ⌘F」上，用户会以为搜索卡死。
    ///
    /// ⚠️ 它的下标就是 `units` 的下标（UTF-16 码元），所以搜索命中可以直接
    /// 交给 `jump(to:)` —— 不需要任何「页码 ↔ 偏移」的换算。
    lazy var findText: NSString = units.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress, buf.count > 0 else { return "" as NSString }
        return NSString(characters: base, length: buf.count)
    }

    /// 章节表版本号：每重新解析一次 +1。
    /// 自检用它断言「改显示设置（字号 / 行距……）不该重新解析全书章节」。
    private(set) var chapterParseGeneration = 0

    var chapterRule = ChapterRule() {
        didSet {
            chapters = ChapterParser.parse(units, rule: chapterRule)
            chapterParseGeneration += 1
            // 章节表换了一版，按章节起点缓存的集合必须同步重建，
            // 否则「章前分页」会拿旧章节表判断，表现成分页错位。
            chapterStartSet = Set(chapters.map { $0.index })
        }
    }

    /// - Parameter chapterRule: 打开时就用这套规则解析章节。
    ///   避免「先按默认规则全量解析一遍、再按用户设置解析一遍」的双倍开销
    ///   （长篇小说一次全量解析就是几百毫秒）。
    init(fileURL: URL, rawText: String, encodingName: String, chapterRule: ChapterRule = ChapterRule()) {
        self.fileURL = fileURL
        self.rawText = rawText
        self.encodingName = encodingName
        // 对应 Book::DecodeText 末尾必定调用的 FormatText
        self.units = TextNormalizer.format(Array(rawText.utf16))
        self.chapters = ChapterParser.parse(self.units, rule: chapterRule)
        self.chapterRule = chapterRule
        self.chapterParseGeneration = 1
    }

    /// 只在规则真的变化时才重新解析章节。
    ///
    /// 设置窗口的滑块是连续触发的（`isContinuous = true`），每拖一下都会
    /// 走 `applySettingsToReader()`。如果这里无条件解析全书，几 MB 的长篇小说
    /// 每动一下滑块就要卡 1 秒多（实测 6.4M 个 UTF-16 码元约 1.3s）。
    func applyChapterRule(_ rule: ChapterRule) {
        guard chapterRule != rule else { return }
        chapterRule = rule
    }

    var displayName: String { fileURL.deletingPathExtension().lastPathComponent }
    var totalLength: Int { units.count }
    var supportsEditing: Bool { true }

    /// 对应 Book::GetCurChapterIndex：返回最后一个 index <= offset 的章节号
    func chapterIndex(at offset: Int) -> Int {
        guard !chapters.isEmpty else { return 0 }
        var result = 0
        for (i, ch) in chapters.enumerated() {
            if ch.index <= offset { result = i } else { break }
        }
        return result
    }

    /// 章节起始偏移的集合（章前分页要按行查，用 Set 避免每次都线性扫章节表）
    private lazy var chapterStartSet: Set<Int> = Set(chapters.map { $0.index })

    /// offset 是否正好是某一章的开头（章前分页用）
    func isChapterStart(at offset: Int) -> Bool { chapterStartSet.contains(offset) }

    /// 对应 Book::IsChapter(index)：offset 是否落在某个章节标题的字符区间内。
    /// 排版时用它决定「这一行是不是标题」→ 标题不加首行缩进（Page.cpp:753 的 !is_title）。
    func isChapterTitle(at offset: Int) -> Bool {
        guard !chapters.isEmpty else { return false }
        let ch = chapters[chapterIndex(at: offset)]
        return offset >= ch.index && offset < ch.index + ch.titleLength
    }

    func chapterTitle(at offset: Int) -> String? {
        guard !chapters.isEmpty else { return nil }
        return chapters[chapterIndex(at: offset)].title
    }
}
