import Foundation

/// TXT 书籍。对应原版 TextBook + Book 基类的可移植部分。
final class TextBook {
    let fileURL: URL
    let encodingName: String
    let rawText: String
    /// 规范化后的 UTF-16 码元数组。
    /// ★ 所有「字符偏移」（进度 / 书签 / 章节锚点）都以这个数组的下标为准，
    ///   与 Windows 版的 wchar_t 下标语义一致。
    let units: [UInt16]
    private(set) var chapters: [Chapter]

    var chapterRule = ChapterRule() {
        didSet { chapters = ChapterParser.parse(units, rule: chapterRule) }
    }

    init(fileURL: URL, rawText: String, encodingName: String) {
        self.fileURL = fileURL
        self.rawText = rawText
        self.encodingName = encodingName
        // 对应 Book::DecodeText 末尾必定调用的 FormatText
        self.units = TextNormalizer.format(Array(rawText.utf16))
        self.chapters = ChapterParser.parse(self.units, rule: ChapterRule())
    }

    var displayName: String { fileURL.deletingPathExtension().lastPathComponent }
    var totalLength: Int { units.count }

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
