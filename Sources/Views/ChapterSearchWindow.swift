import AppKit

/// 「跳转到章节…」搜索面板。
///
/// 目录菜单适合按位置浏览；但几千章的长篇里想直接找某一章，
/// 或者只记得标题里的几个字，打字比翻菜单快得多。
/// 搜索逻辑本身在 `Core/ChapterSearch.swift`（纯逻辑、可单测），这里只负责界面。
final class ChapterSearchWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                          NSWindowDelegate, NSSearchFieldDelegate {

    private(set) var window: NSWindow!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var hintLabel: NSTextField!
    private var jumpButton: NSButton!

    private var book: TextBook?
    private var currentOffset = 0
    /// 当前筛选结果；空查询时就是全书章节（按顺序），方便直接当目录用
    private var hits: [ChapterSearchHit] = []

    /// 选中某一章后回调（参数是 `chapters` 数组下标），真正跳转由 AppDelegate 做
    var onJump: ((Int) -> Void)?

    private let colChapter = NSUserInterfaceItemIdentifier("chapter")

    override init() {
        super.init()
        buildWindow()
    }

    // MARK: - 窗口

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 480, height: 520)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "跳转到章节"
        window.minSize = NSSize(width: 360, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !DevTools.applyFrameAutosaveName(window, "ReaderChapterSearchWindowFrame") { window.center() }

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        let searchH: CGFloat = 26
        let searchY = rect.height - searchH - 14
        let buttonY: CGFloat = 12
        let buttonH: CGFloat = 28
        let hintY: CGFloat = 48
        let hintH: CGFloat = 16
        let scrollY = buttonY + buttonH + 22          // 底部操作区 + 提示
        let scrollH = searchY - 12 - scrollY

        searchField = NSSearchField(frame: NSRect(x: 12, y: searchY,
                                                  width: rect.width - 24, height: searchH))
        searchField.placeholderString = "搜索章节号或标题关键词"
        searchField.delegate = self
        // ⚠️ 不要把搜索框的 target/action 接到「跳转」上：NSSearchField 会在输入
        //    过程中也发送 action，导致刚敲了一两个数字就跳转并把面板关掉。
        //    回车走 delegate 的 control(_:textView:doCommandBy:)，见下。
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(searchField)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: scrollY, width: rect.width, height: scrollH))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        tableView = NSTableView(frame: scroll.bounds)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(jumpSelected)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: colChapter)
        column.resizingMask = .autoresizingMask
        column.width = scroll.bounds.width
        tableView.addTableColumn(column)
        scroll.documentView = tableView
        content.addSubview(scroll)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.frame = NSRect(x: 12, y: hintY, width: rect.width - 24, height: hintH)
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.autoresizingMask = [.width]
        content.addSubview(hintLabel)

        jumpButton = NSButton(title: "跳转", target: self, action: #selector(jumpSelected))
        jumpButton.bezelStyle = .rounded
        jumpButton.keyEquivalent = "\r"
        jumpButton.sizeToFit()
        jumpButton.frame = NSRect(x: 12, y: buttonY,
                                 width: jumpButton.frame.width + 16, height: buttonH)
        content.addSubview(jumpButton)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.sizeToFit()
        closeButton.frame = NSRect(x: rect.width - closeButton.frame.width - 28, y: buttonY,
                                  width: closeButton.frame.width + 16, height: buttonH)
        closeButton.autoresizingMask = [.minXMargin]
        content.addSubview(closeButton)

        window.contentView = content
    }

    /// 打开面板；从当前阅读位置开始（空查询时直接定位到当前章）
    func show(book: TextBook?, currentOffset: Int) {
        self.book = book
        self.currentOffset = currentOffset
        resetToCurrentBook()
        updateHint()
        DevTools.activate()
        window.makeKeyAndOrderFront(nil)
        DevTools.park(window)
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// 换书 / 章节规则变了之后同步内容（窗口没显示时只记下来，等 show 时再刷新）
    func update(book: TextBook?, currentOffset: Int) {
        self.book = book
        self.currentOffset = currentOffset
        guard window.isVisible else { return }
        resetToCurrentBook()
        updateHint()
    }

    /// 清空查询、列出全书、选中当前章（打开面板时的默认状态）
    private func resetToCurrentBook() {
        searchField.stringValue = ""
        refresh(selectFirst: false)
        selectCurrentChapter()
    }

    private func selectCurrentChapter() {
        guard let book, !book.chapters.isEmpty, !hits.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        let idx = min(book.chapterIndex(at: currentOffset), hits.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    // MARK: - 搜索

    /// 重新跑搜索；`selectFirst` 为 true 时选中最佳结果（打字时一直跟着走）
    private func refresh(selectFirst: Bool) {
        if let book {
            hits = ChapterSearch.search(searchField.stringValue, in: book.chapters)
        } else {
            hits = []
        }
        tableView.reloadData()
        if selectFirst {
            if hits.isEmpty {
                tableView.deselectAll(nil)
            } else {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                tableView.scrollRowToVisible(0)
            }
        }
        updateHint()
    }

    private func shortcutText(_ action: ShortcutAction) -> String {
        LibraryStore.shared.settings.shortcut(action)?.symbols ?? "未设置"
    }

    private func updateHint() {
        jumpButton.isEnabled = !hits.isEmpty && tableView.selectedRow >= 0
        guard let book else {
            hintLabel.stringValue = "还没有打开书 —— 用 \(shortcutText(.openFile)) 打开一本 TXT 再搜索章节"
            return
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            hintLabel.stringValue = "全书 \(book.chapters.count) 章 · 输入章节号或标题关键词"
        } else if hits.isEmpty {
            hintLabel.stringValue = "没有匹配的章节 · 试试更短的章节号或标题关键字"
        } else {
            hintLabel.stringValue = "匹配 \(hits.count) 章 · ↑↓ 选择，回车跳转"
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        refresh(selectFirst: true)
    }

    /// 回车才跳转。放在这里而不是搜索框的 action，避免打字过程中被误触发
    /// （NSSearchField 的 action 在输入时也可能发送 —— 那会导致面板自己关掉）。
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            jumpSelected()
            return true
        }
        return false
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let hit = hits[row]
        let reuseId = NSUserInterfaceItemIdentifier("chapter-hit")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: reuseId, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = reuseId
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.textColor = .labelColor
        }
        field.stringValue = "\(hit.chapterNumber). \(hit.title)"
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateHint()
    }

    // MARK: - 动作

    @objc private func jumpSelected() {
        let row = tableView.selectedRow
        guard hits.indices.contains(row) else {
            NSSound.beep()
            return
        }
        onJump?(hits[row].chapterIndex)
        window.orderOut(nil)
    }

    @objc private func closeWindow() {
        window.orderOut(nil)
    }

    // MARK: - 自检探针

    var debugWindowVisible: Bool { window.isVisible }
    /// 回归探针：搜索框不能绑 action —— NSSearchField 输入过程中也会发 action，
    /// 之前导致输入「435」时刚打完 4 面板就跳转关掉了。
    var debugSearchFieldHasAction: Bool { searchField.action != nil }
    /// 自检用：搜索框本体（用来模拟真实回车路径）
    var debugSearchField: NSSearchField { searchField }
    var debugRowCount: Int { hits.count }
    var debugHitIndices: [Int] { hits.map(\.chapterIndex) }
    var debugSelectedRow: Int { tableView.selectedRow }

    /// 自检用：直接设置搜索框内容并跑一次筛选（和用户打字走同一条 refresh 路径）
    func debugSetQuery(_ query: String) {
        searchField.stringValue = query
        refresh(selectFirst: true)
    }

}
