import Foundation
import CoreGraphics

/// 全局默认值。数值全部照搬原 Win32 版（Cache.cpp:317-392），
/// 目的是让 .cache.dat 互通时排版行为一致。
enum ReaderDefaults {
    /// 原版是 "Segoe UI Light"，macOS 上不存在 → 换苹方
    static let fontName: String = "PingFang SC"
    static let fontSize: CGFloat = 14          // 原版 PointSize = 14
    static let charGap: CGFloat = 0            // char_gap
    static let lineGap: CGFloat = 5            // line_gap
    static let paragraphGap: CGFloat = 15      // paragraph_gap
    static let insetTop: CGFloat = 12
    static let insetLeft: CGFloat = 16
    static let insetBottom: CGFloat = 12
    static let insetRight: CGFloat = 16
    static let maxBlankLine: Int = 2           // MAX_BLANK_LINE
    static let lineIndent: Bool = true          // line_indent = 1
    static let wordWrap: Bool = false           // word_wrap = 0
    static let compressBlankLines: Bool = true  // blank_lines = 1（宏名 NO_BLANS_LINE 有误导）
    static let chapterPage: Bool = false        // chapter_page = 0
    static let maxChapterLength: Int = 256     // MAX_CHAPTER_LENGTH
    static let minAlpha: CGFloat = 100.0 / 255.0   // MIN_ALPHA_VALUE = 0x64

    static let defaultTextColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let defaultBackgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // 跟随系统深色模式时用的配色（对齐 macOS 的 label / windowBackground）
    static let darkTextColor = CGColor(red: 0.902, green: 0.902, blue: 0.910, alpha: 1)   // #E6E6E8
    static let darkBackgroundColor = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) // #1C1C1E
}

/// 对应原版 type_t
enum TextEncodingKind: String {
    case unknown = "Unknown"
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16LE"
    case utf16BE = "UTF-16BE"
}
