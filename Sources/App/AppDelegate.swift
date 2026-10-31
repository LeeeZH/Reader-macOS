import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate,
                         NSMenuItemValidation {

    private var window: NSWindow!
    private var readingView: ReadingView!
    private var statusLabel: NSTextField!
    private var libraryWindow: LibraryWindowController?
    private var autoPageMenuItem: NSMenuItem?
    private var editMenuItem: NSMenuItem?
    private var hideChromeMenuItem: NSMenuItem?
    private var dragStrip: WindowDragStrip?
    private var editorTextView: NSTextView?
    private var editorScrollView: NSScrollView?
    private var editOriginalText: String = ""
    var debugEditModeActive: Bool { editorTextView != nil }
    private let editShortcutName = "⌘E"
    /// 当前是否深色外观（编辑模式的文本框也要跟着配色）
    private var isDarkAppearance: Bool {
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private var settingsWindow: SettingsWindowController?
    private var bookmarkWindow: BookmarkWindowController?
    private var chapterSearchWindow: ChapterSearchWindowController?
    private var findWindow: FindWindowController?
    private let statusItemController = StatusItemController()
    private var globalHotKey: GlobalHotKey?
    private var autoPageTimer: Timer?
    /// 当前这轮自动翻页用的是哪套参数（改了就立刻重启定时器）
    private var autoPageRunningIntervalMS = -1
    private var autoPageRunningMode = -1

    private let library = LibraryStore.shared

    /// ⚠️ AppKit 的既定行为：用「打开方式」或带文件参数启动时，
    /// `application(_:openFile:)` 会在 `applicationDidFinishLaunching` **之前**被调用，
    /// 那时窗口还没建好。所以先挂起，等窗口就绪再打开。
    private var pendingFile: URL?
    private var isWindowReady = false
    /// 当前打开的书在本机的路径（用来判断它是否被从阅读列表里移除了）
    private var currentBookPath: String?

    /// 自检用只读探针
    var debugCurrentBookPath: String? { currentBookPath }
    var debugPageStart: Int { readingView?.pageStart ?? -1 }
    var debugAutoPageActive: Bool { autoPageTimer != nil }
    var debugAutoPageInterval: TimeInterval { autoPageInterval }
    var debugAutoPageRowMode: Bool { (library.settings.autoPageMode & 0x0F) == 0x01 }
    var debugOneLineHeight: CGFloat { readingView?.oneLineHeight ?? 0 }
    var debugOnePageHeight: CGFloat { readingView?.onePageHeight ?? 0 }
    var debugScrollOffset: CGFloat { readingView?.scrollOffset ?? -1 }
    var debugCanScrollForward: Bool { readingView?.canScrollForward ?? false }
    var debugSmoothSetting: Bool { library.settings.smoothScroll }
    var debugPageEnd: Int { readingView?.page.end ?? -1 }
    var debugBookLen: Int { readingView?.book?.units.count ?? -1 }
    /// 自检用：模拟「设置界面改了设置」这条路径
    func debugReapplySettings() { applySettingsToReader() }
    var debugHotKeyRegistered: Bool { globalHotKey != nil }
    var debugMenuBarInstalled: Bool { statusItemController.isInstalled }
    var debugLeftRightHideWired: Bool { readingView?.onToggleHideWindow != nil }
    var debugPageMode: Int { library.settings.pageMode }
    var debugTitleVisible: Bool { window?.titleVisibility == .visible }
    var debugCloseButtonHidden: Bool { window?.standardWindowButton(.closeButton)?.isHidden ?? false }
    var debugStatusLabelHidden: Bool { statusLabel?.isHidden ?? false }
    var debugDragStripInstalled: Bool { dragStrip != nil }
    var debugReadingViewHeight: CGFloat { readingView?.frame.height ?? 0 }
    var debugWindowHasShadow: Bool { window?.hasShadow ?? false }
    var debugWindowOpaque: Bool { window?.isOpaque ?? true }
    var debugIsWindowReady: Bool { isWindowReady }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.load()
        buildMenu()
        buildWindow()
        isWindowReady = true
        NSApp.activate(ignoringOtherApps: true)

        if library.recoveredBackupURL != nil {
            statusLabel.stringValue = "⚠️ 存档曾损坏，已备份原文件并从空白开始"
        }

        if let url = pendingFile {
            pendingFile = nil
            open(url: url)
        } else if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            open(url: URL(fileURLWithPath: path))
        } else {
            restoreLastBook()
        }

        applyWindowChrome()
        applyMenuBarAndHotKey()

        // 关窗自检：必须走 AppKit 的真实启动路径才会触发
        // _scheduleCheckForTerminateAfterLastWindowClosed，手动调
        // applicationDidFinishLaunching 是复现不出来的。
        // 正常退出自检：走 NSApp.terminate，会触发 applicationWillTerminate 和
        // 系统的窗口状态保存 —— 用来核对安装后到底会产生哪些文件
        if CommandLine.arguments.contains("--quit-selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                FileHandle.standardError.write("正在正常退出…\n".data(using: .utf8)!)
                NSApp.terminate(nil)
            }
        }

        if closeSelftestEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let w = self?.window else {
                    FileHandle.standardError.write("找不到主窗口\n".data(using: .utf8)!)
                    exit(9)
                }
                FileHandle.standardError.write("正在关闭主窗口: \(w.title)\n".data(using: .utf8)!)
                w.performClose(nil)
                // 关掉最后一个窗口后，applicationShouldTerminateAfterLastWindowClosed
                // 会让 AppKit 自动走 terminate: → applicationWillTerminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    FileHandle.standardError.write("❌ 窗口已关但进程没退出（预期会自动终止）\n".data(using: .utf8)!)
                    exit(8)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowFrame()
        library.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 支持把 txt 拖到 Dock 图标 / 用 Reader 打开
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if isWindowReady { open(url: url) } else { pendingFile = url }
        return true
    }

    // MARK: - 恢复上次阅读

    /// 对应原版 `OnCreate` 里的 `_Cache.get_item(0)`：打开最近阅读的那本
    private func restoreLastBook() {
        guard let item = library.mostRecent else {
            statusLabel.stringValue = "用 ⌘O 打开一个 TXT 文件"
            return
        }
        guard let url = BookPathResolver.resolve(stored: item.fileName) else {
            statusLabel.stringValue = "上次读的《\(item.displayName)》在本机找不到（⌘L 打开阅读列表重新定位）"
            return
        }
        open(url: url)
    }

    // MARK: - 窗口

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 440, height: 700)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Reader"
        window.minSize = NSSize(width: 260, height: 320)
        // ⚠️ 必须显式关掉。NSWindow.isReleasedWhenClosed 默认是 **true**，
        // 在 ARC 下 AppKit 关闭窗口时会额外发一次 release，把 ARC 自己那一个
        // 引用计数也减掉 → 窗口被释放，而我们的 window 属性变成野指针。
        //
        // 后果：关掉最后一个窗口 → AppKit 自动 terminate: →
        // applicationWillTerminate() 里读 window.frame 直接段错误（崩溃报告里是
        // EXC_BAD_ACCESS / objc_msgSend / AppDelegate.applicationWillTerminate）。
        // 另外三个辅助窗口一直设了 false，唯独主窗口漏了。
        window.isReleasedWhenClosed = false
        // 还原上次的窗口大小与位置（存在 .cache.dat 的 header.placement，与原版同字段）
        if let saved = library.mainWindowFrame(primaryScreenHeight: NSScreen.primaryHeight,
                                               screenFrames: NSScreen.screens.map { $0.visibleFrame }) {
            window.setFrame(saved, display: false)
        } else {
            window.center()
        }
        window.delegate = self

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        let statusH: CGFloat = 20
        // ⚠️ 状态栏必须先于阅读视图创建：addSubview 会触发 setFrameSize → 重排 →
        // onStatusChange，那时 statusLabel 若还是 nil 就会隐式解包崩溃。
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 8, y: 2, width: rect.width - 16, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.autoresizingMask = [.width]
        content.addSubview(statusLabel)

        readingView = ReadingView(frame: NSRect(x: 0, y: statusH, width: rect.width, height: rect.height - statusH))
        readingView.autoresizingMask = [.width, .height]
        readingView.settings = library.settings
        readingView.onStatusChange = { [weak self] s in self?.statusLabel?.stringValue = s }
        readingView.onTouchBarStatus = { text in ReaderTouchBar.shared.updateProgress(text) }
        readingView.enableFileDrop()
        readingView.onOpenFile = { [weak self] url in self?.open(url: url) }
        // 左右键一起按 = 隐藏/显示窗口（对应原版 MK_LBUTTON|MK_RBUTTON → ShowHideWindow）
        readingView.onToggleHideWindow = { [weak self] in self?.toggleWindowVisibility() }
        readingView.onMinimizeWindow = { [weak self] in self?.window?.miniaturize(nil) }
        content.addSubview(readingView)

        window.contentView = content

        // ── 触控栏（仅带 Touch Bar 的机型可见，其它机型上是安全空操作）──
        window.touchBar = ReaderTouchBar.shared.makeTouchBar(target: self)
        // 注意：这里**不**打开 NSTouchBar.isAutomaticCustomizeTouchBarMenuItemEnabled。
        // 那个开关会让系统自己往视图菜单插一项「自定义触控栏…」，
        // 而我们已经手动加了一项 —— 两个都开会重复。手动加的好处是位置确定、
        // 且在没有触控栏的机器上也能看到（点了只是没有可自定义的内容）。

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(readingView)
    }

    // MARK: - 打开文件

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .text, .log]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL, restoreOffset: Int? = nil) {
        // 换书过程中先摘掉进度回调，避免把 A 书的偏移写到 B 书头上
        readingView.onProgressChange = nil
        do {
            let data = try Data(contentsOf: url)
            let decoded = try TextDecoder.decode(data)
            let book = TextBook(fileURL: url, rawText: decoded.text, encodingName: decoded.encodingName)

            let settings = library.settings
            // 规则和默认值相同时不会重复解析（大书打开能省一次全量解析）
            book.applyChapterRule(settings.chapterRule)
            readingView.settings = settings
            readingView.book = book
            window.title = "\(book.displayName) — Reader"

            // 加入阅读列表（MRU 置顶；已存在则保留其进度）
            library.touch(fileName: url.path)
            currentBookPath = url.path
            let saved = library.mostRecent?.index ?? 0
            let target = restoreOffset ?? saved
            if target > 0, target < book.units.count {
                readingView.jump(to: target)
            }

            // 现在才接上进度回调
            readingView.onProgressChange = { [weak self] offset in
                self?.library.updateProgress(offset: offset, at: 0)
            }
            library.updateProgress(offset: readingView.page.start, at: 0)

            libraryWindow?.reload()
            bookmarkWindow?.update(book: book)
            chapterSearchWindow?.update(book: book, currentOffset: readingView.pageStart)
            // 换书了：查找结果按旧书的偏移算的，全部作废（查询词保留）
            findWindow?.update(book: book)
            window.makeFirstResponder(readingView)

            if settings.didFallbackFont {
                statusLabel.stringValue = "字体「\(settings.fontName)」本机没有，已回退到 \(settings.renderFontName)"
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "打不开这个文件"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    /// 关掉当前打开的书，回到空状态。
    ///
    /// 阅读列表里把这本书移除、或整个清空之后**必须**调它，否则会留下错乱状态：
    /// 书架已经空了，阅读界面还在显示那本书，而且进度再也写不进去
    /// （`updateProgress` 找不到对应的条目，静默丢弃）。
    private func closeCurrentBook() {
        readingView.onProgressChange = nil
        readingView.book = nil
        bookmarkWindow?.update(book: nil)
        chapterSearchWindow?.update(book: nil, currentOffset: 0)
        findWindow?.update(book: nil)
        currentBookPath = nil
        window.title = "Reader"
    }

    // MARK: - 触控栏动作
    // 触控栏按钮的 target 是 AppDelegate，selector 必须是 @objc 且不能是 private

    @objc func tbPrevPage(_ sender: Any?)      { readingView.goPrevPage() }
    @objc func tbNextPage(_ sender: Any?)      { readingView.goNextPage() }
    @objc func tbPrevChapter(_ sender: Any?)   { readingView.goPrevChapter() }
    @objc func tbNextChapter(_ sender: Any?)   { readingView.goNextChapter() }
    @objc func tbOpenFile(_ sender: Any?)      { openDocument(sender) }
    @objc func tbLibrary(_ sender: Any?)       { showLibrary(sender) }
    @objc func tbExportArchive(_ sender: Any?) { exportArchive(sender) }
    @objc func tbRevealArchive(_ sender: Any?) { revealArchive(sender) }
    @objc func tbFontSmaller(_ sender: Any?)   { adjustFontSize(-1) }
    @objc func tbFontLarger(_ sender: Any?)    { adjustFontSize(+1) }
    @objc func tbAddBookmark(_ sender: Any?)   { addBookmarkAtCurrentPage() }

    /// 在当前页首加一个书签（对应原版 Ctrl+M）
    func addBookmarkAtCurrentPage() {
        guard readingView.book != nil else { return }
        let offset = readingView.page.start
        if library.addBookmark(offset: offset, at: 0) {
            statusLabel.stringValue = "已加书签 · 第 \(offset) 字（⌘M 也可以）"
            bookmarkWindow?.reload()
        } else {
            statusLabel.stringValue = "当前位置已经有书签了"
        }
    }

    /// 调整字号（对应原版 Ctrl+= / Ctrl+-）
    private func adjustFontSize(_ delta: CGFloat) {
        guard readingView.book != nil else { return }
        library.updateSettings { s in
            s.fontPointSize = max(8, min(72, s.fontPointSize + delta))
        }
        let settings = library.settings
        readingView.settings = settings
        statusLabel.stringValue = "字号 \(Int(settings.fontPointSize)) pt"
    }

    // MARK: - 沉浸模式

    @objc func toggleHideChrome(_ sender: Any?) {
        let next = !library.settings.hideChrome
        library.updateSettings { $0.hideChrome = next }
        applyWindowChrome()
        settingsWindow?.syncFromSettings()
    }

    // MARK: - 编辑模式（对应原版 Ctrl+E）

    /// 编辑模式：在阅读区盖一层可编辑的 NSTextView。
    /// 退出时如果改过，提示「保存 / 放弃 / 取消」，保存则写回原文件。
    @objc func toggleEditMode(_ sender: Any?) {
        if editorTextView != nil {
            exitEditMode()
        } else {
            enterEditMode()
        }
    }

    private func enterEditMode() {
        guard let book = readingView.book else {
            NSSound.beep()
            statusLabel?.stringValue = "先打开一本书再进入编辑模式"
            return
        }
        editOriginalText = book.rawText

        let scroll = NSScrollView(frame: readingView.frame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let s = library.settings
        tv.font = NSFont(name: s.renderFontName, size: s.fontPointSize)
            ?? NSFont.systemFont(ofSize: s.fontPointSize)
        tv.textColor = NSColor(cgColor: s.renderTextColor(dark: isDarkAppearance)) ?? .labelColor
        tv.backgroundColor = NSColor(cgColor: s.renderBackgroundColor(dark: isDarkAppearance)) ?? .textBackgroundColor
        tv.string = book.rawText

        scroll.documentView = tv
        window.contentView?.addSubview(scroll)
        editorTextView = tv
        editorScrollView = scroll
        editMenuItem?.state = .on
        statusLabel?.stringValue = "编辑模式 · 改完再按 \(editShortcutName) 退出"
        window.makeFirstResponder(tv)
    }

    private func exitEditMode() {
        guard let tv = editorTextView else { return }
        let newText = tv.string
        let changed = (newText != editOriginalText)

        if changed {
            let a = NSAlert()
            a.messageText = "保存对文本的修改？"
            a.informativeText = "会直接写回原文件（保持原编码 \(readingView.book?.encodingName ?? "UTF-8")），此操作不可撤销。"
            a.addButton(withTitle: "保存")
            a.addButton(withTitle: "放弃修改")
            a.addButton(withTitle: "继续编辑")
            let resp = a.runModal()
            if resp == .alertThirdButtonReturn { return }        // 继续编辑
            if resp == .alertFirstButtonReturn { saveEditedText(newText) }
        }

        editorTextView = nil
        editorScrollView?.removeFromSuperview()
        editorScrollView = nil
        editMenuItem?.state = .off
        window.makeFirstResponder(readingView)
    }

    private func saveEditedText(_ text: String) {
        guard let book = readingView.book else { return }
        guard let data = TextDecoder.encode(text, encodingName: book.encodingName) else {
            let a = NSAlert()
            a.messageText = "保存失败"
            a.informativeText = "文本里有 \(book.encodingName) 表示不了的字符，请先改掉它们。"
            a.runModal()
            return
        }
        let offset = min(readingView.pageStart, text.utf16.count)
        do {
            try data.write(to: book.fileURL, options: .atomic)
            open(url: book.fileURL, restoreOffset: offset)
            statusLabel?.stringValue = "已保存到 \(book.fileURL.lastPathComponent)（\(data.count) 字节）"
        } catch {
            let a = NSAlert()
            a.messageText = "写入失败"
            a.informativeText = "\(error)"
            a.runModal()
        }
    }

    // MARK: - 菜单栏图标 / 全局热键 / 自动翻页

    /// 按设置装上或卸下菜单栏图标与全局热键
    private func applyMenuBarAndHotKey() {
        let s = library.settings

        if s.menuBarIcon {
            statusItemController.install()
            statusItemController.onShowHide = { [weak self] in self?.toggleWindowVisibility() }
            statusItemController.onOpenFile = { [weak self] in
                guard let self = self else { return }
                self.showMainWindow()
                self.openDocument(nil)
            }
            statusItemController.onShowLibrary = { [weak self] in
                self?.showLibrary(nil)
            }
            statusItemController.onShowSettings = { [weak self] in
                guard let self = self else { return }
                self.showMainWindow()
                self.showSettings(nil)
            }
            statusItemController.onToggleAutoPage = { [weak self] in self?.toggleAutoPage(nil) }
            statusItemController.isAutoPageOn = { [weak self] in self?.autoPageTimer != nil }
            statusItemController.onToggleChrome = { [weak self] in
                // 窗口藏着的时候点它，先叫回来再切——否则改了也看不见
                self?.showMainWindow()
                self?.toggleHideChrome(nil)
            }
            statusItemController.isChromeHidden = { [weak self] in
                self?.library.settings.hideChrome ?? false
            }
        } else {
            statusItemController.uninstall()
        }

        if s.globalHotKey {
            if globalHotKey == nil {
                globalHotKey = GlobalHotKey { [weak self] in self?.toggleWindowVisibility() }
            }
            if globalHotKey?.register() != true {
                // 被别的 App 占用 —— 不致命，只是热键用不了
                statusLabel?.stringValue = "⚠️ 全局热键 \(GlobalHotKey.displayName) 被其他 App 占用"
            }
        } else {
            globalHotKey?.unregister()
            globalHotKey = nil
        }
    }

    /// 显示/隐藏阅读窗口。全局热键和菜单栏图标都调它。
    ///
    /// 用 `NSApp.hide` 而不是 `window.orderOut`：藏完还要能一键回来，
    /// hide 会同时隐藏菜单栏之外的所有窗口并让出焦点，是最贴近「老板键」的行为。
    @objc func toggleWindowVisibility() {
        if NSApp.isHidden || !(window?.isVisible ?? false) {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            NSApp.hide(nil)
        }
    }

    private func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 自动翻页一次推进的间隔。
    /// `autopage_mode` 高半字节 = 0x10 时是原版的「按字数」模式，
    /// 那时 `uElapse` 表示「每字符毫秒数」，整页耗时要乘本页字数。
    private var autoPageInterval: TimeInterval {
        let s = library.settings
        let base = Double(max(1000, s.autoPageIntervalMS))     // 最小 1 秒，防呆
        if (s.autoPageMode & 0xF0) == 0x10 {
            let chars = max(1, readingView?.page.lines.reduce(0) { $0 + $1.chars.count } ?? 1)
            return max(0.8, base * Double(chars) / 3000.0 * 10.0)
        }
        return base / 1000.0
    }

    @objc func toggleAutoPage(_ sender: Any?) {
        if autoPageTimer != nil {
            stopAutoPage()
            statusLabel?.stringValue = "已停止自动翻页"
            return
        }
        guard readingView?.book != nil else {
            NSSound.beep()
            statusLabel?.stringValue = "先打开一本书再开自动翻页"
            return
        }
        startAutoPage()
    }

    private func startAutoPage() {
        stopAutoPage()
        scheduleAutoPageTick()
        settingsWindow?.refreshAutoPageState()
        updateAutoPageStatus()
    }

    /// 排下一次自动翻页。
    ///
    /// ⚠️ 用**非重复**定时器、每次触发后重新排一次，而不是
    /// `Timer(repeats: true)` 一把梭。原因：
    ///   · 重复定时器的间隔在建的时候就定死了，改设置不会生效
    ///     （用户反馈过：「开着自动翻页时间隔和方式改了不管用，得关掉重开」）；
    ///   · 「按字数」模式下间隔 = 每字毫秒 × 当前页字数，本来就该每页重算。
    private func scheduleAutoPageTick() {
        // ⚠️ 先把旧的取消掉。改设置时我们是「重新排一次」，
        // 如果只建新的不管旧的，两个定时器会同时在跑 —— 旧的那个还在用老间隔。
        autoPageTimer?.invalidate()
        autoPageTimer = nil

        let interval = autoPageInterval
        // 记下这次用的是哪套参数，供 applySettingsToReader 判断要不要立刻重启
        autoPageRunningIntervalMS = library.settings.autoPageIntervalMS
        autoPageRunningMode = library.settings.autoPageMode

        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.autoPageTick()
        }
        RunLoop.main.add(t, forMode: .common)
        autoPageTimer = t
    }

    /// 一次自动翻页：每次都重新读当前设置，改了立刻生效
    private func autoPageTick() {
        guard let view = readingView, view.book != nil else {
            stopAutoPage()
            return
        }
        // 到底了就停，别空转。
        // 注意：平滑滚动是异步的（pageStart 要等动画走完才变），
        // 所以不能用「pageStart 有没有变」判断到底，要看还能不能往后走。
        guard view.canScrollForward else {
            stopAutoPage()
            statusLabel?.stringValue = "自动翻页已到底，停止"
            return
        }

        let rowMode = (library.settings.autoPageMode & 0x0F) == 0x01   // apm_line
        // 默认走平滑滚动（前提是用户没关掉「平滑滚动」）：
        // 瞬移一大页很跳，滑过去舒服得多。
        if library.settings.smoothScroll {
            view.smoothScroll(by: rowMode ? view.oneLineHeight : view.onePageHeight)
        } else if rowMode {
            view.goNextLines(1)
        } else {
            view.goNextPage()
        }

        scheduleAutoPageTick()
        updateAutoPageStatus()
    }

    private func updateAutoPageStatus() {
        guard autoPageTimer != nil else { return }
        let rowMode = (library.settings.autoPageMode & 0x0F) == 0x01
        statusLabel?.stringValue = String(format: "自动翻页中 · 每 %.1f 秒%@",
                                          autoPageInterval, rowMode ? "滚一行" : "翻一页")
    }

    private func stopAutoPage() {
        autoPageTimer?.invalidate()
        autoPageTimer = nil
        refreshAutoPageMenuState()
        settingsWindow?.refreshAutoPageState()
    }

    private func refreshAutoPageMenuState() {
        autoPageMenuItem?.state = (autoPageTimer != nil) ? .on : .off
    }

    // MARK: - 书签

    @objc func showBookmarks(_ sender: Any?) {
        if bookmarkWindow == nil {
            bookmarkWindow = BookmarkWindowController(store: library) { [weak self] offset in
                guard let self = self else { return }
                self.readingView.jump(to: offset)
                self.window.makeKeyAndOrderFront(nil)
            }
        }
        bookmarkWindow?.update(book: readingView.book)
        bookmarkWindow?.show()
    }

    // MARK: - 章节搜索 / 跳转

    /// 「跳转到章节…」：搜索框支持章节号和标题模糊匹配。
    ///
    /// 菜单栏「目录」第一项和快捷键 ⌘J 都走这里。目录菜单适合按位置翻，
    /// 几千章的长篇里想直接找某一章、或只记得半句标题时，搜索更快。
    @objc func showChapterSearch(_ sender: Any?) {
        guard let book = readingView.book, !book.chapters.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "没有可跳转的章节 —— 先打开一本书"
            return
        }
        if chapterSearchWindow == nil {
            chapterSearchWindow = ChapterSearchWindowController()
            chapterSearchWindow?.onJump = { [weak self] chapterIndex in
                guard let self = self,
                      let book = self.readingView.book,
                      book.chapters.indices.contains(chapterIndex) else { return }
                self.readingView.jump(to: book.chapters[chapterIndex].index)
                self.window.makeKeyAndOrderFront(nil)
            }
        }
        chapterSearchWindow?.show(book: book, currentOffset: readingView.pageStart)
    }

    // MARK: - 全文搜索（⌘F / ⌘G / ⇧⌘G）

    /// 「查找…」（⌘F）：全文搜索面板。
    ///
    /// 交互约定（用户提过两次，别再改回去）：
    ///   · 打开面板永远是**空白**的一次查找 —— 不带上次的查询词；
    ///   · 搜到结果只列出来，**不会自动跳页**；跳转要用户双击 / 回车 / 点「跳转」。
    ///
    /// 编辑模式下把 ⌘F 让给 NSTextView 自己的查找面板：那时光标在文本框里，
    /// 而且正文可能已经改过 —— 按旧偏移跳转只会落到错误的位置。
    @objc func showFind(_ sender: Any?) {
        if let tv = editorTextView {
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            window.makeFirstResponder(tv)
            tv.performTextFinderAction(item)
            return
        }
        guard let book = readingView.book else {
            NSSound.beep()
            statusLabel.stringValue = "先打开一本书再查找（⌘O）"
            return
        }
        ensureFindWindow()
        findWindow?.show(book: book, currentOffset: readingView.pageStart,
                         caseSensitive: library.settings.findCaseSensitive)
    }

    /// 「查找下一个」（⌘G）：面板开着就在结果里往下走并跳过去；
    /// 面板没开时只打开一个空白面板（关掉面板 = 本次查找结束，不记查询词）。
    @objc func findNext(_ sender: Any?) {
        guard let book = readingView.book else {
            NSSound.beep()
            statusLabel.stringValue = "先打开一本书再查找（⌘O）"
            return
        }
        ensureFindWindow()
        if findWindow?.window.isVisible == true {
            findWindow?.nextHit()
            return
        }
        findWindow?.show(book: book, currentOffset: readingView.pageStart,
                         caseSensitive: library.settings.findCaseSensitive)
    }

    /// 「查找上一个」（⇧⌘G）：同上，方向相反。
    @objc func findPrevious(_ sender: Any?) {
        guard let book = readingView.book else {
            NSSound.beep()
            statusLabel.stringValue = "先打开一本书再查找（⌘O）"
            return
        }
        ensureFindWindow()
        if findWindow?.window.isVisible == true {
            findWindow?.previousHit()
            return
        }
        findWindow?.show(book: book, currentOffset: readingView.pageStart,
                         caseSensitive: library.settings.findCaseSensitive)
    }

    /// 懒创建「查找」面板并接好回调（和章节搜索面板同一套写法）。
    private func ensureFindWindow() {
        guard findWindow == nil else { return }
        let wc = FindWindowController()
        // 只有用户主动跳转（双击 / 回车 / 「跳转」/ ⌘G）才会走到这里
        wc.onJump = { [weak self] offset, hitIndex in
            guard let self else { return }
            self.readingView.jump(to: offset)
            // 焦点还给阅读视图：否则方向键 / 空格会被结果表格吃掉，翻不了页
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.readingView)
            let total = self.findWindow?.hitCount ?? 0
            if total > 0 {
                self.statusLabel.stringValue =
                    "第 \(max(0, hitIndex) + 1) / \(total) 处（⌘G 下一个，⇧⌘G 上一个）"
            }
        }
        wc.onHighlight = { [weak self] hits, current in
            guard let self else { return }
            let ranges = hits.map { $0.index..<($0.index + $0.length) }
            let currentRange: Range<Int>? =
                (current >= 0 && current < ranges.count) ? ranges[current] : nil
            self.readingView.setSearchHighlights(ranges, current: currentRange)
        }
        wc.onClose = { [weak self] in
            guard let self else { return }
            self.readingView.clearSearchHighlights()
            self.window.makeFirstResponder(self.readingView)
        }
        wc.onCaseSensitiveChange = { [weak self] on in
            self?.library.updateSettings { $0.findCaseSensitive = on }
        }
        findWindow = wc
    }

    // MARK: - 显示设置

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let wc = SettingsWindowController(store: library) { [weak self] in
                self?.applySettingsToReader()
            }
            wc.onToggleAutoPage = { [weak self] in self?.toggleAutoPage(nil) }
            wc.isAutoPageOn = { [weak self] in self?.autoPageTimer != nil }
            settingsWindow = wc
        }
        settingsWindow?.show()
    }

    /// 统一处理窗口外观：透明（alpha）、顶栏、底栏、拖动条。
    ///
    /// 只调阅读视图的绘制是不够的：NSWindow 默认 `isOpaque = true` 且有不透明底色，
    /// 必须一起关掉，否则背景透明的那层会被窗口底色盖住。
    private func applyWindowChrome() {
        guard let window = window, let content = window.contentView else { return }
        let settings = library.settings
        let translucent = settings.alpha < 255
        let hide = settings.hideChrome

        // ── 窗口透明 ──
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor

        // ⚠️ 背景透明时**必须关掉窗口阴影**。
        // isOpaque = false 的窗口，macOS 是按窗口的 alpha 蒙版去算阴影的；
        // 我们把背景调透明之后只剩文字不透明，阴影就变成「文字的轮廓」，
        // 看起来就是每个字后面拖着一层虚影 —— 用户形容成「像看强光后视网膜上的残留」。
        // 顺带好处：滚动时不会每帧重算阴影，减少掉帧。
        window.hasShadow = !translucent

        // ── 顶栏：隐藏标题文字和三个窗口按钮 ──
        // 透明模式下标题文字也藏掉：它在透明标题栏上是一串不透明的白字
        // （深色外观时），看起来同样像「残留」。
        window.titleVisibility = (hide || translucent) ? .hidden : .visible
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hide
        }
        if hide {
            // 让内容一直铺到窗口顶部（否则标题栏那 28pt 还是空着）
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = hide || translucent

        // ── 底栏：状态文字 + 阅读区高度 ──
        statusLabel?.isHidden = hide
        let statusH: CGFloat = hide ? 0 : 20
        let b = content.bounds
        readingView?.frame = NSRect(x: 0, y: statusH, width: b.width, height: b.height - statusH)

        // ── 拖动条：隐藏标题栏后总得能移动窗口 ──
        if hide {
            if dragStrip == nil {
                let strip = WindowDragStrip(frame: .zero)
                strip.autoresizingMask = [.width, .minYMargin]
                content.addSubview(strip)
                dragStrip = strip
            }
            dragStrip?.frame = NSRect(x: 0, y: b.height - 26, width: b.width, height: 26)
        } else {
            dragStrip?.removeFromSuperview()
            dragStrip = nil
        }

        // 阴影是按窗口 alpha 蒙版算的，换了透明度必须让它重算，
        // 否则会残留上一帧的阴影形状。
        window.invalidateShadow()

        hideChromeMenuItem?.state = hide ? .on : .off
        readingView?.needsDisplay = true
    }

    /// 设置改动后立刻作用到阅读界面
    private func applySettingsToReader() {
        applyWindowChrome()
        applyMenuBarAndHotKey()
        let s = library.settings

        // 自动翻页正在跑的时候，改了间隔或方式要**立刻**生效，不用关掉重开
        if autoPageTimer != nil,
           s.autoPageIntervalMS != autoPageRunningIntervalMS || s.autoPageMode != autoPageRunningMode {
            scheduleAutoPageTick()
        }
        // 章节解析规则变了要先重新解析章节，再重排 —— 否则标题判定用的是旧章节表。
        // ⚠️ 只有规则真的变了才重解析：设置窗口的滑块是连续触发的，字号 / 行距 / 透明度
        //    这些改动跟章节无关，无条件解析全书会让长篇小说的设置面板每拖一下卡一秒多。
        if let book = readingView.book, book.chapterRule != s.chapterRule {
            book.applyChapterRule(s.chapterRule)
            // 章节表变了，搜索面板要同步（没显示时只记下来）
            chapterSearchWindow?.update(book: book, currentOffset: readingView.pageStart)
            // 全文搜索命中里的「第几章」也是按旧章节表算的
            findWindow?.update(book: book)
        }
        readingView.settings = s
    }

    // MARK: - 窗口尺寸记忆

    private func saveWindowFrame() {
        guard let w = window, w.styleMask.contains(.titled) else { return }
        library.setMainWindowFrame(w.frame, primaryScreenHeight: NSScreen.primaryHeight)
    }

    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveWindowFrame() }

    /// 关窗的瞬间就把尺寸位置落盘。
    /// 这时窗口一定还活着，比拖到 applicationWillTerminate 再读安全得多。
    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
    }

    // MARK: - 菜单动作

    @objc func nextPage(_ sender: Any?) { readingView.goNextPage() }
    @objc func prevPage(_ sender: Any?) { readingView.goPrevPage() }
    @objc func nextChapter(_ sender: Any?) { readingView.goNextChapter() }
    @objc func prevChapter(_ sender: Any?) { readingView.goPrevChapter() }

    @objc func showLibrary(_ sender: Any?) {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController(store: library) { [weak self] item in
                guard let self = self else { return }
                let url = URL(fileURLWithPath: item.fileName)
                self.open(url: url, restoreOffset: item.index)
                // 把主窗口提到前面 —— 书架窗口刚被 orderOut，但主窗口可能还在后面
                self.window.makeKeyAndOrderFront(nil)
            }
            // 移除 / 清空如果影响到正在读的那本，阅读界面要同步关掉
            libraryWindow?.onBookRemoved = { [weak self] path in
                guard let self = self, self.currentBookPath == path else { return }
                self.closeCurrentBook()
            }
            libraryWindow?.onAllRemoved = { [weak self] in
                self?.closeCurrentBook()
            }
        }
        libraryWindow?.show()
    }

    /// 把存档在访达里显示出来。
    /// 存档落在 ~/Library/Application Support/Reader/ 下，而 ~/Library 在 Finder 里
    /// 默认是隐藏的，.cache.dat 又是点开头的隐藏文件 —— 不给个入口用户根本找不到。
    @objc func revealArchive(_ sender: Any?) {
        let url = library.fileURL
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 还没生成过：先把目录建出来再打开
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
        statusLabel.stringValue = "存档位置：\(url.path)（已按 ⌘⇧. 可显示隐藏文件）"
    }

    /// 导出存档，用于带回到 Windows 版 Reader（放到它 exe 同目录即可）
    @objc func exportArchive(_ sender: Any?) {
        library.save()   // 先落盘，保证导出的是最新状态
        let panel = NSSavePanel()
        panel.title = "导出 Reader 存档"
        panel.message = "导出的文件名为 .cache.dat。放回 Windows 版 Reader 的 exe 同目录即可继续阅读。"
        panel.nameFieldStringValue = ".cache.dat"
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: library.fileURL, to: dst)
            statusLabel.stringValue = "已导出存档到：\(dst.path)"
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "导出失败"
            a.informativeText = "\(error)"
            a.runModal()
        }
    }

    /// 把存档路径复制到剪贴板（方便发给别人或粘到终端）
    @objc private func copyArchivePath(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(library.fileURL.path, forType: .string)
        statusLabel.stringValue = "已复制存档路径：\(library.fileURL.path)"
    }

    @objc private func menuAddBookmark(_ sender: Any?) { addBookmarkAtCurrentPage() }
    @objc private func menuFontLarger(_ sender: Any?) { adjustFontSize(+1) }
    @objc private func menuFontSmaller(_ sender: Any?) { adjustFontSize(-1) }

    @objc private func jumpToChapter(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let book = readingView.book,
              item.tag >= 0, item.tag < book.chapters.count else { return }
        readingView.jump(to: book.chapters[item.tag].index)
    }

    // MARK: - 关于

    /// 「关于 Reader」：macOS 系统标准面板。
    ///
    /// 面板本身只会自动显示 **图标 + 应用名 + 版本号**，这三样都来自
    /// `Resources/Info.plist`（`CFBundleIconFile` / `CFBundleName` /
    /// `CFBundleShortVersionString` + `CFBundleVersion`）。
    /// 想再往里加东西，只有两个入口：
    ///   · `NSHumanReadableCopyright`（Info.plist）—— 最底层那行灰色小字；
    ///   · `NSAboutPanelOptionCredits`（下面这段）—— 版本号下面的富文本，
    ///     支持换行、居中和 `https` 超链接，就是这里能写的「别的东西」。
    /// 再复杂（按钮、检查更新、滚动长文）标准面板做不到，得自建 `NSWindow`。
    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: aboutCredits(),
        ])
    }

    /// 关于面板里版本号下方的说明文字 —— 想改文案就改这里。
    ///
    /// ⚠️ 面板留给这段文字的高度只有 60 多 pt（11pt 字体约 4 行），
    /// 写超了会被裁掉／出现滚动条，加行前先估一下高度。
    private func aboutCredits() -> NSAttributedString {
        let credits = NSMutableAttributedString()

        /// 追加一行；`link` 非空时这一行是可点击的网址（点它用默认浏览器打开）。
        /// 最后一行不补换行 —— 补了会多出一个空行，把内容顶出可视区。
        func line(_ text: String, link: URL? = nil, spaceAfter: CGFloat = 0, isLast: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacing = spaceAfter
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: link == nil ? NSColor.labelColor : NSColor.linkColor,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: isLast ? text : text + "\n",
                                              attributes: attributes))
        }

        // 应用名 / 版本号由系统从 Info.plist 读出来自动显示，这里不用重复写
        line("github.com/LeeeZH/Reader-macOS",
             link: URL(string: "https://github.com/LeeeZH/Reader-macOS")!)
        line("Apple Silicon · macOS 13+", spaceAfter: 6)
        line("基于 binbyu/Reader（原作者 Binbin Yu）")

        // 上游原项目（Windows 版）的链接
        line("github.com/binbyu/Reader",
             link: URL(string: "https://github.com/binbyu/Reader")!, isLast: true)
        return credits
    }

    // MARK: - 菜单

    private var tocMenu: NSMenu?

    private func buildMenu() {
        let main = NSMenu()

        // --- App ---
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "关于 Reader", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "显示设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Reader", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // --- 文件 ---
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")

        let openItem = NSMenuItem(title: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        let libItem = NSMenuItem(title: "阅读列表", action: #selector(showLibrary(_:)), keyEquivalent: "l")
        libItem.target = self
        fileMenu.addItem(libItem)

        fileMenu.addItem(.separator())
        let revealItem = NSMenuItem(title: "在访达中显示存档",
                                    action: #selector(revealArchive(_:)), keyEquivalent: "s")
        revealItem.keyEquivalentModifierMask = [.command, .shift]
        revealItem.target = self
        fileMenu.addItem(revealItem)

        let copyPathItem = NSMenuItem(title: "复制存档路径",
                                      action: #selector(copyArchivePath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        fileMenu.addItem(copyPathItem)

        let exportItem = NSMenuItem(title: "导出存档…",
                                    action: #selector(exportArchive(_:)), keyEquivalent: "")
        exportItem.target = self
        fileMenu.addItem(exportItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // --- 阅读 ---
        let readItem = NSMenuItem()
        main.addItem(readItem)
        let readMenu = NSMenu(title: "阅读")

        let prev = NSMenuItem(title: "上一页", action: #selector(prevPage(_:)), keyEquivalent: "\u{F702}")
        prev.target = self
        readMenu.addItem(prev)
        let next = NSMenuItem(title: "下一页", action: #selector(nextPage(_:)), keyEquivalent: "\u{F703}")
        next.target = self
        readMenu.addItem(next)
        readMenu.addItem(.separator())

        // ⚠️ 原版用 Ctrl+←/→ 切章节，但 macOS 上 ⌃←/→ 已被系统占用（切换 Space），
        //    所以改用 ⌘↑ / ⌘↓
        let pch = NSMenuItem(title: "上一章", action: #selector(prevChapter(_:)), keyEquivalent: "\u{F700}")
        pch.keyEquivalentModifierMask = [.command]
        pch.target = self
        readMenu.addItem(pch)
        let nch = NSMenuItem(title: "下一章", action: #selector(nextChapter(_:)), keyEquivalent: "\u{F701}")
        nch.keyEquivalentModifierMask = [.command]
        nch.target = self
        readMenu.addItem(nch)

        readMenu.addItem(.separator())
        let mark = NSMenuItem(title: "添加书签", action: #selector(menuAddBookmark(_:)), keyEquivalent: "m")
        mark.target = self
        readMenu.addItem(mark)

        let hideChrome = NSMenuItem(title: "沉浸模式（隐藏顶栏和底栏）",
                                    action: #selector(toggleHideChrome(_:)),
                                    keyEquivalent: "B")
        hideChrome.keyEquivalentModifierMask = [.command, .shift]
        hideChrome.target = self
        hideChromeMenuItem = hideChrome
        readMenu.addItem(hideChrome)

        let editMode = NSMenuItem(title: "编辑模式", action: #selector(toggleEditMode(_:)), keyEquivalent: "e")
        editMode.target = self
        editMenuItem = editMode
        readMenu.addItem(editMode)
        readMenu.addItem(.separator())

        let autoPage = NSMenuItem(title: "自动翻页", action: #selector(toggleAutoPage(_:)), keyEquivalent: "A")
        autoPage.keyEquivalentModifierMask = [.command, .shift]
        autoPage.target = self
        autoPageMenuItem = autoPage
        readMenu.addItem(autoPage)
        readMenu.addItem(.separator())

        let marks = NSMenuItem(title: "书签…", action: #selector(showBookmarks(_:)), keyEquivalent: "b")
        marks.target = self
        readMenu.addItem(marks)
        readMenu.addItem(.separator())

        // 全文搜索：⌘F 是 macOS 上「查找」的约定键位，全屏让给 ⌃⌘F
        // （系统自带的「进入全屏幕」也是 ⌃⌘F，肌肉记忆一致）。
        // 老版本把 ⌘F 用作全屏，README 里还专门为这件事写了道歉 —— 这次一并修掉。
        let find = NSMenuItem(title: "查找…", action: #selector(showFind(_:)), keyEquivalent: "f")
        find.target = self
        readMenu.addItem(find)
        let findNextItem = NSMenuItem(title: "查找下一个",
                                      action: #selector(findNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        readMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: "查找上一个",
                                      action: #selector(findPrevious(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        readMenu.addItem(findPrevItem)
        readMenu.addItem(.separator())

        let zoomIn = NSMenuItem(title: "放大字号", action: #selector(menuFontLarger(_:)), keyEquivalent: "=")
        zoomIn.target = self
        readMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "缩小字号", action: #selector(menuFontSmaller(_:)), keyEquivalent: "-")
        zoomOut.target = self
        readMenu.addItem(zoomOut)

        readItem.submenu = readMenu

        // --- 目录 ---
        // 目录从「阅读」的二级菜单提到菜单栏一级：长篇小说动辄几千章，
        // 藏在二级菜单里不好找。菜单内容在 `menuNeedsUpdate` 里按需重建 ——
        // 每开一本书 / 改一次设置就建几千个 NSMenuItem 会卡主线程
        // （设置里的行距、透明度都是拖动即改的滑块）。
        let tocItem = NSMenuItem()
        main.addItem(tocItem)
        let tocMenu = NSMenu(title: "目录")
        tocMenu.delegate = self
        tocItem.submenu = tocMenu
        self.tocMenu = tocMenu
        // 先放占位项：空子菜单会被 AppKit 当成不可用，用户根本没机会点开触发刷新
        rebuildTOCMenu()

        // --- 视图 ---
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        let customize = NSMenuItem(title: "自定义触控栏…",
                                   action: #selector(NSApplication.toggleTouchBarCustomizationPalette(_:)),
                                   keyEquivalent: "")
        viewMenu.addItem(customize)
        viewMenu.addItem(.separator())
        // ⌘F 已经给「查找」了（macOS 的通用约定），全屏沿用系统标准的 ⌃⌘F
        let fullScreen = NSMenuItem(title: "进入全屏幕",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu

        // --- 窗口 ---
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }

    // MARK: - 目录菜单

    /// 用户每次点开「目录」都会先走这里，按当前书重建整个菜单。
    ///
    /// 只在真正要显示时建：章节可能几千条，打开书 / 拖动设置滑块时
    /// 没必要提前建一遍。顺便让「当前章打勾」永远是最新的
    /// （翻了几页之后再打开目录，勾会跟着走）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tocMenu else { return }
        rebuildTOCMenu()
    }

    /// 重建「目录」菜单 —— **列出全书章节，不设数量上限**。
    ///
    /// 旧版只列前 300 章，几千章的长篇小说从第 301 章起在目录里点不到。
    ///
    /// 菜单打开时从**当前正在读的章节**开始列（旧行为总是从第 1 章开始，
    /// 读到两千章的人得先滚两千行）。当前章之前的章节收进顶部的
    /// 「前面的章节」子菜单，平铺部分的第一项就是当前章。
    private func rebuildTOCMenu() {
        guard let tocMenu else { return }
        tocMenu.removeAllItems()

        // 「跳转到章节…」固定在目录最上面：几千章的书，输入比滚动快。
        // ⌘J 也能直接呼出（菜单项在启动时就会建出来，快捷键常驻）。
        let searchItem = NSMenuItem(title: "跳转到章节…",
                                    action: #selector(showChapterSearch(_:)), keyEquivalent: "j")
        searchItem.target = self
        tocMenu.addItem(searchItem)
        tocMenu.addItem(.separator())

        guard let book = readingView?.book else {
            tocMenu.addItem(placeholder("（未打开文件）"))
            return
        }
        guard !book.chapters.isEmpty else {
            tocMenu.addItem(placeholder("（未识别到章节）"))
            return
        }

        let current = book.chapterIndex(at: readingView.pageStart)
        let sections = TOCMenuContent.sections(chapters: book.chapters, currentIndex: current)

        // 前面的章节：收进子菜单，倒序（前一章在最上面，符合「往回翻」的直觉），
        // 避免把当前章挤到菜单列表的下方
        if !sections.earlier.isEmpty {
            let earlierItem = NSMenuItem(
                title: "↑ 前面的章节（共 \(sections.earlier.count) 章，由近到远）",
                action: nil, keyEquivalent: "")
            let earlierMenu = NSMenu(title: "前面的章节")
            for entry in sections.earlier {
                earlierMenu.addItem(tocMenuItem(for: entry))
            }
            earlierItem.submenu = earlierMenu
            tocMenu.addItem(earlierItem)
            tocMenu.addItem(.separator())
        }

        // 当前章 + 后面的章节：平铺，当前章在第一行并打勾
        for entry in sections.active {
            tocMenu.addItem(tocMenuItem(for: entry))
        }
    }

    /// 一条可点击的目录项（章节序号存在 `tag` 里，`jumpToChapter` 直接读）
    private func tocMenuItem(for entry: TOCMenuContent.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title,
                              action: #selector(jumpToChapter(_:)), keyEquivalent: "")
        item.target = self
        item.tag = entry.chapterIndex
        item.state = entry.isCurrent ? .on : .off
        return item
    }

    private func placeholder(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 菜单校验

    /// 没打开书时禁用「跳转到章节…」和目录里的章节项 —— 自动启用只会让它们看着能点，
    /// 点下去却什么都没发生。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showChapterSearch(_:)) {
            guard let book = readingView?.book else { return false }
            return !book.chapters.isEmpty
        }
        if menuItem.action == #selector(jumpToChapter(_:)) {
            return readingView?.book != nil
        }
        if menuItem.action == #selector(showFind(_:))
            || menuItem.action == #selector(findNext(_:))
            || menuItem.action == #selector(findPrevious(_:)) {
            // 没打开书时禁用：点了也不会有结果，只会让状态栏弹一句提示
            return readingView?.book != nil
        }
        return true
    }

    // MARK: - 自检探针

    /// 自检用：强制按当前书重建「目录」菜单，返回全部菜单项标题
    var debugTOCMenuTitles: [String] {
        rebuildTOCMenu()
        return tocMenu?.items.map(\.title) ?? []
    }

    /// 自检用：菜单栏一级菜单标题（App 菜单没有 title，显示为空串）
    var debugTopLevelMenuTitles: [String] {
        (NSApp.mainMenu?.items ?? []).map { $0.submenu?.title ?? $0.title }
    }

    /// 自检用：「阅读」菜单里的菜单项标题
    var debugReadMenuTitles: [String] {
        let readMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "阅读" }?.submenu
        return (readMenu?.items ?? []).map(\.title)
    }

    /// 自检用：取「目录」菜单里的第 n 项（真正点它，验证跳转接线）
    func debugTOCMenuItem(at index: Int) -> NSMenuItem? {
        rebuildTOCMenu()
        guard let items = tocMenu?.items, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// 自检用：当前书的章节表版本号（用来确认改显示设置不会重解析章节）
    var debugChapterParseGeneration: Int { readingView?.book?.chapterParseGeneration ?? -1 }

    /// 自检用：章节搜索面板是否可见
    var debugChapterSearchVisible: Bool { chapterSearchWindow?.window.isVisible ?? false }

    /// 自检用：章节搜索面板（直接驱动搜索框 / 表格）
    var debugChapterSearch: ChapterSearchWindowController? { chapterSearchWindow }

    /// 自检用：等价于点菜单「跳转到章节…」（顺带验证菜单动作接线）
    func debugShowChapterSearch() { showChapterSearch(nil) }

    // MARK: 自检探针（全文搜索）

    /// 自检用：查找面板是否可见
    var debugFindVisible: Bool { findWindow?.window.isVisible ?? false }
    /// 自检用：查找面板（直接驱动搜索框 / 结果表）
    var debugFindWindow: FindWindowController? { findWindow }
    /// 自检用：等价于点菜单「查找…」
    func debugShowFind() { showFind(nil) }
    /// 自检用：等价于点菜单「查找下一个」/「查找上一个」
    func debugFindNext() { findNext(nil) }
    func debugFindPrevious() { findPrevious(nil) }
    /// 自检用：阅读视图当前页上可见的命中段数量
    var debugVisibleSearchHitCount: Int { readingView?.debugVisibleSearchHitCount ?? -1 }
    /// 自检用：当前页上是否画出了「当前命中」
    var debugHasCurrentSearchHighlight: Bool { readingView?.debugHasCurrentSearchHighlight ?? false }
    /// 自检用：当前页上可见的命中区间（用来核对它们确实落在本页内）
    var debugVisibleSearchRanges: [Range<Int>] { readingView?.debugVisibleSearchRanges ?? [] }

    /// 自检用：某个菜单项实际生效的快捷键（含修饰键，如 "⌃⌘f"）
    func debugShortcut(menuTitle: String, itemTitle: String) -> String? {
        guard let item = debugMenuItem(menuTitle: menuTitle, itemTitle: itemTitle) else { return nil }
        var s = ""
        if item.keyEquivalentModifierMask.contains(.control) { s += "⌃" }
        if item.keyEquivalentModifierMask.contains(.option) { s += "⌥" }
        if item.keyEquivalentModifierMask.contains(.shift) { s += "⇧" }
        if item.keyEquivalentModifierMask.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent
    }

    /// 自检用：按「菜单标题 + 菜单项标题」找菜单项（用来核对快捷键和启用状态）
    func debugMenuItem(menuTitle: String, itemTitle: String) -> NSMenuItem? {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == menuTitle })?.submenu
        else { return nil }
        return menu.items.first { $0.title == itemTitle }
    }
}
