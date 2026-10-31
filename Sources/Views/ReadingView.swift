import AppKit
import CoreText

/// 核心阅读视图：自绘 + 自研分页。
///
/// 为什么不用 NSTextView / CTFramesetter：
///   它们把「整篇文本 → 布局」交给系统，只暴露可见范围查询。
///   而阅读进度、书签、章节锚点全部是字符偏移，必须由我们自己保证
///   「翻到第 N 页时页首的字符偏移」是确定且可复现的。
/// 所以：CoreText 只提供「一个字符有多宽」和「怎么画」，断行与分页由本文件负责。
final class ReadingView: NSView {

    /// 显示设置。改动会重建字体度量并整页重排。
    var settings = ReaderSettings() {
        didSet {
            metrics = TextMetrics(name: settings.renderFontName, size: settings.fontPointSize)
            relayout()
        }
    }

    var book: TextBook? {
        didSet {
            pageStart = 0
            // 换书后旧的搜索高亮（按上一本书的偏移算的）必须立刻丢掉，
            // 否则新书同一个偏移处会被莫名其妙地涂一块黄。
            searchHitRanges = []
            currentSearchRange = nil
            visibleSearchRanges = []
            relayout()
        }
    }

    var onStatusChange: ((String) -> Void)?
    /// 触控栏用的紧凑状态（触控栏横向空间有限，放不下完整状态栏文字）
    var onTouchBarStatus: ((String) -> Void)?
    /// 页首字符偏移发生变化时回调（用于持久化阅读进度）
    var onProgressChange: ((Int) -> Void)?

    private var metrics = TextMetrics()
    private(set) var page: PageBox = .empty
    private(set) var pageStart: Int = 0
    private var lastReportedOffset = -1

    // MARK: 全文搜索高亮状态

    /// 全书命中的字符区间（绝对偏移，按起点升序）—— 由「查找」面板交过来。
    private var searchHitRanges: [Range<Int>] = []
    /// 当前选中的那一处（画得比其它命中更醒目）
    private var currentSearchRange: Range<Int>?
    /// 已经按「当前页 + 下一页」过滤好的可见段，绘制时直接用
    private var visibleSearchRanges: [(range: Range<Int>, isCurrent: Bool)] = []

    // MARK: 平滑滚动状态
    /// 当前页在竖直方向上被顶上去的像素数。0 = 页首对齐顶部。
    private(set) var scrollOffset: CGFloat = 0
    /// 紧接着当前页的下一页 —— 平滑滚动时接在下方连续绘制，把屏幕填满。
    private var nextPage: PageBox = .empty
    /// 动画还没走完的滚动量（正数 = 继续向下滚）
    private var pendingScroll: CGFloat = 0
    private var scrollTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    /// 拖文件到窗口时回调（AppDelegate 接住后打开）
    var onOpenFile: ((URL) -> Void)?

    /// 允许把 txt 拖进来打开（对应原版支持的「文件拖拽」）
    func enableFileDrop() {
        registerForDraggedTypes([.fileURL])
    }

    private func droppedFileURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first else { return nil }
        // 只接受文本类文件，避免把图片/压缩包拖进来
        let ok = ["txt", "text", "md", "log"].contains(url.pathExtension.lowercased())
        return ok ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURL(sender) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedFileURL(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedFileURL(sender) else { return false }
        onOpenFile?(url)
        return true
    }

    /// 当前是否处于深色外观（跟随系统时用它选配色）
    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 系统在浅色/深色之间切换时会被调用
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - 分页

    /// 从 `start` 开始贪心排版，排满一页高度为止。
    /// 对应原版 Page::CalcPageDown 的前向布局部分。
    private func layout(from start: Int) -> PageBox {
        guard let book = book, !book.units.isEmpty else { return .empty }
        let units = book.units

        let width = bounds.width - CGFloat(settings.insetLeft) - CGFloat(settings.insetRight)
        let height = bounds.height - CGFloat(settings.insetTop) - CGFloat(settings.insetBottom)
        guard width > 20, height > 20 else { return PageBox(start: start, length: 0, lines: []) }

        let lineHeight = metrics.lineHeight
        let indentWidth = metrics.advance(0x3000) * 2      // 首行缩进 = 两个全角空格宽
        let charGap = CGFloat(settings.charGap)
        let lineGap = CGFloat(settings.lineGap)
        let paragraphGap = CGFloat(settings.paragraphGap)

        var lines = [LineBox]()
        var y: CGFloat = 0
        var i = max(0, min(start, units.count))
        var pageEnd = i

        while i < units.count {
            // 段落首行 → 首行缩进（对应 Page.cpp:753）
            let isParagraphStart = (i == 0) || (units[i - 1] == 0x0A)
            let isTitle = isParagraphStart && book.isChapterTitle(at: i)
            let logicalStart = i
            var indent: CGFloat = 0
            // 对应 Page.cpp:753：首行缩进仅用于正文段落，章节标题不加缩进
            if settings.lineIndent, isParagraphStart, !isTitle { indent = indentWidth }
            if indent > width / 2 { indent = 0 }            // 缩进放不下则丢弃（Page.cpp:771-774）

            // 剥离段落自带的前导空白，由缩进接管（对应 Page.cpp:861-873）。
            // 不这样做会出现「原文字面缩进 + 首行缩进」的双重缩进。
            var contentStart = i
            if isParagraphStart, !isTitle {
                while contentStart < units.count,
                      units[contentStart] != 0x0A,
                      TextNormalizer.isBlank(units[contentStart]) {
                    contentStart += 1
                }
            }

            // ── 1) 贪心：先找出这一行最多能排到哪（断行判据 Page.cpp:786）──
            var fitEnd = contentStart
            var x = indent
            while fitEnd < units.count {
                let u = units[fitEnd]
                if u == 0x0A { break }
                let (adv, cluster) = metrics.measure(units, at: fitEnd)
                if fitEnd > contentStart, x + adv > width { break }
                x += adv + charGap                              // 行末也计一次 gap（Page.cpp:885）
                fitEnd += cluster
            }

            // ── 2) word wrap：断在单词中间时回退到最近的词边界 ──
            // 对应 Page.cpp:786-844 的三个分支。可断点 = is_blank ∪ is_hyphen（Page.cpp:876-880）。
            var lineEnd = fitEnd
            if settings.wordWrap, fitEnd > contentStart, fitEnd < units.count, units[fitEnd] != 0x0A {
                var boundary = -1
                var k = contentStart
                while k < fitEnd {
                    let u = units[k]
                    if TextNormalizer.isBlank(u) || u == 0x2D { boundary = k + 1 }  // '-' 也可断
                    k += 1
                }
                // boundary <= contentStart 说明整行就是一个超长单词 → 保持硬断
                if boundary > contentStart { lineEnd = boundary }
            }

            // ── 3) 按最终断点生成要绘制的字符 ──
            var chars = [CharBox]()
            var j = contentStart
            while j < lineEnd {
                let (adv, cluster) = metrics.measure(units, at: j)
                chars.append(CharBox(index: j, advance: adv, cluster: cluster))
                j += cluster
            }

            var consumed = lineEnd
            if consumed == logicalStart, contentStart > logicalStart { consumed = contentStart }
            var gap = lineGap
            if lineEnd < units.count, units[lineEnd] == 0x0A {
                consumed = lineEnd + 1
                // 压缩空行时空行不占高度；段末行的 gap 由 LINE_GAP 换成 PART_GAP
                if chars.isEmpty {
                    gap = settings.compressBlankLines ? 0 : lineHeight
                } else {
                    gap = paragraphGap
                }
            }

            // 死循环保护：单字宽于整行时强制前进（对应 Page.cpp:776-779）
            if chars.isEmpty, consumed == logicalStart {
                let (_, cluster) = metrics.measure(units, at: logicalStart)
                chars.append(CharBox(index: logicalStart, advance: 0, cluster: cluster))
                consumed = logicalStart + cluster
                gap = lineGap
            }

            // 放不下就结束本页（对应 y + max(h, sz.cy) > height 的 break）
            if y + lineHeight + gap > height, !lines.isEmpty { break }

            lines.append(LineBox(start: logicalStart, length: consumed - logicalStart, chars: chars,
                                 indent: indent, height: lineHeight, gap: gap))
            y += lineHeight + gap
            pageEnd = consumed
            i = consumed

            // 章前分页（对应原版 CHAPTER_PAGE）：一行都排不下新章内容时，
            // 让新章从下一页的顶部开始
            if settings.chapterPage, consumed < units.count, book.isChapterStart(at: consumed) {
                break
            }
        }

        return PageBox(start: start, length: pageEnd - start, lines: lines)
    }

    /// 只重算分页，**不动滚动偏移**。
    /// 平滑滚动换页时用这个 —— 那时偏移要跨页接续，不能被清零。
    private func rebuildPages() {
        page = layout(from: pageStart)
        if settings.smoothScroll, page.end < (book?.units.count ?? 0) {
            nextPage = layout(from: page.end)
        } else {
            nextPage = .empty
        }
        refreshVisibleSearchHighlights()
        notifyStatus()
        needsDisplay = true
        if pageStart != lastReportedOffset {
            lastReportedOffset = pageStart
            onProgressChange?(pageStart)
        }
    }

    /// 整页重排并回到页首（跳转 / 翻页 / 改设置都走这里）
    private func relayout() {
        scrollOffset = 0
        pendingScroll = 0
        scrollTimer?.invalidate()
        scrollTimer = nil
        rebuildPages()
    }

    // MARK: - 翻页

    func goNextPage() {
        guard page.length > 0 else { return }
        // 翻页保留重叠行数（原版 left_line_count）：保留末尾 N 行，衔接更连贯
        let keep = min(settings.leftLineCount, max(0, page.lines.count - 1))
        if keep > 0 {
            pageStart = page.lines[page.lines.count - keep].start
            relayout()
            return
        }
        let next = page.end
        guard next < (book?.units.count ?? 0) else { return }
        pageStart = next
        relayout()
    }

    /// 逐行滚动一次跨几行（原版 wheel_speed：单行/两行/三行/整页）
    private var linesPerScroll: Int { settings.wheelSpeed >= 3 ? 0 : settings.wheelSpeed + 1 }

    /// 向下滚 N 行（对应原版 Page::LineDown）
    func goNextLines(_ n: Int) {
        guard let book = book, !book.units.isEmpty, n > 0 else { return }
        var remaining = n
        var cursor = pageStart
        var guardCount = 0
        while remaining > 0, guardCount < 64 {
            let p = layout(from: cursor)
            if p.lines.isEmpty { return }
            if p.lines.count > remaining {
                cursor = p.lines[remaining].start
                remaining = 0
            } else {
                remaining -= p.lines.count
                guard p.end < book.units.count, p.end > cursor else { return }   // 到底了
                cursor = p.end
            }
            guardCount += 1
        }
        pageStart = cursor
        relayout()
    }

    /// 向上滚 N 行（对应原版 Page::LineUp）
    ///
    /// ⚠️ 不能直接拿 `previousPageStart` 再取「倒数第 N 行」：
    /// 那个函数给的是**页链**（一页页往回排），而逐行滚动要的是**行链**。
    /// 两条链不是一回事 —— 从别处排出来的一页，未必把当前页首当作行起点，
    /// 硬取「倒数第 N 行」会算出比当前位置还靠后的点，表现就是「上滚没反应」。
    ///
    /// 这里改成：逐页往回退，把每页里位于当前位置之前的行起点收起来，
    /// 得到一条单调递减的行链，再取第 N 个。这样保证一定往前走、不会卡住。
    func goPrevLines(_ n: Int) {
        guard let book = book, !book.units.isEmpty, n > 0, pageStart > 0 else { return }
        var collected: [Int] = []          // 越靠前越接近 pageStart
        var cursor = pageStart
        var guardCount = 0
        while collected.count < n, guardCount < 64 {
            guard let prevStart = previousPageStart(from: cursor), prevStart < cursor else { break }
            let p = layout(from: prevStart)
            var got: [Int] = []
            for line in p.lines where line.start < cursor { got.append(line.start) }
            collected = got.reversed() + collected     // got 是从小到大，反转后「近的在前」
            cursor = prevStart
            guardCount += 1
        }
        guard !collected.isEmpty else { return }
        // `collected` 是从近到远排的：collected[0] 是紧挨当前位置的上一行，
        // collected[n-1] 才是「往回 n 行」。
        //
        // ⚠️ 这里原来写成 collected[count - n]，取到的是这一页里几乎最远的那行。
        // 结果：下滚 1 行 = 1 行，上滚 1 行 = 退回一整页（约 23 行），
        // 表现就是「往下滚正常、往上滚飞快，一下就回到开头」。
        // 当初的测试没抓到，是因为测试数据里 collected 只有 3 个元素、n=2，
        // count-n 恰好等于 n-1 —— 碰巧对了。
        let idx = min(n, collected.count) - 1
        let target = collected[idx]
        guard target < pageStart else { return }
        pageStart = target
        relayout()
    }

    /// 算出「上一页」应该从哪个字符开始。
    ///
    /// 原版用的是真正的反向布局（`Page::CalcPageUp`，Page.cpp:1205-1431）：
    /// 从当前位置往回排一页，再做一次正向重排收敛。
    ///
    /// 这里用等价的二分实现。关键性质：**`pageEnd(s)`（从 s 排一页的结束位置）
    /// 关于 s 单调不减**，所以可以二分。
    ///
    /// ⚠️ 二分的方向很容易搞反，两种写法差别很大：
    ///   - 取**最大**的 s 使 `pageEnd(s) <= start`  ❌
    ///     页面的断开点落在**行**边界上，所以 `pageEnd` 在一行的宽度内是平坦的。
    ///     取最大值会挑到这段平坦区间的末尾 —— 那一页虽然也结束在 start，
    ///     但它从更靠后的位置开始，`[前一页末尾, 它)` 这段内容就被**跳过**了，
    ///     而且一直往前翻会提前卡死、回不到书首。
    ///   - 取**最小**的 s 使 `pageEnd(s) >= start`  ✅（本实现）
    ///     这是从当前位置能一页覆盖到 start 的**最早**起点，保证不漏内容。
    ///
    /// 另一处教训：早先版本用的是「翻页历史栈」，看似更简单，但任何 `jump()`
    /// （目录跳章节、恢复阅读进度）都会把栈清空，导致跳转之后再也翻不回去。
    /// 方向性算法没有这个状态依赖，跳到哪里都能往回翻。
    func previousPageStart(from start: Int) -> Int? {
        guard let book = book, start > 0, !book.units.isEmpty else { return nil }
        var lo = 0
        var hi = start
        var best: Int? = nil
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            let end = layout(from: mid).end
            if end >= start {
                best = mid          // 记下来，继续往更早的方向找
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        // best == start 说明排不出更早的一页（例如窗口太小排不出任何内容）
        guard let b = best, b < start else { return nil }
        return b
    }

    func goPrevPage() {
        guard let prev = previousPageStart(from: pageStart) else { return }
        pageStart = prev
        relayout()
    }

    func jump(to offset: Int) {
        guard let book = book else { return }
        pageStart = max(0, min(offset, max(0, book.units.count - 1)))
        relayout()
    }

    // MARK: - 全文搜索高亮

    /// 交给阅读视图一批命中区间（全书绝对偏移）以及当前选中的那一处。
    ///
    /// 视图不关心它们从哪来、也不做任何「页码 ↔ 偏移」换算：
    /// 命中本身就是偏移，翻页/换字号后按当前页重新过滤即可。
    func setSearchHighlights(_ ranges: [Range<Int>], current: Range<Int>?) {
        searchHitRanges = ranges
        currentSearchRange = current
        refreshVisibleSearchHighlights()
        needsDisplay = true
    }

    func clearSearchHighlights() {
        guard !searchHitRanges.isEmpty || currentSearchRange != nil else { return }
        searchHitRanges = []
        currentSearchRange = nil
        visibleSearchRanges = []
        needsDisplay = true
    }

    /// 按「当前页 + 下一页」裁剪命中段。
    ///
    /// 为什么要带上下一页：平滑滚动时下一页是接在当前页下面一起画的，
    /// 只裁当前页会让滚到一半的命中突然消失、滚过去又出现。
    private func refreshVisibleSearchHighlights() {
        guard !searchHitRanges.isEmpty else {
            visibleSearchRanges = []
            return
        }
        var visible: [Range<Int>] = []
        visible.reserveCapacity(32)
        func collect(_ box: PageBox) {
            guard box.length > 0 else { return }
            for r in searchHitRanges where r.lowerBound < box.end && r.upperBound > box.start {
                visible.append(r)
            }
        }
        collect(page)
        if scrollOffset > 0 { collect(nextPage) }
        visibleSearchRanges = visible.map { ($0, $0 == currentSearchRange) }
    }

    /// 某个字符偏移落在哪一类高亮里：0 = 无，1 = 普通命中，2 = 当前命中。
    private func highlightKind(at index: Int) -> Int {
        var kind = 0
        for entry in visibleSearchRanges {
            if index >= entry.range.lowerBound && index < entry.range.upperBound {
                if entry.isCurrent { return 2 }
                kind = 1
            }
        }
        return kind
    }

    /// 在文字下面铺一层高亮。
    ///
    /// 颜色要分深浅两套：深色模式正文是浅色字，亮黄底 + 浅色字会看不清，
    /// 所以深色模式改用低亮度的琥珀色。两种模式都只填背景，**文字保持不透明** ——
    /// 这是整个界面的一贯原则（窗口半透明时也不让字跟着淡）。
    private func drawSearchHighlights(in line: LineBox, top: CGFloat, ctx: CGContext) {
        guard !visibleSearchRanges.isEmpty, !line.chars.isEmpty else { return }
        let dark = isDarkAppearance
        let normal = (dark ? NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.06, alpha: 0.75)
                           : NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.45, alpha: 0.70)).cgColor
        let current = (dark ? NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.06, alpha: 0.90)
                            : NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.18, alpha: 0.85)).cgColor

        // ⚠️ 必须 save/restore：这里会把 fillColor 改成高亮色，
        //    不还原的话接下来那一行的**文字**会用高亮色画出来（正文变成一片浅黄）。
        ctx.saveGState()
        defer { ctx.restoreGState() }

        var x = CGFloat(settings.insetLeft) + line.indent
        var runStartX: CGFloat?
        var runIsCurrent = false

        func flush(_ endX: CGFloat) {
            guard let startX = runStartX else { return }
            ctx.setFillColor(runIsCurrent ? current : normal)
            // 宽度至少 1pt：空字符（窄空格等）也要能看出「这里命中了」
            ctx.fill(CGRect(x: startX, y: top - line.height,
                            width: max(1, endX - startX), height: line.height))
            runStartX = nil
        }

        for cb in line.chars {
            let kind = highlightKind(at: cb.index)
            if kind == 0 {
                flush(x)
            } else {
                let isCurrent = kind == 2
                if runStartX == nil {
                    runStartX = x
                    runIsCurrent = isCurrent
                } else if isCurrent != runIsCurrent {
                    // 普通命中与当前命中相邻时分成两块画，颜色才分得开
                    flush(x)
                    runStartX = x
                    runIsCurrent = isCurrent
                }
            }
            x += cb.advance + CGFloat(settings.charGap)
        }
        flush(x)
    }

    // MARK: - 自检探针（全文搜索）

    /// 自检用：当前页（含平滑滚动的下一页）上可见的命中段数量
    var debugVisibleSearchHitCount: Int { visibleSearchRanges.count }
    /// 自检用：可见范围里是否有「当前命中」（要画出更醒目的那一处）
    var debugHasCurrentSearchHighlight: Bool { visibleSearchRanges.contains { $0.isCurrent } }
    /// 自检用：可供外部核对的可见命中区间
    var debugVisibleSearchRanges: [Range<Int>] { visibleSearchRanges.map(\.range) }

    /// 跳到下一个章节
    func goNextChapter() {
        guard let book = book, !book.chapters.isEmpty else { return }
        let cur = book.chapterIndex(at: pageStart)
        guard cur + 1 < book.chapters.count else { return }
        jump(to: book.chapters[cur + 1].index)
    }

    /// 跳到上一个章节
    func goPrevChapter() {
        guard let book = book, !book.chapters.isEmpty else { return }
        let cur = book.chapterIndex(at: pageStart)
        if pageStart > book.chapters[cur].index { jump(to: book.chapters[cur].index); return }
        guard cur > 0 else { return }
        jump(to: book.chapters[cur - 1].index)
    }

    // MARK: - 绘制

    /// 正文可绘制区域（挖掉四周的边框距）
    private var contentRect: CGRect {
        CGRect(x: 0,
               y: CGFloat(settings.insetBottom),
               width: bounds.width,
               height: bounds.height - CGFloat(settings.insetTop) - CGFloat(settings.insetBottom))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDarkAppearance
        // 窗口透明度（对应原版 header.alpha）：只让**背景**透明，文字始终不透明。
        // 原版用 UpdateLayeredWindow 是把整个窗口连字一起调透明，字会发虚；
        // 这里只降背景，可读性好得多。
        let bgAlpha = CGFloat(min(255, max(0, settings.alpha))) / 255.0
        if bgAlpha < 1.0 {
            ctx.clear(bounds)
            ctx.saveGState()
            ctx.setAlpha(bgAlpha)
            ctx.setFillColor(settings.renderBackgroundColor(dark: dark))
            ctx.fill(bounds)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(settings.renderBackgroundColor(dark: dark))
            ctx.fill(bounds)
        }
        guard let book = book else { return }
        ctx.setAlpha(1.0)      // 文字永远按不透明画

        // 平滑滚动时内容会上下越出内容区，必须裁剪，
        // 否则文字会画到边框距里、甚至盖住状态栏。
        ctx.saveGState()
        ctx.clip(to: contentRect)

        let units = book.units
        ctx.setFillColor(settings.renderTextColor(dark: dark))
        ctx.textMatrix = .identity

        // AppKit 的 y 轴向上：内容要「往上滚出屏幕」就得让 y 变大，所以这里是 **加**。
        // 写成减号的话会把正文往下推、顶部留白，方向正好相反。
        var top = bounds.height - CGFloat(settings.insetTop) + scrollOffset
        drawLines(page.lines, units: units, top: &top, ctx: ctx)
        // 下一页接在下面继续画，把滚出来的空白填满。
        // 两页在文本上首尾相接，所以堆起来是连续的。
        if scrollOffset > 0, !nextPage.lines.isEmpty {
            drawLines(nextPage.lines, units: units, top: &top, ctx: ctx)
        }

        ctx.restoreGState()
    }

    private func drawLines(_ lines: [LineBox], units: [UInt16], top: inout CGFloat, ctx: CGContext) {
        for line in lines {
            let baseline = top - metrics.ascent
            // 高亮必须在文字之前画（填在字下面），否则会盖住字形
            drawSearchHighlights(in: line, top: top, ctx: ctx)
            var x = CGFloat(settings.insetLeft) + line.indent
            for cb in line.chars {
                drawChar(units, cb.index, at: CGPoint(x: x, y: baseline), ctx: ctx)
                x += cb.advance + CGFloat(settings.charGap)
            }
            top -= (line.height + line.gap)
        }
    }

    private func drawChar(_ units: [UInt16], _ idx: Int, at p: CGPoint, ctx: CGContext) {
        guard idx >= 0, idx < units.count else { return }
        let c = units[idx]
        if c >= 0xD800, c <= 0xDBFF, idx + 1 < units.count,
           units[idx + 1] >= 0xDC00, units[idx + 1] <= 0xDFFF {
            var pair: [UniChar] = [c, units[idx + 1]]
            var glyphs = [CGGlyph](repeating: 0, count: 2)
            if CTFontGetGlyphsForCharacters(metrics.font, &pair, &glyphs, 2), glyphs[0] != 0 {
                var g = glyphs[0]
                var pos = p
                CTFontDrawGlyphs(metrics.font, &g, &pos, 1, ctx)
            }
            return
        }
        var ch = c
        var glyph = CGGlyph(0)
        if CTFontGetGlyphsForCharacters(metrics.font, &ch, &glyph, 1), glyph != 0 {
            var g = glyph
            var pos = p
            CTFontDrawGlyphs(metrics.font, &g, &pos, 1, ctx)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    // MARK: - 输入

    // MARK: - 平滑滚动

    /// 一行的像素高度（自动翻页「逐行」模式用）
    var oneLineHeight: CGFloat { metrics.lineHeight + CGFloat(settings.lineGap) }
    /// 一页的像素高度（自动翻页「翻页」模式用）
    var onePageHeight: CGFloat { page.flowHeight }
    /// 还能不能继续往后走（自动翻页用它判断要不要停）
    var canScrollForward: Bool {
        guard let book = book else { return false }
        return page.end < book.units.count
    }

    /// 鼠标滚轮一格对应的像素距离。
    /// 沿用 `wheelSpeed` 的语义（1/2/3 行或整页），改成平滑之后只是把
    /// 「瞬间跳这么多」变成「动画滚这么多」。
    var wheelStepPoints: CGFloat {
        let n = linesPerScroll
        if n == 0 { return max(80, bounds.height * 0.85) }
        return CGFloat(n) * (metrics.lineHeight + CGFloat(settings.lineGap))
    }

    /// 请求滚动 `delta` 像素（正数 = 向下。内容向下滚 = 看到后面的内容）。
    func smoothScroll(by delta: CGFloat) {
        guard book != nil, page.flowHeight > 0, delta != 0 else { return }
        pendingScroll += delta
        // 一次手势别累积太多，否则会「甩」出去好几页
        let cap = max(120, bounds.height)
        pendingScroll = min(cap, max(-cap, pendingScroll))
        startScrollTimer()
    }

    private func startScrollTimer() {
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepScrollAnimation()
        }
        // .common 模式：拖窗口 / 菜单打开时也要继续走，不然动画会卡住
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func stepScrollAnimation() {
        if abs(pendingScroll) < 0.6 {
            applyScroll(pendingScroll)
            pendingScroll = 0
            scrollTimer?.invalidate()
            scrollTimer = nil
            return
        }
        // 缓出：越接近目标步子越小
        let step = pendingScroll * 0.32
        pendingScroll -= step
        applyScroll(step)
    }

    /// 实际移动视口，并负责跨页。
    /// 正数 = 内容向上走（显示后面的内容）。
    func applyScroll(_ delta: CGFloat) {
        guard let book = book, !book.units.isEmpty, delta != 0, page.flowHeight > 0 else { return }
        var v = scrollOffset + delta
        var guardCount = 0

        // 往下越过页尾 → 翻到下一页，偏移量接续过去
        while v >= page.flowHeight, guardCount < 8 {
            guard page.end < book.units.count else { break }
            v -= page.flowHeight
            pageStart = page.end
            rebuildPages()
            guardCount += 1
        }
        // 往上越过页首 → 翻到上一页
        while v < 0, pageStart > 0, guardCount < 20 {
            guard let prev = previousPageStart(from: pageStart) else { break }
            pageStart = prev
            rebuildPages()
            v += page.flowHeight
            guardCount += 1
        }

        // 书首不能往上滚；末页不能再往下滚（它本身就是最后一屏内容）
        let canScrollDown = page.end < book.units.count
        let upper = canScrollDown ? page.flowHeight : 0
        scrollOffset = min(max(0, v), upper)
        // 滚动会换出/换入下一页的命中段（平滑滚动时下一页是接在下面画的）
        refreshVisibleSearchHighlights()
        needsDisplay = true
    }

    deinit {
        scrollTimer?.invalidate()
    }

    override func keyDown(with event: NSEvent) {
        // 键位对齐原版：← → 整页翻，↑ ↓ 逐行滚（滚动量由 wheel_speed 决定），
        // PageUp/PageDown/空格 整页翻。
        switch event.keyCode {
        case 123, 116:                       // ← / PageUp
            goPrevPage()
        case 124, 121, 49:                   // → / PageDown / 空格
            goNextPage()
        case 126:                            // ↑
            if settings.smoothScroll { smoothScroll(by: -wheelStepPoints) } else { scrollUp() }
        case 125:                            // ↓
            if settings.smoothScroll { smoothScroll(by: wheelStepPoints) } else { scrollDown() }
        default:
            super.keyDown(with: event)
        }
    }

    /// 按设置滚一行/两行/三行，或整页
    func scrollDown() {
        let n = linesPerScroll
        if n == 0 { goNextPage() } else { goNextLines(n) }
    }

    func scrollUp() {
        let n = linesPerScroll
        if n == 0 { goPrevPage() } else { goPrevLines(n) }
    }

    // MARK: - 鼠标按键（对应原版 page_mode / disable_lrhide）

    /// 左右键一起按时回调（AppDelegate 接到「隐藏/显示窗口」）
    var onToggleHideWindow: (() -> Void)?
    /// 「最小化窗口」动作用
    var onMinimizeWindow: (() -> Void)?
    /// 左右一起按之后，两个键松开都不应该再翻页
    private var suppressClick = false

    private func bothButtonsDown() -> Bool {
        (NSEvent.pressedMouseButtons & 0x3) == 0x3      // bit0 左键、bit1 右键
    }

    /// 左键按下时右键可能还按着，右键按下时左键也可能还按着 —— 两边都要查。
    private func checkBothButtons() {
        guard settings.mouseBothAction != .none, bothButtonsDown() else { return }
        suppressClick = true
        performMouseAction(settings.mouseBothAction)
    }

    override func mouseDown(with event: NSEvent) {
        checkBothButtons()
    }

    override func rightMouseDown(with event: NSEvent) {
        checkBothButtons()
    }

    override func mouseUp(with event: NSEvent) {
        if suppressClick {
            // 两个键都松开了才解除抑制，否则另一个键的 up 还会误触发翻页
            if NSEvent.pressedMouseButtons & 0x3 == 0 { suppressClick = false }
            return
        }
        performMouseAction(settings.mouseLeftAction)
    }

    override func rightMouseUp(with event: NSEvent) {
        if suppressClick {
            if NSEvent.pressedMouseButtons & 0x3 == 0 { suppressClick = false }
            return
        }
        performMouseAction(settings.mouseRightAction)
    }

    /// 自检/单测入口：直接驱动一次点击行为
    func performMouseActionForTest(_ action: ReaderSettings.MouseAction) {
        performMouseAction(action)
    }

    /// 执行一个鼠标动作
    private func performMouseAction(_ action: ReaderSettings.MouseAction) {
        switch action {
        case .none:       break
        case .nextPage:   goNextPage()
        case .prevPage:   goPrevPage()
        case .toggleHide: onToggleHideWindow?()
        case .minimize:   onMinimizeWindow?()
        }
    }

    private var scrollAccum: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        // 平滑模式：按像素连续滚，带缓出动画
        if settings.smoothScroll {
            let delta: CGFloat
            if event.hasPreciseScrollingDeltas {
                delta = -event.scrollingDeltaY        // 触控板本来就是像素，直接用
            } else {
                // 鼠标滚轮只有一格一格的事件，换算成固定像素距离（沿用 wheelSpeed 的设置）
                delta = event.scrollingDeltaY < 0 ? wheelStepPoints : -wheelStepPoints
            }
            if delta != 0 { smoothScroll(by: delta) }
            return
        }

        // 关闭平滑时保持原版的「一格跳 N 行」手感
        if event.hasPreciseScrollingDeltas {
            // 触控板：一次手势会发很多个小 delta（包括惯性阶段），
            // 累积到阈值才滚一次，否则会瞬间翻掉十几页。
            scrollAccum += event.scrollingDeltaY
            let threshold: CGFloat = 30
            while abs(scrollAccum) >= threshold {
                if scrollAccum < 0 { scrollDown() } else { scrollUp() }
                scrollAccum += scrollAccum < 0 ? threshold : -threshold
            }
        } else {
            // 鼠标滚轮：一个刻度一个事件
            if event.scrollingDeltaY < 0 { scrollDown() }
            else if event.scrollingDeltaY > 0 { scrollUp() }
        }
    }

    // MARK: - 状态

    private func notifyStatus() {
        guard let book = book else {
            onStatusChange?("用 ⌘O 打开一个 TXT 文件")
            return
        }
        let total = book.totalLength
        let ci = book.chapters.isEmpty ? nil : book.chapterIndex(at: pageStart)

        // ⚠️ 进度统一按**页首偏移**算，与阅读列表共用 ReadingStatus.percent()。
        // 原版用的是页末（m_Index + m_PageLength），但阅读列表拿不到页长，
        // 两边必须用同一个口径，否则会出现「阅读界面 100%、列表 99.7%」。
        onStatusChange?(ReadingStatus.full(
            bookName: book.displayName,
            encoding: book.encodingName,
            totalLength: total,
            chapterIndex: ci,
            chapterCount: book.chapters.count,
            offset: pageStart,
            isLastPage: total > 0 && page.end >= total))

        onTouchBarStatus?(ReadingStatus.compact(
            bookName: book.displayName,
            chapterTitle: ci.map { book.chapters[$0].title },
            offset: pageStart,
            totalLength: total))
    }
}
