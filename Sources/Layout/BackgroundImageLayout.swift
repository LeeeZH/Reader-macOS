import CoreGraphics
import Foundation

/// 原版 `header.bg_image.mode` 的三种取值（`DisplaySet.cpp` 的 `Stretch` / `Tile` / `TileFlip`）。
enum BackgroundImageMode: Int, CaseIterable {
    case stretch = 0    // 拉伸铺满整个窗口
    case tile = 1       // 按图片原尺寸平铺
    case tileFlip = 2   // 平铺，且相邻瓦片镜像翻转（GDI+ `WrapModeTileFlipXY`）

    var title: String {
        switch self {
        case .stretch:  return "拉伸铺满"
        case .tile:     return "平铺"
        case .tileFlip: return "平铺翻转"
        }
    }
}

/// 一块待绘制的背景图瓦片。
///
/// 只描述「画在哪、要不要镜像」，不碰任何绘制 API —— 这样铺法可以单测，
/// 不用起窗口、不用真的读图片文件。
struct BackgroundImageTile {
    var rect: CGRect
    var flipH: Bool
    var flipV: Bool
}

/// 背景图的铺法计算。对应原版 `_load_bg_image()`（DisplaySet.cpp:547-620）：
/// - `Stretch`：整图拉伸到窗口大小（非等比，和原版 `DrawImage` 的行为一致）；
/// - `Tile`：`WrapModeTile`，按原尺寸（1:1）平铺；
/// - `TileFlip`：`WrapModeTileFlipXY`，奇数行 / 奇数列的瓦片在 X / Y 上镜像，
///   形成「镜像棋盘」。
enum BackgroundImageLayout {

    /// 一块背景最多画多少片。
    ///
    /// 1×1 的图片铺满 1000×800 要画 80 万片，逐片 `draw` 会直接把主线程钉死。
    /// 超过上限就把瓦片等比放大到上限以内 —— 视觉上仍然是「铺满的花纹」，
    /// 只是纹理变大，不会卡。（原版走 GDI+ 的纹理 wrap，没有这个问题。）
    static let maxTiles = 2000

    /// 计算某个模式下的瓦片列表；参数非法时返回空（调用方回落到纯色背景）。
    static func tiles(for mode: BackgroundImageMode, imageSize: CGSize,
                      in bounds: CGRect) -> [BackgroundImageTile] {
        guard bounds.width > 0, bounds.height > 0,
              imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite else { return [] }

        switch mode {
        case .stretch:
            // 拉伸：一片就够，直接铺满整个 bounds（原版也是非等比拉伸）
            return [BackgroundImageTile(rect: bounds, flipH: false, flipV: false)]
        case .tile, .tileFlip:
            return tiled(imageSize: imageSize, in: bounds, flip: mode == .tileFlip)
        }
    }

    private static func tiled(imageSize: CGSize, in bounds: CGRect,
                              flip: Bool) -> [BackgroundImageTile] {
        var tileSize = imageSize
        // 小图先放大到「片数不超过上限」，否则逐片绘制会把界面卡住
        while count(tileSize: tileSize, in: bounds) > maxTiles {
            tileSize.width *= 1.5
            tileSize.height *= 1.5
        }

        let cols = Int(ceil(bounds.width / tileSize.width))
        let rows = Int(ceil(bounds.height / tileSize.height))
        var tiles: [BackgroundImageTile] = []
        tiles.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                // 从 (0,0) 开始铺，行优先 —— 和原版纹理坐标的方向一致
                let rect = CGRect(x: bounds.minX + CGFloat(col) * tileSize.width,
                                  y: bounds.minY + CGFloat(row) * tileSize.height,
                                  width: tileSize.width, height: tileSize.height)
                tiles.append(BackgroundImageTile(rect: rect,
                                                 flipH: flip && col % 2 == 1,
                                                 flipV: flip && row % 2 == 1))
            }
        }
        return tiles
    }

    private static func count(tileSize: CGSize, in bounds: CGRect) -> Int {
        let cols = Int(ceil(bounds.width / tileSize.width))
        let rows = Int(ceil(bounds.height / tileSize.height))
        return cols * rows
    }
}
