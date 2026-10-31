import AppKit
import UniformTypeIdentifiers

/// 阅读列表（书架）窗口。
///
/// 为什么单独开窗口，而不是像原版那样塞进「文件」菜单：
///   原版靠 `WM_MENURBUTTONUP` 实现「右键点菜单项删除这本书」，
///   而 macOS 的 `NSMenuItem` **不支持给单个菜单项挂上下文菜单**。
///   与其做得别扭，不如按 macOS 习惯给书架一个独立窗口。
final class LibraryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    /// 按钮顺序：0 打开 / 1 移除 / 2 重新定位 / 3 清空
    private var actionButtons: [NSButton] = []

    /// 某本书被移除时回调（传它原来的路径）
    var onBookRemoved: ((String) -> Void)?
    /// 整个书架被清空时回调
    var onAllRemoved: (() -> Void)?
    private var prefetchingLengths = false

    private let store: LibraryStore
    private let onOpen: (CacheItem) -> Void
    private(set) var window: NSWindow!
    private(set) var tableView: NSTableView!
    private var hintLabel: NSTextField!

    private let colName = NSUserInterfaceItemIdentifier("name")
    private let colProgress = NSUserInterfaceItemIdentifier("progress")
    private let colMarks = NSUserInterfaceItemIdentifier("marks")
    private let colState = NSUserInterfaceItemIdentifier("state")

    init(store: LibraryStore, onOpen: @escaping (CacheItem) -> Void) {
        self.store = store
        self.onOpen = onOpen
        super.init()
        buildWindow()
    }

    // MARK: - 窗口

    // 自下而上的纵向布局（单位 pt）。之前按钮和提示文字重叠就是因为 y 区间算错了。
    private let buttonRowY: CGFloat = 10
    private let buttonRowH: CGFloat = 28
    private let hintY: CGFloat = 44
    private let hintH: CGFloat = 16
    private var contentTop: CGFloat { hintY + hintH + 6 }   // 表格从这之上开始

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 420)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "阅读列表"
        // 最小宽度要放得下那一排按钮，否则又会挤在一起
        window.minSize = NSSize(width: 520, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 让系统帮忙记住尺寸与位置（阅读列表是 macOS 独有的窗口，用 UserDefaults 即可）
        if !DevTools.applyFrameAutosaveName(window, "ReaderLibraryWindowFrame") {
            window.center()
        }

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        // 表格
        let tableRect = NSRect(x: 0, y: contentTop, width: rect.width, height: rect.height - contentTop)
        let scroll = NSScrollView(frame: tableRect)
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
        tableView.doubleAction = #selector(openSelected)

        for (id, title, width) in [(colName, "书名", CGFloat(260)),
                                   (colProgress, "进度", CGFloat(90)),
                                   (colMarks, "书签", CGFloat(60)),
                                   (colState, "状态", CGFloat(150))] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 50
            tableView.addTableColumn(c)
        }
        scroll.documentView = tableView
        content.addSubview(scroll)

        // 提示行
        hintLabel = NSTextField(labelWithString: "")
        hintLabel.frame = NSRect(x: 12, y: hintY, width: rect.width - 24, height: hintH)
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.autoresizingMask = [.width]
        content.addSubview(hintLabel)

        // 按钮行
        let titles = ["打开", "移除", "重新定位…", "清空"]
        let actions: [Selector] = [#selector(openSelected), #selector(removeSelected),
                                   #selector(relocateSelected), #selector(clearAll)]
        var x: CGFloat = 12
        for (t, a) in zip(titles, actions) {
            let b = NSButton(title: t, target: self, action: a)
            b.bezelStyle = .rounded
            b.sizeToFit()
            b.frame = NSRect(x: x, y: buttonRowY, width: b.frame.width + 14, height: buttonRowH)
            b.autoresizingMask = []
            content.addSubview(b)
            actionButtons.append(b)
            x += b.frame.width + 8
        }
        updateButtonStates()

        window.contentView = content
    }

    func show() {
        reload()
        // ⚠️ 顺序很重要：先激活 App，再 makeKeyAndOrderFront。
        // 反过来的话窗口可能不是 key window，红绿灯按钮第一次点击只会激活窗口而不关闭。
        DevTools.activate()
        window.makeKeyAndOrderFront(nil)
        DevTools.park(window)
        scheduleBackgroundWork()
    }

    func reload() {
        // ⚠️ 先刷新「哪些文件在本机存在」的缓存（只做 fileExists，不做目录遍历）
        store.refreshAvailability()
        tableView?.reloadData()
        updateHint()
        updateButtonStates()
        scheduleBackgroundWork()
    }

    /// 后台做两件昂贵的事：搜索搬走的文件、算每本书的总字数（用于显示百分比）。
    /// 挂在 reload 上而不是只在 show 时跑一次 —— 否则后加进来的书永远算不出百分比。
    /// 主线程永远不会被目录遍历或大文件解析卡住。
    private func scheduleBackgroundWork() {
        // 找搬走的文件：没有目标时同步回调 0，不会造成循环；
        // 找到之后会更新路径，下一轮目标为空自然停止。
        store.searchMissingFiles { [weak self] found in
            guard let self = self, found > 0 else { return }
            self.reload()
        }
        // 算总字数：分批 + 总量上限，避免书很多时疯狂读盘
        guard !prefetchingLengths, store.cachedLengthCount < 500 else { return }
        prefetchingLengths = true
        store.prefetchLengths { [weak self] in
            guard let self = self else { return }
            self.prefetchingLengths = false
            // 这里只重画表格，不走 reload —— 否则会和 scheduleBackgroundWork 互相递归
            self.tableView.reloadData()
            self.updateHint()
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    private var selectedIndex: Int? {
        let r = tableView.selectedRow
        return store.items.indices.contains(r) ? r : nil
    }

    private func updateButtonStates() {
        guard actionButtons.count == 4 else { return }
        let has = selectedIndex != nil
        actionButtons[0].isEnabled = has                  // 打开
        actionButtons[1].isEnabled = has                  // 移除
        actionButtons[2].isEnabled = has                  // 重新定位
        actionButtons[3].isEnabled = !store.items.isEmpty // 清空
    }

    // MARK: - NSWindowDelegate

    /// 窗口重新获得焦点时刷新 —— 否则进度显示会停留在上次打开书架时的旧值
    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    private func updateHint() {
        let items = store.items
        if items.isEmpty {
            hintLabel.stringValue = "书架是空的 —— 用 \(store.settings.shortcut(.openFile)?.symbols ?? "未设置") 打开一个 TXT 就会出现在这里；存档位于 ~/Library/Application Support/Reader/.cache.dat（菜单「文件 → 在访达中显示存档」）"
            return
        }
        let missing = store.missingFileCount
        var s = "共 \(items.count) 本书（最近阅读在最上面）"
        if missing > 0 {
            s += " · ⚠️ 有 \(missing) 本的路径在本机找不到，选中后点「重新定位…」指认文件"
        }
        s += " · 双击打开"
        hintLabel.stringValue = s
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { store.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, store.items.indices.contains(row) else { return nil }
        let item = store.items[row]
        let cellId = NSUserInterfaceItemIdentifier("cell-" + id.rawValue)
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = cellId
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingMiddle
        }
        // ⚠️ 只查缓存，绝不做目录遍历（一次重绘有十几个单元格，遍历会卡死界面）
        let exists = store.availableURL(forStoredPath: item.fileName) != nil
        switch id {
        case colName:
            field.stringValue = item.displayName
            field.textColor = exists ? .labelColor : .tertiaryLabelColor
            field.toolTip = item.fileName
        case colProgress:
            let total = store.bookLength(forStoredPath: item.fileName)
            field.stringValue = ReadingStatus.libraryProgress(offset: item.index,
                                                              totalLength: total,
                                                              isNew: item.isNew != 0)
            if let total = total {
                field.toolTip = "第 \(item.index) / \(total) 字"
            } else if item.index > 0 {
                field.toolTip = "正在计算全书字数…"
            } else {
                field.toolTip = nil
            }
            field.textColor = .secondaryLabelColor
        case colMarks:
            field.stringValue = item.marks.isEmpty ? "—" : "\(item.marks.count)"
            field.textColor = .secondaryLabelColor
        case colState:
            field.stringValue = exists ? "可打开" : "⚠️ 找不到文件"
            field.textColor = exists ? .secondaryLabelColor : .systemOrange
        default:
            field.stringValue = ""
        }
        return field
    }

    // MARK: - 动作

    @objc private func openSelected() {
        guard let i = selectedIndex else {
            // 之前这里是静默 return，用户会以为按钮坏了
            NSSound.beep()
            hintLabel.stringValue = "先在列表里选中一本书，再点「打开」（也可以直接双击那一行）"
            return
        }
        let item = store.items[i]
        guard store.availableURL(forStoredPath: item.fileName) != nil else {
            alert("找不到这个文件",
                  "《\(item.displayName)》的位置在本机不存在：\n\(item.fileName)\n\n"
                  + "点「重新定位…」指认它的新位置。进度和书签会照原样保留"
                  + "（它们记的是字符偏移，与路径无关）。")
            return
        }
        onOpen(CacheItem(id: item.id, index: item.index, fileName: item.fileName,
                         marks: item.marks, isNew: item.isNew))
        reload()
        // 打开后把书架收起来，让主窗口露出来 —— 否则用户会以为「点了没反应」
        window.orderOut(nil)
    }

    @objc private func removeSelected() {
        guard let i = selectedIndex else { return }
        let name = store.items[i].displayName
        let a = NSAlert()
        a.messageText = "把《\(name)》从阅读列表移除？"
        a.informativeText = "只删除阅读记录（进度、书签），不会删除原来的 txt 文件。"
        a.addButton(withTitle: "移除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            performRemove(at: i)
        }
    }

    /// 实际执行移除（与确认框分开，方便测试与自动化验证）
    func performRemove(at index: Int) {
        guard store.items.indices.contains(index) else { return }
        let removedPath = store.items[index].fileName
        store.remove(at: index)
        // 如果移除的正是正在读的那本，必须通知阅读界面关掉它
        onBookRemoved?(removedPath)
        reload()
    }

    @objc private func relocateSelected() {
        guard let i = selectedIndex else { return }
        let item = store.items[i]
        let panel = NSOpenPanel()
        panel.message = "指认《\(item.displayName)》的新位置"
        panel.prompt = "使用这个文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.relocate(index: i, to: url)
            reload()
        }
    }

    @objc private func clearAll() {
        guard !store.items.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "清空整个阅读列表？"
        a.informativeText = "会删除全部 \(store.items.count) 本书的阅读进度与书签，不会删除 txt 文件。此操作不可撤销。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            performClearAll()
        }
    }

    /// 实际执行清空（与确认框分开）
    func performClearAll() {
        store.removeAll()
        // 书架空了，阅读界面也得回到空状态 ——
        // 否则会出现「书架是空的，阅读界面还在显示那本书，进度还存不进去」的错乱
        onAllRemoved?()
        reload()
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}
