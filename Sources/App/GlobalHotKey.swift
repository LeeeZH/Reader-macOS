import AppKit
import Carbon.HIToolbox

/// 全局热键（对应原版 `Keyset.cpp` 里 `KI_HIDE` 那一项，原版默认 **Alt+H**）。
///
/// 用 Carbon 的 `RegisterEventHotKey`，而不是 `NSEvent.addGlobalMonitorForEvents`：
///   · 不需要「辅助功能」授权（全局监听要）
///   · 不开后台线程、不需要轮询
/// 代价是要用 Carbon 的键码 —— 但这点完全可控。
final class GlobalHotKey {

    /// 保持强引用：Carbon 的回调是 C 函数指针，靠 userData 找回实例。
    private static var active: GlobalHotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    /// 注册。默认 ⌃⌥H（对应原版的 Alt+H，但 macOS 上 ⌥H 常被输入法占用，加个 ⌃ 更保险）。
    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_H),
                  modifiers: UInt32 = UInt32(controlKey | optionKey)) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.action()
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef)
        guard installStatus == noErr else { return false }

        // 任意四字符签名 + id，用来区分我们自己的热键
        let hotKeyID = EventHotKeyID(signature: OSType(0x52445252), id: 1)   // 'RDRR'
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        if regStatus != noErr {
            // 多半是被别的 App 占用了
            if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
            return false
        }
        GlobalHotKey.active = self
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        if GlobalHotKey.active === self { GlobalHotKey.active = nil }
    }

    /// 供界面显示的组合键名称
    static let displayName = ReaderSettings.globalHotKeyDisplayName

    deinit { unregister() }
}
