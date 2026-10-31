import AppKit

/// 开发工具 / 自检进程的「安静模式」。
///
/// 为什么需要：每个 `--xxx-selftest` / `--render-*` 都会走到
/// `applicationDidFinishLaunching`，以前那里会 `NSApp.activate(ignoringOtherApps:)`
/// 再 `makeKeyAndOrderFront`，把窗口弹到正在用电脑的人面前。跑一次 `verify.sh`
/// 要启动二十多个进程，用户看到的是一连串闪窗 + 焦点被抢。
///
/// 现在 `main.swift` 一旦检测到开发工具参数就设置 `READER_DEVTOOLS_QUIET=1`，
/// 这里统一做三件事：
///   1. 进程用 `.accessory`（不进 Dock、不抢菜单栏）；
///   2. 不调用 `NSApp.activate`；
///   3. 窗口统一挪到屏幕外。
///
/// 正常启动（双击 app / `run.sh` / 打包后的用户使用）时 `isQuiet == false`，
/// 所有行为与以前完全一致。
enum DevTools {

    static let isQuiet: Bool = ProcessInfo.processInfo.environment["READER_DEVTOOLS_QUIET"] == "1"

    /// 安静模式下把窗口挪到屏幕外的坐标（足够远，多显示器也碰不到）
    private static let offscreenOrigin = NSPoint(x: -20000, y: -20000)

    /// 进程的激活策略：正常启动 `.regular`（Dock + 菜单栏），开发工具 `.accessory`。
    static var activationPolicy: NSApplication.ActivationPolicy {
        isQuiet ? .accessory : .regular
    }

    /// 只在正常启动时抢焦点；自检 / 渲染进程调用它是空操作。
    static func activate() {
        guard !isQuiet else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 让窗口对用户不可见，避免自检时闪窗。正常启动不动。
    ///
    /// ⚠️ 只靠 `setFrameOrigin` 不够：`NSWindow.setFrame` 会走 AppKit 的
    /// `constrainFrameRect(_:to:)`，把窗口又拉回屏幕边缘（实测 -20000 被拉回
    /// 屏幕角落）。这里再叠加 `alphaValue = 0`，双保险；窗口仍然 `isVisible == true`，
    /// 自检里依赖可见性的断言不受影响。
    static func park(_ window: NSWindow?) {
        guard isQuiet, let window else { return }
        window.alphaValue = 0
        window.setFrameOrigin(offscreenOrigin)
    }

    /// 设置窗口位置自动保存。自检时既不读也不写 ——
    /// 否则屏幕外的位置会被存进用户偏好，下次正常打开窗口就跑到屏幕外了。
    @discardableResult
    static func applyFrameAutosaveName(_ window: NSWindow, _ name: String) -> Bool {
        guard !isQuiet else { return true }
        return window.setFrameAutosaveName(name)
    }
}
