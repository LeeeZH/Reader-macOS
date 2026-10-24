import AppKit

// 把一张图案（SVG 或 PNG）处理成符合 macOS 规范的应用图标。
//
// 用法: MakeIcon <输入.svg|png> <输出.png> [图案占比 0~1] [背景色 #RRGGBB]
//
// 做四件事：
//   1. **矢量渲染**：SVG 走 NSImage 直接按目标尺寸光栅化（清晰且保留透明度）。
//      不要用 qlmanage —— 它渲染的 SVG 会带一层不透明白底，导致「居中」无从谈起。
//   2. **重新居中**：量出不透明部分的包围盒，再把它摆到画布正中
//      （原始素材往往不居中，直接当图标会明显偏）。
//   3. **圆角矩形（squircle）底**：macOS 的 App 图标既不是方的、也不是普通圆角，
//      而是「1024 画布里 824×824 主体 + 185.4 圆角」。不套这个形状，
//      在 Dock 里会比别的图标大一圈、形状也不对。
//   4. **浅渐变**：纯平底色在深色壁纸下很死板，加一层极浅的竖向渐变。

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: MakeIcon <in.svg|png> <out.png> [图案占比] [背景色 #RRGGBB]\n".data(using: .utf8)!)
    exit(1)
}
let inURL  = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let artworkFraction = CGFloat(args.count > 3 ? (Double(args[3]) ?? 0.62) : 0.62)
let bgHex  = args.count > 4 ? args[4] : "#FFFFFF"

// macOS 图标网格（Big Sur 之后的规范）
let CANVAS = 1024
let BODY   = 824
let INSET  = (CANVAS - BODY) / 2
let CORNER = 185.4

func hexToRGB(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return (1, 1, 1) }
    return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
}

// ---- 1. 载入源图（SVG 自动按矢量光栅化，PNG 则原样）----
guard let source = NSImage(contentsOf: inURL) else {
    FileHandle.standardError.write("✗ 读不到输入图片: \(inURL.path)\n".data(using: .utf8)!)
    exit(2)
}
let isVector = source.representations.contains { $0 is NSBitmapImageRep == false }

guard let raster = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: CANVAS, pixelsHigh: CANVAS,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("✗ 创建画布失败\n".data(using: .utf8)!)
    exit(3)
}
raster.size = NSSize(width: CANVAS, height: CANVAS)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)
source.draw(in: NSRect(x: 0, y: 0, width: CANVAS, height: CANVAS),
            from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

// ---- 2. 量不透明区域的包围盒 ----
var bbox = NSRect(x: 0, y: 0, width: CANVAS, height: CANVAS)
if let data = raster.bitmapData {
    let rowBytes = raster.bytesPerRow
    let spp = raster.samplesPerPixel
    var minX = CANVAS, minY = CANVAS, maxX = -1, maxY = -1
    for y in 0..<CANVAS {
        let row = y * rowBytes
        for x in 0..<CANVAS where data[row + x * spp + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    if maxX >= 0 {
        // NSBitmapImageRep 的 y 轴向下，与 NSGraphicsContext 一致，直接用
        bbox = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
if bbox.width <= 0 || bbox.height <= 0 {
    FileHandle.standardError.write("✗ 源图全是透明的，量不到图案\n".data(using: .utf8)!)
    exit(4)
}

// ---- 3. 画布：圆角矩形底 + 浅渐变 ----
guard let ctx = NSGraphicsContext(bitmapImageRep: raster) else { exit(5) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.clear(NSRect(x: 0, y: 0, width: CANVAS, height: CANVAS))

let body = NSRect(x: INSET, y: INSET, width: BODY, height: BODY)
let squircle = CGPath(roundedRect: body, cornerWidth: CORNER, cornerHeight: CORNER, transform: nil)
let (r, g, b) = hexToRGB(bgHex)
let top    = CGColor(red: r, green: g, blue: b, alpha: 1)
let bottom = CGColor(red: max(0, r - 0.055), green: max(0, g - 0.055), blue: max(0, b - 0.043), alpha: 1)
if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [top, bottom] as CFArray, locations: [0, 1]) {
    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: CANVAS), end: CGPoint(x: 0, y: 0), options: [])
    cg.restoreGState()
}

// ---- 4. 图案等比缩放并居中（按包围盒中心对齐画布中心）----
let box = CGFloat(CANVAS) * artworkFraction
let scale = min(box / bbox.width, box / bbox.height)
let drawW = CGFloat(CANVAS) * scale
let drawH = CGFloat(CANVAS) * scale
let originX = CGFloat(CANVAS) / 2 - bbox.midX * scale
let originY = CGFloat(CANVAS) / 2 - bbox.midY * scale
source.draw(in: NSRect(x: originX, y: originY, width: drawW, height: drawH),
            from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let png = raster.representation(using: .png, properties: [:]) else { exit(6) }
do { try png.write(to: outURL) } catch {
    FileHandle.standardError.write("✗ 写入失败: \(error)\n".data(using: .utf8)!)
    exit(7)
}

let srcKind = isVector ? "矢量" : "位图"
FileHandle.standardError.write(String(
    format: "  源: %@（%@）  包围盒 %dx%d  缩放 %.3f  底 %.1f×%.1f 圆角 %.1f\n",
    inURL.lastPathComponent, srcKind,
    Int(bbox.width), Int(bbox.height), scale,
    CGFloat(BODY), CGFloat(BODY), CGFloat(CORNER)).data(using: .utf8)!)
exit(0)
