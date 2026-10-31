import AppKit

/// 「查找」面板（全文搜索）。
///
/// 和「跳转到章节…」的区别：那边命中一条章节标题，这边命中正文里的**任意一段文字**，
/// 所以位置是字符偏移而不是章节下标 —— 跳转直接复用 `ReadingView.jump(to:)`。
///
/// 搜索内核在 `Core/TextSearch.swift`（纯逻辑、可单测），这里只负责界面、
/// 防抖、后台线程和「过期结果丢弃」。
///
/// ## 交互约定（容易改坏，先说清楚）
///
/// 1. **搜索不跳页**：结果只是列出来，当前页最多把落在本页的命中涂成普通高亮。
///    跳转必须是用户主动的动作 —— 双击结果行、点「跳转」、回车，或 ⌘G / ⇧⌘G。
///    理由：打字过程中结果每 250ms 就换一批，自动跳页会让人一边打字一边被甩走。
/// 2. **关闭 = 这次查找结束**：关掉面板会清空输入框、结果和高亮。
///    下次按 ⌘F 是一个干净的空白面板，不会带着上次的词、更不会自己跳回去。
/// 3. **光标跟着手走**：匹配到结果后会自动选中「离阅读位置最近的那一处」，
///    但**只选中、不跳转** —— 这样回车 / 双击才有明确的落点。
///
/// ## 三条踩过的坑
///
/// 1. **搜索框不要绑 target/action**：NSSearchField 输入过程中也会发 action，
///    之前章节搜索面板刚打完第一个数字就自己跳转关掉了；
/// 2. 窗口必须 `isReleasedWhenClosed = false`（主窗口曾因漏设这个而段错误）；
/// 3. 搜索在后台队列跑，回来后必须比对 generation —— 否则打字快时
///    先发的慢查询会把后发的快查询结果覆盖掉，列表闪回旧内容。
final class FindWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                  NSWindowDelegate, NSSearchFieldDelegate {

    private(set) var window: NSWindow!
    private var searchField: NSSearchField!
    private var caseCheck: NSButton!
    private var tableView: NSTableView!
    private var hintLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var jumpButton: NSButton!

    private var book: Book?
    /// 打开面板时读者所在的位置：结果自动选中这里附近的那一处（只选中，不跳）。
    private var anchorOffset = 0
    private(set) var results = SearchResults.empty
    private var isSearching = false

    /// 用户主动要求跳到某一处时回调：(字符偏移, 命中序号)。真正跳转由 AppDelegate 做。
    var onJump: ((Int, Int) -> Void)?
    /// 把整批命中交给阅读视图画高亮：(命中列表, 当前序号；-1 = 没有选中)
    var onHighlight: (([SearchHit], Int) -> Void)?
    /// 面板关闭时回调（AppDelegate 用它清掉阅读界面上的高亮并交还焦点）
    var onClose: (() -> Void)?
    /// 「区分大小写」被切换（AppDelegate 负责存进 .cache.dat）
    var onCaseSensitiveChange: ((Bool) -> Void)?

    private let colHit = NSUserInterfaceItemIdentifier("find-hit")
    private var searchGeneration = 0
    private var debounceTimer: Timer?
    private let searchQueue = DispatchQueue(label: "reader.find", qos: .userInitiated)

    /// 输入防抖：长篇小说全文扫描不是零成本，每敲一个键都扫会跟打字抢 CPU。
    private let debounceInterval: TimeInterval = 0.25

    override init() {
        super.init()
        buildWindow()
    }

    // MARK: - 窗口

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 490, height: 560)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "查找"
        window.minSize = NSSize(width: 380, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !DevTools.applyFrameAutosaveName(window, "ReaderFindWindowFrame") { window.center() }

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        let searchH: CGFloat = 26
        let searchY = rect.height - searchH - 14
        let caseY = searchY - 26
        let buttonY: CGFloat = 12
        let buttonH: CGFloat = 28
        let hintY: CGFloat = 48
        let hintH: CGFloat = 16

        searchField = NSSearchField(frame: NSRect(x: 12, y: searchY,
                                                  width: rect.width - 24, height: searchH))
        searchField.placeholderString = "在全文中查找…"
        searchField.delegate = self
        // ⚠️ 绝对不要把 target/action 接到「跳转 / 下一个」上：NSSearchField 在输入
        //    过程中也会发 action，会导致刚敲一个字就跳转。回车走 delegate 的回调。
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.autoresizingMask = [.width, .minYMargin]
        content.addSubview(searchField)

        caseCheck = NSButton(checkboxWithTitle: "区分大小写", target: self,
                             action: #selector(caseSensitiveChanged(_:)))
        caseCheck.frame = NSRect(x: 12, y: caseY, width: 200, height: 18)
        caseCheck.font = NSFont.systemFont(ofSize: 11)
        caseCheck.autoresizingMask = [.minYMargin]
        content.addSubview(caseCheck)

        let scrollTop = caseY - 8
        let scrollBottom = hintY + hintH + 8
        let scroll = NSScrollView(frame: NSRect(x: 0, y: scrollBottom,
                                                width: rect.width, height: scrollTop - scrollBottom))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        tableView = NSTableView(frame: scroll.bounds)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // 双击才跳：单击只选中（否则用方向键挑结果时会被一路带跑）
        tableView.doubleAction = #selector(jumpToSelected)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: colHit)
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

        jumpButton = NSButton(title: "跳转", target: self, action: #selector(jumpToSelected))
        jumpButton.bezelStyle = .rounded
        jumpButton.keyEquivalent = "\r"
        jumpButton.sizeToFit()
        jumpButton.frame = NSRect(x: 12, y: buttonY,
                                  width: jumpButton.frame.width + 16, height: buttonH)
        content.addSubview(jumpButton)

        prevButton = NSButton(title: "上一个", target: self, action: #selector(previousHit))
        prevButton.bezelStyle = .rounded
        prevButton.sizeToFit()
        prevButton.frame = NSRect(x: jumpButton.frame.maxX + 8, y: buttonY,
                                  width: prevButton.frame.width + 14, height: buttonH)
        content.addSubview(prevButton)

        nextButton = NSButton(title: "下一个", target: self, action: #selector(nextHit))
        nextButton.bezelStyle = .rounded
        nextButton.sizeToFit()
        nextButton.frame = NSRect(x: prevButton.frame.maxX + 8, y: buttonY,
                                  width: nextButton.frame.width + 14, height: buttonH)
        content.addSubview(nextButton)

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.sizeToFit()
        closeButton.frame = NSRect(x: rect.width - closeButton.frame.width - 28, y: buttonY,
                                   width: closeButton.frame.width + 16, height: buttonH)
        closeButton.autoresizingMask = [.minXMargin]
        content.addSubview(closeButton)

        window.contentView = content
        updateButtonsAndHint()
    }

    // MARK: - 打开 / 更新 / 关闭

    /// 打开面板。
    ///
    /// **每次打开都是一次全新的查找**：输入框清空、结果清空、不跳转。
    /// 这样「上次搜到第 12 章」不会在下次按 ⌘F 时把人拽回去。
    func show(book: Book?, currentOffset: Int, caseSensitive: Bool) {
        self.book = book
        self.anchorOffset = currentOffset
        caseCheck.state = caseSensitive ? .on : .off
        resetSearchState()

        DevTools.activate()
        window.makeKeyAndOrderFront(nil)
        DevTools.park(window)
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// 换书 / 关书。
    ///
    /// 面板开着、查询词还在的话，按新书重搜一次**并且不跳转** —— 换书时最不希望的
    /// 就是页面自己跳走；书关掉了就把输入框也清掉。
    func update(book: Book?) {
        self.book = book
        cancelPendingSearch()
        searchGeneration += 1              // 让还在跑的后台搜索作废
        isSearching = false
        guard book != nil else {
            resetSearchState()
            return
        }
        guard !searchField.stringValue.isEmpty else {
            resetResultState()
            return
        }
        onHighlight?([], -1)
        runSearch(query: searchField.stringValue, generation: nextGeneration(),
                  caseSensitive: caseCheck.state == .on, selectAnchor: true)
    }

    /// 关窗（点红叉、Esc、或用菜单关）时清掉输入框、结果和高亮。
    func windowWillClose(_ notification: Notification) {
        resetSearchState()
        onClose?()
    }

    var query: String { searchField.stringValue }

    /// 当前结果条数（AppDelegate 用它显示「第 n / 共 m 处」）
    var hitCount: Int { results.hits.count }

    // MARK: - 搜索

    private func nextGeneration() -> Int {
        searchGeneration += 1
        return searchGeneration
    }

    private func cancelPendingSearch() {
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    /// 输入变化：防抖后丢后台。打字过程中只取消旧的，不立刻扫。
    private func scheduleSearch() {
        cancelPendingSearch()
        guard book != nil else {
            resetResultState()
            return
        }
        let query = searchField.stringValue
        guard !query.isEmpty else {
            searchGeneration += 1
            isSearching = false
            resetResultState()
            return
        }
        let gen = nextGeneration()
        isSearching = true
        updateButtonsAndHint()
        let caseSensitive = caseCheck.state == .on
        let timer = Timer(timeInterval: debounceInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.runSearch(query: query, generation: gen,
                           caseSensitive: caseSensitive, selectAnchor: true)
        }
        // .common：菜单打开、拖窗口时防抖计时器也要继续走
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func runSearch(query: String, generation gen: Int,
                           caseSensitive: Bool, selectAnchor: Bool) {
        guard let book else {
            resetResultState()
            return
        }
        let haystack = book.findText
        let chapters = book.chapters
        isSearching = true
        updateButtonsAndHint()
        searchQueue.async { [weak self] in
            let found = TextSearch.find(query: query, haystack: haystack,
                                        chapters: chapters, caseSensitive: caseSensitive)
            DispatchQueue.main.async {
                guard let self, gen == self.searchGeneration else { return }   // 过期结果
                self.isSearching = false
                self.apply(found, selectAnchor: selectAnchor)
            }
        }
    }

    /// 结果落地：刷新列表，**只选中、不跳转**。
    ///
    /// 选中「离阅读位置最近的那一处」只是给回车 / 双击一个明确落点；
    /// 页面本身一动不动。同时把命中交回阅读视图画普通高亮（当前命中尚未产生）。
    private func apply(_ found: SearchResults, selectAnchor: Bool) {
        results = found
        tableView.reloadData()
        if selectAnchor, !found.hits.isEmpty {
            let row = TextSearch.firstIndex(atOrAfter: anchorOffset, hits: found.hits) ?? 0
            selectRow(row)
        } else {
            tableView.deselectAll(nil)
        }
        updateButtonsAndHint()
        onHighlight?(found.hits, -1)
    }

    /// 只选中某一行的结果（不动阅读页面）。
    private func selectRow(_ row: Int) {
        guard results.hits.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateButtonsAndHint()
    }

    /// 把这次查找的所有状态清掉（输入框、结果、选中、高亮）。
    ///
    /// 「关闭面板」和「重新打开」都走这里：用户明确要求关掉就等于本次查找结束。
    private func resetSearchState() {
        cancelPendingSearch()
        searchGeneration += 1
        isSearching = false
        searchField.stringValue = ""
        resetResultState()
    }

    private func resetResultState() {
        results = .empty
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateButtonsAndHint()
        onHighlight?([], -1)
    }

    // MARK: - 跳转（唯一的入口：双击 / 回车 / 「跳转」按钮 / ⌘G / ⇧⌘G）

    @objc private func jumpToSelected() {
        guard !results.hits.isEmpty else {
            NSSound.beep()
            return
        }
        var row = tableView.selectedRow
        if row < 0 { row = 0 }      // 没选中就跳第一处，别让按钮点了没反应
        guard results.hits.indices.contains(row) else {
            NSSound.beep()
            return
        }
        selectRow(row)
        let hit = results.hits[row]
        onJump?(hit.index, row)
        onHighlight?(results.hits, row)
        updateButtonsAndHint()
    }

    // MARK: - 上一个 / 下一个

    @objc func nextHit() {
        guard !results.hits.isEmpty else { NSSound.beep(); return }
        let row = tableView.selectedRow
        let target = row < 0 ? 0 : (TextSearch.index(after: row, hits: results.hits) ?? 0)
        selectRow(target)
        jumpToSelected()
    }

    @objc func previousHit() {
        guard !results.hits.isEmpty else { NSSound.beep(); return }
        let row = tableView.selectedRow
        let target: Int
        if row < 0 {
            target = results.hits.count - 1
        } else {
            target = TextSearch.index(before: row, hits: results.hits) ?? (results.hits.count - 1)
        }
        selectRow(target)
        jumpToSelected()
    }

    @objc private func caseSensitiveChanged(_ sender: Any?) {
        onCaseSensitiveChange?(caseCheck.state == .on)
        // 换匹配方式后旧结果全部作废，立刻按当前查询重搜（同样不跳转）
        cancelPendingSearch()
        runSearch(query: searchField.stringValue, generation: nextGeneration(),
                  caseSensitive: caseCheck.state == .on, selectAnchor: true)
    }

    @objc private func closeWindow() {
        resetSearchState()
        window.orderOut(nil)
        onClose?()
    }

    private func shortcutText(_ action: ShortcutAction) -> String {
        LibraryStore.shared.settings.shortcut(action)?.symbols ?? "未设置"
    }

    private func updateButtonsAndHint() {
        let hasHits = !results.hits.isEmpty
        jumpButton.isEnabled = hasHits
        prevButton.isEnabled = hasHits
        nextButton.isEnabled = hasHits
        let row = tableView.selectedRow

        guard let book else {
            hintLabel.stringValue = "还没有打开书 —— 用 \(shortcutText(.openFile)) 打开一本 TXT 再查找"
            return
        }
        if isSearching {
            hintLabel.stringValue = "正在搜索…"
            return
        }
        if results.query.isEmpty {
            hintLabel.stringValue = "全书 \(book.units.count) 字 · 输入要在全文中查找的内容"
            return
        }
        guard hasHits else {
            hintLabel.stringValue = "没有找到「\(results.query)」"
            return
        }
        var text: String
        if row >= 0 {
            text = "已选中第 \(row + 1) / \(results.hits.count) 处 · 双击或点「跳转」才跳"
        } else {
            text = "共 \(results.hits.count) 处 · 双击或点「跳转」才跳"
        }
        if results.truncated {
            text += " · 结果太多，只列前 \(results.hits.count) 处"
        }
        hintLabel.stringValue = text
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch()
    }

    /// 回车 = 跳到选中的那一处（和「跳转」按钮同一动作）。
    /// 搜索框自己不绑 action，避免打字过程中被误触发。
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            jumpToSelected()
            return true
        }
        return false
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { results.hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.hits.indices.contains(row) else { return nil }
        let hit = results.hits[row]
        let reuseId = NSUserInterfaceItemIdentifier("find-hit-row")
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
        let chapter = book.flatMap { b -> String? in
            b.chapters.indices.contains(hit.chapterIndex) ? b.chapters[hit.chapterIndex].title : nil
        } ?? "（无章节）"
        // 行首序号 + 章节名 + 上下文片段：一眼能判断「是不是这处」
        field.stringValue = "\(row + 1). \(chapter) · \(hit.excerpt)"
        return field
    }

    /// 单击只改选中，不跳转；双击才走 `jumpToSelected`。
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonsAndHint()
    }

    // MARK: - 自检探针

    var debugWindowVisible: Bool { window.isVisible }
    /// 回归探针：搜索框不能绑 action（否则打字过程中会自己跳转）
    var debugSearchFieldHasAction: Bool { searchField.action != nil }
    var debugSearchField: NSSearchField { searchField }
    var debugRowCount: Int { results.hits.count }
    var debugSelectedRow: Int { tableView.selectedRow }
    var debugHitOffsets: [Int] { results.hits.map(\.index) }
    var debugHitExcerpts: [String] { results.hits.map(\.excerpt) }
    var debugTruncated: Bool { results.truncated }
    var debugQuery: String { searchField.stringValue }
    var debugCaseSensitive: Bool { caseCheck.state == .on }
    /// 双击是否接上了跳转（回归探针：单击绝不能接到跳转上）
    var debugDoubleActionWired: Bool { tableView.doubleAction != nil }
    /// 「跳转」按钮是否存在/可用
    var debugJumpButtonEnabled: Bool { jumpButton.isEnabled }

    /// 自检用：等价于双击 / 点「跳转」/ 回车（走真实的 jumpToSelected 路径）
    func debugJumpToSelected() { jumpToSelected() }

    /// 自检用：等价于用户**单击**某一行（只选中，不跳转）
    func debugClickRow(_ row: Int) { selectRow(row) }

    /// 自检用：切换「区分大小写」并**同步**重搜一次。
    /// （真实路径是异步的；自检要确定的结果，所以这里走同步，逻辑完全一样。）
    func debugSetCaseSensitive(_ on: Bool) {
        caseCheck.state = on ? .on : .off
        onCaseSensitiveChange?(on)
        cancelPendingSearch()
        searchGeneration += 1
        guard let book else {
            resetResultState()
            return
        }
        let found = TextSearch.find(query: searchField.stringValue, haystack: book.findText,
                                    chapters: book.chapters, caseSensitive: on)
        isSearching = false
        apply(found, selectAnchor: true)
    }

    /// 自检用：**同步**跑一次搜索（不走防抖/后台），让断言是确定的。
    /// 走的是和用户打字完全相同的 `TextSearch.find` + `apply` 路径。
    func debugSearchImmediately(_ query: String) {
        cancelPendingSearch()
        searchField.stringValue = query
        searchGeneration += 1
        guard let book else {
            resetResultState()
            return
        }
        let found = TextSearch.find(query: query, haystack: book.findText,
                                    chapters: book.chapters,
                                    caseSensitive: caseCheck.state == .on)
        isSearching = false
        apply(found, selectAnchor: true)
    }
}
