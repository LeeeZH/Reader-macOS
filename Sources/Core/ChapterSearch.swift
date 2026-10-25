import Foundation

/// 一条章节搜索结果（「跳转到章节…」列表里的一行）。
struct ChapterSearchHit: Equatable {
    /// `chapters` 数组下标（0-based），跳转时直接用它。
    let chapterIndex: Int
    /// 章节序号（1-based，恒等于 `chapterIndex + 1`）。
    /// 它表示「书里的第几条」；标题里写的数字可能缺章/重号，两者不一定相等。
    let chapterNumber: Int
    /// 标题原文（不折叠大小写、不做全半角归一），列表里直接显示。
    let title: String
    /// 排序权重，越大越靠前。只有相对大小有意义，具体数值不是对外契约。
    let score: Int
}

/// 章节搜索内核（「跳转到章节…」搜索框用）。
///
/// 单独抽成纯函数而不是塞进界面层：搜索框每敲一个键都要对全表重算一次，
/// 逻辑在这里才能用单测把「输入章节号必须排到标题里恰好含这个数字的
/// 章节前面」这类容易回归的行为钉死，不用起窗口。
enum ChapterSearch {

    /// 评分档位。
    ///
    /// 分档而不是把所有加分混在一个池子里，是为了保证硬优先级：
    /// 章节号命中永远压过标题文本命中 —— 用户输入章节号想要的是那一章，
    /// 而不是标题里恰好含这个数字的另一章。文本匹配再像（最多一万多分）
    /// 也翻不过章节号那一档。
    private enum Tier {
        /// 查询里的数字 == 标题自带的章节号（最贴近用户看到的章节标题）
        static let numberInTitle = 1_000_000
        /// 查询里的数字 == 1-based 章节序号（标题里没写数字时靠它兜底）
        static let chapterNumber = 500_000
        /// 标题里连续出现查询（子串命中）
        static let substring = 10_000
        /// 标题里按顺序跳字出现查询（字符顺序对即可，中间可以缺字）
        static let subsequence = 1_000
    }

    /// 搜索章节。
    ///
    /// - 空查询（含全空白）：按章节顺序返回全部章节，score 均为 0；
    /// - 非空查询：score 降序，同分按章节号（1-based）升序。
    static func search(_ query: String, in chapters: [Chapter]) -> [ChapterSearchHit] {
        let q = fold(query)
        guard !q.isEmpty else {
            // 空查询等价于「列出目录」：顺序和章节表完全一致。
            return chapters.enumerated().map { i, chapter in
                ChapterSearchHit(chapterIndex: i, chapterNumber: i + 1,
                                 title: chapter.title, score: 0)
            }
        }

        let queryNumber = parseChapterNumber(q)
        var hits: [ChapterSearchHit] = []
        hits.reserveCapacity(chapters.count)
        // 折叠后的标题只在这一轮里用来比较，不需要保留；复用同一块缓冲区，
        // 避免每次按键给 3000 个标题各分配一个数组（那是这里最贵的一步）。
        var title: [UInt32] = []
        title.reserveCapacity(64)

        for (i, chapter) in chapters.enumerated() {
            // 标题也要折叠后才能和查询用同一套标量比较：全半角、大小写
            // 在这一层抹平，后面的匹配就只剩整数相等，3000 章也是微秒级。
            fold(chapter.title, into: &title)
            var score = 0
            if let n = queryNumber {
                if parseChapterNumber(title) == n {
                    score = Tier.numberInTitle
                } else if i + 1 == n {
                    score = Tier.chapterNumber
                }
            }
            if score == 0 {
                score = textScore(q, in: title)
                guard score > 0 else { continue }
            }
            hits.append(ChapterSearchHit(chapterIndex: i, chapterNumber: i + 1,
                                         title: chapter.title, score: score))
        }

        // 同分按章节号升序：读者更可能想找靠前的那个；也让文本搜索里同分
        // 章节的先后稳定下来，边输入边刷新时列表不会乱跳。
        hits.sort { a, b in
            a.score != b.score ? a.score > b.score : a.chapterNumber < b.chapterNumber
        }
        return hits
    }

    // MARK: - 文本匹配

    /// 标题匹配得分；0 表示不匹配。
    ///
    /// 先试连续子串（分数档明显高于跳字），不行再退化为「按顺序跳字」。
    /// 位置越靠前、查询占标题比例越大，得分越高。
    private static func textScore(_ query: [UInt32], in title: [UInt32]) -> Int {
        guard !query.isEmpty, query.count <= title.count else { return 0 }

        if let position = firstSubstringPosition(query, in: title) {
            var score = Tier.substring
            if query.count == title.count { score += 2_000 }        // 整个标题就是查询
            if position == 0 { score += 1_000 }                     // 前缀命中
            score += max(0, 500 - position * 10)                    // 越靠前越好
            score += 1_000 * query.count / title.count              // 覆盖度
            return score
        }

        var qi = 0
        var first = -1
        var last = -1
        for (ti, scalar) in title.enumerated() where qi < query.count {
            if scalar == query[qi] {
                if first < 0 { first = ti }
                last = ti
                qi += 1
            }
        }
        guard qi == query.count else { return 0 }

        let span = last - first + 1
        let gaps = span - query.count
        var score = Tier.subsequence
        score += max(0, 800 - gaps * 40)                            // 跳字越少越好
        score += max(0, 300 - first * 5)                            // 起始越靠前越好
        score += 500 * query.count / title.count                    // 覆盖度
        return score
    }

    /// 连续子串第一次出现的位置（字符/标量下标）。
    /// 查询很短、标题也短（章节标题最多 255 字），朴素扫描比建索引更划算。
    private static func firstSubstringPosition(_ query: [UInt32], in title: [UInt32]) -> Int? {
        guard !query.isEmpty, query.count <= title.count else { return nil }
        let firstScalar = query[0]
        var i = 0
        let lastStart = title.count - query.count
        while i <= lastStart {
            if title[i] == firstScalar {
                var j = 1
                while j < query.count, title[i + j] == query[j] { j += 1 }
                if j == query.count { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - 折叠（全半角 / 大小写 / 首尾空白）

    /// 把字符串折叠成可以直接整数比较的 Unicode 标量数组：
    ///   · 全角 ASCII（含全角数字、全角字母）→ 半角；
    ///   · ASCII 大写 → 小写（英文标题大小写不敏感）；
    ///   · 全角空格 / 不换行空格 → 普通空格，并去掉首尾空白。
    ///
    /// 不用 `String.folding(options:)`：那个要整串走 ICU，在「1200～3000 章
    /// 每敲一键重算一次」的场景里，手写一遍标量遍历便宜一个数量级。
    private static func fold(_ s: String) -> [UInt32] {
        var out: [UInt32] = []
        fold(s, into: &out)
        return out
    }

    /// `fold` 的复用缓冲区版本：`out` 会被清空重填，避免逐章分配。
    private static func fold(_ s: String, into out: inout [UInt32]) {
        out.removeAll(keepingCapacity: true)
        let scalarCount = s.unicodeScalars.count
        if out.capacity < scalarCount { out.reserveCapacity(scalarCount) }

        for scalar in s.unicodeScalars {
            var v = scalar.value
            if v >= 0xFF01 && v <= 0xFF5E {
                v -= 0xFEE0                                  // 全角 ASCII 区（！～）→ 半角
            } else if v == 0x3000 || v == 0x00A0 || v == 0x200B || v == 0xFEFF {
                v = 0x20                                     // 全角/不换行/零宽空格都当普通空格
            }
            if v >= 0x41 && v <= 0x5A { v += 0x20 }          // A-Z → a-z
            out.append(v)
        }

        var lo = 0
        var hi = out.count
        while lo < hi, isBlank(out[lo]) { lo += 1 }
        while hi > lo, isBlank(out[hi - 1]) { hi -= 1 }
        if lo > 0 || hi < out.count {
            out.removeSubrange(hi..<out.count)
            out.removeFirst(lo)
        }
    }

    private static func isBlank(_ v: UInt32) -> Bool {
        v == 0x20
            || (v >= 0x09 && v <= 0x0D)
            || v == 0x2028 || v == 0x2029
            || (v >= 0x2000 && v <= 0x200A)
            || v == 0x205F
    }

    // MARK: - 章节号解析

    /// 从（已折叠的）查询或标题开头解析章节号。
    ///
    /// 只认开头：真正想搜标题正文的人输入带数字的标题时，不该被当成章节号。
    /// 解析失败返回 nil，调用方退回纯文本匹配。
    private static func parseChapterNumber(_ s: [UInt32]) -> Int? {
        guard !s.isEmpty else { return nil }

        var i = (s[0] == 0x7B2C) ? 1 : 0        // 跳过「第」
        let begin = i
        while i < s.count,
              isASCIIDigit(s[i]) || chineseDigitValues[s[i]] != nil || chineseUnitValues[s[i]] != nil {
            i += 1
        }
        guard i > begin else { return nil }
        let body = s[begin..<i]

        // 数字后面必须是章节单位（如「第…章」）、空白/标点，或者直接结束。
        // 「数字 + 英文」这种标题里的数字不当章节号，避免误跳。
        if i < s.count {
            let next = s[i]
            guard chapterUnitValues.contains(next) || isBlank(next) || isPunctuation(next) else {
                return nil
            }
        }

        // 纯阿拉伯数字
        if body.allSatisfy(isASCIIDigit) {
            guard body.count <= 9 else { return nil }         // 防溢出；章节号不会有 10 位
            var n = 0
            for v in body { n = n * 10 + Int(v - 0x30) }
            return n > 0 ? n : nil
        }

        // 中英混写（如「1百2」）不支持，退回文本匹配
        guard body.allSatisfy({ chineseDigitValues[$0] != nil || chineseUnitValues[$0] != nil }) else {
            return nil
        }
        return parseChineseNumber(body)
    }

    /// 解析中文数字串（已确认只含中文数字/单位，含繁体大写）。
    ///
    ///   · 十/百/千 是段内单位，同一段里必须从大到小出现（「百十」判非法）；
    ///   · 万/亿 先把前面一段结算掉再进位，所以「一万二千」= 12000；
    ///   · 单独一个「十」按「一十」算，所以「十二」= 12；
    ///   · 末尾的个位（含「零一」里的 1）最后补上，「一千零一」= 1001。
    private static func parseChineseNumber(_ chars: ArraySlice<UInt32>) -> Int? {
        var result = 0              // 已结算的万/亿以上部分
        var section = 0             // 当前这一段千以内的小计
        var digit = 0               // 还没乘单位的个位
        var lastSmallUnit = Int.max // 段内单位递减检查
        var sawNumeral = false

        for v in chars {
            if let d = chineseDigitValues[v] {
                digit = d
                sawNumeral = true
                continue
            }
            guard let unit = chineseUnitValues[v] else { return nil }
            sawNumeral = true

            if unit >= 10_000 {
                section += digit
                digit = 0
                guard section > 0 else { return nil }           // 「万」「亿」前面不能没数字
                if unit == 10_000 {
                    result += section * 10_000
                } else {
                    guard result + section <= 999_999_999 / unit else { return nil }
                    result = (result + section) * unit
                }
                guard result <= 999_999_999 else { return nil } // 章节号不会这么大，顺手防溢出
                section = 0
                lastSmallUnit = Int.max
            } else {
                if digit == 0 {
                    guard unit == 10 else { return nil }         // 「百」「千」前面不能为空
                    digit = 1                                    // 「十二」= 一十二
                }
                guard unit < lastSmallUnit else { return nil }   // 段内单位必须递减
                section += digit * unit
                digit = 0
                lastSmallUnit = unit
            }
        }

        guard sawNumeral else { return nil }
        section += digit
        let value = result + section
        return (value > 0 && value <= 999_999_999) ? value : nil
    }

    private static func isASCIIDigit(_ v: UInt32) -> Bool { v >= 0x30 && v <= 0x39 }

    private static func isPunctuation(_ v: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(v) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }

    /// 中文数字（含大写/繁体）：零〇一二两三四五六七八九…
    private static let chineseDigitValues: [UInt32: Int] = {
        var map = [UInt32: Int]()
        func put(_ chars: String, _ value: Int) {
            for scalar in chars.unicodeScalars { map[scalar.value] = value }
        }
        put("零〇", 0)
        put("一壹", 1)
        put("二两贰", 2)
        put("三叁", 3)
        put("四肆", 4)
        put("五伍", 5)
        put("六陆", 6)
        put("七柒", 7)
        put("八捌", 8)
        put("九玖", 9)
        return map
    }()

    /// 中文数量单位（含大写/繁体）
    private static let chineseUnitValues: [UInt32: Int] = {
        var map = [UInt32: Int]()
        func put(_ chars: String, _ value: Int) {
            for scalar in chars.unicodeScalars { map[scalar.value] = value }
        }
        put("十拾", 10)
        put("百佰", 100)
        put("千仟", 1_000)
        put("万萬", 10_000)
        put("亿億", 100_000_000)
        return map
    }()

    /// 章节单位：数字后面跟这些字才认为「这是个章节号」。
    /// 注意没有「回」之外的章节量词扩展，够覆盖中文小说常见写法即可。
    private static let chapterUnitValues: Set<UInt32> = {
        var set = Set<UInt32>()
        for scalar in "章节節回卷部集篇话話幕".unicodeScalars { set.insert(scalar.value) }
        return set
    }()
}
