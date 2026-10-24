import AppKit

/// 触控栏（Touch Bar）支持 —— 面向带 Touch Bar 的 MacBook Pro（如 Mac14,7 = 13" M2 2022）。
///
/// 设计取舍：触控栏横向空间非常有限（大约只放得下 5~6 个元素），所以
///   - **常驻区**只放最高频的：上一页 / 进度 / 下一页；
///   - **两侧各一个 popover**：「文件」和「阅读」，把长尾操作收进去，点开才展开；
///   - 其余动作（上一章/下一章/加书签/字号…）注册为**可选**，
///     用户可以在系统「自定义触控栏…」里自己拖出来。
///
/// 不带 Touch Bar 的机器上，这些 API 都是安全的空操作，不会报错也不会有副作用。
final class ReaderTouchBar: NSObject, NSTouchBarDelegate {

    static let shared = ReaderTouchBar()

    private weak var target: AnyObject?
    private var progressField: NSTextField?
    /// 进度文字可能先于控件创建到达（触控栏是懒加载的），先记下来
    private var pendingProgressText = "—"

    // MARK: - 标识符

    enum ID {
        static let customization = NSTouchBar.CustomizationIdentifier("com.lizhuohong.reader.touchbar")

        static let fileGroup      = NSTouchBarItem.Identifier("reader.fileGroup")
        static let readGroup      = NSTouchBarItem.Identifier("reader.readGroup")
        static let prevPage       = NSTouchBarItem.Identifier("reader.prevPage")
        static let nextPage       = NSTouchBarItem.Identifier("reader.nextPage")
        static let progress       = NSTouchBarItem.Identifier("reader.progress")
        static let prevChapter    = NSTouchBarItem.Identifier("reader.prevChapter")
        static let nextChapter    = NSTouchBarItem.Identifier("reader.nextChapter")
        static let addBookmark    = NSTouchBarItem.Identifier("reader.addBookmark")
        static let fontSmaller    = NSTouchBarItem.Identifier("reader.fontSmaller")
        static let fontLarger     = NSTouchBarItem.Identifier("reader.fontLarger")
        static let openFile       = NSTouchBarItem.Identifier("reader.openFile")
        static let library        = NSTouchBarItem.Identifier("reader.library")
        static let exportArchive  = NSTouchBarItem.Identifier("reader.exportArchive")
        static let revealArchive  = NSTouchBarItem.Identifier("reader.revealArchive")
    }

    // MARK: - 主条

    func makeTouchBar(target: AnyObject) -> NSTouchBar {
        self.target = target
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = ID.customization
        bar.defaultItemIdentifiers = [
            ID.fileGroup,
            .fixedSpaceSmall,
            ID.prevPage,
            ID.progress,
            ID.nextPage,
            .fixedSpaceSmall,
            ID.readGroup,
        ]
        bar.customizationAllowedItemIdentifiers = [
            ID.fileGroup, ID.readGroup,
            ID.prevPage, ID.nextPage,
            ID.prevChapter, ID.nextChapter,
            ID.progress,
            ID.addBookmark,
            ID.fontSmaller, ID.fontLarger,
            .flexibleSpace, .fixedSpaceSmall, .fixedSpaceLarge,
        ]
        bar.principalItemIdentifier = ID.progress
        return bar
    }

    // MARK: - 子 popover

    private func makeFileBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [
            ID.openFile, ID.library,
            .fixedSpaceSmall,
            ID.exportArchive,
            .fixedSpaceSmall,
            ID.revealArchive,
        ]
        return bar
    }

    private func makeReadBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [
            ID.prevChapter, ID.nextChapter,
            .fixedSpaceSmall,
            ID.addBookmark,
            .fixedSpaceSmall,
            ID.fontSmaller, ID.fontLarger,
        ]
        return bar
    }

    // MARK: - 进度

    /// 由 AppDelegate 在翻页 / 换书时调用
    func updateProgress(_ text: String) {
        pendingProgressText = text
        progressField?.stringValue = text
    }

    // MARK: - 调试：把会构建出来的条目列出来（无法用眼睛看触控栏时用这个核对）

    func describeAllItems(target: AnyObject) -> [String] {
        let bar = makeTouchBar(target: target)
        var out: [String] = []
        out.append("主条默认: " + bar.defaultItemIdentifiers.map { $0.rawValue }.joined(separator: ", "))
        out.append("主条可自定义: " + bar.customizationAllowedItemIdentifiers.map { $0.rawValue }.joined(separator: ", "))
        for id in bar.defaultItemIdentifiers where !id.rawValue.hasPrefix("NSTouchBarItem") {
            guard let item = touchBar(bar, makeItemForIdentifier: id) else { continue }
            out.append(describe(item, id))
            if let pop = item as? NSPopoverTouchBarItem {
                let sub = pop.popoverTouchBar      // Swift 里是非可选类型
                out.append("    └ popover: " + sub.defaultItemIdentifiers.map { $0.rawValue }.joined(separator: ", "))
                for sid in sub.defaultItemIdentifiers where !sid.rawValue.hasPrefix("NSTouchBarItem") {
                    if let s = touchBar(sub, makeItemForIdentifier: sid) { out.append("        " + describe(s, sid)) }
                }
            }
        }
        out.append("可选条目:")
        for id in bar.customizationAllowedItemIdentifiers
        where !id.rawValue.hasPrefix("NSTouchBarItem")
            && !bar.defaultItemIdentifiers.contains(id) {
            if let item = touchBar(bar, makeItemForIdentifier: id) { out.append("    " + describe(item, id)) }
        }
        return out
    }

    private func describe(_ item: NSTouchBarItem, _ id: NSTouchBarItem.Identifier) -> String {
        var s = "\(id.rawValue) → \(type(of: item))"
        if let b = item as? NSButtonTouchBarItem { s += "  标题=\"\(b.title)\" enabled=\(b.isEnabled)" }
        if let p = item as? NSPopoverTouchBarItem {
            s += "  折叠=\"\(p.collapsedRepresentationLabel)\" 内含 \(p.popoverTouchBar.defaultItemIdentifiers.count) 项"
        }
        if let c = item as? NSCustomTouchBarItem { s += "  视图=\(type(of: c.view)) 优先级=\(c.visibilityPriority.rawValue)" }
        return s
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let t = target

        func button(_ id: NSTouchBarItem.Identifier, _ title: String, _ action: Selector) -> NSTouchBarItem {
            let item = NSButtonTouchBarItem(identifier: id, title: title, target: t, action: action)
            item.customizationLabel = title
            return item
        }

        switch identifier {

        // ---- 常驻 ----
        case ID.prevPage:
            return button(ID.prevPage, "◀ 上一页", #selector(AppDelegate.tbPrevPage(_:)))

        case ID.nextPage:
            return button(ID.nextPage, "下一页 ▶", #selector(AppDelegate.tbNextPage(_:)))

        case ID.progress:
            let item = NSCustomTouchBarItem(identifier: ID.progress)
            let label = NSTextField(labelWithString: pendingProgressText)
            label.alignment = .center
            label.font = .systemFont(ofSize: 13)
            label.textColor = .white
            // ⚠️ 必须用**中间截断**：文字是「书名 · 章节标题 · 百分比」，
            // 尾部截断会把百分比切掉，那是读者最需要的信息。
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
            label.heightAnchor.constraint(equalToConstant: 20).isActive = true
            // 空间不够时优先压缩自己，而不是把两侧的翻页按钮挤掉
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            item.view = label
            item.customizationLabel = "阅读进度"
            item.visibilityPriority = .high
            progressField = label
            return item

        // ---- popover ----
        case ID.fileGroup:
            let item = NSPopoverTouchBarItem(identifier: ID.fileGroup)
            item.collapsedRepresentationLabel = "文件"
            item.customizationLabel = "文件"
            item.popoverTouchBar = makeFileBar()
            item.showsCloseButton = true
            return item

        case ID.readGroup:
            let item = NSPopoverTouchBarItem(identifier: ID.readGroup)
            item.collapsedRepresentationLabel = "阅读"
            item.customizationLabel = "阅读"
            item.popoverTouchBar = makeReadBar()
            item.showsCloseButton = true
            return item

        case ID.openFile:      return button(ID.openFile, "打开…", #selector(AppDelegate.tbOpenFile(_:)))
        case ID.library:       return button(ID.library, "阅读列表", #selector(AppDelegate.tbLibrary(_:)))
        case ID.exportArchive: return button(ID.exportArchive, "导出存档…", #selector(AppDelegate.tbExportArchive(_:)))
        case ID.revealArchive: return button(ID.revealArchive, "显示存档", #selector(AppDelegate.tbRevealArchive(_:)))

        case ID.prevChapter:   return button(ID.prevChapter, "◀◀ 上一章", #selector(AppDelegate.tbPrevChapter(_:)))
        case ID.nextChapter:   return button(ID.nextChapter, "下一章 ▶▶", #selector(AppDelegate.tbNextChapter(_:)))
        case ID.addBookmark:   return button(ID.addBookmark, "加书签", #selector(AppDelegate.tbAddBookmark(_:)))
        case ID.fontSmaller:   return button(ID.fontSmaller, "A−", #selector(AppDelegate.tbFontSmaller(_:)))
        case ID.fontLarger:    return button(ID.fontLarger, "A＋", #selector(AppDelegate.tbFontLarger(_:)))

        default:
            // .fixedSpaceSmall / .flexibleSpace 这类系统标识符由 AppKit 自己处理，
            // 不会走到 delegate 这里
            return nil
        }
    }
}
