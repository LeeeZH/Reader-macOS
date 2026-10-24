import AppKit

// ── 开发工具一律用临时存档，绝不碰用户的真实 .cache.dat ──
// （命令行参数里出现任何 `--xxx` 工具开关时生效）
do {
    let devFlags: Set<String> = [
        "--render-page", "--render-library", "--render-settings", "--render-bookmarks",
        "--dump-pages", "--library-selftest", "--dump-touchbar",
        "--close-selftest", "--quit-selftest", "--early-open-selftest",
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
        for _ in 0..<pages { view.goNextPage() }
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
    ad.open(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
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
    ad.open(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
    ad.toggleEditMode(nil)
    log("  进入编辑模式: \(ad.debugEditModeActive ? "✅" : "❌")")
    ad.toggleEditMode(nil)
    log("  未改动退出: \(ad.debugEditModeActive ? "❌ 还在编辑" : "✅ 已退出（未弹保存框）")")

    log("--- 11) 沉浸模式（隐藏顶栏和底栏） ---")
    ad.open(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
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
    ad.open(url: URL(fileURLWithPath: cwd + "/samples/古文观止.txt"))
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

app.run()
