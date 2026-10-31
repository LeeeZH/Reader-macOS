import Foundation
import CoreGraphics

/// `header` 里与阅读相关的字段的类型化视图。
/// 未建模的字段（按键绑定、书源、代理…）留在 `CacheDocument.header` 里原样保留。
struct ReaderSettings {
    var fontName: String = ReaderDefaults.fontName
    var fontPointSize: CGFloat = ReaderDefaults.fontSize
    var textColorRef: UInt32 = 0x000000
    var titleColorRef: UInt32 = 0x000000
    var backgroundColorRef: UInt32 = 0x00FFFFFF
    var alpha: Int = 0xFF

    /// 章节标题是否与正文「同字体同色」——原版 `header.use_same_font`，默认 1。
    ///
    /// 这个字段的语义和前两个**绑在一起**（见原版 `Page::SelectFont`）：
    /// 为 1 时标题行连 `font_title` / `font_color_title` 都不看，整行走正文那套；
    /// 为 0 时标题段落才切到下面这套字体与颜色。
    /// 直接读写原版字段，不新增自定义键 —— Windows 存档里的标题字体过来就能生效。
    var useSameFont: Bool = true
    /// 标题字体（原版 `header.font_title` 的 LOGFONT，点值换算与正文相同）
    var titleFontName: String = ReaderDefaults.fontName
    var titlePointSize: CGFloat = ReaderDefaults.fontSize

    /// 背景图片（原版 `header.bg_image`，三个字段：enable / mode / file_name）。
    /// `mode` 语义照原版 `DisplaySet.cpp`：0 = 拉伸、1 = 平铺、2 = 平铺翻转。
    /// 直接读写原版结构，不新增自定义键。
    var bgImageEnabled: Bool = false
    var bgImageMode: Int = 0
    var bgImageFileName: String = ""

    /// 用户自定义的快捷键。原版没有对应字段（它的 `keyset` 是 Win32 的 VK 码，
    /// 和 macOS 的菜单键位对不齐），所以走自定义键 `macos_shortcuts`，Windows 版忽略。
    ///
    /// 只存**覆盖项**：key = `ShortcutAction.rawValue`，value = `KeyCombo.stored`。
    /// value 为空串表示用户主动清掉了绑定（菜单上不显示快捷键）。
    var shortcutOverrides: [String: String] = [:]

    var charGap: Int = 0
    var lineGap: Int = 5
    var paragraphGap: Int = 15
    var leftLineCount: Int = 0
    var insetLeft: Int = 0
    var insetTop: Int = 0
    var insetRight: Int = 0
    var insetBottom: Int = 0

    var wordWrap: Bool = false
    var lineIndent: Bool = true
    var compressBlankLines: Bool = true
    var chapterPage: Bool = false

    var wheelSpeed: Int = 0
    var autoPageMode: Int = 0
    var autoPageIntervalMS: Int = 3000

    /// 跟随系统深色模式。
    ///
    /// 打开时忽略下面两个自定义颜色，用系统配色 —— 这样在浅色/深色之间切换时
    /// 阅读界面会跟着变。用户一旦自己调过颜色，设置界面会自动把它关掉。
    ///
    /// 存成 header 里的自定义键 `macos_follow_system`：Windows 版读到会忽略，
    /// 它自己存盘时也会丢掉这个键（读不到就退回默认值 true，行为仍然合理）。
    var followSystemAppearance: Bool = true

    /// 平滑滚动：按像素连续滚动（带缓出动画），而不是一次跳一整行。
    /// 关掉后恢复原版那种「一格滚 N 行」的跳行手感。
    ///
    /// 和 `followSystemAppearance` 一样存成 header 里的自定义键
    /// `macos_smooth_scroll` —— Windows 版会忽略。
    var smoothScroll: Bool = true

    /// 在菜单栏显示图标（托盘）
    var menuBarIcon: Bool = true
    /// 启用全局热键隐藏/显示窗口
    var globalHotKey: Bool = true

    /// 沉浸模式：隐藏标题栏（含关闭/最小化/最大化按钮）和底部状态栏
    var hideChrome: Bool = false

    /// 全文搜索是否区分大小写（「查找」面板里的 checkbox）。
    /// 和上面几个一样存成 header 自定义键 `macos_find_case_sensitive`，Windows 版忽略。
    var findCaseSensitive: Bool = false

    /// 窗口置顶：主窗口浮在其它应用的普通窗口 / 最大化窗口之上
    /// （`NSWindow.level = .floating`）。
    ///
    /// 为什么只做到 `floating`，不去盖别人的**原生全屏**：
    /// 原生全屏是独立 Space，跨 App 覆盖要靠 `.canJoinAllSpaces` +
    /// `.fullScreenAuxiliary` + 更高 level，属于系统没承诺的灰区，升级可能就坏。
    /// 需求只到「最大化应用也不挡住」，floating 就够，而且稳定。
    ///
    /// 存成 header 自定义键 `macos_always_on_top`，Windows 版读到会忽略。
    var keepOnTop: Bool = false

    /// 鼠标每个键分别做什么（取代原版 page_mode 的预设）
    enum MouseAction: Int, CaseIterable {
        case none = 0          // 不动作
        case nextPage = 1      // 下一页
        case prevPage = 2      // 上一页
        case toggleHide = 3    // 隐藏/显示窗口
        case minimize = 4      // 最小化窗口
    }

    var mouseLeftAction: MouseAction = .nextPage
    var mouseRightAction: MouseAction = .prevPage
    /// 左右键一起按的动作（只支持隐藏 / 最小化 / 不动作）
    var mouseBothAction: MouseAction = .toggleHide

    /// 鼠标翻页方式（原版 `page_mode`，只用于和 Windows 存档互转）：
    ///   0 = 鼠标不翻页
    ///   1 = 左键下一页、右键上一页（原版默认）
    ///   2 = 三分区：左 1/3 上一页、右 1/3 下一页、中间不动
    var pageMode: Int = 1

    /// 禁用「左右键一起按隐藏窗口」（原版 `disable_lrhide`）。
    /// 原版默认禁用；我们默认**开启**，因为这是摸鱼的关键操作。
    var disableBothClickHide: Bool = false

    /// 全局热键的组合键名称（放 Core 里，设置界面也能引用）。
    /// 实际注册在 `Sources/App/GlobalHotKey.swift`。
    static let globalHotKeyDisplayName = "⌃⌥H"

    var chapterRule = ChapterRule()

    // MARK: 从 header 读取

    init() {}

    init(header: [String: JSONValue]) {
        let d = CacheSchema.defaultHeader()
        func i(_ k: String) -> Int { header[k]?.intValue ?? d[k]?.intValue ?? 0 }
        func b(_ k: String) -> Bool { i(k) != 0 }
        func s(_ k: String) -> String { header[k]?.stringValue ?? d[k]?.stringValue ?? "" }
        _ = s   // 目前只有部分字段是字符串，保留helper等待设置界面使用

        // 保留存档里的原始字体名（可能是 Windows 字体）。
        // 渲染时的回退交给 FontResolver —— 这里若改写，用户切回 Windows 就丢设置了。
        fontName = fontField("lfFaceName", header, d)
        let lfHeight = fontFieldInt("lfHeight", header, d, fallback: -19)
        // LOGFONT.lfHeight 是 96 DPI 下的**像素**高（负数）；点值 = 像素 × 72 / 96
        fontPointSize = max(6, min(96, CGFloat(-lfHeight) * 72.0 / 96.0))

        // 标题字体：默认值与正文相同（原版 default_header 里 font_title = logoFont()），
        // 所以「没配过标题字体」的存档读出来仍是同字体，渲染结果与 M2 之前逐像素一致。
        useSameFont = b("use_same_font")
        titleFontName = fontField("lfFaceName", header, d, in: "font_title")
        let titleLfHeight = fontFieldInt("lfHeight", header, d, in: "font_title", fallback: -19)
        titlePointSize = max(6, min(96, CGFloat(-titleLfHeight) * 72.0 / 96.0))

        textColorRef = UInt32(truncatingIfNeeded: i("font_color"))
        titleColorRef = UInt32(truncatingIfNeeded: i("font_color_title"))
        backgroundColorRef = UInt32(truncatingIfNeeded: i("bg_color"))
        alpha = i("alpha")

        charGap = i("char_gap")
        lineGap = i("line_gap")
        paragraphGap = i("paragraph_gap")
        leftLineCount = i("left_line_count")
        // 背景图片：缺这个对象时保持字段初值（关闭 / 拉伸 / 空路径）
        if let bi = header["bg_image"] {
            bgImageEnabled = (bi.field("enable")?.intValue ?? 0) != 0
            bgImageMode = bi.field("mode")?.intValue ?? 0
            bgImageFileName = bi.field("file_name")?.stringValue ?? ""
        }
        // 快捷键覆盖项：缺这个键 = 全用默认；空串 = 用户清掉了绑定
        if let sc = header["macos_shortcuts"]?.objectValue {
            for (k, v) in sc {
                if let raw = v.stringValue { shortcutOverrides[k] = raw }
            }
        }
        if let r = header["internal_border"], let o = r.objectValue {
            var m: [String: Int] = [:]
            for (k, v) in o { m[k] = v.intValue ?? 0 }
            insetLeft = m["left"] ?? 0; insetTop = m["top"] ?? 0
            insetRight = m["right"] ?? 0; insetBottom = m["bottom"] ?? 0
        }

        wordWrap = b("word_wrap")
        lineIndent = b("line_indent")
        compressBlankLines = b("blank_lines")
        chapterPage = b("chapter_page")

        wheelSpeed = i("wheel_speed")
        autoPageMode = i("autopage_mode")
        autoPageIntervalMS = i("uElapse")

        // 默认 true：新装用户开箱就能跟随系统深色模式
        followSystemAppearance = header["macos_follow_system"]?.boolValue ?? true
        smoothScroll = header["macos_smooth_scroll"]?.boolValue ?? true
        menuBarIcon = header["macos_menu_bar"]?.boolValue ?? true
        globalHotKey = header["macos_hotkey"]?.boolValue ?? true
        hideChrome = header["macos_hide_chrome"]?.boolValue ?? false
        findCaseSensitive = header["macos_find_case_sensitive"]?.boolValue ?? false
        keepOnTop = header["macos_always_on_top"]?.boolValue ?? false
        pageMode = header["page_mode"]?.intValue ?? 1
        // 注意这里是「禁用」语义：原版默认 1（禁用），缺省时我们取 0（启用）
        disableBothClickHide = (header["disable_lrhide"]?.intValue ?? 0) != 0

        // 每个键的动作。没有自定义键时，从原版的 page_mode / disable_lrhide 推导，
        // 这样 Windows 存档也能得到合理的行为。
        if let v = header["macos_mouse_left"]?.intValue, let a = MouseAction(rawValue: v) {
            mouseLeftAction = a
        } else {
            // page_mode 0 = 不翻页；1 / 2 都当作「左键下一页」（2 的三分区在 macOS 版没做）
            mouseLeftAction = pageMode == 0 ? .none : .nextPage
        }
        if let v = header["macos_mouse_right"]?.intValue, let a = MouseAction(rawValue: v) {
            mouseRightAction = a
        } else {
            mouseRightAction = pageMode == 0 ? .none : .prevPage
        }
        if let v = header["macos_mouse_both"]?.intValue, let a = MouseAction(rawValue: v) {
            mouseBothAction = a
        } else {
            mouseBothAction = disableBothClickHide ? .none : .toggleHide
        }

        if let cr = header["chapter_rule"] {
            chapterRule = ChapterRule(
                kind: ChapterRuleKind(rawValue: cr.field("rule")?.intValue ?? 0) ?? .default,
                keyword: cr.field("keyword")?.stringValue ?? "",
                regex: cr.field("regex")?.stringValue ?? "")
        }
    }

    /// 读某个 LOGFONT 字段。`in` 是 header 里的字体对象名：正文 `font`、标题 `font_title`。
    private func fontField(_ key: String, _ h: [String: JSONValue], _ d: [String: JSONValue],
                           in parent: String = "font") -> String {
        h[parent]?.field(key)?.stringValue ?? d[parent]?.field(key)?.stringValue ?? ""
    }
    private func fontFieldInt(_ key: String, _ h: [String: JSONValue], _ d: [String: JSONValue],
                              in parent: String = "font", fallback: Int) -> Int {
        h[parent]?.field(key)?.intValue ?? d[parent]?.field(key)?.intValue ?? fallback
    }

    // MARK: 写回 header

    /// 把字体名 / 字号写回某个 LOGFONT 对象（正文 `font` / 标题 `font_title`）。
    ///
    /// ⚠️ 存档里**完全没有**这个键（或是个空对象）时必须退回默认 LOGFONT。
    /// 直接写 `{}` 会让 Windows 版读到 lfHeight / lfFaceName 全 0 的字体 —— 字体就没了。
    /// `CacheCodec.decode` 不会补齐缺键（只有写盘时 `normalizedHeader` 才按顺序补），
    /// 所以这种「不完整但合法」的存档真能出现。
    private func writeFont(_ parent: String, name: String, pointSize: CGFloat,
                           to header: inout [String: JSONValue]) {
        var lf: [(String, JSONValue)]
        if let cur = header[parent]?.objectValue, !cur.isEmpty {
            lf = cur
        } else if let def = CacheSchema.defaultHeader()[parent]?.objectValue {
            lf = def
        } else {
            return
        }
        let pixel = -Int((pointSize * 96.0 / 72.0).rounded())
        for i in lf.indices {
            switch lf[i].0 {
            case "lfHeight":    lf[i].1 = .int(pixel)
            case "lfFaceName":  lf[i].1 = .string(name)
            default: break
            }
        }
        header[parent] = .object(lf)
    }

    func apply(to header: inout [String: JSONValue]) {
        func set(_ k: String, _ v: JSONValue) { header[k] = v }

        // 字体：写回 LOGFONT（lfHeight 由点值换算成 96 DPI 像素高）
        writeFont("font", name: fontName, pointSize: fontPointSize, to: &header)
        // 标题字体：同一个 LOGFONT 结构，只换字段来源
        writeFont("font_title", name: titleFontName, pointSize: titlePointSize, to: &header)
        set("use_same_font", .int(useSameFont ? 1 : 0))

        set("font_color", .int(Int(textColorRef)))
        set("font_color_title", .int(Int(titleColorRef)))
        set("bg_color", .int(Int(backgroundColorRef)))
        set("alpha", .int(alpha))

        set("char_gap", .int(charGap))
        set("line_gap", .int(lineGap))
        set("paragraph_gap", .int(paragraphGap))
        set("left_line_count", .int(leftLineCount))
        set("internal_border", .object([
            ("left", .int(insetLeft)), ("top", .int(insetTop)),
            ("right", .int(insetRight)), ("bottom", .int(insetBottom)),
        ]))

        // 背景图片：保留对象里可能存在的其它子字段（和 font 一样，不静默丢）
        var bgImage = header["bg_image"]?.objectValue ?? []
        func putBgImage(_ key: String, _ value: JSONValue) {
            if let i = bgImage.firstIndex(where: { $0.0 == key }) {
                bgImage[i].1 = value
            } else {
                bgImage.append((key, value))
            }
        }
        putBgImage("enable", .int(bgImageEnabled ? 1 : 0))
        putBgImage("mode", .int(bgImageMode))
        putBgImage("file_name", .string(bgImageFileName))
        set("bg_image", .object(bgImage))

        set("word_wrap", .int(wordWrap ? 1 : 0))
        set("line_indent", .int(lineIndent ? 1 : 0))
        set("blank_lines", .int(compressBlankLines ? 1 : 0))
        set("chapter_page", .int(chapterPage ? 1 : 0))

        set("wheel_speed", .int(wheelSpeed))
        set("autopage_mode", .int(autoPageMode))
        set("uElapse", .int(autoPageIntervalMS))

        set("macos_follow_system", .int(followSystemAppearance ? 1 : 0))
        set("macos_smooth_scroll", .int(smoothScroll ? 1 : 0))
        set("macos_menu_bar", .int(menuBarIcon ? 1 : 0))
        set("macos_hotkey", .int(globalHotKey ? 1 : 0))
        set("macos_hide_chrome", .int(hideChrome ? 1 : 0))
        set("macos_find_case_sensitive", .int(findCaseSensitive ? 1 : 0))
        set("macos_always_on_top", .int(keepOnTop ? 1 : 0))
        // 自定义快捷键：只写覆盖项，按 id 排序保证输出稳定（便于 diff / 排查）。
        // 没有任何覆盖时不写这个键 —— 老用户 / Windows 存档的文件里不会平白多出一行。
        if shortcutOverrides.isEmpty {
            header.removeValue(forKey: "macos_shortcuts")
        } else {
            set("macos_shortcuts", .object(shortcutOverrides.keys.sorted().map {
                ($0, .string(shortcutOverrides[$0] ?? ""))
            }))
        }
        // 反向推导回原版字段，保证 Windows 版读到的行为别太离谱
        let winPageMode: Int = (mouseLeftAction == .none && mouseRightAction == .none) ? 0 : 1
        set("page_mode", .int(winPageMode))
        set("disable_lrhide", .int(mouseBothAction == .none ? 1 : 0))

        set("macos_mouse_left", .int(mouseLeftAction.rawValue))
        set("macos_mouse_right", .int(mouseRightAction.rawValue))
        set("macos_mouse_both", .int(mouseBothAction.rawValue))

        set("chapter_rule", .object([
            ("rule", .int(chapterRule.kind.rawValue)),
            ("keyword", .string(chapterRule.keyword)),
            ("regex", .string(chapterRule.regex)),
        ]))
    }

    // MARK: 颜色转换
    // ⚠️ Win32 的 COLORREF 是 0x00BBGGRR（BGR 顺序），不是 RGB

    var textColor: CGColor { CGColor.fromColorRef(textColorRef) }
    /// 标题的自定义颜色（`useSameFont` 为真时原版不用它）
    var titleColor: CGColor { CGColor.fromColorRef(titleColorRef) }
    var backgroundColor: CGColor { CGColor.fromColorRef(backgroundColorRef) }

    /// 实际用于渲染的颜色：跟随系统时用系统配色，否则用用户自定义的
    func renderTextColor(dark: Bool) -> CGColor {
        followSystemAppearance ? (dark ? ReaderDefaults.darkTextColor : ReaderDefaults.defaultTextColor) : textColor
    }

    func renderBackgroundColor(dark: Bool) -> CGColor {
        followSystemAppearance ? (dark ? ReaderDefaults.darkBackgroundColor : ReaderDefaults.defaultBackgroundColor) : backgroundColor
    }

    /// 标题实际用于渲染的颜色。
    ///
    /// 和原版 `Page::SelectFont` 一致：`useSameFont` 时标题**连颜色也**跟着正文，
    /// 此时 `font_color_title` 根本不被读取。只有关掉同字体后，标题颜色才有意义：
    /// 跟随系统时仍用系统配色（否则深色模式下默认黑色标题会看不见），否则用自定义值。
    func renderTitleColor(dark: Bool) -> CGColor {
        if useSameFont { return renderTextColor(dark: dark) }
        if followSystemAppearance { return dark ? ReaderDefaults.darkTextColor : ReaderDefaults.defaultTextColor }
        return CGColor.fromColorRef(titleColorRef)
    }

    /// 实际用于渲染的字体名（Windows 字体不存在时回退到苹方）
    var renderFontName: String { FontResolver.resolve(fontName) }
    /// 标题实际用于渲染的字体名（同上，回退规则一致）
    var renderTitleFontName: String { FontResolver.resolve(titleFontName) }
    /// 是否发生了字体回退（UI 可据此提示用户）
    var didFallbackFont: Bool { FontResolver.needsFallback(fontName) }

    /// 背景图在当前配置下能不能真的画出来（已启用 + 选了文件 + 文件还在）。
    /// 文件不存在时各处一律回落纯色 —— 不弹窗、不崩（设置页负责提示）。
    var hasUsableBackgroundImage: Bool {
        guard bgImageEnabled, !bgImageFileName.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: bgImageFileName)
    }

    // MARK: - 快捷键

    /// 某个功能当前生效的快捷键。`nil` = 用户把它清掉了（菜单上不显示快捷键）。
    func shortcut(_ action: ShortcutAction) -> KeyCombo? {
        if let raw = shortcutOverrides[action.rawValue] {
            return KeyCombo(stored: raw)      // 空串解析失败 → nil（不绑定）
        }
        return action.defaultCombo
    }

    /// 这个功能是否被用户改过（设置页据此决定「还原」按钮是否可用）
    func shortcutIsOverridden(_ action: ShortcutAction) -> Bool {
        shortcutOverrides[action.rawValue] != nil
    }

    /// 设置快捷键。`nil` 表示清掉绑定（存空串，和「没改过」区分开）。
    mutating func setShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        shortcutOverrides[action.rawValue] = combo?.stored ?? ""
    }

    /// 单个功能还原默认
    mutating func resetShortcut(_ action: ShortcutAction) {
        shortcutOverrides.removeValue(forKey: action.rawValue)
    }

    /// 全部还原默认
    mutating func resetAllShortcuts() {
        shortcutOverrides.removeAll()
    }

    /// 这个键位目前被哪个功能占着（不含自己）。冲突检查用。
    func conflictingAction(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && shortcut($0) == combo }
    }
}

extension CGColor {
    /// Win32 COLORREF (0x00BBGGRR) → CGColor
    static func fromColorRef(_ v: UInt32) -> CGColor {
        let r = CGFloat(v & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat((v >> 16) & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// CGColor → Win32 COLORREF (0x00BBGGRR)
    var colorRef: UInt32 {
        guard let c = components, c.count >= 3 else { return 0 }
        let r = UInt32(max(0, min(255, (c[0] * 255).rounded())))
        let g = UInt32(max(0, min(255, (c[1] * 255).rounded())))
        let b = UInt32(max(0, min(255, (c[2] * 255).rounded())))
        return (b << 16) | (g << 8) | r
    }
}
