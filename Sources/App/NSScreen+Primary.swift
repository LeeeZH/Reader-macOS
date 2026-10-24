import AppKit

extension NSScreen {
    /// 主屏高度。Cocoa 屏幕坐标系的原点就在主屏左下角，
    /// 与 Win32 的「主屏左上角」换算时需要这个值来翻转 y。
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 900
    }
}
