import AppKit

// ── 开发工具一律用临时存档，绝不碰用户的真实 .cache.dat ──
// （命令行参数里出现任何 `--xxx` 工具开关时生效）
do {
    let devFlags: Set<String> = [
        "--render-page", "--render-library", "--render-settings", "--render-bookmarks",
        "--render-chapter-search", "--render-find",
        "--dump-pages", "--dump-chapters", "--library-selftest", "--dump-touchbar",
        "--close-selftest", "--quit-selftest", "--early-open-selftest",
        "--open-async-selftest", "--open-bench",
        "--toc-selftest", "--chapter-search-selftest", "--find-selftest",
        "--always-on-top-selftest",
    ]
    if CommandLine.arguments.contains(where: { devFlags.contains($0) }) {
        let dir = NSTemporaryDirectory() + "reader-devtools-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("READER_CACHE_PATH", dir + "/.cache.dat", 1)
        FileHandle.standardError.write("[开发工具] 存档重定向到 \(dir)\n".data(using: .utf8)!)
    }
}

let app = NSApplication.shared

// ── 开发者工具：把某本书的第一页离屏渲染成 PNG ──
// 用法： Reader --render-page <book.txt> <out.png> [页码]
// 不依赖窗口与屏幕截图，用于人工检查排版，后续也用于与 Windows 版做 parity 对比。
// --dark：强制以深色外观渲染，用来预览深色模式
let forceDark = CommandLine.arguments.contains("--dark")
if forceDark {
    NSApp.appearance = NSAppearance(named: .darkAqua)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-page"),
   CommandLine.arguments.count > idx + 2 {
    let src = CommandLine.arguments[idx + 1]
    let dst = CommandLine.arguments[idx + 2]
    let pages = CommandLine.arguments.count > idx + 3 ? (Int(CommandLine.arguments[idx + 3]) ?? 0) : 0
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        let decoded = try TextDecoder.decode(data)
        let book = TextBook(fileURL: URL(fileURLWithPath: src),
                            rawText: decoded.text, encodingName: decoded.encodingName)
        let view = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
        // 离屏渲染时视图不在窗口里，effectiveAppearance 取不到 app 的外观，
        // 所以预览要显式指定（真实运行时靠 effectiveAppearance 自动跟随系统）
        if forceDark {
            view.appearance = NSAppearance(named: .darkAqua)
        }
        view.book = book
        // --alpha N：预览窗口透明度（0-255）对绘制的影响
        if let ai = CommandLine.arguments.firstIndex(of: "--alpha"),
           CommandLine.arguments.count > ai + 1,
           let a = Int(CommandLine.arguments[ai + 1]) {
            view.settings.alpha = min(255, max(0, a))
        }
        // --title-font <名字> [--title-size <pt>]：预览「章节标题独立字体」的效果
        // （等价于关掉设置里的「章节标题与正文用同一字体」）。
        // 截图对比 M3 前后就靠它：不带参数 = 默认同字体，带上 = 标题换字号/字体。
        if let ti = CommandLine.arguments.firstIndex(of: "--title-font"),
           CommandLine.arguments.count > ti + 1 {
            let name = CommandLine.arguments[ti + 1]
            var size = view.settings.fontPointSize
            if let si = CommandLine.arguments.firstIndex(of: "--title-size"),
               CommandLine.arguments.count > si + 1,
               let s = Double(CommandLine.arguments[si + 1]) {
                size = CGFloat(s)
            }
            view.settings.useSameFont = false
            view.settings.titleFontName = name
            view.settings.titlePointSize = size
        }
        for _ in 0..<pages { view.goNextPage() }
        // 可选：--find <查询词> 把命中高亮画出来并跳到第一处（检查高亮效果用）
        if let fi = CommandLine.arguments.firstIndex(of: "--find"),
           CommandLine.arguments.count > fi + 1 {
            let q = CommandLine.arguments[fi + 1]
            let r = TextSearch.find(query: q, haystack: book.findText, chapters: book.chapters)
            if let first = r.hits.first {
                view.jump(to: first.index)
                view.setSearchHighlights(r.hits.map { $0.index..<($0.index + $0.length) },
                                         current: first.index..<(first.index + first.length))
                FileHandle.standardError.write(
                    "全文搜索「\(q)」命中 \(r.hits.count) 处，已跳到第 1 处\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("全文搜索「\(q)」没有命中\n".data(using: .utf8)!)
            }
        }
        // 可选第 5 个参数：平滑滚动的像素偏移（用来预览「滚到一半」的状态，
        // 检查下一页有没有严丝合缝地接在下面）
        if CommandLine.arguments.count > idx + 4,
           let scrollPts = Double(CommandLine.arguments[idx + 4]), scrollPts != 0 {
            view.applyScroll(CGFloat(scrollPts))
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
        try png.write(to: URL(fileURLWithPath: dst))
        let c = book.chapters.count
        FileHandle.standardError.write(
            "已渲染第 \(pages + 1) 页 → \(dst)\n编码=\(decoded.encodingName) 总字数=\(book.units.count) 章节数=\(c) 本页偏移=\(view.page.start)..\(view.page.end)\n"
                .data(using: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write("渲染失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// ── 开发者工具：把「阅读列表」窗口离屏渲染成 PNG ──
// 用法： Reader --render-library <out.png>
if let idx = CommandLine.arguments.firstIndex(of: "--render-library"),
   CommandLine.arguments.count > idx + 1 {
    let dst = CommandLine.arguments[idx + 1]
    // 用一个临时存档塞几条演示数据，好把各种状态都渲染出来
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-lib-render-\\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let demoStore = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat"))
    demoStore.load()
    demoStore.setMainWindowFrame(.init(x: 0, y: 0, width: 300, height: 500), primaryScreenHeight: 900)
    demoStore.touch(fileName: FileManager.default.currentDirectoryPath + "/samples/古文观止-GBK.txt")
    demoStore.updateProgress(offset: 300, at: 0)          // 古文观止 GBK 版约 1125 字
    demoStore.touch(fileName: FileManager.default.currentDirectoryPath + "/samples/古文观止.txt")
    demoStore.updateProgress(offset: 700, at: 0)        // 古文观止约 1125 字
    _ = demoStore.addBookmark(offset: 500, at: 0)
    _ = demoStore.addBookmark(offset: 900, at: 0)
    demoStore.touch(fileName: "D:\\小说\\一本在 Windows 上的书.txt")

    let wc = LibraryWindowController(store: demoStore) { _ in }
    wc.reload()
    // 等一下后台的字数预取，否则进度列只会显示字符偏移
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    wc.reload()
    guard let view = wc.window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        FileHandle.standardError.write("已渲染阅读列表 → \(dst)\n".data(using: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write("渲染失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// ── 开发者工具：导出分页表（parity / 回归用）──
// 用法: Reader --dump-pages <book.txt> [宽 高]
// 输出每页的首字符偏移、覆盖字数、行数。拿去和 Windows 原版逐页比对，
// 就能确认「每页行数是否一致」—— 这是方案里 R2 风险（CoreText 行高与 GDI sz.cy 的差异）
// 唯一可靠的验证手段。
if let idx = CommandLine.arguments.firstIndex(of: "--dump-pages"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let w = CommandLine.arguments.count > idx + 2 ? (Double(CommandLine.arguments[idx + 2]) ?? 420) : 420
    let h = CommandLine.arguments.count > idx + 3 ? (Double(CommandLine.arguments[idx + 3]) ?? 660) : 660
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try TextDecoder.decode(data)
        let book = TextBook(fileURL: URL(fileURLWithPath: path), rawText: decoded.text, encodingName: decoded.encodingName)
        let view = ReadingView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.book = book
        var out = "page\tstart\tlength\tlines\tchapter\n"
        var page = 0
        var guardCount = 0
        while guardCount < 20000 {
            let ci = book.chapters.isEmpty ? "-" : String(book.chapterIndex(at: view.page.start) + 1)
            out += "\(page)\t\(view.page.start)\t\(view.page.length)\t\(view.page.lines.count)\t\(ci)\n"
            if view.page.end >= book.units.count { break }
            let before = view.page.start
            view.goNextPage()
            if view.page.start == before { break }
            page += 1
            guardCount += 1
        }
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
        FileHandle.standardError.write("共 \(page + 1) 页 · 画布 \(Int(w))x\(Int(h)) · 全书 \(book.units.count) 字 · \(book.chapters.count) 章\n".data(using: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write("失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// ── 开发者工具：导出章节表（章节解析等价性 / parity 回归用）──
// 用法: Reader --dump-chapters <book.txt>
// 输出每章的 行首偏移、标题长度、标题。改动章节解析后和旧版逐行 diff，
// 确认「解析结果一模一样」——章节表不写盘，这是唯一可靠的自动化比对手段。
if let idx = CommandLine.arguments.firstIndex(of: "--dump-chapters"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try TextDecoder.decode(data)
        let book = TextBook(fileURL: URL(fileURLWithPath: path),
                            rawText: decoded.text, encodingName: decoded.encodingName)
        var out = "index\toffset\ttitle_len\ttitle\n"
        out.reserveCapacity(book.chapters.count * 48)
        for (i, ch) in book.chapters.enumerated() {
            out += "\(i)\t\(ch.index)\t\(ch.titleLength)\t\(ch.title)\n"
        }
        FileHandle.standardOutput.write(out.data(using: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write("失败: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// ── 开发者工具：把「书签」窗口离屏渲染成 PNG ──
if let idx = CommandLine.arguments.firstIndex(of: "--render-bookmarks"),
   CommandLine.arguments.count > idx + 1 {
    let dst = CommandLine.arguments[idx + 1]
    let cwd = FileManager.default.currentDirectoryPath
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-bm-render-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let demoStore = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat"))
    demoStore.load()
    let bookPath = cwd + "/samples/古文观止.txt"
    demoStore.touch(fileName: bookPath)
    for off in [0, 300, 700, 1000] { _ = demoStore.addBookmark(offset: off, at: 0) }
    let data = try? Data(contentsOf: URL(fileURLWithPath: bookPath))
    let decoded = data.flatMap { try? TextDecoder.decode($0) }
    let book = decoded.map { TextBook(fileURL: URL(fileURLWithPath: bookPath), rawText: $0.text, encodingName: $0.encodingName) }
    let wc = BookmarkWindowController(store: demoStore) { _ in }
    wc.update(book: book)
    wc.show()
    guard let view = wc.window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        FileHandle.standardError.write("已渲染书签面板 → \(dst)\n".data(using: .utf8)!)
        exit(0)
    } catch { exit(1) }
}

// ── 开发者工具：把「跳转到章节」搜索面板离屏渲染成 PNG ──
// 用法： Reader --render-chapter-search <out.png> [查询词]
// 查询词省略时渲染「空查询 = 全书目录」的状态。
if let idx = CommandLine.arguments.firstIndex(of: "--render-chapter-search"),
   CommandLine.arguments.count > idx + 1 {
    let dst = CommandLine.arguments[idx + 1]
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-search-render-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    // 造一本 1200 章的书，渲染出来的才是「长篇搜索」的真实样子
    var text = ""
    for i in 1...1200 {
        if i == 122 {
            text += "第一百二十二章 山门旧事\n\n这是第122章的正文。\n\n"
        } else {
            text += "第\(i)章 测试章节\(i)\n\n这是第\(i)章的正文。\n\n"
        }
    }
    let bookURL = tmpDir.appendingPathComponent("渲染用长篇.txt")
    try? text.write(to: bookURL, atomically: true, encoding: .utf8)
    let wc = ChapterSearchWindowController()
    let data = try? Data(contentsOf: bookURL)
    let decoded = data.flatMap { try? TextDecoder.decode($0) }
    let book = decoded.map {
        TextBook(fileURL: bookURL, rawText: $0.text, encodingName: $0.encodingName)
    }
    wc.show(book: book, currentOffset: 0)
    if CommandLine.arguments.count > idx + 2 {
        wc.debugSetQuery(CommandLine.arguments[idx + 2])
    }
    guard let view = wc.window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        FileHandle.standardError.write("已渲染章节搜索面板 → \(dst)\n".data(using: .utf8)!)
        exit(0)
    } catch { exit(1) }
}

// ── 开发者工具：把「查找」面板离屏渲染成 PNG ──
// 用法： Reader --render-find <out.png> [查询词，默认「之」]
// 渲染的是真实的面板 + 真实搜索结果（同步跑一次搜索，保证截图可复现）。
if let idx = CommandLine.arguments.firstIndex(of: "--render-find"),
   CommandLine.arguments.count > idx + 1 {
    let dst = CommandLine.arguments[idx + 1]
    let query = CommandLine.arguments.count > idx + 2 ? CommandLine.arguments[idx + 2] : "之"
    let cwd = FileManager.default.currentDirectoryPath
    let src = URL(fileURLWithPath: cwd + "/samples/古文观止.txt")
    let wc = FindWindowController()
    let book = (try? Data(contentsOf: src)).flatMap { try? TextDecoder.decode($0) }.map {
        TextBook(fileURL: src, rawText: $0.text, encodingName: $0.encodingName)
    }
    wc.show(book: book, currentOffset: 0, caseSensitive: false)
    wc.debugSearchImmediately(query)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let view = wc.window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        FileHandle.standardError.write(
            "已渲染查找面板 → \(dst)（查询「\(query)」，命中 \(wc.debugRowCount) 处）\n"
                .data(using: .utf8)!)
        exit(0)
    } catch { exit(1) }
}

// ── 开发者工具：把「显示设置」窗口离屏渲染成 PNG ──
if let idx = CommandLine.arguments.firstIndex(of: "--render-settings"),
   CommandLine.arguments.count > idx + 1 {
    let dst = CommandLine.arguments[idx + 1]
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-set-render-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let demoStore = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat"))
    demoStore.load()
    let wc = SettingsWindowController(store: demoStore) { }
    // 可选第二个参数：切到指定标签页再渲染
    if CommandLine.arguments.count > idx + 2, let tab = Int(CommandLine.arguments[idx + 2]) {
        wc.debugSelectTab(tab)
    }
    guard let view = wc.window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        FileHandle.standardError.write("已渲染显示设置 → \(dst)\n".data(using: .utf8)!)
        exit(0)
    } catch { exit(1) }
}

// ── 开发者工具：阅读列表窗口自检（按钮 / 选中 / 打开 / 进度 / 关闭）──
if CommandLine.arguments.contains("--library-selftest") {
    let t0 = Date()
    func log(_ msg: String) {
        let line = String(format: "[%7.3fs] %@\n", Date().timeIntervalSince(t0), msg)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    let cwd = FileManager.default.currentDirectoryPath
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-lib-self-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let store = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat"))
    store.load()
    store.touch(fileName: cwd + "/samples/古文观止.txt")
    store.updateProgress(offset: 7000, at: 0)          // 约一半
    store.touch(fileName: cwd + "/samples/古文观止-GBK.txt")
    store.touch(fileName: "D:\\小说\\搬走了的书.txt")   // 找不到
    log("书架: " + store.items.map { "\($0.displayName)@\($0.index)" }.joined(separator: " | "))

    var opened: CacheItem?
    let wc = LibraryWindowController(store: store) { opened = $0 }
    wc.show()                                           // show 会刷新并触发后台预取
    pump(1.5)
    func buttons() -> [NSButton] { wc.window.contentView!.subviews.compactMap { $0 as? NSButton } }

    log("--- 1) 进度显示（之前是裸的字符偏移，现在应该是百分比） ---")
    pump(2.0)                                           // 等后台算完字数
    for (i, it) in store.items.enumerated() {
        let total = store.bookLength(forStoredPath: it.fileName)
        let cell = wc.tableView.view(atColumn: 1, row: i, makeIfNecessary: true) as? NSTextField
        let shown = cell?.stringValue ?? "(未渲染)"
        log("  [\(i)] \(it.displayName)  偏移=\(it.index)  全书=\(total.map(String.init) ?? "?")  显示「\(shown)」")
    }

    log("--- 2) 按钮启用状态（之前空选中是静默失败） ---")
    wc.tableView.deselectAll(nil)
    log("  未选中时: " + buttons().map { "\($0.title)=\($0.isEnabled ? "可点" : "禁用")" }.joined(separator: " "))
    wc.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    log("  选中一行后: " + buttons().map { "\($0.title)=\($0.isEnabled ? "可点" : "禁用")" }.joined(separator: " "))

    log("--- 3) 打开（打开后书架应收起，主窗口露出） ---")
    opened = nil
    wc.window.makeKeyAndOrderFront(nil)
    log("  打开前 isVisible=\(wc.window.isVisible)")
    NSApp.sendAction(Selector(("openSelected")), to: wc, from: nil)
    log("  onOpen " + (opened.map { "触发 → \($0.fileName)" } ?? "没触发"))
    log("  打开后 isVisible=\(wc.window.isVisible)  （期望 false = 已收起）")

    log("--- 4) 后台搜索搬走的文件 ---")
    var found = -1
    store.searchMissingFiles { found = $0 }
    pump(3.0)
    log("  找到 \(found) 个搬走的文件；缺失数=\(store.missingFileCount)")

    log("--- 5) 显示设置窗口 ---")
    let setStore = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat.settings"))
    setStore.load()
    var changeCount = 0
    let swc = SettingsWindowController(store: setStore) { changeCount += 1 }
    swc.onToggleAutoPage = {}          // 自检里直接构造，接线要自己补上
    swc.isAutoPageOn = { false }
    swc.show()
    log("  窗口尺寸: \(Int(swc.window.frame.width)) x \(Int(swc.window.frame.height))")
    setStore.updateSettings { $0.lineGap = 22; $0.wordWrap = true; $0.chapterPage = true }
    swc.syncFromSettings()
    log("  同步后设置: 行距=\(setStore.settings.lineGap) wordWrap=\(setStore.settings.wordWrap) chapterPage=\(setStore.settings.chapterPage)")
    log("  写回校验: \(setStore.settings.lineGap == 22 ? "✅ 成功" : "❌ 失败")")
    // 关键回归：跟随系统默认开启时，颜色块也必须可点
    log("  颜色块可点: \(swc.debugColorWellsEnabled ? "✅" : "❌ 又被禁用了")  （跟随系统=\(setStore.settings.followSystemAppearance)）")
    log("  自动翻页开关已就位: \(swc.onToggleAutoPage != nil ? "✅" : "❌")")
    log("  标签页: \(swc.debugTabTitles.joined(separator: " / "))")
    var tabSwitchOK = true
    for i in 0..<swc.debugTabTitles.count {
        swc.debugSelectTab(i)
        if swc.debugVisibleTabIndex != i { tabSwitchOK = false }
    }
    log("  逐个切换标签: \(tabSwitchOK ? "✅ 都正确" : "❌ 有错")")
    swc.debugSelectTab(0)

    log("--- 6) 进度口径一致性（真实的 ReadingView ↔ 阅读列表） ---")
    let longPath = cwd + "/samples/古文观止.txt"
    if let data = try? Data(contentsOf: URL(fileURLWithPath: longPath)),
       let decoded = try? TextDecoder.decode(data) {
        let book = TextBook(fileURL: URL(fileURLWithPath: longPath),
                            rawText: decoded.text, encodingName: decoded.encodingName)
        var statusText = ""
        var touchText = ""
        let view = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
        view.onStatusChange = { statusText = $0 }
        view.onTouchBarStatus = { touchText = $0 }
        view.book = book
        // 翻到最后一页
        var guardCount = 0
        while view.page.end < book.totalLength, guardCount < 500 {
            view.goNextPage(); guardCount += 1
        }
        let libText = ReadingStatus.libraryProgress(offset: view.page.start,
                                                    totalLength: book.totalLength,
                                                    isNew: false)
        let pct = String(format: "%.1f%%", ReadingStatus.percent(offset: view.page.start,
                                                                 totalLength: book.totalLength))
        log("  末页: 页首偏移=\(view.page.start) 页末=\(view.page.end) 全书=\(book.totalLength)")
        log("  阅读界面状态栏: \(statusText)")
        log("  触控栏        : \(touchText)")
        log("  阅读列表      : \(libText)")
        let ok = statusText.contains(pct) && touchText.contains(pct) && libText == pct
        log(ok ? "  ✅ 三处一致（\(pct)）" : "  ❌ 不一致！期望 \(pct)")
    } else {
        log("  (读不到样例文件，跳过)")
    }

    log("--- 7) 移除 / 清空要通知阅读界面 ---")
    // 契约：移除任意一本都上报它的路径；由 AppDelegate 判断「是不是正在读的那本」，
    // 是就关掉阅读界面。所以这里要验证的是「有没有上报」和「清空有没有单独通知」。
    var removedPath: String?
    var allRemoved = false
    wc.onBookRemoved = { removedPath = $0 }
    wc.onAllRemoved = { allRemoved = true }

    let readingPath = store.items.first(where: { $0.fileName.contains("古文观止") })?.fileName
    let otherIdx = store.items.firstIndex(where: { $0.fileName.contains("古文观止-GBK") }) ?? 0
    let otherPath = store.items[otherIdx].fileName
    wc.performRemove(at: otherIdx)
    log("  移除 古文观止-GBK → 上报路径正确: \(removedPath == otherPath)")

    if let keep = readingPath, let ki = store.items.firstIndex(where: { $0.fileName == keep }) {
        removedPath = nil
        wc.performRemove(at: ki)
        log("  移除正在读的那本 → 上报路径匹配: \(removedPath == keep)")
    }

    wc.performClearAll()
    log("  清空 → onAllRemoved 触发: \(allRemoved)，剩余 \(store.items.count) 本")

    log("--- 8) 书签面板 ---")
    let bmStore = LibraryStore(fileURL: tmpDir.appendingPathComponent(".cache.dat.bm"))
    bmStore.load()
    bmStore.touch(fileName: cwd + "/samples/古文观止.txt")
    var jumped: Int?
    let bwc = BookmarkWindowController(store: bmStore) { jumped = $0 }
    bwc.update(book: nil)
    log("  未打开书时提示: \(bwc.window.isVisible ? "" : "(窗口未显示)")")
    for off in [0, 300, 700] { _ = bmStore.addBookmark(offset: off, at: 0) }
    let bmData = try? Data(contentsOf: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    let bmBook = bmData.flatMap { d in (try? TextDecoder.decode(d)).map { TextBook(fileURL: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"), rawText: $0.text, encodingName: $0.encodingName) } }
    bwc.update(book: bmBook)
    log("  载入后表格行数 = \(bwc.numberOfRows(in: bwc.window.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView ?? NSTableView()))")
    log("  书签数 = \(bmStore.items.first?.marks.count ?? -1)")

    log("--- 9) 菜单栏图标 / 全局热键 / 自动翻页 ---")
    let sic = StatusItemController()
    sic.install()
    log("  菜单栏图标安装: \(sic.isInstalled ? "✅" : "❌")")
    log("  菜单项: \(sic.debugMenuTitles.joined(separator: " / "))")
    let needImm = sic.debugMenuTitles.contains { $0.contains("沉浸") }
    log("  含「沉浸阅读」: \(needImm ? "✅" : "❌")")
    sic.uninstall()
    log("  卸载后: \(sic.isInstalled ? "❌ 还在" : "✅ 已移除")")

    let hk = GlobalHotKey { }
    let hkOK = hk.register()
    log("  全局热键 \(GlobalHotKey.displayName) 注册: \(hkOK ? "✅ 成功" : "⚠️ 被其他 App 占用（不算失败）")")
    hk.unregister()
    log("  热键已注销")

    // 这个自检块跑在 app.delegate 赋值之前，所以要自己造一个 AppDelegate。
    // 好处是顺便验证了「设置 → 装上托盘/热键」这条真实接线。
    let ad = AppDelegate()
    NSApp.delegate = ad
    ad.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    LibraryStore.shared.updateSettings { $0.autoPageIntervalMS = 1000; $0.autoPageMode = 0 }
    ad.openSynchronously(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    do {
        let beforeAuto = ad.debugPageStart
        ad.toggleAutoPage(nil)
        log("  自动翻页已启动: \(ad.debugAutoPageActive ? "✅" : "❌")，起点 \(beforeAuto)")
        RunLoop.current.run(until: Date().addingTimeInterval(2.4))
        let afterAuto = ad.debugPageStart
        log("  1 秒间隔跑了 2.4 秒: \(beforeAuto) → \(afterAuto) \(afterAuto > beforeAuto ? "✅ 确实在翻" : "❌ 没动")")
        // ★ 回归：**运行中**改间隔要立刻生效（之前定时器把间隔定死了，得关掉重开）
        LibraryStore.shared.updateSettings { $0.autoPageIntervalMS = 4000 }
        ad.debugReapplySettings()
        let holdAt = ad.debugPageStart
        log("  运行中把间隔改成 4 秒，当前间隔=\(String(format: "%.1f", ad.debugAutoPageInterval)) 秒")
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        let stillAt = ad.debugPageStart
        log("  再跑 1.6 秒: \(holdAt) → \(stillAt) \(stillAt == holdAt ? "✅ 没有多翻（新间隔生效）" : "❌ 还在用旧间隔")")

        // ★ 回归：**运行中**改方式也要立刻生效
        LibraryStore.shared.updateSettings { $0.autoPageMode = 1; $0.autoPageIntervalMS = 700 }   // 逐行
        ad.debugReapplySettings()
        log("  运行中改成「逐行」+ 0.7 秒: 逐行模式=\(ad.debugAutoPageRowMode ? "✅" : "❌")")
        let lineBefore = ad.debugPageStart
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let lineDelta = ad.debugPageStart - lineBefore
        log("  跑了 1 秒前进 \(lineDelta) 字（一行约 10~30，一整页约 380）")
        log("  判定: \(lineDelta > 0 && lineDelta < 100 ? "✅ 方式改了立刻生效（确实只滚了一行）" : "❌ 行为不对")")

        // ★ 平滑滚动模式下的自动翻页
        // 注意定时器最小间隔被钳到 1 秒（防呆），动画本身约 0.3 秒，
        // 所以至少要等 1.4 秒才可能看到结果，这里留到 2.2 秒避免抖动。
        LibraryStore.shared.updateSettings {
            $0.autoPageIntervalMS = 1000
            $0.autoPageMode = 0        // 每页翻一次
            $0.smoothScroll = true
        }
        ad.debugReapplySettings()
        if ad.debugAutoPageActive { ad.toggleAutoPage(nil) }   // 上一段可能还在跑
        let smoothBefore = ad.debugPageStart
        ad.toggleAutoPage(nil)
        log("  平滑模式自动翻页：起点 \(smoothBefore)，一行=\(Int(ad.debugOneLineHeight))px 一页=\(Int(ad.debugOnePageHeight))px")
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        let smoothAfter = ad.debugPageStart
        log("  跑了 2.2 秒: \(smoothBefore) → \(smoothAfter)（前进 \(smoothAfter - smoothBefore) 字）")
        log("  判定: \(smoothAfter > smoothBefore ? "✅ 平滑翻页生效" : "❌ 没动")")
        ad.toggleAutoPage(nil)

        LibraryStore.shared.updateSettings { $0.autoPageMode = 0; $0.autoPageIntervalMS = 3000; $0.smoothScroll = true }
        ad.debugReapplySettings()
        log("  已停止: \(ad.debugAutoPageActive ? "❌ 还在跑" : "✅")")
        log("  菜单栏图标由设置驱动: \(ad.debugMenuBarInstalled ? "✅ 已装" : "未装")")
        log("  全局热键由设置驱动: \(ad.debugHotKeyRegistered ? "✅ 已注册" : "未注册")")
        log("  左右一起按→隐藏 已接线: \(ad.debugLeftRightHideWired ? "✅" : "❌")  鼠标模式=\(ad.debugPageMode)")
    }

    log("--- 10) 编辑模式 + 编码写回 ---")
    for enc in ["UTF-8", "UTF-8 (BOM)", "UTF-16LE", "UTF-16BE", "GB18030"] {
        let sample = "第1章 测试\n中文内容，还有 ASCII。\n"
        if let data = TextDecoder.encode(sample, encodingName: enc),
           let back = try? TextDecoder.decode(data) {
            log("  \(enc) 往返: \(back.text == sample ? "✅" : "❌")  字节=\(data.count)")
        } else {
            log("  \(enc) 往返: ❌ 编码失败")
        }
    }
    ad.openSynchronously(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    ad.toggleEditMode(nil)
    log("  进入编辑模式: \(ad.debugEditModeActive ? "✅" : "❌")")
    ad.toggleEditMode(nil)
    log("  未改动退出: \(ad.debugEditModeActive ? "❌ 还在编辑" : "✅ 已退出（未弹保存框）")")

    log("--- 11) 沉浸模式（隐藏顶栏和底栏） ---")
    ad.openSynchronously(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    LibraryStore.shared.updateSettings { $0.hideChrome = false }
    ad.toggleHideChrome(nil)   // 先确保是「关」，下一行再开
    if LibraryStore.shared.settings.hideChrome { ad.toggleHideChrome(nil) }
    log("  正常模式: 标题可见=\(ad.debugTitleVisible) 关闭按钮隐藏=\(ad.debugCloseButtonHidden) 状态栏隐藏=\(ad.debugStatusLabelHidden)")
    let normalHeight = ad.debugReadingViewHeight
    ad.toggleHideChrome(nil)
    log("  沉浸模式: 标题可见=\(ad.debugTitleVisible) 关闭按钮隐藏=\(ad.debugCloseButtonHidden) 状态栏隐藏=\(ad.debugStatusLabelHidden)")
    log("  拖动条已装: \(ad.debugDragStripInstalled ? "✅" : "❌")")
    log("  阅读区高度 \(Int(normalHeight)) → \(Int(ad.debugReadingViewHeight))（应变高）")
    ad.toggleHideChrome(nil)
    log("  切回正常: 标题可见=\(ad.debugTitleVisible) 拖动条=\(ad.debugDragStripInstalled ? "还在" : "✅ 已移除")")

    log("--- 12) 存档路径是算出来的，不是写死的 ---")
    let home = NSHomeDirectory()
    let computed = LibraryStore.shared.fileURL.path
    log("  当前用户家目录: \(home)")
    log("  存档路径:       \(computed)")
    log("  是否在家目录下: \(computed.hasPrefix(home) ? "✅ 是（跟随真实用户）" : "❌ 不在家目录下")")
    let expected = home + "/Library/Application Support/Reader/.cache.dat"
    log("  等于「家目录 + 固定相对路径」: \(computed == expected ? "✅ 是（运行时推导，换用户/换机器自动跟着变）" : "❌ 否")")
    log("  父目录自动创建: \(FileManager.default.fileExists(atPath: (computed as NSString).deletingLastPathComponent) ? "✅ 已存在" : "首次保存时创建")")

    log("--- 13) 透明度对窗口属性的影响 ---")
    // 关键回归：透明时窗口阴影必须关掉。isOpaque=false 的窗口，macOS 按 alpha
    // 蒙版算阴影；背景透明后只剩文字不透明 → 阴影变成「文字轮廓」，
    // 看起来就是每个字后面拖着一层虚影（用户形容为「视网膜残留」）。
    ad.openSynchronously(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    LibraryStore.shared.updateSettings { $0.alpha = 255 }
    ad.toggleHideChrome(nil); ad.toggleHideChrome(nil)     // 触发一次 applyWindowChrome
    log("  alpha=255: 窗口不透明=\(ad.debugWindowOpaque)  有阴影=\(ad.debugWindowHasShadow)")
    let opaqueState = (ad.debugWindowOpaque, ad.debugWindowHasShadow)

    LibraryStore.shared.updateSettings { $0.alpha = 120 }
    ad.toggleHideChrome(nil); ad.toggleHideChrome(nil)
    log("  alpha=120: 窗口不透明=\(ad.debugWindowOpaque)  有阴影=\(ad.debugWindowHasShadow)")
    let translucentState = (ad.debugWindowOpaque, ad.debugWindowHasShadow)

    let shadowOK = opaqueState.0 && opaqueState.1 && !translucentState.0 && !translucentState.1
    log("  判定: " + (shadowOK ? "✅ 不透明时有阴影；透明时阴影已关闭，不会有文字虚影" : "❌ 状态不对"))
    LibraryStore.shared.updateSettings { $0.alpha = 255 }
    ad.toggleHideChrome(nil); ad.toggleHideChrome(nil)

    log("--- 14) 平滑滚动动画 ---")
    // 前面单测都是直接调 applyScroll（绕过动画），这里验证定时器这条真实路径
    let animURL = URL(fileURLWithPath: cwd + "/samples/古文观止.txt")
    if let d = try? Data(contentsOf: animURL), let txt = try? TextDecoder.decode(d) {
        let animBook = TextBook(fileURL: animURL, rawText: txt.text, encodingName: txt.encodingName)
        let av = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
        av.book = animBook
        log("  起始偏移 = \(av.scrollOffset)")
        av.smoothScroll(by: 150)
        RunLoop.current.run(until: Date().addingTimeInterval(0.30))
        log("  滚动 150px 后偏移 = \(String(format: "%.1f", Double(av.scrollOffset)))（应接近 150）")
        log("  动画已收敛: \(abs(av.scrollOffset - 150) < 3 ? "✅" : "❌")")
        av.smoothScroll(by: -150)
        RunLoop.current.run(until: Date().addingTimeInterval(0.30))
        log("  滚回后偏移 = \(String(format: "%.1f", Double(av.scrollOffset)))（应接近 0）")
        log("  回到页首: \(av.scrollOffset < 3 ? "✅" : "❌")")
        // 跨页动画
        let flow = av.page.flowHeight
        av.smoothScroll(by: flow + 100)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        log("  跨页滚动后 页首=\(av.pageStart) 偏移=\(String(format: "%.1f", Double(av.scrollOffset)))")
    }

    log("--- 15) 窗口关闭 ---")
    wc.show()
    log("  show 后 isVisible=\(wc.window.isVisible) isKey=\(wc.window.isKeyWindow) 可关闭=\(wc.window.styleMask.contains(.closable))")
    log("  关闭按钮存在=\(wc.window.standardWindowButton(.closeButton) != nil) 启用=\(wc.window.standardWindowButton(.closeButton)?.isEnabled ?? false)")
    wc.window.performClose(nil)
    log("  performClose 后 isVisible=\(wc.window.isVisible)")
    exit(0)
}

// ── 开发者工具：列出触控栏会构建出的条目 ──
// 触控栏没法截图，用这个核对结构（会实例化全部条目，能提前暴露构造错误）
if CommandLine.arguments.contains("--dump-touchbar") {
    let probe = AppDelegate()
    for line in ReaderTouchBar.shared.describeAllItems(target: probe) {
        print(line)
    }
    print("")
    // 验证「懒加载」这条容易出错的路径：
    // 触控栏条目是系统在需要时才创建的。如果 App 先更新了进度文字、
    // 之后系统才创建标签控件，文字不能丢（真机上换书时就是这个顺序）。
    let sampleStatus = ReadingStatus.compact(bookName: "古文观止",
                                             chapterTitle: "第1章 测试章节标题",
                                             offset: 500, totalLength: 1125)
    ReaderTouchBar.shared.updateProgress(sampleStatus)
    let probe2 = AppDelegate()
    let bar2 = ReaderTouchBar.shared.makeTouchBar(target: probe2)
    let progressID = NSTouchBarItem.Identifier("reader.progress")
    if let item = ReaderTouchBar.shared.touchBar(bar2, makeItemForIdentifier: progressID) as? NSCustomTouchBarItem,
       let field = item.view as? NSTextField {
        print("先更新、后创建控件 → 标签显示: \"\(field.stringValue)\"")
        print(field.stringValue == sampleStatus ? "  ✅ 懒加载路径正确（文字没丢）" : "  ❌ 文字丢了")
        print("  截断方式: \(field.lineBreakMode == .byTruncatingMiddle ? "中间截断（书名与百分比都保留）" : "非中间截断")")
        let w = (field.stringValue as NSString).size(withAttributes: [.font: field.font ?? NSFont.systemFont(ofSize: 13)]).width
        print(String(format: "  实际渲染宽度: %.1fpt（标签最小宽度 190pt）", w))
    } else {
        print("  ❌ 无法取出进度标签控件")
    }
    exit(0)
}

/// 关窗自检开关（由 --close-selftest 打开）
let closeSelftestEnabled = CommandLine.arguments.contains("--close-selftest")

/// 启动前打开文件的自检开关
///
/// 复现「双击 txt / 把文件拖到 Dock 图标」这条路径：AppKit 会在
/// `finishLaunching` 阶段就调 `application(_:openFile:)`，**比
/// `applicationDidFinishLaunching` 更早** —— 那时窗口还没建出来。
/// 早期版本没有这个防护，`open(url:)` 会撞上隐式解包 nil，崩在
/// `EXC_BREAKPOINT / _assertionFailure`（崩溃报告里能看到完整栈）。
let earlyOpenSelftest = CommandLine.arguments.contains("--early-open-selftest")

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// ── 开发者工具：目录菜单自检（一级菜单 + 长篇小说全部章节 + 当前章定位 + 跳转）──
// 旧版目录只列前 300 章，几千章的小说从第 301 章起点不到。
// 这里造一本 3000 章的书（真实网文常见量级），走真实启动路径验五件事：
//   1.「目录」是菜单栏一级菜单，且已从「阅读」里移出
//   2. 目录列满全部章节（含第 301 章、最后一章），不再有「只列前 300」提示
//   3. 打开目录时从当前章开始列，前面的章节收进顶部子菜单
//   4. 当前章打勾；点当前章 / 最后一章都能真的跳过去
//   5. 重建菜单的耗时（防止以后改回同步/多次重建，变成卡顿）
if CommandLine.arguments.contains("--toc-selftest") {
    var failures = 0
    func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
    func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        log(cond ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !cond { failures += 1 }
    }

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-toc-self-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    // 造一本 3000 章的书（默认章节规则能识别「第 N 章」）
    let chapterCount = 3000
    var text = ""
    for i in 1...chapterCount {
        text += "第\(i)章 测试章节\(i)\n\n这是第\(i)章的正文，用来占位。\n\n"
    }
    let bookURL = tmpDir.appendingPathComponent("长篇小说.txt")
    do {
        try text.write(to: bookURL, atomically: true, encoding: .utf8)
    } catch {
        log("❌ 造测试文件失败: \(error)")
        exit(1)
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    // 还没打开书时也要有占位项，否则空子菜单会让「目录」变灰、点不开
    let beforeOpen = delegate.debugTOCMenuTitles
    check(beforeOpen.first == "跳转到章节…", "目录顶部有「跳转到章节…」入口",
          beforeOpen.joined(separator: " / "))
    check(beforeOpen.contains("（未打开文件）"), "没打开书时目录是占位项（菜单不会变灰）",
          beforeOpen.joined(separator: " / "))
    if let searchItem = delegate.debugTOCMenuItem(at: 0) {
        check(searchItem.keyEquivalent == "j", "「跳转到章节…」快捷键是 ⌘J")
        check(searchItem.target === delegate, "「跳转到章节…」target 指向 AppDelegate")
        check(!delegate.validateMenuItem(searchItem), "没打开书时「跳转到章节…」是禁用的")
    } else {
        check(false, "能取到「跳转到章节…」菜单项")
    }

    delegate.openSynchronously(url: bookURL)
    log("打开测试书: \(bookURL.lastPathComponent)（\(chapterCount) 章）")

    let topLevel = delegate.debugTopLevelMenuTitles.filter { !$0.isEmpty }
    log("菜单栏一级菜单: \(topLevel.joined(separator: " / "))")
    let tocPos = topLevel.firstIndex(of: "目录")
    check(tocPos != nil, "「目录」在菜单栏一级")
    if let tocPos, let readPos = topLevel.firstIndex(of: "阅读") {
        check(tocPos == readPos + 1, "「目录」紧跟在「阅读」后面")
    }

    let readTitles = delegate.debugReadMenuTitles
    check(!readTitles.contains("目录"), "「阅读」里不再重复放目录",
          readTitles.joined(separator: " / "))

    // ---- 当前在第 1 章：整本平铺（没有「前面的章节」子菜单） ----
    // 菜单结构：[0] 跳转到章节…、[1] 分隔线、[2...] 章节
    let startTitles = delegate.debugTOCMenuTitles
    check(startTitles.count == chapterCount + 2, "目录列出了全部章节",
          "实际 \(startTitles.count) 项（含 2 项固定入口）")
    check(startTitles[2].hasPrefix("1. "), "第 1 章在平铺段最前面", startTitles[2])
    check(!startTitles.contains { $0.contains("前面的章节") },
          "第 1 章时没有「前面的章节」子菜单")
    check(!startTitles.contains { $0.contains("只列前") }, "没有「此处只列前 300」的说明项")
    if let searchItem = delegate.debugTOCMenuItem(at: 0) {
        check(delegate.validateMenuItem(searchItem), "打开书后「跳转到章节…」可用")
    }

    if let first = delegate.debugTOCMenuItem(at: 2) {
        check(first.state == .on, "当前章（第 1 章）打勾")
    } else {
        check(false, "能取到第 1 章菜单项")
    }

    // 解析同一本书拿到准确偏移（用于跳转断言）
    guard let data = try? Data(contentsOf: bookURL),
          let decoded = try? TextDecoder.decode(data) else {
        log("❌ 重新解析测试书失败")
        exit(1)
    }
    let book = TextBook(fileURL: bookURL, rawText: decoded.text, encodingName: decoded.encodingName)
    let lastIndex = book.chapters.count - 1
    let middleIndex = 1499        // 第 1500 章

    // ---- 跳到第 1500 章，再打开目录：应该从当前章开始列 ----
    // 此时菜单结构：[0] 跳转、[1] 分隔线、[2] 前面的章节、[3] 分隔线、[4...] 当前章及之后
    if let item = delegate.debugTOCMenuItem(at: middleIndex + 2), let action = item.action {
        NSApp.sendAction(action, to: item.target, from: item)
    }
    log("跳到第 1500 章：页首偏移=\(delegate.debugPageStart) 期望=\(book.chapters[middleIndex].index)")

    let buildStart = Date()
    let titles = delegate.debugTOCMenuTitles          // 强制按当前章重建
    let buildMS = Date().timeIntervalSince(buildStart) * 1000
    log(String(format: "目录菜单重建 %d 项，耗时 %.1f ms", titles.count, buildMS))

    check(titles.first == "跳转到章节…", "「跳转到章节…」始终在目录最上面", titles.first ?? "无")
    check(titles[2].contains("前面的章节"),
          "★ 前面的章节收进子菜单，不再从第 1 章开始", titles[2])
    check(titles.count == 4 + (chapterCount - middleIndex),
          "平铺部分是当前章 + 后面的章节", "实际 \(titles.count) 项")
    if titles.count > 4 {
        check(titles[3].isEmpty, "子菜单和当前章之间有分隔线")
        check(titles[4].hasPrefix("1500. "), "★ 分隔线后第一项就是当前章（第 1500 章）", titles[4])
    }
    check(titles.last?.contains("第\(chapterCount)章") == true,
          "后面的章节一直到最后一章", titles.last ?? "无")
    check(!titles.dropFirst(4).contains { $0.hasPrefix("1. ") }, "第 1 章不在平铺段里")
    check(buildMS < 500, "重建 \(titles.count) 项菜单耗时可接受", String(format: "%.1f ms", buildMS))

    if let earlier = delegate.debugTOCMenuItem(at: 2)?.submenu {
        check(earlier.items.count == middleIndex, "「前面的章节」子菜单里有 \(middleIndex) 章",
              "实际 \(earlier.items.count)")
        check(earlier.items.first?.title.hasPrefix("\(middleIndex). ") == true,
              "★ 子菜单第一项是当前章的前一章（由近到远）", earlier.items.first?.title ?? "无")
        check(earlier.items.last?.title.hasPrefix("1. ") == true,
              "子菜单最后一项是第 1 章", earlier.items.last?.title ?? "无")
        check(earlier.items.allSatisfy { $0.tag >= 0 && $0.tag < middleIndex },
              "子菜单里的 tag 都指向当前章之前的章节")
    } else {
        check(false, "能取到「前面的章节」子菜单")
    }

    if let current = delegate.debugTOCMenuItem(at: 4) {
        check(current.tag == middleIndex && current.state == .on,
              "★ 平铺第一项是打勾的当前章", "tag=\(current.tag)")
    } else {
        check(false, "能取到当前章菜单项")
    }

    // 点最后一章：走 NSApp.sendAction，和真实点菜单同一条路径
    if let item = delegate.debugTOCMenuItem(at: titles.count - 1) {
        check(item.tag == lastIndex, "最后一项 tag = 最后一章下标", "tag=\(item.tag)")
        check(item.target === delegate, "菜单项 target 指向 AppDelegate")
        if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        let expected = book.chapters[lastIndex].index
        log("点最后一章：页首偏移=\(delegate.debugPageStart) 期望=\(expected)")
        check(delegate.debugPageStart == expected, "★ 点第 \(book.chapters.count) 章能跳过去")
    } else {
        check(false, "能取到最后一章菜单项")
    }

    // 顶部「前面的章节」子菜单里的旧章节也要能点（跳回第 100 章）
    if let earlierMenu = delegate.debugTOCMenuItem(at: 2)?.submenu,
       let oldItem = earlierMenu.items.first(where: { $0.tag == 99 }),
       let action = oldItem.action {
        let expected = book.chapters[99].index
        NSApp.sendAction(action, to: oldItem.target, from: oldItem)
        check(delegate.debugPageStart == expected, "★ 「前面的章节」子菜单里的第 100 章也能跳过去")
    } else {
        check(false, "能取到「前面的章节」子菜单里的第 100 章")
    }

    log(failures == 0 ? "✅ 目录自检全部通过" : "❌ 目录自检失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

// ── 开发者工具：章节搜索面板自检（模糊搜索 + 跳转）──
// 造一本 1200 章的书（其中一章用中文数字 + 可跳字的标题），验四件事：
//   1. 五种章节号写法（阿拉伯 / 中文 / 全角 / 带「第…章」）都命中同一章
//   2. 标题能模糊搜：按顺序跳字也能命中
//   3. 面板打开时列出全书并选中当前章，回车能真的跳过去
//   4. 打字过程中面板不会自己关掉（搜索框不能绑随输入触发的 action）
if CommandLine.arguments.contains("--chapter-search-selftest") {
    var failures = 0
    func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
    func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        log(cond ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !cond { failures += 1 }
    }

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-search-self-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let chapterCount = 1200
    var text = ""
    for i in 1...chapterCount {
        if i == 122 {
            text += "第一百二十二章 山门旧事\n\n这是第122章的正文。\n\n"
        } else {
            text += "第\(i)章 测试章节\(i)\n\n这是第\(i)章的正文。\n\n"
        }
    }
    let bookURL = tmpDir.appendingPathComponent("搜索测试.txt")
    do {
        try text.write(to: bookURL, atomically: true, encoding: .utf8)
    } catch {
        log("❌ 造测试文件失败: \(error)")
        exit(1)
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    delegate.openSynchronously(url: bookURL)
    log("打开测试书: \(bookURL.lastPathComponent)（\(chapterCount) 章）")

    guard let data = try? Data(contentsOf: bookURL),
          let decoded = try? TextDecoder.decode(data) else {
        log("❌ 重新解析测试书失败")
        exit(1)
    }
    let book = TextBook(fileURL: bookURL, rawText: decoded.text, encodingName: decoded.encodingName)
    let targetOffset = book.chapters[121].index

    // ---- 打开面板 ----
    delegate.debugShowChapterSearch()
    check(delegate.debugChapterSearchVisible, "菜单 / ⌘J 能打开搜索面板")
    guard let wc = delegate.debugChapterSearch else {
        log("❌ 拿不到搜索面板")
        exit(1)
    }
    check(wc.debugRowCount == chapterCount, "空查询列出全书章节", "实际 \(wc.debugRowCount)")
    check(wc.debugSelectedRow == 0, "空查询默认选中当前章（第 1 章）", "实际 \(wc.debugSelectedRow)")

    // ---- 改显示设置不该重解析章节（大书拖滑块卡顿回归） ----
    let parseGen = delegate.debugChapterParseGeneration
    LibraryStore.shared.updateSettings { $0.lineGap += 1 }
    delegate.debugReapplySettings()
    check(delegate.debugChapterParseGeneration == parseGen,
          "★ 改显示设置（行距）不重新解析章节",
          "版本 \(parseGen) → \(delegate.debugChapterParseGeneration)")

    // 改章节规则才应该重新解析；验完立刻恢复默认，后面的搜索断言才成立
    LibraryStore.shared.updateSettings {
        $0.chapterRule.kind = .keyword
        $0.chapterRule.keyword = "第"
    }
    delegate.debugReapplySettings()
    check(delegate.debugChapterParseGeneration == parseGen + 1,
          "★ 改章节规则才重新解析一次",
          "版本 \(parseGen) → \(delegate.debugChapterParseGeneration)")
    LibraryStore.shared.updateSettings { $0.chapterRule = ChapterRule() }
    delegate.debugReapplySettings()
    check(delegate.debugChapterParseGeneration == parseGen + 2,
          "切回默认规则再解析一次（恢复测试环境）",
          "版本 \(parseGen) → \(delegate.debugChapterParseGeneration)")

    // ---- 章节号：五种写法都要能搜到第 122 章 ----
    for (query, name) in [("122", "阿拉伯数字"),
                          ("第122章", "带第/章"),
                          ("一百二十二", "中文数字"),
                          ("第一百二十二章", "中文数字带第/章"),
                          ("１２２", "全角数字")] {
        wc.debugSetQuery(query)
        check(wc.debugHitIndices.first == 121,
              "搜索「\(query)」（\(name)）第一个命中第 122 章",
              "实际 \(wc.debugHitIndices.first ?? -1)")
    }

    // ---- 标题模糊：跳字也能匹配 ----
    wc.debugSetQuery("山门事")
    check(wc.debugHitIndices.first == 121,
          "★ 标题跳字查询「山门事」命中「山门旧事」",
          "实际 \(wc.debugHitIndices.first ?? -1)")
    wc.debugSetQuery("山门旧事")
    check(wc.debugHitIndices.first == 121, "标题连续子串也能命中",
          "实际 \(wc.debugHitIndices.first ?? -1)")
    wc.debugSetQuery("找不到的标题zzz")
    check(wc.debugRowCount == 0, "没有匹配时列表为空", "实际 \(wc.debugRowCount)")

    // ---- 打字过程中面板不能自己关（回归：输入 435 时刚打完 4 就跳转关掉了） ----
    check(!wc.debugSearchFieldHasAction,
          "★ 搜索框没有绑定会随打字触发的 action")
    for typed in ["4", "43", "435"] {
        wc.debugSetQuery(typed)
        check(wc.debugWindowVisible, "输入「\(typed)」时面板仍然打开")
    }

    // ---- 回车跳转（走真实的 delegate 回调，不是直接调内部方法） ----
    wc.debugSetQuery("122")
    let handled = wc.control(wc.debugSearchField, textView: NSTextView(),
                             doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check(handled, "搜索框把回车事件消费掉（不会漏给别的控件）")
    log("跳转后页首偏移=\(delegate.debugPageStart) 期望=\(targetOffset)")
    check(delegate.debugPageStart == targetOffset, "★ 从搜索结果回车能跳过去")
    check(!delegate.debugChapterSearchVisible, "跳转后面板自动收起")

    // ---- 再次打开：查询清空、选中当前章（第 122 章） ----
    delegate.debugShowChapterSearch()
    check(wc.debugRowCount == chapterCount, "重新打开时查询已清空", "实际 \(wc.debugRowCount)")
    check(wc.debugSelectedRow == 121, "重新打开时选中当前章（第 122 章）",
          "实际 \(wc.debugSelectedRow)")

    log(failures == 0 ? "✅ 章节搜索自检全部通过" : "❌ 章节搜索自检失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

// ── 开发者工具：全文搜索（查找面板）自检 ──
// 覆盖：⌘F / ⌘G / ⇧⌘G 的菜单键位、命中位置、**搜索不自动跳页**、
// 双击 / 「跳转」才跳、单击只选中、关面板清空输入框、重新打开是空白查找。
if CommandLine.arguments.contains("--find-selftest") {
    var failures = 0
    func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
    func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        log(cond ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !cond { failures += 1 }
    }

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("reader-find-self-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    // 300 章：第 122 章标题里直接写阿拉伯数字（便于核对命中偏移），第 3 章带英文
    let chapterCount = 300
    var text = ""
    for i in 1...chapterCount {
        if i == 122 {
            text += "第122章 山门旧事\n\n这是第122章的正文，山门旧事无人知。\n\n"
        } else if i == 3 {
            text += "第3章 Hello World\n\nHello World，hello again。\n\n"
        } else {
            text += "第\(i)章 测试章节\(i)\n\n这是第\(i)章的正文，用来占位。\n\n"
        }
    }
    let bookURL = tmpDir.appendingPathComponent("查找测试.txt")
    do {
        try text.write(to: bookURL, atomically: true, encoding: .utf8)
    } catch {
        log("❌ 造测试文件失败: \(error)")
        exit(1)
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    // ---- 菜单键位：⌘F 给查找，全屏让给 ⌃⌘F ----
    let findKey = delegate.debugShortcut(menuTitle: "阅读", itemTitle: "查找…") ?? "无"
    check(findKey == "⌘f", "★ 「查找…」快捷键是 ⌘F", findKey)
    let fsKey = delegate.debugShortcut(menuTitle: "视图", itemTitle: "进入全屏幕") ?? "无"
    check(fsKey == "⌃⌘f", "★ 全屏已改为 ⌃⌘F（不再和查找抢 ⌘F）", fsKey)
    check(delegate.debugShortcut(menuTitle: "阅读", itemTitle: "查找下一个") == "⌘g",
          "「查找下一个」是 ⌘G")
    check(delegate.debugShortcut(menuTitle: "阅读", itemTitle: "查找上一个") == "⇧⌘g",
          "「查找上一个」是 ⇧⌘G")

    // ---- 没打开书时菜单项禁用 ----
    if let findItem = delegate.debugMenuItem(menuTitle: "阅读", itemTitle: "查找…") {
        check(!delegate.validateMenuItem(findItem), "没打开书时「查找…」是禁用的")
    } else {
        check(false, "能找到「查找…」菜单项")
    }

    delegate.openSynchronously(url: bookURL)
    guard let data = try? Data(contentsOf: bookURL),
          let decoded = try? TextDecoder.decode(data) else {
        log("❌ 重新解析测试书失败")
        exit(1)
    }
    let book = TextBook(fileURL: bookURL, rawText: decoded.text, encodingName: decoded.encodingName)
    check(book.chapters.count == chapterCount, "测试书解析出 \(chapterCount) 章",
          "实际 \(book.chapters.count)")

    // ---- 打开面板 ----
    delegate.debugShowFind()
    check(delegate.debugFindVisible, "菜单 / ⌘F 能打开查找面板")
    guard let wc = delegate.debugFindWindow else {
        log("❌ 拿不到查找面板")
        exit(1)
    }
    check(wc.debugRowCount == 0, "刚打开（还没有查询词）时结果为空", "实际 \(wc.debugRowCount)")
    check(wc.debugQuery.isEmpty, "刚打开的输入框是空的", "实际「\(wc.debugQuery)」")
    check(!wc.debugSearchFieldHasAction, "★ 搜索框没有绑定会随打字触发的 action")
    check(wc.debugDoubleActionWired, "双击结果行接上了跳转（单击只选中）")

    // ---- 搜索命中：数量、偏移，以及「不自动跳页」 ----
    let pageBeforeSearch = delegate.debugPageStart
    wc.debugSearchImmediately("第122章")
    check(wc.debugRowCount == 2, "「第122章」命中 2 处（标题 + 正文）", "实际 \(wc.debugRowCount)")
    let firstHit = wc.debugHitOffsets.first ?? -1
    check(firstHit == book.chapters[121].index, "★ 第一处命中就是第 122 章标题起点",
          "命中 \(firstHit)，章节起点 \(book.chapters[121].index)")
    check(delegate.debugPageStart == pageBeforeSearch,
          "★ 搜到结果不自动跳页", "页首 \(delegate.debugPageStart) → \(pageBeforeSearch)")
    check(!delegate.debugHasCurrentSearchHighlight, "★ 没跳之前不画「当前命中」")
    check(wc.debugSelectedRow == 0, "默认只选中离阅读位置最近的那一处",
          "实际第 \(wc.debugSelectedRow) 行")

    // ---- 单击只是选中，不能跳 ----
    wc.debugClickRow(wc.debugRowCount - 1)
    check(wc.debugSelectedRow == 1, "单击另一行会改选中", "实际第 \(wc.debugSelectedRow) 行")
    check(delegate.debugPageStart == pageBeforeSearch, "★ 单击结果行不跳页")

    // ---- 用户主动跳转（双击 / 「跳转」按钮 / 回车）才跳 ----
    wc.debugClickRow(0)
    wc.debugJumpToSelected()
    check(delegate.debugPageStart == firstHit, "★ 主动跳转才跳到命中处",
          "页首 \(delegate.debugPageStart)，命中 \(firstHit)")
    check(delegate.debugHasCurrentSearchHighlight, "跳过去后本页有「当前命中」高亮")
    check(delegate.debugVisibleSearchHitCount >= 1, "本页画出了命中高亮",
          "可见 \(delegate.debugVisibleSearchHitCount)")
    let pageRange = delegate.debugPageStart..<delegate.debugPageEnd
    check(delegate.debugVisibleSearchRanges.allSatisfy { pageRange.overlaps($0) },
          "★ 高亮区间都与当前页相交（不会画到别的页）")

    // ---- 上一个 / 下一个（⌘G / ⇧⌘G 本身是显式命令，会跳）----
    let secondHit = wc.debugHitOffsets.count > 1 ? wc.debugHitOffsets[1] : -1
    delegate.debugFindNext()
    check(wc.debugSelectedRow == 1, "⌘G 选中下一处", "实际第 \(wc.debugSelectedRow) 行")
    check(delegate.debugPageStart == secondHit, "⌘G 跳到第二处",
          "页首 \(delegate.debugPageStart)，期望 \(secondHit)")
    delegate.debugFindNext()
    check(wc.debugSelectedRow == 0, "★ 最后一处的下一处环绕回第一处",
          "实际第 \(wc.debugSelectedRow) 行")
    delegate.debugFindPrevious()
    check(wc.debugSelectedRow == 1, "★ 第一处的上一处环绕到最后一处",
          "实际第 \(wc.debugSelectedRow) 行")

    // ---- 大小写（切换后重搜同样不跳）----
    let pageBeforeCase = delegate.debugPageStart
    wc.debugSearchImmediately("HELLO")
    check(wc.debugRowCount == 3, "默认大小写不敏感：HELLO 命中 3 处（标题 + 正文两处）", "实际 \(wc.debugRowCount)")
    check(delegate.debugPageStart == pageBeforeCase, "重新搜索也不跳页")
    wc.debugSetCaseSensitive(true)
    check(wc.debugRowCount == 0, "★ 勾上「区分大小写」后 HELLO 不再命中", "实际 \(wc.debugRowCount)")
    wc.debugSetCaseSensitive(false)
    check(wc.debugRowCount == 3, "关掉「区分大小写」后 HELLO 又能命中", "实际 \(wc.debugRowCount)")

    // ---- 关面板：输入框清空、结果清空、高亮清除 ----
    let pageBeforeClose = delegate.debugPageStart
    wc.window.performClose(nil)
    check(!delegate.debugFindVisible, "面板已关闭")
    check(wc.debugQuery.isEmpty, "★ 关闭面板会清空输入框", "实际「\(wc.debugQuery)」")
    check(wc.debugRowCount == 0, "关闭后结果也清空", "实际 \(wc.debugRowCount)")
    check(delegate.debugVisibleSearchHitCount == 0, "★ 关掉面板后阅读界面不再有高亮",
          "可见 \(delegate.debugVisibleSearchHitCount)")

    // ---- 重新打开：空白的一次查找，不会跳回上次的位置（用户报过的问题）----
    delegate.debugShowFind()
    check(delegate.debugFindVisible, "⌘F 能重新打开面板")
    check(wc.debugQuery.isEmpty, "★ 重新打开时输入框是空的", "实际「\(wc.debugQuery)」")
    check(wc.debugRowCount == 0, "★ 重新打开不会自动重搜（结果为空）", "实际 \(wc.debugRowCount)")
    check(delegate.debugPageStart == pageBeforeClose,
          "★ 重新打开不会跳回上次搜索的位置",
          "页首 \(delegate.debugPageStart) → \(pageBeforeClose)")

    // ---- 面板关着按 ⌘G：只打开空白面板，不重放上次查询 ----
    wc.window.performClose(nil)
    delegate.debugFindNext()
    check(delegate.debugFindVisible, "⌘G 能把面板打开")
    check(wc.debugQuery.isEmpty && wc.debugRowCount == 0,
          "面板关着按 ⌘G 也是一次空白查找", "查询「\(wc.debugQuery)」结果 \(wc.debugRowCount)")

    log(failures == 0 ? "✅ 全文搜索自检全部通过" : "❌ 全文搜索自检失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

// ── 开发者工具：窗口置顶自检 ──
// 自动能验的是 AppKit 状态（level / 失焦隐藏 / 存档往返）；
// 「真的盖住别的 App」只能人手看：勾上设置 → 切到别的应用 → 窗口仍在最上面。
if CommandLine.arguments.contains("--always-on-top-selftest") {
    var failures = 0
    func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
    func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        log(cond ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !cond { failures += 1 }
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    check(!delegate.debugWindowLevelIsFloating, "默认不置顶（level = normal）")
    check(!delegate.debugWindowHidesOnDeactivate, "失焦不隐藏窗口（否则切到别的应用就消失）")
    check(delegate.debugKeepOnTopMenuState == .off, "「视图 → 窗口置顶」初始未勾选")
    check(delegate.debugShortcut(menuTitle: "视图", itemTitle: "窗口置顶") == "⌃⌘t",
          "「窗口置顶」快捷键是 ⌃⌘T",
          delegate.debugShortcut(menuTitle: "视图", itemTitle: "窗口置顶") ?? "无")
    check(delegate.debugStatusItemController.debugState(ofTitle: "窗口置顶") == .off,
          "菜单栏图标里的「窗口置顶」初始未勾选")
    if let item = delegate.debugMenuItem(menuTitle: "视图", itemTitle: "窗口置顶") {
        check(item.target === delegate && item.action == #selector(AppDelegate.toggleKeepOnTop(_:)),
              "菜单项接的是 AppDelegate.toggleKeepOnTop")
    } else {
        check(false, "「视图」菜单里有「窗口置顶」")
    }
    check(delegate.debugStatusItemController.debugMenuTitles.contains("窗口置顶"),
          "菜单栏图标菜单里有「窗口置顶」")

    // 设置窗口的复选框也要能查到（后面还要用它验证三处联动）
    delegate.showSettings(nil)
    check(!delegate.debugSettingsKeepOnTopChecked, "设置窗口的复选框初始未勾选")
    delegate.debugCloseAuxWindows()

    // ---- 路径 1：左上角菜单栏的「视图 → 窗口置顶」 ----
    delegate.debugToggleKeepOnTopFromMenu()
    check(LibraryStore.shared.settings.keepOnTop, "★ 菜单开关能打开置顶")
    check(delegate.debugWindowLevelIsFloating, "★ 菜单开关立即生效（窗口 level = floating）")
    check(delegate.debugKeepOnTopMenuState == .on, "菜单项自己打勾")
    check(delegate.debugStatusItemController.debugState(ofTitle: "窗口置顶") == .on,
          "★ 菜单栏图标菜单同步打勾")
    check(delegate.debugSettingsKeepOnTopChecked, "★ 设置窗口复选框同步打勾")
    check(!delegate.debugWindowHidesOnDeactivate, "置顶状态下失焦也不隐藏")
    let floatingLevel = NSWindow.Level.floating.rawValue
    let normalLevel = NSWindow.Level.normal.rawValue
    log("  floating level = \(floatingLevel)，normal level = \(normalLevel)（数值越大越靠前）")
    check(floatingLevel > normalLevel, "floating 的层级高于普通窗口（才能盖住最大化的应用）")

    // ---- 路径 2：右上角菜单栏图标里的「窗口置顶」 ----
    delegate.debugStatusItemController.debugToggleKeepOnTop()
    check(!LibraryStore.shared.settings.keepOnTop, "★ 菜单栏图标的开关能关掉置顶")
    check(!delegate.debugWindowLevelIsFloating, "托盘开关立即生效（回到 normal）")
    check(delegate.debugKeepOnTopMenuState == .off, "★ 「视图」菜单同步取消勾选")
    check(!delegate.debugSettingsKeepOnTopChecked, "★ 设置窗口复选框同步取消")

    // ---- 路径 3：设置窗口里改，菜单 / 托盘也要跟着变 ----
    LibraryStore.shared.updateSettings { $0.keepOnTop = true }
    delegate.debugReapplySettings()          // 设置窗口改完走的就是这条
    check(delegate.debugKeepOnTopMenuState == .on, "★ 设置窗口打开置顶后菜单打勾")
    check(delegate.debugStatusItemController.debugState(ofTitle: "窗口置顶") == .on,
          "★ 设置窗口打开置顶后菜单栏图标同步")
    check(delegate.debugWindowLevelIsFloating, "设置窗口的改动也立即生效")

    // ---- 只置顶主窗口：辅助窗口保持 normal，可见期间主窗口临时降级 ----
    delegate.showSettings(nil)
    check(!delegate.debugAuxWindowLevels.isEmpty, "已创建辅助窗口（设置窗口）")
    check(delegate.debugAuxWindowLevels.allSatisfy { $0 == .normal },
          "★ 辅助窗口不跟着置顶（设置 / 书架 / 书签 / 查找保持 normal）",
          "\(delegate.debugAuxWindowLevels)")
    check(!delegate.debugWindowLevelIsFloating,
          "★ 辅助窗口可见期间主窗口临时降级（否则设置会被置顶的书盖住）")

    delegate.debugCloseAuxWindows()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    check(delegate.debugWindowLevelIsFloating, "★ 关掉辅助窗口后主窗口恢复置顶")

    delegate.debugToggleKeepOnTopFromMenu()
    check(!delegate.debugWindowLevelIsFloating, "关掉置顶后回到 normal level")
    check(!LibraryStore.shared.settings.keepOnTop, "关掉后设置也回到 false")

    // 存档往返：重启后仍生效
    LibraryStore.shared.updateSettings { $0.keepOnTop = true }
    _ = LibraryStore.shared.save()
    let reloaded = LibraryStore(fileURL: LibraryStore.shared.fileURL)
    reloaded.load()
    check(reloaded.settings.keepOnTop, "★ 置顶开关写盘后重新加载仍然生效")

    log(failures == 0 ? "✅ 窗口置顶自检全部通过" : "❌ 窗口置顶自检失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

if earlyOpenSelftest {
    let cwd = FileManager.default.currentDirectoryPath
    let file = cwd + "/samples/古文观止.txt"
    FileHandle.standardError.write("模拟启动前的打开请求: \(file)\n".data(using: .utf8)!)
    // 此刻 must 还没建窗口
    _ = delegate.application(app, openFile: file)
    FileHandle.standardError.write("  openFile 回调已返回，窗口就绪=\(delegate.debugIsWindowReady)（应为 false）\n".data(using: .utf8)!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        let opened = delegate.debugCurrentBookPath ?? ""
        if opened.contains("古文观止") {
            FileHandle.standardError.write("✅ 启动前的打开请求被挂起并在窗口建好后正确打开\n".data(using: .utf8)!)
            exit(0)
        } else {
            FileHandle.standardError.write("❌ 启动前的打开请求丢了（当前=\(opened.isEmpty ? "无" : opened)）\n".data(using: .utf8)!)
            exit(8)
        }
    }
}

// ── 开发者工具：异步打开自检 ──
// 用法： Reader --open-async-selftest
// 保证「打开大文件时主线程不被解码/解析卡住」这条优化不回退：
//   1. open 立即返回  2. 加载中显示转圈  3. 后台完成后书才上屏
//   4. 连续快速打开 A→B，只有 B 生效（旧请求结果被丢弃）
if CommandLine.arguments.contains("--open-async-selftest") {
    var failures = 0
    func log(_ msg: String) {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    }
    func check(_ cond: Bool, _ name: String, _ detail: String = "") {
        log(cond ? "  ✅ \(name)" : "  ❌ \(name)\(detail.isEmpty ? "" : "（\(detail)）")")
        if !cond { failures += 1 }
    }

    let ad = AppDelegate()
    NSApp.delegate = ad
    ad.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    let cwd = FileManager.default.currentDirectoryPath
    let bookA = cwd + "/samples/古文观止.txt"
    let bookB = cwd + "/samples/古文观止-GBK.txt"

    log("--- 1) open 立即返回 ---")
    let t0 = Date()
    ad.open(url: URL(fileURLWithPath: bookA))
    let retMS = Date().timeIntervalSince(t0) * 1000
    check(retMS < 50, "open 调用立即返回（不等解码/解析）", String(format: "%.1fms", retMS))
    check(ad.debugIsOpeningBook, "加载中标记为 true")
    check(ad.debugIsLoadingIndicatorVisible, "加载中显示转圈指示器")

    log("--- 2) 后台完成后书才上屏 ---")
    let deadline = Date().addingTimeInterval(5)
    while ad.debugIsOpeningBook, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    check(!ad.debugIsOpeningBook, "加载完成（5 秒内）")
    check(!ad.debugIsLoadingIndicatorVisible, "加载完成后转圈停止")
    check(ad.debugCurrentBookPath == bookA, "当前书是刚打开的那本", ad.debugCurrentBookPath ?? "nil")
    check(ad.debugBookLen > 0, "正文已上屏", "units=\(ad.debugBookLen)")

    log("--- 3) 连续快速打开 A→B，只有 B 生效 ---")
    ad.open(url: URL(fileURLWithPath: bookA))
    ad.open(url: URL(fileURLWithPath: bookB))
    let deadline2 = Date().addingTimeInterval(5)
    while ad.debugIsOpeningBook, Date() < deadline2 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    check(!ad.debugIsOpeningBook, "第二轮加载完成")
    check(ad.debugCurrentBookPath == bookB,
          "最后打开的 B 生效（A 的过期结果被丢弃）", ad.debugCurrentBookPath ?? "nil")

    log(failures == 0 ? "✅ 异步打开自检全部通过" : "❌ 异步打开自检失败 \(failures) 项")
    exit(failures == 0 ? 0 : 1)
}

// ── 开发者工具：异步打开耗时基准 ──
// 用法： Reader --open-bench <book.txt>
// 输出 open 调用返回耗时、书真正上屏耗时（两次计时之间主线程只跑 RunLoop）。
// 注意：applicationDidFinishLaunching 会先把命令行里的书自动打开一次（warmup），
// 所以这里量的是**第二次**打开 —— 页缓存已热。冷读首开看 READER_OPEN_TIMING 第一组。
// 要量「用户真实首开」：直接 `READER_OPEN_TIMING=1 Reader <book>`，看第一组数字。
if let idx = CommandLine.arguments.firstIndex(of: "--open-bench"),
   CommandLine.arguments.count > idx + 1 {
    let ad = AppDelegate()
    NSApp.delegate = ad
    ad.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    // ⚠️ applicationDidFinishLaunching 会把命令行里第一个非 `-` 参数当成书直接打开。
    // 先把它等完，否则下面这次 open 会排在串行队列后面，测成「两次打开叠加」。
    let warmup = Date().addingTimeInterval(120)
    while ad.debugIsOpeningBook, Date() < warmup {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let path = CommandLine.arguments[idx + 1]
    let t0 = Date()
    ad.open(url: URL(fileURLWithPath: path))
    let retMS = Date().timeIntervalSince(t0) * 1000
    let deadline = Date().addingTimeInterval(120)
    while ad.debugIsOpeningBook, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let totalMS = Date().timeIntervalSince(t0) * 1000
    FileHandle.standardError.write(String(
        format: "open 返回 %.1f ms · 书真正上屏 %.1f ms（第二次打开·页缓存已热）· 总字数 %d · 章节 %d\n",
        retMS, totalMS, ad.debugBookLen, ad.debugChapterCount).data(using: .utf8)!)
    exit(ad.debugBookLen > 0 ? 0 : 1)
}

app.run()
