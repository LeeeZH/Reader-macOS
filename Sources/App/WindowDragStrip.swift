import AppKit

/// 隐藏标题栏之后用来拖动窗口的透明条。
///
/// 窗口没有标题栏就拖不动了。而这个条不能影响正文的点击翻页，
/// 所以只铺在顶部很窄的一条，并且只处理拖拽（单击仍然穿透给下面的视图）。
final class WindowDragStrip: NSView {

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
