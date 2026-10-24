import Foundation
import CoreText

/// 处理「Windows 版存档里记的字体在 macOS 上不存在」的情况。
///
/// 重要：**只影响渲染，不改写存档**。
/// `Segoe UI Light` 这类 Windows 字体在 macOS 上会由系统静默替换成某个默认字体，
/// 如果直接拿它创建 CTFont，用户看到的是「设置里写着微软雅黑、实际渲染成别的」。
/// 所以这里显式探测并在渲染时回退到苹方，同时把原值原样留在 .cache.dat 里，
/// 保证用户切回 Windows 时字体设置不丢。
enum FontResolver {

    /// 该字体名在本机是否真实可用
    static func isAvailable(_ name: String, size: CGFloat = 14) -> Bool {
        guard !name.isEmpty else { return false }
        let desc = CTFontDescriptorCreateWithNameAndSize(name as CFString, size)
        guard let list = CTFontDescriptorCreateMatchingFontDescriptors(desc, nil) else { return false }
        return CFArrayGetCount(list) > 0
    }

    /// 按优先级回退：请求的字体 → 首选回退字体 → Helvetica
    static func resolve(_ requested: String,
                        fallback: String = ReaderDefaults.fontName) -> String {
        if isAvailable(requested) { return requested }
        if !fallback.isEmpty, isAvailable(fallback) { return fallback }
        for candidate in ["PingFang SC", "Heiti SC", "STHeiti", "Helvetica"] where isAvailable(candidate) {
            return candidate
        }
        return "Helvetica"
    }

    /// 是否需要回退（用于在 UI 上提示用户）
    static func needsFallback(_ requested: String) -> Bool {
        !requested.isEmpty && !isAvailable(requested)
    }
}
