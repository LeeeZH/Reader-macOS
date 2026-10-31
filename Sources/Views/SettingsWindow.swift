import AppKit

/// 显示设置窗口。
///
/// 设计原则：**只暴露真正生效的项**。方案里列过的 `alpha`（窗口透明度）、
/// 自动翻页等属于后续阶段，在它们实现之前不放进界面 —— 免得做出一堆点了没反应的开关。
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let store: LibraryStore
    private let onChange: () -> Void
    private(set) var window: NSWindow!

    // 控件
    private var fontPopup: NSPopUpButton!
    private var sizeSlider: NSSlider!
    private var sizeLabel: NSTextField!
    private var titleSameFontCheck: NSButton!
    private var titleFontPopup: NSPopUpButton!
    private var titleSizeSlider: NSSlider!
    private var titleSizeLabel: NSTextField!
    private var titleColorWell: NSColorWell!
    private var textColorWell: NSColorWell!
    private var bgColorWell: NSColorWell!
    private var followSystemCheck: NSButton!
    private var alphaSlider: NSSlider!
    private var alphaLabel: NSTextField!
    private var menuBarCheck: NSButton!
    private var hotKeyCheck: NSButton!
    private var keepOnTopCheck: NSButton!
    private var autoPageIntervalSlider: NSSlider!
    private var autoPageIntervalLabel: NSTextField!
    private var autoPageModePopup: NSPopUpButton!
    private var mouseLeftPopup: NSPopUpButton!
    private var mouseRightPopup: NSPopUpButton!
    private var mouseBothPopup: NSPopUpButton!

    private let buttonActions: [ReaderSettings.MouseAction] = [.nextPage, .prevPage, .toggleHide, .none]
    private let buttonTitles = ["下一页", "上一页", "隐藏/显示窗口", "不动作"]
    private let bothActions: [ReaderSettings.MouseAction] = [.toggleHide, .minimize, .none]
    private let bothTitles = ["隐藏/显示窗口", "最小化窗口", "不动作"]
    private var autoPageCheck: NSButton!
    private var hideChromeCheck: NSButton!
    private var charGapSlider: NSSlider!
    private var lineGapSlider: NSSlider!
    private var paraGapSlider: NSSlider!
    private var insetSliders: [NSSlider] = []
    /// 滑块右侧的数值标签（字距 / 行距 / 段距 / 翻页重叠）。
    /// 之前这些标签是 `addSliderRow` 里的局部变量，创建后没人再更新，
    /// 于是拖滑块时阅读界面变了、数字却一直停在初始值。
    private var sliderValueLabels: [NSSlider: NSTextField] = [:]
    private var indentCheck: NSButton!
    private var blankCheck: NSButton!
    private var wrapCheck: NSButton!
    private var chapterPageCheck: NSButton!
    private var wheelPopup: NSPopUpButton!
    private var smoothCheck: NSButton!
    private var overlapSlider: NSSlider!
    private var rulePopup: NSPopUpButton!
    private var keywordField: NSTextField!
    private var regexField: NSTextField!

    private var segmented: NSSegmentedControl!
    private var pageViews: [NSScrollView] = []

    private var isSyncing = false

    /// 跟随系统时为色块取「实际生效」的颜色
    private var isDarkAppearance: Bool {
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 自检用：标签页
    var debugTabTitles: [String] {
        guard let seg = segmented else { return [] }
        return (0..<seg.segmentCount).map { seg.label(forSegment: $0) ?? "" }
    }
    var debugVisibleTabIndex: Int { pageViews.firstIndex { !$0.isHidden } ?? -1 }
    func debugSelectTab(_ i: Int) {
        segmented.selectedSegment = i
        showPage(i)
    }

    /// 自检用：颜色块是否可点（曾经因为「跟随系统」默认开启而被禁用）
    var debugColorWellsEnabled: Bool { (textColorWell?.isEnabled ?? false) && (bgColorWell?.isEnabled ?? false) }
    /// 自检用：「窗口置顶」复选框的勾选状态（要和菜单 / 托盘联动）
    var debugKeepOnTopChecked: Bool { keepOnTopCheck?.state == .on }
    /// 自检用：章节标题那组的可编辑状态（同字体模式下三个控件都该置灰）
    var debugTitleControlsEnabled: (font: Bool, size: Bool, color: Bool) {
        (titleFontPopup?.isEnabled ?? false, titleSizeSlider?.isEnabled ?? false,
         titleColorWell?.isEnabled ?? false)
    }
    /// 自检用：勾/取消「章节标题与正文用同一字体和颜色」（走和真实点击同一条刷新路径）
    func debugSetTitleSameFont(_ same: Bool) {
        titleSameFontCheck.state = same ? .on : .off
        titleSameFontChanged()
    }

    /// 自动翻页是运行时状态（不在存档里），由外部提供
    var onToggleAutoPage: (() -> Void)?
    var isAutoPageOn: () -> Bool = { false }

    init(store: LibraryStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        super.init()
        buildWindow()
        syncFromSettings()
    }

    // MARK: - 窗口

    private func buildWindow() {
        // 取色器：NSColorWell 点的就是这个共享面板
        NSColorPanel.shared.showsAlpha = true
        NSColorPanel.shared.isContinuous = true

        func entry(_ title: String, _ pair: (NSScrollView, NSSize)) -> (String, NSScrollView, NSSize) {
            (title, pair.0, pair.1)
        }
        // 所有页面先建出来（控件初始化都在里面），再统一算窗口尺寸
        let built = [
            entry("显示", buildDisplayTab()),
            entry("翻页", buildPageTab()),
            entry("窗口", buildWindowTab()),
            entry("章节", buildChapterTab()),
            entry("其他", buildOtherTab()),
        ]
        let contentWidth = max(470, built.map { $0.2.width }.max() ?? 470)
        let contentHeight = min(660, built.map { $0.2.height }.max() ?? 500)

        let rect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight + 56)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: contentWidth, height: 300)
        window.delegate = self
        if !window.setFrameAutosaveName("ReaderSettingsWindowFrame") { window.center() }

        // 用分段控件当标签栏：NSTabView 在离屏渲染下标签文字画不出来，
        // 而且自绘更容易控制尺寸
        segmented = NSSegmentedControl(labels: built.map { $0.0 },
                                       trackingMode: .selectOne,
                                       target: self, action: #selector(tabChanged))
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(origin: .zero, size: rect.size))
        root.addSubview(segmented)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            segmented.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root

        pageViews = built.map { $0.1 }
        for v in pageViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            v.isHidden = true
        }
        showPage(0)
    }

    @objc private func tabChanged() {
        showPage(segmented.selectedSegment)
    }

    private func showPage(_ index: Int) {
        for (i, v) in pageViews.enumerated() { v.isHidden = (i != index) }
    }

    // MARK: - 各标签页

    private func makeGrid() -> NSGridView {
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .leading
        grid.column(at: 0).width = 74
        grid.column(at: 1).width = 250
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        return grid
    }

    /// 把 grid 包进滚动视图，返回 (视图, 建议尺寸)
    private func wrap(_ grid: NSGridView) -> (NSScrollView, NSSize) {
        let fitting = grid.fittingSize
        let size = NSSize(width: max(470, fitting.width + 44), height: fitting.height + 36)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // 用 flipped 视图当文档：否则内容会沉到滚动视图的底部（NSScrollView 原点是左下角）
        let doc = FlippedView(frame: NSRect(origin: .zero, size: size))
        doc.autoresizingMask = [.width]
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
        ])
        scroll.documentView = doc
        return (scroll, size)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func section(_ grid: NSGridView, _ title: String) {
        let l = NSTextField(labelWithString: title)
        l.font = NSFont.boldSystemFont(ofSize: 12)
        l.alignment = .left
        let row = grid.addRow(with: [l])
        row.mergeCells(in: NSRange(location: 0, length: 3))
        row.cell(at: 0).xPlacement = .leading
        grid.addRow(with: [NSGridCell.emptyContentView])
    }

    private func addSliderRow(_ grid: NSGridView, _ title: String,
                              _ lo: Double, _ hi: Double, _ value: Double,
                              _ action: Selector) -> NSSlider {
        let s = NSSlider(value: value, minValue: lo, maxValue: hi, target: self, action: action)
        s.isContinuous = true
        let v = NSTextField(labelWithString: "\(Int(value))")
        v.textColor = .secondaryLabelColor
        v.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        grid.addRow(with: [label(title), s, v])
        sliderValueLabels[s] = v
        return s
    }

    private func buildDisplayTab() -> (NSScrollView, NSSize) {
        let grid = makeGrid()

        section(grid, "字体")
        fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        populateFonts()
        grid.addRow(with: [label("字体"), fontPopup])

        sizeSlider = NSSlider(value: 14, minValue: 8, maxValue: 72,
                              target: self, action: #selector(sizeChanged))
        sizeSlider.isContinuous = true
        sizeLabel = NSTextField(labelWithString: "14 pt")
        sizeLabel.textColor = .secondaryLabelColor
        grid.addRow(with: [label("字号"), sizeSlider, sizeLabel])

        textColorWell = NSColorWell(frame: .zero)
        textColorWell.target = self
        textColorWell.action = #selector(colorChanged)
        grid.addRow(with: [label("文字颜色"), textColorWell])

        bgColorWell = NSColorWell(frame: .zero)
        bgColorWell.target = self
        bgColorWell.action = #selector(colorChanged)
        grid.addRow(with: [label("背景颜色"), bgColorWell])

        followSystemCheck = NSButton(checkboxWithTitle: "跟随系统深色模式（忽略上面两个颜色）",
                                     target: self, action: #selector(followSystemChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, followSystemCheck])

        // ── 章节标题（原版 use_same_font / font_title / font_color_title）──
        // 默认勾上：与正文同字体同色，渲染结果和加这个功能之前完全一样。
        // 取消勾选后下面三行才生效 —— 和原版 DisplaySet.cpp 一样在同字体模式下置灰，
        // 而不是留着控件让人点了没反应。
        section(grid, "章节标题")
        titleSameFontCheck = NSButton(checkboxWithTitle: "章节标题与正文用同一字体和颜色",
                                      target: self, action: #selector(titleSameFontChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, titleSameFontCheck])

        titleFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        titleFontPopup.target = self
        titleFontPopup.action = #selector(titleFontChanged)
        populateFonts(for: titleFontPopup, current: store.settings.titleFontName)
        grid.addRow(with: [label("标题字体"), titleFontPopup])

        titleSizeSlider = NSSlider(value: 14, minValue: 8, maxValue: 72,
                                   target: self, action: #selector(titleSizeChanged))
        titleSizeSlider.isContinuous = true
        titleSizeLabel = NSTextField(labelWithString: "14 pt")
        titleSizeLabel.textColor = .secondaryLabelColor
        grid.addRow(with: [label("标题字号"), titleSizeSlider, titleSizeLabel])

        titleColorWell = NSColorWell(frame: .zero)
        titleColorWell.target = self
        titleColorWell.action = #selector(titleColorChanged)
        grid.addRow(with: [label("标题颜色"), titleColorWell])

        section(grid, "排版")
        charGapSlider = addSliderRow(grid, "字距", 0, 10, 0, #selector(spacingChanged))
        lineGapSlider = addSliderRow(grid, "行距", 0, 40, 5, #selector(spacingChanged))
        paraGapSlider = addSliderRow(grid, "段距", 0, 60, 15, #selector(spacingChanged))

        let insetBox = NSStackView()
        insetBox.orientation = .horizontal
        insetBox.spacing = 6
        insetSliders = []
        for name in ["左", "上", "右", "下"] {
            let sl = NSSlider(value: 0, minValue: 0, maxValue: 80,
                              target: self, action: #selector(spacingChanged))
            sl.isContinuous = true
            sl.widthAnchor.constraint(equalToConstant: 52).isActive = true
            insetSliders.append(sl)
            let l = NSTextField(labelWithString: name)
            l.font = NSFont.systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            insetBox.addArrangedSubview(l)
            insetBox.addArrangedSubview(sl)
        }
        grid.addRow(with: [label("内部边框"), insetBox])

        section(grid, "段落")
        indentCheck = NSButton(checkboxWithTitle: "首行缩进（两个全角空格）",
                               target: self, action: #selector(toggleChanged))
        blankCheck = NSButton(checkboxWithTitle: "压缩空行（连续空行只留一行）",
                              target: self, action: #selector(toggleChanged))
        wrapCheck = NSButton(checkboxWithTitle: "英文单词换行（Word wrap）",
                             target: self, action: #selector(toggleChanged))
        chapterPageCheck = NSButton(checkboxWithTitle: "章前分页（每章从新一页开始）",
                                    target: self, action: #selector(toggleChanged))
        for c in [indentCheck!, blankCheck!, wrapCheck!, chapterPageCheck!] {
            grid.addRow(with: [NSGridCell.emptyContentView, c])
        }
        return wrap(grid)
    }

    private func buildPageTab() -> (NSScrollView, NSSize) {
        let grid = makeGrid()

        section(grid, "滚动")
        wheelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        wheelPopup.addItems(withTitles: ["滚动 1 行", "滚动 2 行", "滚动 3 行", "整页翻"])
        wheelPopup.target = self
        wheelPopup.action = #selector(wheelChanged)
        grid.addRow(with: [label("滚轮"), wheelPopup])

        smoothCheck = NSButton(checkboxWithTitle: "平滑滚动（像素级，带缓出动画）",
                               target: self, action: #selector(smoothChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, smoothCheck])

        overlapSlider = addSliderRow(grid, "翻页重叠", 0, 5, 0, #selector(spacingChanged))

        section(grid, "鼠标")
        mouseLeftPopup = makeMousePopup(buttonActions, buttonTitles, #selector(mouseLeftChanged))
        grid.addRow(with: [label("左键"), mouseLeftPopup])

        mouseRightPopup = makeMousePopup(buttonActions, buttonTitles, #selector(mouseRightChanged))
        grid.addRow(with: [label("右键"), mouseRightPopup])

        mouseBothPopup = makeMousePopup(bothActions, bothTitles, #selector(mouseBothChanged))
        grid.addRow(with: [label("左右一起按"), mouseBothPopup])

        section(grid, "自动翻页")
        autoPageCheck = NSButton(checkboxWithTitle: "启用自动翻页（⇧⌘A）",
                                 target: self, action: #selector(autoPageToggled))
        grid.addRow(with: [NSGridCell.emptyContentView, autoPageCheck])

        autoPageIntervalSlider = NSSlider(value: 3, minValue: 1, maxValue: 30,
                                          target: self, action: #selector(autoPageIntervalChanged))
        autoPageIntervalSlider.isContinuous = true
        autoPageIntervalLabel = NSTextField(labelWithString: "3 秒")
        autoPageIntervalLabel.textColor = .secondaryLabelColor
        autoPageIntervalLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        grid.addRow(with: [label("间隔"), autoPageIntervalSlider, autoPageIntervalLabel])

        autoPageModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        autoPageModePopup.addItems(withTitles: ["每页翻一次", "每次滚一行"])
        autoPageModePopup.target = self
        autoPageModePopup.action = #selector(autoPageModeChanged)
        grid.addRow(with: [label("方式"), autoPageModePopup])
        return wrap(grid)
    }

    private func buildWindowTab() -> (NSScrollView, NSSize) {
        let grid = makeGrid()

        section(grid, "外观")
        alphaSlider = NSSlider(value: 100, minValue: 10, maxValue: 100,
                               target: self, action: #selector(alphaChanged))
        alphaSlider.isContinuous = true
        alphaLabel = NSTextField(labelWithString: "100%")
        alphaLabel.textColor = .secondaryLabelColor
        alphaLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        grid.addRow(with: [label("不透明度"), alphaSlider, alphaLabel])

        hideChromeCheck = NSButton(checkboxWithTitle: "沉浸模式：隐藏顶栏和底栏（⇧⌘B）",
                                   target: self, action: #selector(hideChromeChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, hideChromeCheck])

        section(grid, "置顶")
        keepOnTopCheck = NSButton(checkboxWithTitle: "窗口置顶：浮在其它应用上面",
                                  target: self, action: #selector(keepOnTopChanged))
        // 标题太长会把复选框的文字截断（设置窗口宽度由最宽的一页决定），
        // 细节放 tooltip 里
        keepOnTopCheck.toolTip = "勾选后 Reader 浮在其它应用的普通 / 最大化窗口之上，"
            + "点别的应用也挡不住它。别人按绿色按钮进的原生全屏盖不住。"
        grid.addRow(with: [NSGridCell.emptyContentView, keepOnTopCheck])

        section(grid, "入口")
        menuBarCheck = NSButton(checkboxWithTitle: "在菜单栏显示图标",
                                target: self, action: #selector(menuBarChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, menuBarCheck])

        hotKeyCheck = NSButton(checkboxWithTitle: "全局热键 \(ReaderSettings.globalHotKeyDisplayName) 隐藏/显示窗口",
                               target: self, action: #selector(hotKeyChanged))
        grid.addRow(with: [NSGridCell.emptyContentView, hotKeyCheck])
        return wrap(grid)
    }

    private func buildChapterTab() -> (NSScrollView, NSSize) {
        let grid = makeGrid()

        section(grid, "章节解析")
        rulePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        rulePopup.addItems(withTitles: ["默认规则（第X章 / 楔子 / 序章）", "按关键字", "按正则表达式"])
        rulePopup.target = self
        rulePopup.action = #selector(ruleKindChanged)
        grid.addRow(with: [label("方式"), rulePopup])

        keywordField = NSTextField(string: "")
        keywordField.placeholderString = "例如：第/卷/Chapter"
        keywordField.target = self
        keywordField.action = #selector(ruleTextChanged)
        grid.addRow(with: [label("关键字"), keywordField])

        regexField = NSTextField(string: "")
        regexField.placeholderString = "例如：第.*章\\s+.*"
        regexField.target = self
        regexField.action = #selector(ruleTextChanged)
        grid.addRow(with: [label("正则"), regexField])

        let hint = NSTextField(wrappingLabelWithString: "改完规则后目录会立刻按新规则重新解析。\n默认规则能识别「第X章/卷/部/节」「楔子」「序章」。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 320
        grid.addRow(with: [NSGridCell.emptyContentView])
        let r = grid.addRow(with: [hint])
        r.mergeCells(in: NSRange(location: 0, length: 3))
        return wrap(grid)
    }

    private func buildOtherTab() -> (NSScrollView, NSSize) {
        let grid = makeGrid()

        section(grid, "存档")
        let kindLabel = NSTextField(labelWithString: LibraryStore.locationKind(for: store.fileURL))
        kindLabel.font = NSFont.systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor
        grid.addRow(with: [label("模式"), kindLabel])
        // ⚠️ 用构造时传进来的 store，不要用 LibraryStore.shared。
        // 正式运行时两者是同一个实例，但离屏渲染工具会塞一个临时 store，
        // 用 shared 的话这里会显示错误的路径（曾经就是）。
        // 路径可能很长（尤其家目录很深时）。用中间截断 + 悬停看全：
        // 换成 wrappingLabel 的话，网格算不出足够行高，末尾的 `.cache.dat` 会被切掉。
        let pathLabel = NSTextField(labelWithString: store.fileURL.path)
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = store.fileURL.path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        grid.addRow(with: [label("位置"), pathLabel])

        let reveal = NSButton(title: "在访达中显示", target: self, action: #selector(revealArchive))
        reveal.bezelStyle = .rounded
        grid.addRow(with: [NSGridCell.emptyContentView, reveal])

        section(grid, "重置")
        let reset = NSButton(title: "还原所有设置", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        grid.addRow(with: [NSGridCell.emptyContentView, reset])

        let hint = NSTextField(wrappingLabelWithString: "会重置字体、配色、排版、翻页、鼠标、窗口、章节规则。\n阅读进度和书架不受影响。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 320
        let r = grid.addRow(with: [hint])
        r.mergeCells(in: NSRange(location: 0, length: 3))
        return wrap(grid)
    }

    @objc private func revealArchive() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    private func populateFonts() {
        populateFonts(for: fontPopup, current: store.settings.fontName)
    }

    /// 把系统字体族填进指定的下拉框（正文 / 标题共用）。
    private func populateFonts(for popup: NSPopUpButton, current: String) {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        popup.removeAllItems()
        if !families.contains(current) {
            // 存档里是 Windows 字体（本机没有）→ 放到最前面并标注
            popup.addItem(withTitle: "\(current)（本机没有，自动回退）")
            popup.lastItem?.representedObject = current
        }
        for f in families {
            popup.addItem(withTitle: f)
            popup.lastItem?.representedObject = f
        }
        selectPopup(popup, current)
    }

    private func selectPopup(_ popup: NSPopUpButton, _ value: String) {
        for item in popup.itemArray where (item.representedObject as? String) == value {
            popup.select(item)
            return
        }
    }

    /// 同字体模式下标题的字体 / 字号 / 颜色都不生效 —— 置灰，别让人以为坏了。
    private func updateTitleControlsEnabled() {
        let on = titleSameFontCheck.state == .off
        titleFontPopup.isEnabled = on
        titleSizeSlider.isEnabled = on
        titleColorWell.isEnabled = on
        titleSizeLabel.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    // MARK: - 同步

    func syncFromSettings() {
        isSyncing = true
        defer { isSyncing = false }
        let s = store.settings

        for item in fontPopup.itemArray where (item.representedObject as? String) == s.fontName {
            fontPopup.select(item)
            break
        }
        sizeSlider.doubleValue = Double(s.fontPointSize)
        // 取整到最接近的点值：LOGFONT 存的是整数像素，14pt ↔ -19px ↔ 14.25pt，
        // 往回收的时候四舍五入才还原得出用户当初选的数（直接截断会显示 21）。
        sizeLabel.stringValue = "\(Int(s.fontPointSize.rounded())) pt"
        // 跟随系统时，色块显示**实际生效**的系统配色 —— 否则显示的是存档里
        // 那两个没被使用的值，等于在骗人。
        let dark = isDarkAppearance
        if s.followSystemAppearance {
            textColorWell.color = NSColor(cgColor: s.renderTextColor(dark: dark)) ?? .black
            bgColorWell.color = NSColor(cgColor: s.renderBackgroundColor(dark: dark)) ?? .white
        } else {
            textColorWell.color = NSColor(cgColor: s.textColor) ?? .black
            bgColorWell.color = NSColor(cgColor: s.backgroundColor) ?? .white
        }
        followSystemCheck.state = s.followSystemAppearance ? .on : .off

        // ── 章节标题 ──
        titleSameFontCheck.state = s.useSameFont ? .on : .off
        selectPopup(titleFontPopup, s.titleFontName)
        titleSizeSlider.doubleValue = Double(s.titlePointSize)
        titleSizeLabel.stringValue = "\(Int(s.titlePointSize.rounded())) pt"
        // 与正文两个色块同样的规矩：跟随系统时显示**实际生效**的颜色，
        // 否则显示存档里的自定义值（哪怕当前没被用上，至少不是骗人的）。
        titleColorWell.color = s.followSystemAppearance
            ? (NSColor(cgColor: s.renderTitleColor(dark: dark)) ?? .black)
            : (NSColor(cgColor: s.titleColor) ?? .black)
        updateTitleControlsEnabled()
        let pct = Int(round(Double(s.alpha) / 255.0 * 100))
        alphaSlider.doubleValue = Double(max(10, min(100, pct)))
        alphaLabel.stringValue = "\(max(10, min(100, pct)))%"
        menuBarCheck.state = s.menuBarIcon ? .on : .off
        hotKeyCheck.state = s.globalHotKey ? .on : .off
        let secs = min(30, max(1, Int(round(Double(s.autoPageIntervalMS) / 1000.0))))
        autoPageIntervalSlider.doubleValue = Double(secs)
        autoPageIntervalLabel.stringValue = "\(secs) 秒"
        autoPageModePopup.selectItem(at: (s.autoPageMode & 0x0F) == 0x01 ? 1 : 0)
        autoPageCheck.state = isAutoPageOn() ? .on : .off
        hideChromeCheck.state = s.hideChrome ? .on : .off
        keepOnTopCheck.state = s.keepOnTop ? .on : .off
        selectAction(mouseLeftPopup, s.mouseLeftAction)
        selectAction(mouseRightPopup, s.mouseRightAction)
        selectAction(mouseBothPopup, s.mouseBothAction)
        // ⚠️ 色块**永远可点**。之前这里是 `isEnabled = !followSystemAppearance`，
        // 而「跟随系统」默认开启 → 用户根本改不了颜色，看起来就像功能坏了。
        textColorWell.isEnabled = true
        bgColorWell.isEnabled = true

        charGapSlider.doubleValue = Double(s.charGap)
        lineGapSlider.doubleValue = Double(s.lineGap)
        paraGapSlider.doubleValue = Double(s.paragraphGap)
        for (i, v) in [s.insetLeft, s.insetTop, s.insetRight, s.insetBottom].enumerated() {
            insetSliders[i].doubleValue = Double(v)
        }

        indentCheck.state = s.lineIndent ? .on : .off
        blankCheck.state = s.compressBlankLines ? .on : .off
        wrapCheck.state = s.wordWrap ? .on : .off
        chapterPageCheck.state = s.chapterPage ? .on : .off

        wheelPopup.selectItem(at: min(3, max(0, s.wheelSpeed)))
        smoothCheck.state = s.smoothScroll ? .on : .off
        overlapSlider.doubleValue = Double(s.leftLineCount)
        updateSliderValueLabels()

        rulePopup.selectItem(at: min(2, max(0, s.chapterRule.kind.rawValue)))
        keywordField.stringValue = s.chapterRule.keyword
        regexField.stringValue = s.chapterRule.regex
        updateRuleFieldState()
    }

    private func updateRuleFieldState() {
        let kind = rulePopup.indexOfSelectedItem
        keywordField.isEnabled = (kind == 1)
        regexField.isEnabled = (kind == 2)
    }

    /// 把界面上的值写回设置并通知外部刷新
    private func apply(_ mutate: (inout ReaderSettings) -> Void) {
        guard !isSyncing else { return }
        store.updateSettings(mutate)
        onChange()
    }

    private func colorRef(from well: NSColorWell) -> UInt32 {
        (well.color.usingColorSpace(.sRGB) ?? well.color).cgColor.colorRef
    }

    // MARK: - 动作

    @objc private func fontChanged() {
        guard let name = fontPopup.selectedItem?.representedObject as? String else { return }
        apply { $0.fontName = name }
    }

    @objc private func sizeChanged() {
        let v = CGFloat(sizeSlider.doubleValue.rounded())
        sizeLabel.stringValue = "\(Int(v)) pt"
        apply { $0.fontPointSize = v }
    }

    @objc private func colorChanged() {
        let t = colorRef(from: textColorWell)
        let b = colorRef(from: bgColorWell)
        apply {
            $0.textColorRef = t
            $0.backgroundColorRef = b
            // 用户显式选色 → 退出「跟随系统」，否则选了也不生效
            $0.followSystemAppearance = false
        }
        followSystemCheck.state = .off
    }

    @objc private func alphaChanged() {
        let pct = Int(alphaSlider.doubleValue.rounded())
        alphaLabel.stringValue = "\(pct)%"
        apply { $0.alpha = min(255, max(0, Int(round(Double(pct) * 255.0 / 100.0)))) }
    }

    /// 让滑块右侧的数字跟着滑块走（取整后显示）。
    /// 拖动是连续的，所以这个函数会被高频调用；只改 4 个 NSTextField，开销可以忽略。
    private func updateSliderValueLabels() {
        for (slider, label) in sliderValueLabels {
            label.stringValue = "\(Int(slider.doubleValue.rounded()))"
        }
    }

    /// 自检用：字距 / 行距 / 段距 / 翻页重叠 四个滑块右侧显示的数字
    var debugSpacingLabelValues: [String] {
        [charGapSlider, lineGapSlider, paraGapSlider, overlapSlider].compactMap {
            sliderValueLabels[$0]?.stringValue
        }
    }

    /// 自检用：模拟拖动四个间距滑块（走和真实拖动同一条刷新路径）
    func debugSetSpacing(charGap: Int, lineGap: Int, paraGap: Int, overlap: Int) {
        charGapSlider.doubleValue = Double(charGap)
        lineGapSlider.doubleValue = Double(lineGap)
        paraGapSlider.doubleValue = Double(paraGap)
        overlapSlider.doubleValue = Double(overlap)
        spacingChanged()
    }

    /// 自动翻页的开关状态刷新（到书末自动停下时也要能把勾去掉）
    func refreshAutoPageState() {
        autoPageCheck?.state = isAutoPageOn() ? .on : .off
    }

    @objc private func autoPageToggled() {
        onToggleAutoPage?()
        refreshAutoPageState()
    }

    @objc private func hideChromeChanged() {
        let on = hideChromeCheck.state == .on
        apply { $0.hideChrome = on }
    }

    // MARK: - 章节标题

    @objc private func titleSameFontChanged() {
        apply { $0.useSameFont = titleSameFontCheck.state == .on }
        updateTitleControlsEnabled()
    }

    @objc private func titleFontChanged() {
        guard let name = titleFontPopup.selectedItem?.representedObject as? String else { return }
        apply { $0.titleFontName = name }
    }

    @objc private func titleSizeChanged() {
        let v = CGFloat(titleSizeSlider.doubleValue.rounded())
        titleSizeLabel.stringValue = "\(Int(v)) pt"
        apply { $0.titlePointSize = v }
    }

    @objc private func titleColorChanged() {
        let ref = colorRef(from: titleColorWell)
        apply {
            $0.titleColorRef = ref
            // 和正文取色一致：用户显式选色就退出「跟随系统」，否则选了也不生效
            $0.followSystemAppearance = false
        }
        // 退出「跟随系统」会同时改变正文/背景的实际配色，整块面板要一起刷新 ——
        // 否则正文色块还显示着系统配色，看起来像「点了标题色、正文图标错了」。
        syncFromSettings()
    }

    private func makeMousePopup(_ actions: [ReaderSettings.MouseAction],
                                _ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, a) in actions.enumerated() {
            p.addItem(withTitle: titles[i])
            p.lastItem?.representedObject = a.rawValue
        }
        p.target = self
        p.action = action
        return p
    }

    private func selectedAction(_ p: NSPopUpButton) -> ReaderSettings.MouseAction {
        guard let raw = p.selectedItem?.representedObject as? Int else { return .none }
        return ReaderSettings.MouseAction(rawValue: raw) ?? .none
    }

    private func selectAction(_ p: NSPopUpButton, _ action: ReaderSettings.MouseAction) {
        for item in p.itemArray where (item.representedObject as? Int) == action.rawValue {
            p.select(item)
            return
        }
    }

    @objc private func mouseLeftChanged() {
        let a = selectedAction(mouseLeftPopup)
        apply { $0.mouseLeftAction = a }
    }

    @objc private func mouseRightChanged() {
        let a = selectedAction(mouseRightPopup)
        apply { $0.mouseRightAction = a }
    }

    @objc private func mouseBothChanged() {
        let a = selectedAction(mouseBothPopup)
        apply { $0.mouseBothAction = a }
    }

    @objc private func menuBarChanged() {
        let on = menuBarCheck.state == .on
        apply { $0.menuBarIcon = on }
    }

    @objc private func hotKeyChanged() {
        let on = hotKeyCheck.state == .on
        apply { $0.globalHotKey = on }
    }

    @objc private func keepOnTopChanged() {
        let on = keepOnTopCheck.state == .on
        apply { $0.keepOnTop = on }
    }

    @objc private func autoPageIntervalChanged() {
        let secs = Int(autoPageIntervalSlider.doubleValue.rounded())
        autoPageIntervalLabel.stringValue = "\(secs) 秒"
        apply { $0.autoPageIntervalMS = secs * 1000 }
    }

    @objc private func autoPageModeChanged() {
        let lineMode = autoPageModePopup.indexOfSelectedItem == 1
        apply { s in
            // 低半字节 = 翻页(0)/逐行(1)；高半字节保留（原版「按字数」模式）
            s.autoPageMode = (s.autoPageMode & 0xF0) | (lineMode ? 0x01 : 0x00)
        }
    }

    @objc private func followSystemChanged() {
        let on = followSystemCheck.state == .on
        apply { $0.followSystemAppearance = on }
    }

    @objc private func spacingChanged() {
        let cg = Int(charGapSlider.doubleValue.rounded())
        let lg = Int(lineGapSlider.doubleValue.rounded())
        let pg = Int(paraGapSlider.doubleValue.rounded())
        let insets = insetSliders.map { Int($0.doubleValue.rounded()) }
        let overlap = Int(overlapSlider.doubleValue.rounded())
        updateSliderValueLabels()
        apply {
            $0.charGap = cg
            $0.lineGap = lg
            $0.paragraphGap = pg
            $0.insetLeft = insets[0]; $0.insetTop = insets[1]
            $0.insetRight = insets[2]; $0.insetBottom = insets[3]
            $0.leftLineCount = overlap
        }
    }

    @objc private func toggleChanged() {
        let a = indentCheck.state == .on
        let b = blankCheck.state == .on
        let c = wrapCheck.state == .on
        let d = chapterPageCheck.state == .on
        apply {
            $0.lineIndent = a
            $0.compressBlankLines = b
            $0.wordWrap = c
            $0.chapterPage = d
        }
    }

    @objc private func smoothChanged() {
        let on = smoothCheck.state == .on
        apply { $0.smoothScroll = on }
    }

    @objc private func wheelChanged() {
        let v = wheelPopup.indexOfSelectedItem
        apply { $0.wheelSpeed = v }
    }

    @objc private func ruleKindChanged() {
        updateRuleFieldState()
        let kind = rulePopup.indexOfSelectedItem
        apply { $0.chapterRule.kind = ChapterRuleKind(rawValue: kind) ?? .default }
    }

    @objc private func ruleTextChanged() {
        let kw = keywordField.stringValue
        let re = regexField.stringValue
        apply {
            $0.chapterRule.keyword = kw
            $0.chapterRule.regex = re
        }
    }

    @objc private func resetDefaults() {
        let a = NSAlert()
        a.messageText = "还原所有显示设置？"
        a.informativeText = "字体会回到苹方 14pt、配色回到默认、排版与章节规则一并重置。阅读进度和书架不受影响。"
        a.addButton(withTitle: "还原")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.updateSettings { s in
            let fresh = ReaderSettings()
            s.fontName = fresh.fontName
            s.fontPointSize = fresh.fontPointSize
            s.useSameFont = fresh.useSameFont
            s.titleFontName = fresh.titleFontName
            s.titlePointSize = fresh.titlePointSize
            s.titleColorRef = fresh.titleColorRef
            s.textColorRef = fresh.textColorRef
            s.backgroundColorRef = fresh.backgroundColorRef
            s.followSystemAppearance = fresh.followSystemAppearance
            s.alpha = fresh.alpha
            s.menuBarIcon = fresh.menuBarIcon
            s.globalHotKey = fresh.globalHotKey
            s.autoPageIntervalMS = fresh.autoPageIntervalMS
            s.autoPageMode = fresh.autoPageMode
            s.hideChrome = fresh.hideChrome
            s.pageMode = fresh.pageMode
            s.disableBothClickHide = fresh.disableBothClickHide
            s.mouseLeftAction = fresh.mouseLeftAction
            s.mouseRightAction = fresh.mouseRightAction
            s.mouseBothAction = fresh.mouseBothAction
            s.charGap = fresh.charGap
            s.lineGap = fresh.lineGap
            s.paragraphGap = fresh.paragraphGap
            s.insetLeft = fresh.insetLeft; s.insetTop = fresh.insetTop
            s.insetRight = fresh.insetRight; s.insetBottom = fresh.insetBottom
            s.lineIndent = fresh.lineIndent
            s.compressBlankLines = fresh.compressBlankLines
            s.wordWrap = fresh.wordWrap
            s.chapterPage = fresh.chapterPage
            s.wheelSpeed = fresh.wheelSpeed
            s.smoothScroll = fresh.smoothScroll
            s.leftLineCount = fresh.leftLineCount
            s.chapterRule = fresh.chapterRule
        }
        syncFromSettings()
        onChange()
    }

    func show() {
        syncFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncFromSettings()
    }
}


/// 让内容从顶部开始排的容器视图（NSScrollView 的文档视图默认原点在左下角）
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
