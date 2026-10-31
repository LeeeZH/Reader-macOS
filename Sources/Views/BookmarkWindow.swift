import AppKit

/// 书签面板。
///
/// 之前书签是「只能加不能看」：快捷键能加、也能存进 `.cache.dat`、书架里还能看到数量，
/// 但没有任何地方能列出它们并跳回去 —— 等于白存。
final class BookmarkWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    private let store: LibraryStore
    private let onJump: (Int) -> Void
    private(set) var window: NSWindow!
    private var tableView: NSTableView!
    private var hintLabel: NSTextField!
    private var buttons: [NSButton] = []

    /// 当前书（用于把字符偏移翻译成章节名）
    private var book: Book?

    private let colChapter = NSUserInterfaceItemIdentifier("chapter")
    private let colOffset = NSUserInterfaceItemIdentifier("offset")

    init(store: LibraryStore, onJump: @escaping (Int) -> Void) {
        self.store = store
        self.onJump = onJump
        super.init()
        buildWindow()
    }

    private var marks: [Int] { store.items.first?.marks ?? [] }

    // MARK: - 窗口

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 360)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "书签"
        window.minSize = NSSize(width: 380, height: 220)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !DevTools.applyFrameAutosaveName(window, "ReaderBookmarkWindowFrame") { window.center() }

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        let buttonRowY: CGFloat = 10
        let buttonRowH: CGFloat = 28
        let hintY: CGFloat = 44
        let contentTop: CGFloat = 66

        let scroll = NSScrollView(frame: NSRect(x: 0, y: contentTop, width: rect.width, height: rect.height - contentTop))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        tableView = NSTableView(frame: scroll.bounds)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(jumpSelected)
        for (id, title, w) in [(colChapter, "章节", CGFloat(330)), (colOffset, "位置", CGFloat(120))] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = w
            c.minWidth = 60
            tableView.addTableColumn(c)
        }
        scroll.documentView = tableView
        content.addSubview(scroll)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.frame = NSRect(x: 12, y: hintY, width: rect.width - 24, height: 16)
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.autoresizingMask = [.width]
        content.addSubview(hintLabel)

        for (i, spec) in [("跳转", #selector(jumpSelected)),
                          ("删除", #selector(removeSelected)),
                          ("全部清除", #selector(clearAll))].enumerated() {
            let b = NSButton(title: spec.0, target: self, action: spec.1)
            b.bezelStyle = .rounded
            b.sizeToFit()
            b.frame = NSRect(x: 12 + CGFloat(i) * 92, y: buttonRowY,
                             width: b.frame.width + 14, height: buttonRowH)
            content.addSubview(b)
            buttons.append(b)
        }

        window.contentView = content
    }

    func show() {
        reload()
        DevTools.activate()
        window.makeKeyAndOrderFront(nil)
        DevTools.park(window)
    }

    /// 换书或加/删书签后都要调
    func reload() {
        tableView?.reloadData()
        updateHint()          // 提示与按钮可用状态都在里面一起更新
    }

    func update(book: Book?) {
        self.book = book
        reload()
    }

    /// 界面里展示快捷键一律走这里（用户改了键位要跟着变）
    private func shortcutText(_ action: ShortcutAction) -> String {
        store.settings.shortcut(action)?.symbols ?? "未设置"
    }

    private func updateHint() {
        if book == nil {
            hintLabel.stringValue = "还没有打开书。用 \(shortcutText(.openFile)) 打开一本，再按 \(shortcutText(.addBookmark)) 加书签。"
        } else if marks.isEmpty {
            hintLabel.stringValue = "这本书还没有书签 —— 读到想记的地方按 \(shortcutText(.addBookmark))（每本最多 256 个）"
        } else {
            hintLabel.stringValue = "共 \(marks.count) 个书签 · 双击或点「跳转」回到该位置"
        }
        buttons[1].isEnabled = selectedIndex != nil
        buttons[2].isEnabled = !marks.isEmpty
    }

    private var selectedIndex: Int? {
        let r = tableView.selectedRow
        return marks.indices.contains(r) ? r : nil
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { marks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, marks.indices.contains(row) else { return nil }
        let offset = marks[row]
        let cellId = NSUserInterfaceItemIdentifier("bm-" + id.rawValue)
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = cellId
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
        }
        switch id {
        case colChapter:
            if let book = book, !book.chapters.isEmpty {
                let idx = book.chapterIndex(at: offset)
                field.stringValue = "\(idx + 1). \(book.chapters[idx].title)"
            } else {
                field.stringValue = "（无章节信息）"
            }
            field.textColor = .labelColor
        case colOffset:
            field.stringValue = "第 \(offset) 字"
            field.textColor = .secondaryLabelColor
        default:
            field.stringValue = ""
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateHint() }

    // MARK: - 动作

    @objc private func jumpSelected() {
        guard let i = selectedIndex else {
            NSSound.beep()
            hintLabel.stringValue = "先在列表里选一个书签（也可以直接双击）"
            return
        }
        onJump(marks[i])
    }

    @objc private func removeSelected() {
        guard let i = selectedIndex, book != nil else { return }
        store.removeBookmark(offset: marks[i], at: 0)
        reload()
    }

    @objc private func clearAll() {
        guard book != nil, !marks.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "清除这本书的全部 \(marks.count) 个书签？"
        a.informativeText = "阅读进度和书架不受影响。"
        a.addButton(withTitle: "清除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for m in marks { store.removeBookmark(offset: m, at: 0) }
        reload()
    }
}
