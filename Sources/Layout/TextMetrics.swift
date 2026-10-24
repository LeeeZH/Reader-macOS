import Foundation
import CoreText

/// 字体度量 + 逐码元 advance 缓存。
///
/// 原版每字符调一次 GetTextExtentPoint32 且**无任何缓存**（Page.cpp:765），
/// 一页 500~2000 次、每次重绘全量重测。这里是相对原版最大的性能改进点。
final class TextMetrics {
    let font: CTFont
    let ascent: CGFloat
    let descent: CGFloat
    let lineHeight: CGFloat
    private var cache: [UInt16: CGFloat] = [:]

    init(name: String = ReaderDefaults.fontName, size: CGFloat = ReaderDefaults.fontSize) {
        // Windows 字体（如 Segoe UI Light）在 macOS 上不存在：
        // CTFontCreateWithName 会静默替换成别的字体，所以先用 FontResolver 显式探测再回退。
        let resolved = FontResolver.resolve(name)
        let f = CTFontCreateWithName(resolved as CFString, size, nil)
        self.font = f
        self.ascent = CTFontGetAscent(f)
        self.descent = CTFontGetDescent(f)
        let leading = CTFontGetLeading(f)
        // 原版用 GDI 的 sz.cy 作行高。这里 ascent+descent+leading 更贴近排版语义，
        // 但与 GDI 会有细微差异 → 影响每页行数。M1 阶段会用原版截图定标。
        self.lineHeight = ceil(ascent + descent + leading)
    }

    /// 取单个码元（或代理对）的 advance 与码元簇长度。
    /// 对应 GDI 的 GetTextExtentPoint32(..., 1 char, ...)：**无 kerning、无连字**。
    func measure(_ text: [UInt16], at i: Int) -> (advance: CGFloat, cluster: Int) {
        let c = text[i]
        // 代理对：合并测量，避免把 emoji / 增补平面汉字劈成两半
        if c >= 0xD800, c <= 0xDBFF, i + 1 < text.count {
            let c2 = text[i + 1]
            if c2 >= 0xDC00, c2 <= 0xDFFF {
                var pair: [UniChar] = [c, c2]
                var glyphs = [CGGlyph](repeating: 0, count: 2)
                if CTFontGetGlyphsForCharacters(font, &pair, &glyphs, 2), glyphs[0] != 0 {
                    var g = glyphs[0]
                    var adv = CGSize.zero
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
                    return (CGFloat(adv.width), 2)
                }
                return (0, 2)
            }
        }
        if let v = cache[c] { return (v, 1) }
        var ch = c
        var glyph = CGGlyph(0)
        var w: CGFloat = 0
        if CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) {
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
            w = CGFloat(adv.width)
        }
        cache[c] = w
        return (w, 1)
    }

    /// 便捷方法：单个码元宽度
    func advance(_ c: UInt16) -> CGFloat {
        if let v = cache[c] { return v }
        return measure([c], at: 0).advance
    }
}
