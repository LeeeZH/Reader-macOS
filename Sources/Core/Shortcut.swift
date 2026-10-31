import Foundation

/// 一个快捷键组合：修饰键 + 一个键。
///
/// 这是全 app 唯一的「快捷键真值」表示：设置页录制出来的、存进 `.cache.dat` 的、
/// 应用到 `NSMenuItem` 的都是它。解析 / 格式化 / 校验都做成纯逻辑，可以单测。
struct KeyCombo: Equatable, Hashable {

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option  = Modifiers(rawValue: 1 << 1)
        static let shift   = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 键本身。字母 / 符号统一存小写单字符；特殊键用枚举。
    enum Key: Hashable {

        /// 允许作为快捷键的字符键（都是不用 Shift 就能打出来的）。
        /// Shift+数字会变成 `!@#` 这类符号，直接拒绝，免得菜单键位和实际按键对不上。
        static let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-=[];',./\\`")

        case character(String)          // "f" "=" "," "1"
        case left, right, up, down
        case pageUp, pageDown, home, end
        case space, tab, returnKey, escape
        case function(Int)              // F1...F20

        /// 存盘用的 token（例如 "f" / "left" / "f5"）
        var token: String {
            switch self {
            case .character(let c): return c
            case .left: return "left"
            case .right: return "right"
            case .up: return "up"
            case .down: return "down"
            case .pageUp: return "pageup"
            case .pageDown: return "pagedown"
            case .home: return "home"
            case .end: return "end"
            case .space: return "space"
            case .tab: return "tab"
            case .returnKey: return "return"
            case .escape: return "escape"
            case .function(let n): return "f\(n)"
            }
        }

        /// 界面上显示的名字。**全称**，不用 ⌘ / ⇧ 这类图标（用户要求）。
        var displayName: String {
            switch self {
            case .character(let c): return c.uppercased()
            case .left: return "←"
            case .right: return "→"
            case .up: return "↑"
            case .down: return "↓"
            case .pageUp: return "PageUp"
            case .pageDown: return "PageDown"
            case .home: return "Home"
            case .end: return "End"
            case .space: return "Space"
            case .tab: return "Tab"
            case .returnKey: return "Return"
            case .escape: return "Esc"
            case .function(let n): return "F\(n)"
            }
        }

        /// 紧凑显示名（菜单 / 状态栏风格）：字母大写、方向键用箭头、PageUp 用 ⇞。
        var symbolName: String {
            switch self {
            case .character(let c): return c.uppercased()
            case .left: return "←"
            case .right: return "→"
            case .up: return "↑"
            case .down: return "↓"
            case .pageUp: return "⇞"
            case .pageDown: return "⇟"
            case .home: return "↖"
            case .end: return "↘"
            case .space: return "Space"
            case .tab: return "⇥"
            case .returnKey: return "↩"
            case .escape: return "⎋"
            case .function(let n): return "F\(n)"
            }
        }

        /// 允许**不带修饰键**单独使用的键。
        ///
        /// 方向键 / F 键 / PageUp/Down 这类不会和打字冲突；字母数字和符号
        /// 要是不加修饰键，用户一读正文就触发菜单，属于事故。
        var allowsBareUse: Bool {
            switch self {
            case .character: return false
            case .left, .right, .up, .down, .pageUp, .pageDown, .home, .end,
                 .space, .returnKey, .escape, .tab, .function:
                return true
            }
        }
    }

    var modifiers: Modifiers
    var key: Key

    init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: - 存盘格式（header 里的字符串）

    /// 存盘格式：`"command+shift+b"`、`"left"`、`"f5"`。
    var stored: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key.token)
        return parts.joined(separator: "+")
    }

    /// 从存盘格式还原。空串 / 无法识别返回 nil（空串的语义是「用户清掉了」，
    /// 调用方会把它当成「不绑定」而不是「用默认值」）。
    init?(stored: String) {
        let s = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: "+").map(String.init)
        guard let last = parts.last else { return nil }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m {
            case "control", "ctrl": mods.insert(.control)
            case "option", "alt", "opt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "command", "cmd": mods.insert(.command)
            default: return nil
            }
        }
        guard let key = Key(token: last) else { return nil }
        self.init(key, mods)
    }

    // MARK: - 界面显示（全称）

    /// 紧凑显示格式：`"⇧⌘B"`、`"⌘F"`、`"←"`。
    ///
    /// **只给设置页以外的界面用**（状态栏提示、各窗口空状态文案、设置页里
    /// 「自动翻页」「沉浸模式」这类行内提示）—— 和 macOS 菜单栏的显示习惯一致。
    /// 快捷键设置页本身一律用 `display` 全称。
    var symbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key.symbolName
    }

    /// 显示格式：`"command + shift + B"`。
    ///
    /// 修饰键顺序固定 control → option → shift → command（和 macOS 的 ⌃⌥⇧⌘ 一致），
    /// 单个修饰键时就是用户要的 `command + F`。**不出现任何图标**。
    var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key.displayName)
        return parts.joined(separator: " + ")
    }
}

extension KeyCombo.Key {
    init?(token: String) {
        if token.count == 1, let c = token.first, !c.isWhitespace {
            let lower = token.lowercased()
            // 严格按允许集合校验：乱码 / Shift 符号（!@#）之类一律当非法
            guard let ch = lower.first, Self.allowedCharacters.contains(ch) else { return nil }
            self = .character(lower)
            return
        }
        switch token {
        case "left": self = .left
        case "right": self = .right
        case "up": self = .up
        case "down": self = .down
        case "pageup", "pgup": self = .pageUp
        case "pagedown", "pgdn": self = .pageDown
        case "home": self = .home
        case "end": self = .end
        case "space": self = .space
        case "tab": self = .tab
        case "return", "enter": self = .returnKey
        case "escape", "esc": self = .escape
        default:
            guard token.hasPrefix("f"), let n = Int(token.dropFirst()), (1...20).contains(n) else {
                return nil
            }
            self = .function(n)
        }
    }
}

// MARK: - 校验

/// 录制结果为什么不能用。带一句给用户看的解释 —— 冲突和非法组合都被拒绝时
/// **必须说明原因**（这是快捷键录制器的通病，参考 cmux issue #2988）。
enum ShortcutValidation: Equatable {
    case needsModifier
    case reserved(String)
    case unsupportedKey

    var message: String {
        switch self {
        case .needsModifier:
            return "字母、数字、符号要搭配至少一个修饰键，否则会和打字冲突"
        case .reserved(let combo):
            return "\(combo) 是 macOS 的系统标准键，不能占用"
        case .unsupportedKey:
            return "这个键不支持，请用字母 / 数字 / 方向键 / F1–F20 / 空格这类键"
        }
    }

    /// 校验一个组合能不能分配给菜单功能。`nil` 表示通过。
    static func check(_ combo: KeyCombo) -> ShortcutValidation? {
        if !combo.key.allowsBareUse && combo.modifiers.isEmpty {
            return .needsModifier
        }
        // 系统标准键：退出 / 关闭窗口 / 隐藏 app，抢了会让人打不开或关不掉东西
        let reserved: [(KeyCombo, String)] = [
            (KeyCombo(.character("q"), .command), "command + Q"),
            (KeyCombo(.character("w"), .command), "command + W"),
            (KeyCombo(.character("h"), .command), "command + H"),
        ]
        if let hit = reserved.first(where: { $0.0 == combo }) {
            return .reserved(hit.1)
        }
        return nil
    }
}
