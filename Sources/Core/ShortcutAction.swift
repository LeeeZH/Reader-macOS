import Foundation

/// 快捷键页的分组（和菜单结构对应，用户找起来有据可依）。
enum ShortcutCategory: String, CaseIterable {
    case file
    case reading
    case find
    case view
    case app

    var title: String {
        switch self {
        case .file: return "文件"
        case .reading: return "阅读"
        case .find: return "查找"
        case .view: return "视图"
        case .app: return "设置"
        }
    }
}

/// 所有**可自定义**的菜单功能。一个 case = 菜单里的一行 + 快捷键页的一行。
///
/// ⚠️ `rawValue` 是写进 `.cache.dat` 的稳定 id（`macos_shortcuts` 的键），
/// 一旦发布就不能改名，否则用户的自定义键位会丢。
///
/// 系统标准键不在这个表里，固定不动：
/// 退出 `⌘Q`、隐藏 `⌘H`、关闭窗口 `⌘W`、最小化 `⌘M`、关于、自定义触控栏。
enum ShortcutAction: String, CaseIterable {

    // 文件
    case openFile = "open_file"
    case showLibrary = "show_library"
    case revealArchive = "reveal_archive"

    // 阅读
    case prevPage = "prev_page"
    case nextPage = "next_page"
    case prevChapter = "prev_chapter"
    case nextChapter = "next_chapter"
    case addBookmark = "add_bookmark"
    case toggleHideChrome = "toggle_hide_chrome"
    case toggleEditMode = "toggle_edit_mode"
    case toggleAutoPage = "toggle_auto_page"
    case showBookmarks = "show_bookmarks"
    case fontLarger = "font_larger"
    case fontSmaller = "font_smaller"

    // 查找
    case showFind = "show_find"
    case findNext = "find_next"
    case findPrevious = "find_previous"
    case jumpToChapter = "jump_to_chapter"

    // 视图
    case keepOnTop = "keep_on_top"
    case fullScreen = "full_screen"

    // 设置
    case appSettings = "app_settings"

    /// 快捷键页里的功能名（短、直白）
    var title: String {
        switch self {
        case .openFile: return "打开文件"
        case .showLibrary: return "阅读列表"
        case .revealArchive: return "在访达中显示存档"
        case .prevPage: return "上一页"
        case .nextPage: return "下一页"
        case .prevChapter: return "上一章"
        case .nextChapter: return "下一章"
        case .addBookmark: return "添加书签"
        case .toggleHideChrome: return "沉浸模式"
        case .toggleEditMode: return "编辑模式"
        case .toggleAutoPage: return "自动翻页"
        case .showBookmarks: return "书签面板"
        case .fontLarger: return "放大字号"
        case .fontSmaller: return "缩小字号"
        case .showFind: return "查找"
        case .findNext: return "查找下一个"
        case .findPrevious: return "查找上一个"
        case .jumpToChapter: return "跳转到章节"
        case .keepOnTop: return "窗口置顶"
        case .fullScreen: return "进入全屏幕"
        case .appSettings: return "显示设置"
        }
    }

    /// 菜单里那一行原本的标题（AppDelegate 建菜单用，和以前逐字一致）
    var menuTitle: String {
        switch self {
        case .openFile: return "打开…"
        case .showLibrary: return "阅读列表"
        case .revealArchive: return "在访达中显示存档"
        case .prevPage: return "上一页"
        case .nextPage: return "下一页"
        case .prevChapter: return "上一章"
        case .nextChapter: return "下一章"
        case .addBookmark: return "添加书签"
        case .toggleHideChrome: return "沉浸模式（隐藏顶栏和底栏）"
        case .toggleEditMode: return "编辑模式"
        case .toggleAutoPage: return "自动翻页"
        case .showBookmarks: return "书签…"
        case .fontLarger: return "放大字号"
        case .fontSmaller: return "缩小字号"
        case .showFind: return "查找…"
        case .findNext: return "查找下一个"
        case .findPrevious: return "查找上一个"
        case .jumpToChapter: return "跳转到章节…"
        case .keepOnTop: return "窗口置顶"
        case .fullScreen: return "进入全屏幕"
        case .appSettings: return "显示设置…"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .openFile, .showLibrary, .revealArchive: return .file
        case .prevPage, .nextPage, .prevChapter, .nextChapter,
             .addBookmark, .toggleHideChrome, .toggleEditMode, .toggleAutoPage,
             .showBookmarks, .fontLarger, .fontSmaller:
            return .reading
        case .showFind, .findNext, .findPrevious, .jumpToChapter: return .find
        case .keepOnTop, .fullScreen: return .view
        case .appSettings: return .app
        }
    }

    /// 默认键位。改动这里等于改「还原默认」的目标，发布后不要再动
    /// （除非是有意调整默认值，并同步 README 的快捷键速查）。
    var defaultCombo: KeyCombo {
        switch self {
        case .openFile: return KeyCombo(.character("o"), .command)
        case .showLibrary: return KeyCombo(.character("l"), .command)
        case .revealArchive: return KeyCombo(.character("s"), [.command, .shift])
        case .prevPage: return KeyCombo(.left)
        case .nextPage: return KeyCombo(.right)
        case .prevChapter: return KeyCombo(.up, .command)
        case .nextChapter: return KeyCombo(.down, .command)
        // 原版 Windows 是 Ctrl+M 加书签，macOS 上 ⌘M 是「最小化」的系统标准键，
        // 留给最小化；加书签沿用浏览器 / 阅读器的通用约定 ⌘D。
        case .addBookmark: return KeyCombo(.character("d"), .command)
        case .toggleHideChrome: return KeyCombo(.character("b"), [.command, .shift])
        case .toggleEditMode: return KeyCombo(.character("e"), .command)
        case .toggleAutoPage: return KeyCombo(.character("a"), [.command, .shift])
        case .showBookmarks: return KeyCombo(.character("b"), .command)
        case .fontLarger: return KeyCombo(.character("="), .command)
        case .fontSmaller: return KeyCombo(.character("-"), .command)
        case .showFind: return KeyCombo(.character("f"), .command)
        case .findNext: return KeyCombo(.character("g"), .command)
        case .findPrevious: return KeyCombo(.character("g"), [.command, .shift])
        case .jumpToChapter: return KeyCombo(.character("j"), .command)
        case .keepOnTop: return KeyCombo(.character("t"), [.command, .control])
        case .fullScreen: return KeyCombo(.character("f"), [.command, .control])
        case .appSettings: return KeyCombo(.character(","), .command)
        }
    }

    /// 给状态栏 / 提示文案用的全称，例如「command + F」。
    /// 设置没改过时就是默认值。
    func display(in settings: ReaderSettings) -> String {
        settings.shortcut(self)?.display ?? "未设置"
    }
}
