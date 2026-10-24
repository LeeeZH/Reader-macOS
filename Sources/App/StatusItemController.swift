import AppKit

/// 菜单栏图标（托盘）。对应原版 `Shell_NotifyIcon` 那一套。
///
/// 它的价值不只是「多个入口」：全局热键把窗口藏起来之后，
/// 菜单栏图标是唯一还能点回来的地方。
final class StatusItemController: NSObject, NSMenuDelegate {

    private var item: NSStatusItem?

    var onShowHide: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onShowLibrary: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onToggleAutoPage: (() -> Void)?
    var isAutoPageOn: () -> Bool = { false }
    var onToggleChrome: (() -> Void)?
    var isChromeHidden: () -> Bool = { false }

    var isInstalled: Bool { item != nil }

    /// 自检用：当前菜单项标题
    var debugMenuTitles: [String] {
        (item?.menu?.items ?? []).filter { !$0.isSeparatorItem }.map { $0.title }
    }

    func install() {
        guard item == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "book.fill", accessibilityDescription: "Reader")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Reader"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "显示 / 隐藏阅读窗口", action: #selector(doShowHide), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开文件…", action: #selector(doOpenFile), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "阅读列表", action: #selector(doShowLibrary), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "自动翻页", action: #selector(doToggleAutoPage), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "沉浸阅读（隐藏顶栏和底栏）", action: #selector(doToggleChrome), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示设置…", action: #selector(doShowSettings), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        item = statusItem
    }

    func uninstall() {
        if let item = item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
    }

    /// 菜单每次弹出前刷新各开关的勾选状态
    func menuNeedsUpdate(_ menu: NSMenu) {
        let autoOn = isAutoPageOn()
        let chromeHidden = isChromeHidden()
        for menuItem in menu.items {
            switch menuItem.action {
            case #selector(doToggleAutoPage): menuItem.state = autoOn ? .on : .off
            case #selector(doToggleChrome):   menuItem.state = chromeHidden ? .on : .off
            default: break
            }
        }
    }

    @objc private func doShowHide() { onShowHide?() }
    @objc private func doOpenFile() { onOpenFile?() }
    @objc private func doShowLibrary() { onShowLibrary?() }
    @objc private func doShowSettings() { onShowSettings?() }
    @objc private func doToggleAutoPage() { onToggleAutoPage?() }
    @objc private func doToggleChrome() { onToggleChrome?() }
}
