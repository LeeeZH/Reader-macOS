import AppKit

/// 快捷键录制控件：点一下就「现场按键」，不做下拉选择器、不弹窗。
///
/// 交互（参考 Raycast / VS Code 的录制器）：
///   · 点击 → 进入录制态，显示「按下快捷键…」；
///   · 按下组合键 → 回调 `onCommit`（由设置页校验冲突后再落盘）；
///   · `Esc` → 取消；`Delete` / `Backspace` → 清掉绑定（菜单上不显示快捷键）；
///   · 点到别处 → 视为取消。
///
/// 录制期间用**本地事件监听**截住按键：菜单的 key equivalent 在事件分发阶段就会
/// 抢先处理，只靠 `keyDown` 会录不到 ⌘Q 这类组合（而且会真的把 app 退掉）。
final class ShortcutRecorderView: NSView {

    private(set) var combo: KeyCombo?
    private(set) var isRecording = false
    /// 当前显示的候选键位正和别人冲突（设置页负责判定，这里只管画红框）
    private(set) var isConflicted = false

    /// 用户录完一个组合（窗口/键盘组合交给设置页校验、落盘）
    var onCommit: ((KeyCombo?) -> Void)?
    /// 开始录制（设置页用它可以结束别的录制器）
    var onBegin: (() -> Void)?
    /// 用户按 Esc / 点别处取消
    var onCancel: (() -> Void)?
    /// 录到了不能用的组合（例如裸字母、Shift+数字这种）
    var onReject: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "未设置")
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 24) }

    /// 自检用：当前显示的文本（全称或「按下快捷键…」）
    var currentDisplayText: String { label.stringValue }

    /// 自检用：边框此刻是不是红色（用户看到的「红框」）
    var debugBorderIsRed: Bool {
        layer?.borderColor == NSColor.systemRed.cgColor
    }

    override var acceptsFirstResponder: Bool { true }

    /// 外部（设置页 sync）刷值
    func update(_ combo: KeyCombo?) {
        self.combo = combo
        isConflicted = false
        refreshAppearance()
    }

    /// 冲突时的候选值：红框显示，但**不落盘**，等用户点「交换」或「取消」
    func showConflictCandidate(_ combo: KeyCombo) {
        self.combo = combo
        isConflicted = true
        refreshAppearance()
    }

    /// 只标红、不改显示值。
    /// 用于两类情况：① 已保存的重复键位（提示用户哪几行撞了）；
    /// ② 「还原」会和别人撞（还原后的值不先显示，避免界面又出现两个同键）。
    func setConflictHighlight(_ on: Bool) {
        isConflicted = on
        refreshAppearance()
    }

    private func refreshAppearance() {
        if isRecording {
            label.stringValue = "按下快捷键…"
            label.textColor = .controlAccentColor
            toolTip = "Esc 取消 · Delete 清除绑定"
        } else {
            label.stringValue = combo?.display ?? "未设置"
            label.textColor = combo == nil ? .secondaryLabelColor : .labelColor
            toolTip = nil
        }
        layer?.borderWidth = isRecording || isConflicted ? 1.5 : 1
        layer?.borderColor = isConflicted
            ? NSColor.systemRed.cgColor
            : (isRecording ? NSColor.controlAccentColor.cgColor
                           : NSColor.separatorColor.cgColor)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        super.draw(dirtyRect)
    }

    // MARK: - 录制

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        isConflicted = false
        refreshAppearance()
        onBegin?()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if let window = self.window, event.window === window {
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { return event }   // 点自己不算「点别处」
            }
            self.cancelRecording()
            return event
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        onCancel?()
    }

    private func stopRecording() {
        isRecording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        refreshAppearance()
    }

    /// 返回 true 表示这个事件被录制器吃掉了
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 53:                                   // Esc
            cancelRecording()
            return true
        case 51, 117:                              // Delete / Fn+Delete
            stopRecording()
            onCommit?(nil)
            return true
        case 55, 56, 57, 58, 59, 60, 61, 62:       // 纯修饰键，继续等主键
            return true
        default:
            break
        }
        guard let combo = KeyCombo(event: event) else {
            onReject?("这个键不支持，请用字母 / 数字 / 方向键 / F1–F20 这类键")
            return true
        }
        if let why = ShortcutValidation.check(combo) {
            onReject?(why.message)
            return true
        }
        stopRecording()
        onCommit?(combo)
        return true
    }
}

// MARK: - NSEvent → KeyCombo

extension KeyCombo {

    /// F1–F20 的 keyCode（Carbon `kVK_F*` 的数值）
    fileprivate static let functionKeyNumbers: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// 从一次按键事件生成组合。录制器专用。
    init?(event: NSEvent) {
        var mods: Modifiers = []
        if event.modifierFlags.contains(.control) { mods.insert(.control) }
        if event.modifierFlags.contains(.option) { mods.insert(.option) }
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if event.modifierFlags.contains(.command) { mods.insert(.command) }

        var key: Key?
        switch Int(event.keyCode) {
        case 123: key = .left
        case 124: key = .right
        case 126: key = .up
        case 125: key = .down
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 115: key = .home
        case 119: key = .end
        case 49: key = .space
        case 48: key = .tab
        case 36, 76: key = .returnKey
        case 53: key = .escape
        default:
            if let n = KeyCombo.functionKeyNumbers[event.keyCode] {
                key = .function(n)
            } else if let chars = event.charactersIgnoringModifiers?.lowercased(),
                      chars.count == 1, let c = chars.first,
                      KeyCombo.Key.allowedCharacters.contains(c) {
                key = .character(String(c))
            }
        }
        guard let key else { return nil }
        self.init(key, mods)
    }
}

// MARK: - KeyCombo → NSMenuItem 键位

extension KeyCombo {

    /// 菜单用的 `keyEquivalent` 字符。方向键 / PageUp 这类用 AppKit 的函数键私用区。
    var menuKeyEquivalent: String {
        func scalar(_ v: Int) -> String {
            guard let s = UnicodeScalar(UInt32(v)) else { return "" }
            return String(Character(s))
        }
        switch key {
        case .character(let c): return c
        case .left:     return scalar(NSLeftArrowFunctionKey)
        case .right:    return scalar(NSRightArrowFunctionKey)
        case .up:       return scalar(NSUpArrowFunctionKey)
        case .down:     return scalar(NSDownArrowFunctionKey)
        case .pageUp:   return scalar(NSPageUpFunctionKey)
        case .pageDown: return scalar(NSPageDownFunctionKey)
        case .home:     return scalar(NSHomeFunctionKey)
        case .end:      return scalar(NSEndFunctionKey)
        case .space:    return " "
        case .tab:      return "\t"
        case .returnKey: return "\r"
        case .escape:   return scalar(0x1B)
        case .function(let n): return scalar(NSF1FunctionKey + n - 1)
        }
    }

    /// 菜单用的修饰键掩码
    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }
}
