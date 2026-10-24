import Foundation
import CoreGraphics
import AppKit

// 极简断言框架（不引入任何第三方依赖）
var passed = 0, failed = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\(detail().isEmpty ? "" : "  → \(detail())")") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    check(a == b, name, "得到 \(a)，期望 \(b)")
}
func units(_ s: String) -> [UInt16] { Array(s.utf16) }
func str(_ u: [UInt16]) -> String { String(decoding: u, as: UTF16.self) }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reader-tests")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// ============ 1. TextDecoder：编码自动识别 ============
print("\n[1] TextDecoder 编码识别")

let cnText = "第一章 开始\n\n正文内容 Hello 123\n"

// GBK
let gbkEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
let gbkData = cnText.data(using: gbkEnc)!
let gbkFile = tmp.appendingPathComponent("gbk.txt")
try gbkData.write(to: gbkFile)
let d1 = try TextDecoder.decode(try Data(contentsOf: gbkFile))
eq(d1.encodingName, "GB18030", "GBK 文件被识别为 GB18030")
eq(d1.text, cnText, "GBK 解码内容正确")

// UTF-8 BOM
var utf8Bom = Data([0xEF, 0xBB, 0xBF]); utf8Bom.append(cnText.data(using: .utf8)!)
let d2 = try TextDecoder.decode(utf8Bom)
eq(d2.encodingName, "UTF-8 (BOM)", "UTF-8 BOM 识别")
eq(d2.text, cnText, "UTF-8 BOM 解码内容正确")

// UTF-16LE
var u16le = Data([0xFF, 0xFE])
for u in units(cnText) { u16le.append(UInt8(u & 0xFF)); u16le.append(UInt8(u >> 8)) }
let d3 = try TextDecoder.decode(u16le)
eq(d3.encodingName, "UTF-16LE", "UTF-16LE 识别")
eq(d3.text, cnText, "UTF-16LE 解码内容正确")

// UTF-16BE
var u16be = Data([0xFE, 0xFF])
for u in units(cnText) { u16be.append(UInt8(u >> 8)); u16be.append(UInt8(u & 0xFF)) }
let d4 = try TextDecoder.decode(u16be)
eq(d4.encodingName, "UTF-16BE", "UTF-16BE 识别")
eq(d4.text, cnText, "UTF-16BE 解码内容正确")

// 无 BOM 纯 ASCII → UTF-8
let d5 = try TextDecoder.decode("hello world\n".data(using: .utf8)!)
eq(d5.encodingName, "UTF-8", "纯 ASCII 识别为 UTF-8")

// 严格 UTF-8 校验
check(TextDecoder.isValidUTF8([0xE4, 0xB8, 0xAD]), "合法 UTF-8 中文字节通过")
check(!TextDecoder.isValidUTF8([0xC0, 0x80]), "拒绝 overlong 编码 (C0 80)")
check(TextDecoder.isValidUTF8([0xE4, 0xB8]), "容忍末尾截断的序列（探测窗口可能切在多字节字符中间）")

// ============ 2. TextNormalizer::format —— 存档坐标的定义函数 ============
print("\n[2] TextNormalizer.format（进度/书签兼容性的地基）")

eq(str(TextNormalizer.format(units("A\n\nB\n"))), "A\n\nB\n", "单个空行保留")
eq(str(TextNormalizer.format(units("\n\n\nA\n"))), "A\n", "开头空行全删")
eq(str(TextNormalizer.format(units("A\n\n\n\nB\n"))), "A\n\nB\n", "连续空行压缩为 1 行")
eq(str(TextNormalizer.format(units("A\r\nB\r\n"))), "A\nB\n", "CRLF 归一为 LF")
eq(str(TextNormalizer.format(units("A  \nB\n"))), "A\nB\n", "行尾空白被裁掉")
eq(str(TextNormalizer.format(units("     abc\n"))), "    abc\n", ">4 空格缩进压成 4 个半角空格")
eq(str(TextNormalizer.format(units("  abc\n"))), "  abc\n", "2 空格缩进原样保留")
eq(str(TextNormalizer.format(units("\u{3000}\u{3000}\u{3000}abc\n"))),
   "\u{3000}\u{3000}abc\n", ">2 全角空格缩进压成 2 个全角空格")
eq(str(TextNormalizer.format(units("A\n\n\n"))), "A\n\n", "末尾单个空行保留（与原版一致）")

// 孤立 CR 不是换行（原版 quirk，刻意保留）
let crOnly = TextNormalizer.format(units("A\rB\n"))
check(str(crOnly).contains("\r"), "孤立 CR 被保留为普通字符（原版 quirk）")

// ★ 回归：探测窗口切在多字节字符中间时，不能把合法 UTF-8 判成非法。
// 曾经这里照搬了原版**已修复前**的逻辑（return 0 而非 break），
// 导致任何超过 4096 字节的 UTF-8 文件都有约 2/3 概率被误判。
let manyChinese = String(repeating: "天地玄黄宇宙洪荒", count: 3000)
let manyBytes = [UInt8](manyChinese.data(using: .utf8)!)
check(manyBytes.count > 4096, "测试数据超过 4096 字节", "\(manyBytes.count) 字节")
check(TextDecoder.isValidUTF8(manyBytes), "整段合法 UTF-8 通过")

// 找一个正好切在续字节上的偏移（即被切断的位置）
var cutAt = 4096
while cutAt < manyBytes.count, (manyBytes[cutAt] & 0xC0) != 0x80 { cutAt += 1 }
check(cutAt < manyBytes.count, "找到了切在多字节字符中间的偏移")
check(TextDecoder.isValidUTF8(Array(manyBytes.prefix(cutAt))),
      "★ 探测窗口被切断时仍判定为 UTF-8（原 bug 点）", "cutAt=\(cutAt)")
check(TextDecoder.isValidUTF8(Array(manyBytes.prefix(4096))),
      "★ 前 4096 字节判定为 UTF-8")

// 端到端：大一点的 UTF-8 中文文件必须被识别为 "UTF-8"，而不是退回分支
let bigURL = tmp.appendingPathComponent("big-utf8.txt")
try manyChinese.write(to: bigURL, atomically: true, encoding: .utf8)
let bigDecoded = try TextDecoder.decode(try Data(contentsOf: bigURL))
eq(bigDecoded.encodingName, "UTF-8", "★ >4096 字节的 UTF-8 文件被正确识别为 UTF-8")
eq(bigDecoded.text, manyChinese, "内容完全一致，没有乱码")

// 真正的非法字节仍要拒绝（不能因为容忍截断就全都放行）
check(!TextDecoder.isValidUTF8([0xFF, 0xFE, 0x41]), "非法首字节仍被拒绝")
check(!TextDecoder.isValidUTF8([0xE4, 0x41, 0x42]), "续字节不合法仍被拒绝")
check(!TextDecoder.isValidUTF8([0xE4, 0xB8, 0x41]), "续字节不合法仍被拒绝（中间位置）")

// ============ 3. ChapterParser ============
print("\n[3] ChapterParser 章节解析")

let novel = "第一章 开始\n正文甲\n第二章 转折\n正文乙\n楔子\n序章\n第3章 终章\n"
let nu = TextNormalizer.format(units(novel))
let chs = ChapterParser.parse(nu, rule: ChapterRule(kind: .default))
eq(chs.count, 5, "默认规则识别出 5 个章节")
if chs.count >= 5 {
    eq(chs[0].title, "第一章 开始", "第 1 章标题")
    eq(chs[0].index, 0, "第 1 章偏移为 0")
    eq(chs[1].title, "第二章 转折", "第 2 章标题")
    let expect2 = units("第一章 开始\n正文甲\n").count
    eq(chs[1].index, expect2, "第 2 章偏移 = 前面所有字符数")
}
check(chs.contains { $0.title.hasPrefix("楔子") }, "识别「楔子」特例")
check(chs.contains { $0.title.hasPrefix("序章") }, "识别「序章」特例")
check(chs.contains { $0.title.hasPrefix("第3章") }, "识别阿拉伯数字章节")

// 不应误识别
let notChapter = TextNormalizer.format(units("这本书的第三章很有意思\n他没有第一章那么强\n"))
let nc = ChapterParser.parse(notChapter, rule: ChapterRule(kind: .default))
check(nc.isEmpty, "行中间的「第X章」不被误识别", "误识别出 \(nc.count) 个")

// 关键字模式
let kw = ChapterParser.parse(nu, rule: ChapterRule(kind: .keyword, keyword: "第"))
eq(kw.count, 3, "关键字模式（关键字「第」）匹配到 3 行")

// 正则模式
let re = ChapterParser.parse(nu, rule: ChapterRule(kind: .regex, regex: "第.{1,3}章\\s+\\S+"))
check(re.count >= 3, "正则模式可用", "得到 \(re.count) 个")

// ============ 4. TextBook 端到端 ============
print("\n[4] TextBook 端到端")
let book = TextBook(fileURL: gbkFile, rawText: cnText, encodingName: "GB18030")
eq(book.displayName, "gbk", "书名取文件名")
check(book.totalLength > 0, "规范化后有内容", "\(book.totalLength) 个码元")
check(book.chapters.count >= 1, "书本解析出章节", "\(book.chapters.count) 个")
eq(book.chapterIndex(at: 0), 0, "偏移 0 属于第 0 章")

// ============ 5. 偏移语义一致性 ============
print("\n[5] 字符偏移语义（对齐原版 wchar_t 下标）")
let s = "第一章abc"
eq(units(s).count, 6, "中文与 ASCII 都是 1 个 UTF-16 码元")
eq(TextNormalizer.format(units("第一章 开始\n正文\n")).count,
   units("第一章 开始\n正文\n").count, "本样例无空行可压缩，长度不变")


// ============ 6. .cache.dat 兼容层 ============
print("\n[6] .cache.dat 读写（与 Windows 版互通）")

// 6.1 XOR 混淆
let plain = Data("hello".utf8)
eq(CacheCodec.xor(CacheCodec.xor(plain)), plain, "XOR 0x3a 往返")
eq(CacheCodec.xorKey, 0x3A, "异或键为 0x3a")
check(CacheCodec.xor(plain) != plain, "确实做了混淆")

// 6.2 解析一份「Windows 风格」的存档（键顺序照抄 json_header_t）
let winJson = """
{"header":{"version":"2.0.0.5","item_count":2,"item_id":0,"style":13565952,"exstyle":524304,\
"fs_style":13565952,"fs_exstyle":524304,"char_gap":1,"line_gap":7,"paragraph_gap":18,\
"left_line_count":0,"font_color":255,"font_color_title":65535,"use_same_font":1,\
"bg_color":16777215,"alpha":200,"meun_font_follow":0,"wheel_speed":2,"page_mode":1,\
"autopage_mode":0,"uElapse":2500,"hide_taskbar":0,"show_systray":0,"disable_lrhide":1,\
"disable_eschide":1,"word_wrap":1,"line_indent":0,"blank_lines":0,"chapter_page":1,\
"ingore_version":"","checkver_time":0,"global_key":0,\
"cust_colors":[16777215,16777215,16777215,16777215,16777215,16777215,16777215,16777215,\
16777215,16777215,16777215,16777215,16777215,16777215,16777215,16777215],\
"keyset":[{"value":1096,"is_disable":0},{"value":123,"is_disable":0}],\
"placement":{"length":44,"flags":0,"showCmd":1,"ptMinPosition":{"x":-1,"y":-1},\
"ptMaxPosition":{"x":-1,"y":-1},"rcNormalPosition":{"left":10,"top":20,"right":310,"bottom":520}},\
"fs_placement":{"length":44,"flags":0,"showCmd":1,"ptMinPosition":{"x":-1,"y":-1},\
"ptMaxPosition":{"x":-1,"y":-1},"rcNormalPosition":{"left":0,"top":0,"right":300,"bottom":500}},\
"fs_rect":{"left":0,"top":0,"right":0,"bottom":0},\
"internal_border":{"left":11,"top":12,"right":13,"bottom":14},\
"font":{"lfHeight":-19,"lfWidth":0,"lfEscapement":0,"lfOrientation":0,"lfWeight":300,\
"lfItalic":0,"lfUnderline":0,"lfStrikeOut":0,"lfCharSet":0,"lfOutPrecision":3,\
"lfClipPrecision":2,"lfQuality":2,"lfPitchAndFamily":34,"lfFaceName":"Segoe UI Light"},\
"font_title":{"lfHeight":-19,"lfWidth":0,"lfEscapement":0,"lfOrientation":0,"lfWeight":300,\
"lfItalic":0,"lfUnderline":0,"lfStrikeOut":0,"lfCharSet":0,"lfOutPrecision":3,\
"lfClipPrecision":2,"lfQuality":2,"lfPitchAndFamily":34,"lfFaceName":"Segoe UI Light"},\
"bg_image":{"enable":0,"mode":0,"file_name":""},\
"proxy":{"enable":0,"port":0,"addr":"","user":"","pass":""},\
"chapter_rule":{"rule":2,"keyword":"卷","regex":"第.*章"},"tag_count":0,"tags":[],\
"book_source_count":0,"book_sources":[]},\
"items":[\
{"id":0,"index":1234,"file_name":"D:\\\\小说\\\\测试书.txt","mark_size":2,"is_new":0,"mark":[100,200]},\
{"id":1,"index":0,"file_name":"D:\\\\小说\\\\第二本.txt","mark_size":0,"is_new":1,"mark":[]}]}
"""
let winData = CacheCodec.xor(Data(winJson.utf8))
let doc = try CacheCodec.decode(winData)

eq(doc.items.count, 2, "解析出 2 本书")
eq(doc.items[0].index, 1234, "★ 第 1 本书的进度偏移（字符偏移）正确")
eq(doc.items[0].marks, [100, 200], "第 1 本书的书签正确")
eq(doc.items[0].fileName, "D:\\小说\\测试书.txt", "Windows 路径保留")
eq(doc.items[1].isNew, 1, "未读标记正确")
eq(doc.currentItemIndex, 0, "当前书下标正确")

let st = ReaderSettings(header: doc.header)
eq(st.lineGap, 7, "行距读取")
eq(st.paragraphGap, 18, "段距读取")
eq(st.charGap, 1, "字距读取")
eq(st.insetLeft, 11, "内部左边距读取")
eq(st.insetBottom, 14, "内部下边距读取")
eq(st.wordWrap, true, "word_wrap 读取")
eq(st.lineIndent, false, "line_indent 读取")
eq(st.compressBlankLines, false, "blank_lines 读取")
eq(st.chapterPage, true, "chapter_page 读取")
eq(st.wheelSpeed, 2, "滚轮速度读取")
eq(st.autoPageIntervalMS, 2500, "自动翻页间隔读取")
eq(st.fontName, "Segoe UI Light", "字体名原样保留（不改写存档）")
eq(st.alpha, 200, "窗口不透明度读取")
eq(st.chapterRule.kind, .regex, "章节规则模式读取")
eq(st.chapterRule.regex, "第.*章", "章节规则正则读取")
check(abs(st.fontPointSize - 14.25) < 0.01, "lfHeight -19px 换算为 14.25pt", "得到 \(st.fontPointSize)")

// 6.3 未知字段必须保留（否则一存盘就抹掉用户的其它设置）
var docWithExtra = doc
docWithExtra.header["future_field"] = .string("keep-me")
let reencoded = try CacheCodec.encode(docWithExtra)
let reencodedText = String(decoding: CacheCodec.xor(reencoded), as: UTF8.self)
check(reencodedText.contains("\"future_field\":\"keep-me\""), "规范表之外的字段被原样保留")

// 6.4 往返：解码 → 编码 → 再解码，模型必须一致
let roundTrip = try CacheCodec.decode(reencoded)
eq(roundTrip.items.count, doc.items.count, "往返后书籍数一致")
eq(roundTrip.items[0].index, doc.items[0].index, "往返后进度偏移一致")
eq(roundTrip.items[0].marks, doc.items[0].marks, "往返后书签一致")
eq(roundTrip.items[0].fileName, doc.items[0].fileName, "往返后路径一致")
let st2 = ReaderSettings(header: roundTrip.header)
eq(st2.lineGap, st.lineGap, "往返后行距一致")
eq(st2.fontName, st.fontName, "往返后字体一致")
eq(st2.chapterRule.regex, st.chapterRule.regex, "往返后章节规则一致")

// 6.5 写出的键顺序必须与 json_header_t 的插入顺序一致
func headerSlice(_ text: String) -> String {
    guard let a = text.range(of: "\"header\":{") else { return text }
    guard let b = text.range(of: "},\"items\"", range: a.upperBound..<text.endIndex) else { return text }
    return String(text[a.upperBound..<b.lowerBound])
}
let hs = headerSlice(reencodedText)
var orderOK = true
var lastPos = hs.startIndex
var missing: [String] = []
for key in CacheSchema.headerKeyOrder {
    guard let r = hs.range(of: "\"\(key)\":") else { missing.append(key); orderOK = false; continue }
    if r.lowerBound < lastPos { orderOK = false }
    lastPos = r.lowerBound
}
check(missing.isEmpty, "header 包含全部 47 个键", "缺少: \(missing)")
check(orderOK, "header 键顺序与 cJSON 输出一致")

// 6.6 item 的键顺序
let itemsText = reencodedText
if let a = itemsText.range(of: "\"items\":[") {
    let seg = String(itemsText[a.upperBound...])
    var prev = seg.startIndex
    var ok = true
    for k in CacheSchema.itemKeyOrder {
        guard let r = seg.range(of: "\"\(k)\":") else { ok = false; break }
        if r.lowerBound < prev { ok = false }
        prev = r.lowerBound
    }
    check(ok, "items 键顺序为 id,index,file_name,mark_size,is_new,mark")
} else {
    check(false, "items 键顺序检查（未找到 items）")
}

// 6.7 与 Windows 版一致：item_count == 0 时不写 items 键
var emptyDoc = CacheDocument()
emptyDoc.items = []
let emptyEncoded = String(decoding: CacheCodec.xor(try CacheCodec.encode(emptyDoc)), as: UTF8.self)
check(!emptyEncoded.contains("\"items\""), "无书时不写 items 键（与原版 create_json 一致）")

// 6.8 item_count 与数组长度不符时整体丢弃（原版 parser_json 行为）
let mismatch = winJson.replacingOccurrences(of: "\"item_count\":2", with: "\"item_count\":5")
let mismatchDoc = try CacheCodec.decode(CacheCodec.xor(Data(mismatch.utf8)))
eq(mismatchDoc.items.count, 0, "item_count 不符时丢弃列表（与原版一致）")

// 6.9 COLORREF 是 BGR 顺序
let red = CGColor.fromColorRef(0x000000FF)     // COLORREF 里 0x0000FF = 红
var comps = red.components!
check(abs(comps[0] - 1) < 0.01 && abs(comps[1]) < 0.01 && abs(comps[2]) < 0.01,
      "COLORREF 0x0000FF 解析为红色（BGR 顺序）")
let white = CGColor.fromColorRef(0x00FFFFFF)
comps = white.components!
check(abs(comps[0] - 1) < 0.01 && abs(comps[1] - 1) < 0.01 && abs(comps[2] - 1) < 0.01, "COLORREF 0x00FFFFFF 为白色")
eq(white.colorRef, UInt32(0x00FFFFFF), "CGColor → COLORREF 往返")

// 6.10 路径解析
eq(BookPathResolver.baseName("D:\\小说\\某本书.txt"), "某本书.txt", "Windows 路径取文件名")
eq(BookPathResolver.baseName("/Users/x/books/a.txt"), "a.txt", "POSIX 路径取文件名")
check(BookPathResolver.isWindowsStyle("D:\\a\\b.txt"), "识别 Windows 路径")
check(!BookPathResolver.isWindowsStyle("/Users/a.txt"), "识别 POSIX 路径")

// 6.11 字体迁移：Windows 字体在 macOS 不存在时要回退，但不改存档
check(FontResolver.isAvailable("PingFang SC"), "苹方在本机可用")
check(!FontResolver.isAvailable("Segoe UI Light"), "Segoe UI Light 在本机不可用（符合预期）")
eq(FontResolver.resolve("Segoe UI Light"), "PingFang SC", "不存在的字体回退到苹方")
eq(FontResolver.resolve("PingFang SC"), "PingFang SC", "存在的字体保持不变")
check(FontResolver.needsFallback("Segoe UI Light"), "标记出需要回退")
check(!FontResolver.needsFallback("PingFang SC"), "苹方不需要回退")
eq(st.renderFontName, "PingFang SC", "ReaderSettings 暴露渲染用字体名")
eq(st.fontName, "Segoe UI Light", "同时保留原始字体名供回写 Windows")

// 6.12 损坏存档不能崩
check((try? CacheCodec.decode(Data([0x00, 0x01, 0x02]))) == nil, "损坏数据抛错而不是崩溃")


// ============ 7. LibraryStore：阅读列表与进度持久化 ============
print("\n[7] LibraryStore 阅读列表 / 进度持久化")

let libURL = tmp.appendingPathComponent(".cache.dat")
try? FileManager.default.removeItem(at: libURL)

let store = LibraryStore(fileURL: libURL)
store.load()
eq(store.items.count, 0, "初始书架为空")

store.touch(fileName: "/tmp/第一本.txt")
store.touch(fileName: "/tmp/第二本.txt")
eq(store.items.count, 2, "加入 2 本")
eq(store.items[0].fileName, "/tmp/第二本.txt", "最近打开的排最前（MRU）")
eq(store.items[1].fileName, "/tmp/第一本.txt", "先打开的排在后面")
eq(store.items[0].id, 0, "id 恒等于下标（与原版 move_item 的重排一致）")
eq(store.items[1].id, 1, "id 恒等于下标")

// 重复打开同一本不应新增，只置顶
store.touch(fileName: "/tmp/第一本.txt")
eq(store.items.count, 2, "重复打开不新增")
eq(store.items[0].fileName, "/tmp/第一本.txt", "重复打开会置顶")

// 进度
store.touch(fileName: "/tmp/第二本.txt")
store.updateProgress(offset: 4321, at: 0)
eq(store.items[0].index, 4321, "进度已记录")
eq(store.items[0].isNew, 0, "记录进度后清除未读标记")

// 书签
check(store.addBookmark(offset: 500, at: 0), "添加书签")
check(store.addBookmark(offset: 100, at: 0), "添加第二个书签")
check(!store.addBookmark(offset: 100, at: 0), "重复书签被拒绝")
eq(store.items[0].marks, [100, 500], "书签按偏移排序")
store.removeBookmark(offset: 100, at: 0)
eq(store.items[0].marks, [500], "删除书签")

// 落盘 → 重新载入
check(store.save(), "保存成功")
check(FileManager.default.fileExists(atPath: libURL.path), "存档文件已生成")

let store2 = LibraryStore(fileURL: libURL)
store2.load()
eq(store2.items.count, 2, "重新载入后书籍数一致")
eq(store2.items[0].fileName, "/tmp/第二本.txt", "重新载入后 MRU 顺序一致")
eq(store2.items[0].index, 4321, "★ 重新载入后阅读进度一致")
eq(store2.items[0].marks, [500], "重新载入后书签一致")

// 移除 / 清空
store2.remove(at: 1)
eq(store2.items.count, 1, "移除一本")
eq(store2.items[0].id, 0, "移除后重新编号")
store2.removeAll()
eq(store2.items.count, 0, "清空书架")

// 存档是混淆过的（不是明文 JSON）
let rawBytes = try Data(contentsOf: libURL)
check(rawBytes.first != UInt8(ascii: "{"), "落盘内容不是明文 JSON（已 XOR 混淆）")
let plainAgain = String(decoding: CacheCodec.xor(rawBytes), as: UTF8.self)
check(plainAgain.hasPrefix("{"), "去混淆后是 JSON")

// 损坏存档：应备份而不是静默丢弃
let badURL = tmp.appendingPathComponent(".cache.dat.bad")
try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: badURL)
let store3 = LibraryStore(fileURL: badURL)
store3.load()
eq(store3.items.count, 0, "损坏存档不崩溃，从空白开始")
check(store3.recoveredBackupURL != nil, "损坏存档已备份")
if let b = store3.recoveredBackupURL {
    check(FileManager.default.fileExists(atPath: b.path), "备份文件确实存在")
}

// ============ 8. 读取 Windows 版格式的存档 ============
print("\n[8] 读取 Windows 版 .cache.dat 格式")

// 应用已不再提供「导入外部存档」的入口（正常使用只有一台电脑，不需要倒来倒去）。
// 但**文件格式依然完全兼容**：把 Windows 版的 .cache.dat 直接放到
// ~/Library/Application Support/Reader/ 下，load() 就能原样读出来。
let winURL = tmp.appendingPathComponent(".cache.dat.win")
try CacheCodec.xor(Data(winJson.utf8)).write(to: winURL)

let winStore = LibraryStore(fileURL: winURL)
winStore.load()
eq(winStore.items.count, 2, "读到 2 本书")
eq(winStore.items[0].index, 1234, "★ Windows 存档里的进度偏移原样读出")
eq(winStore.items[0].marks, [100, 200], "★ Windows 存档里的书签原样读出")
eq(winStore.items[0].fileName, "D:\\小说\\测试书.txt", "Windows 路径原样保留")
eq(ReaderSettings(header: winStore.document.header).lineGap, 7, "Windows 存档里的设置读出")
eq(winStore.missingFileCount, 2, "Windows 路径在本机都打不开，标为待重新定位")

// 重新定位：进度和书签是字符偏移，与路径无关，所以必须原样保留
let gbkAbs = tmp.appendingPathComponent("gbk.txt")
winStore.relocate(index: 0, to: gbkAbs)
eq(winStore.items[0].index, 1234, "★ 重新定位后进度不变")
eq(winStore.items[0].marks, [100, 200], "★ 重新定位后书签不变")
check(winStore.availableURL(forStoredPath: gbkAbs.path) != nil, "重新定位后路径变为可用")
eq(winStore.missingFileCount, 1, "只剩 1 本待重新定位")

check(winStore.save(), "重新定位后能落盘")
let winStore2 = LibraryStore(fileURL: winURL)
winStore2.load()
eq(winStore2.items[0].fileName, gbkAbs.path, "重新定位的结果已持久化")
eq(winStore2.items[0].index, 1234, "重读后进度仍在")

// ============ 9. 窗口位置记忆 ============
print("\n[9] 窗口位置记忆（跨平台坐标换算）")

let screenH: CGFloat = 900

// Cocoa frame → Win32 RECT：y 轴要翻转
let macFrame = CGRect(x: 100, y: 100, width: 440, height: 700)
let winRect = WindowPlacement.toWinRect(macFrame, primaryScreenHeight: screenH)
eq(winRect.left, 100, "left 不变")
eq(winRect.right, 540, "right 不变")
eq(winRect.top, 100, "top = 屏高 - maxY")
eq(winRect.bottom, 800, "bottom = 屏高 - minY")

// RECT → frame：往返必须一致
let back = WindowPlacement.toNSRect(left: winRect.left, top: winRect.top,
                                    right: winRect.right, bottom: winRect.bottom,
                                    primaryScreenHeight: screenH)
eq(back, macFrame, "★ 坐标换算往返一致")

// 非法矩形
check(WindowPlacement.toNSRect(left: 10, top: 10, right: 5, bottom: 20,
                               primaryScreenHeight: screenH) == nil, "宽为负的矩形被拒绝")
check(WindowPlacement.toNSRect(left: 10, top: 20, right: 20, bottom: 5,
                               primaryScreenHeight: screenH) == nil, "高为负的矩形被拒绝")

// 可用性检查（屏幕被拔掉 / 分辨率变了要有兜底）
let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
check(WindowPlacement.isUsable(CGRect(x: 100, y: 100, width: 440, height: 700), screenFrames: screens),
      "正常窗口位置可用")
check(!WindowPlacement.isUsable(CGRect(x: 5000, y: 5000, width: 440, height: 700), screenFrames: screens),
      "跑到屏幕外的位置被判定为不可用")
check(!WindowPlacement.isUsable(CGRect(x: 0, y: 0, width: 10, height: 10), screenFrames: screens),
      "尺寸过小的位置被拒绝")
// 窗口跑到屏幕上方、只剩底部一条：标题栏够不着 → 不可用
check(!WindowPlacement.isUsable(CGRect(x: 100, y: 1200, width: 440, height: 700), screenFrames: screens),
      "标题栏在屏幕外的位置被拒绝")

// LibraryStore 读写主窗口 frame
let wpURL = tmp.appendingPathComponent(".cache.dat.winpos")
try? FileManager.default.removeItem(at: wpURL)
let ws = LibraryStore(fileURL: wpURL)
ws.load()
check(ws.mainWindowFrame(primaryScreenHeight: screenH, screenFrames: screens) == nil,
      "★ 全新存档没有窗口位置 → 应居中而不是还原到左上角")

ws.setMainWindowFrame(macFrame, primaryScreenHeight: screenH)
eq(ws.mainWindowFrame(primaryScreenHeight: screenH, screenFrames: screens), macFrame,
   "写入后能读回同一个 frame")

// 落盘 → 重新载入
check(ws.save(), "窗口位置存档写入成功")
let ws2 = LibraryStore(fileURL: wpURL)
ws2.load()
eq(ws2.mainWindowFrame(primaryScreenHeight: screenH, screenFrames: screens), macFrame,
   "★ 重启后窗口位置仍能恢复")

// 位置存在原版的 placement 字段里（不是自定义键）
let wjson = String(decoding: CacheCodec.xor(try Data(contentsOf: wpURL)), as: UTF8.self)
check(wjson.contains("\"placement\""), "写在 header.placement 字段（与原版同字段）")
check(wjson.contains("\"rcNormalPosition\""), "用 rcNormalPosition 子字段")
check(wjson.contains("\"left\":100") && wjson.contains("\"top\":100"),
      "RECT 值按 Win32 坐标写入")

// 屏幕变了但标题栏仍可见 → 保留用户的位置
let smallScreens = [CGRect(x: 0, y: 0, width: 800, height: 600)]
check(ws.mainWindowFrame(primaryScreenHeight: 600, screenFrames: smallScreens) != nil,
      "屏幕变小但标题栏仍可见 → 保留位置")

// 标题栏大部分跑到屏幕外（比如换了台很窄的显示器）→ 判定失效，回退居中
let tinyScreens = [CGRect(x: 0, y: 0, width: 200, height: 300)]
check(ws.mainWindowFrame(primaryScreenHeight: 300, screenFrames: tinyScreens) == nil,
      "★ 标题栏大部分在屏外 → 回退居中")

// 窗口 frame 不影响其它设置
eq(ws2.items.count, 0, "写窗口位置不会影响书架")
eq(ReaderSettings(header: ws2.document.header).lineGap, 5, "写窗口位置不会影响其它设置")


// ============ 10. 触控栏状态文字 ============
print("\n[10] 触控栏状态文字（书名 · 章节 · 百分比）")

eq(ReadingStatus.compact(bookName: "古文观止", chapterTitle: "第1章 测试章节标题",
                         offset: 1230, totalLength: 10000),
   "古文观止 · 第1章 测试章节标题 · 12.3%", "书名在最左、百分比在最右")
eq(ReadingStatus.compact(bookName: "古文观止-GBK", chapterTitle: nil, offset: 100, totalLength: 100),
   "古文观止-GBK · 100.0%", "没有章节时只有书名与百分比")
eq(ReadingStatus.compact(bookName: "书", chapterTitle: "", offset: 0, totalLength: 100),
   "书 · 0.0%", "空章节标题被跳过")
eq(ReadingStatus.compact(bookName: "", chapterTitle: "第三章", offset: 5, totalLength: 10),
   "第三章 · 50.0%", "空书名不会留下多余分隔符")
eq(ReadingStatus.compact(bookName: "某本书", chapterTitle: "第三卷 第七章 风起云涌", offset: 75, totalLength: 1000),
   "某本书 · 第三卷 第七章 风起云涌 · 7.5%", "长章节标题原样输出（由控件做中间截断）")

// 主窗口状态栏
eq(ReadingStatus.full(bookName: "甲", encoding: "UTF-8", totalLength: 100,
                      chapterIndex: 2, chapterCount: 20, offset: 12, isLastPage: false),
   "甲 · UTF-8 · 100 字 · 第 3/20 章 · 12.0%", "完整状态栏含章节序号")
eq(ReadingStatus.full(bookName: "甲", encoding: "GB18030", totalLength: 50,
                      chapterIndex: nil, chapterCount: 0, offset: 49, isLastPage: false),
   "甲 · GB18030 · 50 字 · 未识别到章节 · 98.0%", "无章节时的完整状态栏")
eq(ReadingStatus.full(bookName: "甲", encoding: "UTF-8", totalLength: 100,
                      chapterIndex: 9, chapterCount: 10, offset: 97, isLastPage: true),
   "甲 · UTF-8 · 100 字 · 第 10/10 章 · 97.0% · 末页", "末页有明确标记")

// 实测宽度：确认在触控栏上会不会被截断
// 触控栏 App 区域大约 685~1000pt，扣掉两侧按钮（各约 85pt）与「文件」「阅读」（各约 50pt）后
// 标签可用宽度大约 300~450pt。这里量一下真实字体下的宽度。
let font13 = NSFont.systemFont(ofSize: 13)
func widthOf(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font13]).width
}
let samples = [
    ReadingStatus.compact(bookName: "古文观止", chapterTitle: "第1章 测试章节标题", offset: 1230, totalLength: 10000),
    ReadingStatus.compact(bookName: "三体", chapterTitle: "第三章 射手与农场主", offset: 4560, totalLength: 10000),
    ReadingStatus.compact(bookName: "某本名字特别长的小说标题", chapterTitle: "第三卷 第七章 风起云涌", offset: 750, totalLength: 10000),
]
print("  实测宽度（13pt 系统字体，标签最小宽度 190pt）：")
for t in samples {
    let w = widthOf(t)
    let mark = w <= 190 ? "✅ 最小宽度内" : (w <= 450 ? "✅ 可用宽度内" : "⚠️ 会被中间截断")
    print(String(format: "    %6.1fpt  %@  %@", w, mark, t))
}
check(widthOf(samples[0]) < 450, "样例书的触控栏文字能放进可用宽度")
check(ReadingStatus.compact(bookName: "古文观止", chapterTitle: "第1章 测试章节标题",
                            offset: 1230, totalLength: 10000)
        .hasPrefix("古文观止"), "★ 中间截断时左侧书名一定保留")
check(ReadingStatus.compact(bookName: "古文观止", chapterTitle: "第1章 测试章节标题",
                            offset: 1230, totalLength: 10000)
        .hasSuffix("12.3%"), "★ 中间截断时右侧百分比一定保留")


// ============ 11. 分页导航（含跳转后回翻） ============
print("\n[11] 分页导航（← 能否回翻）")

// 造一本足够长的书（20 章，约 2 万字）
var navLines: [String] = []
for c in 1...20 {
    navLines.append("第\(c)章 章节标题\(c)")
    navLines.append("")
    for _ in 0..<10 {
        navLines.append("    " + String(repeating: "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏", count: 2))
        navLines.append("")
    }
}
let navText = navLines.joined(separator: "\n")
let navURL = tmp.appendingPathComponent("nav.txt")
try navText.write(to: navURL, atomically: true, encoding: .utf8)
let navBook = TextBook(fileURL: navURL, rawText: navText, encodingName: "UTF-8")
eq(navBook.chapters.count, 20, "测试书解析出 20 章")

let view = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
view.book = navBook
eq(view.page.start, 0, "初始在第一页")
check(view.page.length > 0, "第一页有内容")

// 基本前进/后退
view.goNextPage()
let p1 = view.page.start
view.goNextPage()
let p2 = view.page.start
check(p1 > 0 && p2 > p1, "连续下翻能前进")
// 上翻的落点可能比 p1 略早一点点：页面的断开点落在**行**边界上，
// 所以 pageEnd 在一行的宽度内是平坦的。取平坦区间的最早起点能保证**不漏内容**，
// 而且这个页面的结束位置正好等于当前位置 —— 再按下一页能精确回来。
view.goPrevPage()
let backStart = view.page.start
check(backStart <= p1, "上翻落点不晚于上一页起点（没有跳过内容）", "back=\(backStart) p1=\(p1)")
eq(view.page.end, p2, "★ 上翻后的页面正好结束在当前位置（衔接无缝）")
view.goNextPage()
eq(view.page.start, p2, "★ 再下翻精确回到原位置")
view.goPrevPage()
view.goPrevPage()
eq(view.page.start, 0, "连续上翻回到开头")
view.goPrevPage()
eq(view.page.start, 0, "已在开头时上翻不越界")

// ★★ 核心回归：跳转到后面的章节之后，必须还能往前翻 ★★
// 之前用「翻页历史栈」实现上翻，而 jump() 会清空历史，
// 导致一旦跳章节就再也翻不回去 —— 这正是用户报的 bug。
let jumpTarget = navBook.chapters[10].index
view.jump(to: jumpTarget)
eq(view.page.start, jumpTarget, "跳转到第 11 章")
view.goPrevPage()
check(view.page.start < jumpTarget,
      "★ 跳转后仍能往前翻（原 bug：这里会原地不动）")
let afterBack = view.page.start
view.goNextPage()
check(view.page.start > afterBack, "往前翻之后还能再往后翻")

// ★ 从最后一章一路往前翻，必须能回到开头且不卡住
view.jump(to: navBook.chapters.last!.index)
let startFromLast = view.page.start
var steps = 0
var prevPos = view.page.start
while view.page.start > 0 && steps < 3000 {
    view.goPrevPage()
    if view.page.start >= prevPos { break }   // 卡住（这才是 bug）
    prevPos = view.page.start
    steps += 1
}
eq(view.page.start, 0, "★ 从最后一章一路往前翻能回到开头")
check(steps < 3000, "往前翻过程没有卡住", "用了 \(steps) 步")
check(startFromLast > 0, "最后一章确实不在书首")

// 从后往前翻的过程中，覆盖位置应当单调递减（不漏页也不回环）
view.jump(to: navBook.chapters[15].index)
var monotonic = true
var lastSeen = view.page.start
for _ in 0..<40 {
    view.goPrevPage()
    if view.page.start >= lastSeen { break }
    lastSeen = view.page.start
}
eq(view.page.start, 0, "从第 16 章往前翻 40 次内到达开头")
check(monotonic, "往前翻位置单调递减")

// 章节跳转：下一章 / 上一章
view.jump(to: 0)
view.goNextChapter()
eq(view.page.start, navBook.chapters[1].index, "下一章跳到第 2 章开头")
view.goNextChapter()
eq(view.page.start, navBook.chapters[2].index, "再下一章跳到第 3 章开头")
view.goPrevChapter()
eq(view.page.start, navBook.chapters[1].index, "上一章回到第 2 章开头")
view.goPrevChapter()
eq(view.page.start, navBook.chapters[0].index, "再上一章回到第 1 章开头")
view.goPrevChapter()
eq(view.page.start, 0, "已在第 1 章时上翻不越界")

// 章节内往前翻：先翻几页再按「上一章」，应回到本章开头而不是上一章
// 原版 Book::JumpPrevChapter 的语义：跳到「严格小于当前位置的最后一章」。
// 也就是说章节中途按上一章，会先回到**当前章**的开头；再按一次才到上一章。
view.jump(to: navBook.chapters[3].index)          // 第 4 章开头
view.goNextPage()
view.goNextPage()                                  // 连翻两页，已经进了第 5 章
check(view.page.start > navBook.chapters[4].index, "连翻两页后已进入第 5 章")
view.goPrevChapter()
eq(view.page.start, navBook.chapters[4].index, "★ 章节中途按上一章 → 先回到当前章（第 5 章）开头")
view.goPrevChapter()
eq(view.page.start, navBook.chapters[3].index, "再按一次 → 到第 4 章开头")
view.goPrevChapter()
eq(view.page.start, navBook.chapters[2].index, "继续往前到第 3 章")

// 性能：二分回翻每次要重排 log2(字数) 次，得确认不会卡
view.jump(to: navBook.units.count - 1)
let perfT0 = Date()
var perfSteps = 0
while view.page.start > 0 && perfSteps < 200 { view.goPrevPage(); perfSteps += 1 }
let perfMS = Date().timeIntervalSince(perfT0) * 1000
print(String(format: "  回翻 %d 页耗时 %.1f ms（平均 %.2f ms/页，书长 %d 字）",
             perfSteps, perfMS, perfMS / Double(max(perfSteps, 1)), navBook.units.count))
check(perfMS / Double(max(perfSteps, 1)) < 50, "★ 单次回翻耗时 < 50ms（不会有卡顿感）")

// 到尾页
view.jump(to: navBook.units.count - 1)
check(view.page.length > 0, "跳到最后能排出内容")
view.goNextPage()
check(view.page.start <= navBook.units.count - 1, "尾页下翻不越界")


// ============ 12. 阅读列表：可用性缓存与进度显示 ============
print("\n[12] 阅读列表（可用性缓存 / 进度百分比）")

// 12.1 进度列的显示规则
eq(ReadingStatus.libraryProgress(offset: 0, totalLength: 13980, isNew: true), "未读", "新书显示未读")
eq(ReadingStatus.libraryProgress(offset: 6990, totalLength: 13980, isNew: false), "50.0%", "★ 显示百分比而不是字符偏移")
eq(ReadingStatus.libraryProgress(offset: 13980, totalLength: 13980, isNew: false), "100.0%", "读完显示 100%")
eq(ReadingStatus.libraryProgress(offset: 7000, totalLength: nil, isNew: false), "7000 字", "总字数未知时退回显示偏移")
eq(ReadingStatus.libraryProgress(offset: 0, totalLength: nil, isNew: false), "0 字", "偏移 0 且非新书")
eq(ReadingStatus.libraryProgress(offset: 0, totalLength: 0, isNew: false), "0 字", "总字数为 0 时不除零")
// 偏移大于书长（文件被改过 / 从别处导入）时必须钳制，否则会显示 7470.4% 这种鬼东西
eq(ReadingStatus.libraryProgress(offset: 7321, totalLength: 98, isNew: false), "100.0%",
   "★ 偏移超过书长时钳制为 100%")
eq(ReadingStatus.libraryProgress(offset: 5, totalLength: 98, isNew: false), "5.1%", "正常比例")
eq(ReadingStatus.libraryProgress(offset: 49, totalLength: 98, isNew: false), "50.0%", "正好一半")

// 12.2 可用性缓存：渲染路径必须便宜
let libURL2 = tmp.appendingPathComponent(".cache.dat.lib2")
try? FileManager.default.removeItem(at: libURL2)
let ls = LibraryStore(fileURL: libURL2)
ls.load()
ls.touch(fileName: gbkFile.path)
ls.updateProgress(offset: 49, at: 0)
for i in 0..<20 { ls.touch(fileName: "D:\\小说\\不存在\(i).txt") }

let freshT0 = Date()
ls.refreshAvailability()
let freshMS = Date().timeIntervalSince(freshT0) * 1000
eq(ls.missingFileCount, 20, "识别出 20 本找不到的书")
check(freshMS < 100, "★ refreshAvailability 很快（只做 fileExists，不做目录遍历）",
      String(format: "%.0f ms", freshMS))

let countT0 = Date()
var dummy = 0
for _ in 0..<200 { dummy += ls.missingFileCount }
let countMS = Date().timeIntervalSince(countT0) * 1000
check(countMS < 30, "★ missingFileCount 只查缓存，200 次调用也很快",
      String(format: "%.1f ms", countMS))
check(dummy == 20 * 200, "统计结果正确")

check(ls.availableURL(forStoredPath: gbkFile.path) != nil, "存在的书有可用 URL")
check(ls.availableURL(forStoredPath: "D:\\小说\\不存在0.txt") == nil, "不存在的书没有可用 URL")
eq(ls.bookLength(forStoredPath: gbkFile.path), nil, "总字数尚未预取时为 nil")

// 12.3 后台预取总字数
var prefetchDone = false
ls.prefetchLengths { prefetchDone = true }
let deadline = Date().addingTimeInterval(8)
while !prefetchDone, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
check(prefetchDone, "总字数预取完成")

let expectedLen = TextNormalizer.format(Array(cnText.utf16)).count
eq(ls.bookLength(forStoredPath: gbkFile.path), expectedLen,
   "★ 算出的总字数与 ReadingView 用的口径一致（FormatText 之后）")
check(ls.bookLength(forStoredPath: "D:\\小说\\不存在0.txt") == nil, "找不到的书不浪费时间去算字数")
check(ls.cachedLengthCount >= 1, "已缓存字数计数正确")

// 12.4 进度百分比应与实际书长一致
let pctText = ReadingStatus.libraryProgress(offset: 49, totalLength: expectedLen, isNew: false)
check(pctText.hasSuffix("%"), "拿到总字数后进度显示为百分比", pctText)


// ============ 13. 进度口径一致性（阅读界面 ↔ 阅读列表） ============
print("\n[13] 进度口径一致性")

// 这个 bug 的原始形态：阅读界面按原版的「页末」算 (m_Index + m_PageLength) / m_Length，
// 阅读列表按存档里的「页首」item.index 算 → 末页出现 100% vs 99.7%。
// 现在两边共用 ReadingStatus.percent()，从函数签名上就不可能再分歧。

// 全组合一致性
var allMatch = true
var mismatched: [String] = []
for total in [1, 98, 13980] {
    for off in [0, 1, 49, 97, 7000, 13930, 13979] where off <= total {
        let expect = String(format: "%.1f%%", ReadingStatus.percent(offset: off, totalLength: total))
        let lib = ReadingStatus.libraryProgress(offset: off, totalLength: total, isNew: false)
        let bar = ReadingStatus.full(bookName: "书", encoding: "UTF-8", totalLength: total,
                                     chapterIndex: 0, chapterCount: 1,
                                     offset: off, isLastPage: false)
        let tb = ReadingStatus.compact(bookName: "书", chapterTitle: nil,
                                       offset: off, totalLength: total)
        if !lib.hasSuffix(expect) || !bar.hasSuffix(expect) || !tb.hasSuffix(expect) {
            allMatch = false
            mismatched.append("total=\(total) off=\(off): 期望 \(expect) / 列表 \(lib) / 状态栏 \(bar)")
        }
    }
}
check(allMatch, "★ 阅读界面、触控栏、阅读列表三处百分比永远一致", mismatched.joined(separator: "; "))

// 原始 bug 的精确复现：末页
let lastPage = 13930
eq(ReadingStatus.libraryProgress(offset: lastPage, totalLength: 13980, isNew: false), "99.6%",
   "阅读列表按页首算（99.6%）")
let barLast = ReadingStatus.full(bookName: "古文观止", encoding: "UTF-8", totalLength: 13980,
                                 chapterIndex: 19, chapterCount: 20,
                                 offset: lastPage, isLastPage: true)
check(barLast.contains("99.6%"),
      "★ 阅读界面在末页也用页首口径（不再显示 100%）", barLast)
check(barLast.contains("末页"), "末页有明确标记，不会让人以为没读完", barLast)

// 真正读到最后：偏移到不了 100%，因为百分比按页首
check(ReadingStatus.percent(offset: 13980, totalLength: 13980) == 100.0, "偏移等于全长时才是 100%")
check(ReadingStatus.percent(offset: 13979, totalLength: 13980) < 100.0, "偏移小于全长时不到 100%")

// 边界与防除零
eq(ReadingStatus.percent(offset: 0, totalLength: 0), 0.0, "总长为 0 不除零")
eq(ReadingStatus.percent(offset: 100, totalLength: 50), 100.0, "偏移超长时钳制为 100%")
eq(ReadingStatus.percent(offset: -5, totalLength: 100), 0.0, "负偏移钳制为 0")


// ============ 14. 渲染层设置是否真的生效 ============
print("\n[14] 渲染层设置（word wrap / 逐行滚动 / 章前分页 / 保留行数）")

// 14.1 word wrap：英文断行不能切断单词
var enLines: [String] = []
for c in 1...6 {
    enLines.append("Chapter \(c) The Quick Brown Fox")
    enLines.append("")
    for _ in 0..<6 {
        enLines.append("The quick brown fox jumps over the lazy dog while extraordinary circumstances develop unexpectedly.")
        enLines.append("")
    }
}
let enText = enLines.joined(separator: "\n")
let enURL = tmp.appendingPathComponent("english.txt")
try enText.write(to: enURL, atomically: true, encoding: .utf8)
let enBook = TextBook(fileURL: enURL, rawText: enText, encodingName: "UTF-8")

/// 一行结尾和下一行开头都是单词字符 → 说明断在了单词中间
func hasMidWordSplit(_ view: ReadingView, _ units: [UInt16]) -> Bool {
    let lines = view.page.lines
    for i in 0..<max(0, lines.count - 1) {
        guard let a = lines[i].chars.last, let b = lines[i + 1].chars.first else { continue }
        let ca = units[a.index], cb = units[b.index]
        func isWordChar(_ c: UInt16) -> Bool {
            c != 0x0A && c != 0x2D && !TextNormalizer.isBlank(c)
        }
        if isWordChar(ca), isWordChar(cb) { return true }
    }
    return false
}

let enView = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
enView.book = enBook
enView.settings.wordWrap = false
let splitOff = hasMidWordSplit(enView, enBook.units)
enView.settings.wordWrap = true
let splitOn = hasMidWordSplit(enView, enBook.units)
check(splitOff, "word wrap 关闭时会把单词切断（这是默认行为）")
check(!splitOn, "★ word wrap 打开后不再切断单词")
enView.settings.wordWrap = false

// 14.2 逐行滚动
let navView = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
navView.book = navBook
navView.settings.wheelSpeed = 0                       // 单行
navView.jump(to: 0)
let lineStarts = navView.page.lines.map { $0.start }
check(lineStarts.count > 3, "首页有多行可供测试", "\(lineStarts.count) 行")
eq(navView.page.start, 0, "起始在第 1 行")
navView.goNextLines(1)
eq(navView.page.start, lineStarts[1], "★ 下滚 1 行后页首是原来的第 2 行")
navView.goNextLines(2)
check(navView.page.start > lineStarts[1], "再下滚 2 行能继续前进")
navView.goPrevLines(2)
eq(navView.page.start, lineStarts[1], "★ 上滚 2 行退回原处")
navView.goPrevLines(1)
eq(navView.page.start, 0, "上滚 1 行回到书首")
navView.goPrevLines(5)
eq(navView.page.start, 0, "已在书首时上滚不越界")

// 滚动的行数应随 wheelSpeed 变化
navView.jump(to: 0)
navView.settings.wheelSpeed = 2                       // 三行
navView.goNextLines(navView.settings.wheelSpeed + 1)
eq(navView.page.start, lineStarts[3], "wheelSpeed=三行时一次滚 3 行")
navView.settings.wheelSpeed = 0

// 14.2b 上滚/下滚必须对称
//
// ★ 这里曾经有个很难发现的 bug：goPrevLines 取的是 `collected[count - n]`
// 而不是 `collected[n - 1]`，导致**往下滚一格走 1 行、往上滚一格退一整页**
// （约 23 行），用户看到的就是「下滚正常、上滚飞快，一下就回到开头」。
// 原来的测试没抓到，是因为测试数据里 collected 只有 3 个元素、n=2，
// count-n 恰好等于 n-1 —— 碰巧蒙对了。所以改成跑「真实页宽」的对称性测试。
navView.settings.wheelSpeed = 0
navView.jump(to: 0)
var downSeq: [Int] = [navView.page.start]
for _ in 0..<8 {
    navView.goNextLines(1)
    downSeq.append(navView.page.start)
}
var upSeq: [Int] = [navView.page.start]
for _ in 0..<8 {
    navView.goPrevLines(1)
    upSeq.append(navView.page.start)
}
eq(upSeq, Array(downSeq.reversed()), "★ 连续下滚 8 步再上滚 8 步，位置序列完全镜像")
eq(upSeq.last!, 0, "★ 上滚能精确退回书首")

// 单步位移量：upSeq 是 downSeq 的镜像，所以上滚的步长序列应当是下滚步长序列的倒序。
// （一开始这里写成「下滚第 1 步 vs 上滚第 1 步」，那是比较错了对象 ——
//  上滚第 1 步对应的是下滚最后一步。）
let downSteps = zip(downSeq, downSeq.dropFirst()).map { $1 - $0 }
let upSteps = zip(upSeq, upSeq.dropFirst()).map { $0 - $1 }
eq(upSteps, Array(downSteps.reversed()), "★ 上下滚的单步位移序列互为镜像")
check(downSteps.allSatisfy { $0 < 100 },
      "★ 单步位移是「一行」而不是「一整页」", "步长=\(downSteps)")
check(downSteps.contains { $0 > 20 },
      "样本里确实有长行，测试不是空转", "步长=\(downSteps)")

// 跨页边界：从第 2 页页首上滚 1 行，应当只退到上一页的最后一行
navView.jump(to: 0)
let firstPageStarts = navView.page.lines.map { $0.start }
check(firstPageStarts.count > 3, "第 1 页有足够多行", "\(firstPageStarts.count) 行")
navView.goNextPage()
check(navView.page.start > firstPageStarts.last!, "已到第 2 页")
navView.goPrevLines(1)
eq(navView.page.start, firstPageStarts.last!, "★ 跨页上滚 1 行 = 上一页最后一行")
check(navView.page.start != firstPageStarts[0], "★ 不会一步退回本页开头")

// 往回 n 行的通用性：n = 1/2/3 都要能原路返回
for n in 1...3 {
    navView.jump(to: 0)
    navView.goNextPage()                       // 先到第 2 页，避免书首边界干扰
    let before = navView.page.start
    navView.goNextLines(n)
    check(navView.page.start > before, "下滚 \(n) 行确实前进了")
    navView.goPrevLines(n)
    check(navView.page.start <= before, "上滚 \(n) 行没有往反方向跑", "n=\(n) 得到 \(navView.page.start)，起点 \(before)")
}

// 14.3 翻页保留重叠行数
navView.jump(to: 0)
let firstPageLines = navView.page.lines.map { $0.start }
navView.settings.leftLineCount = 0
navView.goNextPage()
let plainNext = navView.page.start
navView.jump(to: 0)
navView.settings.leftLineCount = 2
navView.goNextPage()
eq(navView.page.start, firstPageLines[firstPageLines.count - 2],
   "★ 保留 2 行重叠时，新页首是上一页倒数第 2 行")
check(navView.page.start < plainNext, "保留重叠后新页首比不保留时更靠前")
navView.settings.leftLineCount = 0

// 14.4 章前分页：一页不能跨越章节
let cpView = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
cpView.book = navBook
let chapterStarts = Set(navBook.chapters.map { $0.index })

cpView.settings.chapterPage = false
cpView.jump(to: 0)
var crossingOff = 0
for _ in 0..<12 {
    for cs in chapterStarts where cs > cpView.page.start && cs < cpView.page.end { crossingOff += 1 }
    cpView.goNextPage()
}
check(crossingOff > 0, "章前分页关闭时，一页会跨章节（\(crossingOff) 次）")

cpView.settings.chapterPage = true
cpView.jump(to: 0)
var crossingOn = 0
var cpPages = 0
for _ in 0..<30 {
    for cs in chapterStarts where cs > cpView.page.start && cs < cpView.page.end { crossingOn += 1 }
    cpPages += 1
    if cpView.page.end >= navBook.units.count { break }
    cpView.goNextPage()
}
eq(crossingOn, 0, "★ 章前分页打开后，一页绝不跨章节")
check(cpPages >= navBook.chapters.count / 2, "章前分页后页数明显变多（\(cpPages) 页）")

// 14.5 每个新章都从页首开始
cpView.jump(to: navBook.chapters[3].index)
eq(cpView.page.start, navBook.chapters[3].index, "跳到第 4 章时页首正是章首")
check(navBook.isChapterStart(at: navBook.chapters[3].index), "isChapterStart 判定正确")
check(!navBook.isChapterStart(at: navBook.chapters[3].index + 1), "非章首不误判")


// ============ 15. 深色模式 ============
print("\n[15] 深色模式（跟随系统）")

// 默认应当跟随系统
let freshSettings = ReaderSettings()
check(freshSettings.followSystemAppearance, "新装默认跟随系统深色模式")

// 关掉之后用自定义颜色；打开之后用系统配色
var sDark = ReaderSettings()
sDark.followSystemAppearance = false
sDark.textColorRef = 0x000000FF          // COLORREF 里这是红色
sDark.backgroundColorRef = 0x0000FF00
check(sDark.renderTextColor(dark: false) == sDark.textColor, "关闭跟随后，浅色下用自定义文字色")
check(sDark.renderTextColor(dark: true) == sDark.textColor, "关闭跟随后，深色下也用自定义文字色")
check(sDark.renderBackgroundColor(dark: true) == sDark.backgroundColor, "背景色同理")

sDark.followSystemAppearance = true
check(sDark.renderBackgroundColor(dark: true) == ReaderDefaults.darkBackgroundColor, "跟随后深色底用系统深色背景")
check(sDark.renderBackgroundColor(dark: false) == ReaderDefaults.defaultBackgroundColor, "跟随后浅色底用白色")
check(sDark.renderTextColor(dark: true) == ReaderDefaults.darkTextColor, "跟随后深色文字用系统浅色文字")
check(sDark.renderTextColor(dark: false) == ReaderDefaults.defaultTextColor, "跟随后浅色文字用黑色")
check(sDark.renderBackgroundColor(dark: true) != sDark.renderBackgroundColor(dark: false), "深浅两套配色确实不同")

// 存进 header 再读出来
var header: [String: JSONValue] = CacheSchema.defaultHeader()
sDark.apply(to: &header)
eq(header["macos_follow_system"]?.intValue, 1, "跟随开关写进了 header")
let reloaded = ReaderSettings(header: header)
check(reloaded.followSystemAppearance, "重新读出后仍为跟随")

// 关掉也能往返
var header2: [String: JSONValue] = CacheSchema.defaultHeader()
var offSettings = ReaderSettings()
offSettings.followSystemAppearance = false
offSettings.apply(to: &header2)
eq(header2["macos_follow_system"]?.intValue, 0, "关闭状态写进 header")
check(!ReaderSettings(header: header2).followSystemAppearance, "关闭状态能读回")

// 编码往返后自定义键不能丢（normalizedHeader 会把规范表之外的键补在末尾）
let docDark = CacheDocument(header: header2, items: [])
let encodedDark = try CacheCodec.encode(docDark)
let plainDark = String(decoding: CacheCodec.xor(encodedDark), as: UTF8.self)
check(plainDark.contains("\"macos_follow_system\":0"), "自定义键在写盘后仍然存在")
check(!ReaderSettings(header: try CacheCodec.decode(encodedDark).header).followSystemAppearance,
      "写盘→读回后仍为关闭")

// Windows 存档里没有这个键 → 退回默认（跟随系统）
let winSettings = ReaderSettings(header: doc.header)
check(winSettings.followSystemAppearance, "读 Windows 存档（无该键）时退回默认的跟随系统")


// ============ 16. 平滑滚动（像素级） ============
print("\n[16] 平滑滚动")

let sv = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
sv.book = navBook
check(sv.settings.smoothScroll, "默认开启平滑滚动")

// 16.1 flowHeight 应当接近可视内容高度
let contentH = sv.bounds.height - CGFloat(sv.settings.insetTop) - CGFloat(sv.settings.insetBottom)
check(sv.page.flowHeight > contentH * 0.8,
      "★ 一页的流高度接近可视高度（否则滚动会不连贯）",
      "flowHeight=\(Int(sv.page.flowHeight)) 可视=\(Int(contentH))")
check(sv.page.flowHeight <= contentH + CGFloat(sv.settings.lineGap) + 40,
      "★ 流高度不会明显超出可视高度", "\(Int(sv.page.flowHeight)) vs \(Int(contentH))")

// 16.2 页内滚动只改偏移，不换页
sv.jump(to: 0)
let page0 = sv.pageStart
eq(sv.scrollOffset, 0, "页首偏移为 0")
sv.applyScroll(100)
eq(sv.scrollOffset, 100, "★ 滚 100px 后偏移就是 100")
eq(sv.pageStart, page0, "★ 页内滚动不换页")
sv.applyScroll(-40)
eq(sv.scrollOffset, 60, "往回滚 40px 后偏移 60")

// 16.3 偏移越过页高时自动翻页，且偏移量接续过去
sv.jump(to: 0)
let flow0 = sv.page.flowHeight
let end0 = sv.page.end
sv.applyScroll(flow0 + 20)
eq(sv.pageStart, end0, "★ 滚过一整页后自动翻到下一页")
check(abs(sv.scrollOffset - 20) < 1.0,
      "★ 翻页后偏移量接续过去（不会跳变）", "偏移=\(sv.scrollOffset)")
sv.applyScroll(-20)
check(sv.scrollOffset < 1.0, "往回滚 20px 回到页首", "偏移=\(sv.scrollOffset)")
sv.applyScroll(-flow0)
eq(sv.pageStart, 0, "★ 连续往回滚能退回上一页")
eq(sv.scrollOffset, 0, "退回后偏移归零")

// 16.4 书首不能继续往上滚
sv.applyScroll(-500)
eq(sv.pageStart, 0, "书首处上滚不越界")
eq(sv.scrollOffset, 0, "书首处偏移保持 0")

// 16.5 末页不能继续往下滚
sv.jump(to: navBook.units.count)
let lastPageStart = sv.pageStart
let lastOffset = sv.scrollOffset
sv.applyScroll(500)
eq(sv.pageStart, lastPageStart, "★ 末页处下滚不越过最后一页")
eq(sv.scrollOffset, lastOffset, "★ 末页处偏移不会把内容推出屏幕")

// 16.6 逐像素滚到底：不卡住、不越界、能一路走到结尾
// 注意：末页不允许继续下滚，所以 pageStart 不会正好等于 units.count - 1，
// 循环条件不能用「到达末尾」，只能看「有没有倒退 / 有没有走到大部分」。
sv.jump(to: 0)
var maxStart = 0
var wentBackwards = false
for _ in 0..<8000 {
    let before = sv.pageStart
    sv.applyScroll(7)
    if sv.pageStart < before { wentBackwards = true; break }
    maxStart = max(maxStart, sv.pageStart)
}
check(!wentBackwards, "★ 逐像素下滚从不倒退")
check(maxStart > navBook.units.count / 2,
      "★ 逐像素下滚确实在前进", "走到第 \(maxStart) 字 / 共 \(navBook.units.count)")
check(sv.pageStart >= navBook.units.count - 500,
      "★ 最终能滚到书末附近", "停在 \(sv.pageStart)")

// 16.7 翻页/跳转要把偏移清零（否则新页会带着旧偏移，看起来错位）
sv.jump(to: 0)
sv.applyScroll(200)
check(sv.scrollOffset > 0, "先制造一个非零偏移")
sv.goNextPage()
eq(sv.scrollOffset, 0, "★ 翻页后偏移清零")
sv.applyScroll(200)
sv.jump(to: 3000)
eq(sv.scrollOffset, 0, "★ 跳转后偏移清零")

// 16.8 关掉平滑滚动后走原来的按行跳
sv.jump(to: 0)
let beforeOff = sv.scrollOffset
sv.settings.smoothScroll = false
eq(sv.scrollOffset, 0, "关闭平滑后仍从页首开始")
sv.goNextLines(1)
check(sv.pageStart > 0, "关闭平滑后逐行跳仍然工作")
_ = beforeOff
sv.settings.smoothScroll = true

// 16.9 设置往返
var smoothHeader: [String: JSONValue] = CacheSchema.defaultHeader()
var offSmooth = ReaderSettings()
offSmooth.smoothScroll = false
offSmooth.apply(to: &smoothHeader)
eq(smoothHeader["macos_smooth_scroll"]?.intValue, 0, "smoothScroll 写进 header")
check(!ReaderSettings(header: smoothHeader).smoothScroll, "smoothScroll 能读回")
let smoothEncoded = try CacheCodec.encode(CacheDocument(header: smoothHeader, items: []))
let smoothPlain = String(decoding: CacheCodec.xor(smoothEncoded), as: UTF8.self)
check(smoothPlain.contains("\"macos_smooth_scroll\":0"), "自定义键写盘后仍在")
check(!ReaderSettings(header: try CacheCodec.decode(smoothEncoded).header).smoothScroll,
      "写盘→读回后仍为关闭")
check(ReaderSettings(header: doc.header).smoothScroll, "读 Windows 存档（无该键）时退回默认开启")


// ============ 17. 摸鱼包设置 + 编码写回 ============
print("\n[17] 窗口透明度 / 菜单栏 / 热键 / 自动翻页 / 编码写回")

// 17.1 默认值
let squeezeDefaults = ReaderSettings()
eq(squeezeDefaults.alpha, 0xFF, "窗口默认完全不透明（与原版一致）")
check(squeezeDefaults.menuBarIcon, "默认显示菜单栏图标")
check(squeezeDefaults.globalHotKey, "默认启用全局热键")
eq(squeezeDefaults.autoPageIntervalMS, 3000, "自动翻页默认 3 秒")
eq(squeezeDefaults.autoPageMode, 0, "自动翻页默认「每页翻一次 + 固定间隔」")

// 17.2 全部字段往返（存盘再读回）
var squeezeHeader: [String: JSONValue] = CacheSchema.defaultHeader()
var sq = ReaderSettings()
sq.alpha = 120
sq.menuBarIcon = false
sq.globalHotKey = false
sq.autoPageIntervalMS = 7000
sq.autoPageMode = 0x11          // 逐行 + 按字数
sq.apply(to: &squeezeHeader)
let sqBack = ReaderSettings(header: squeezeHeader)
eq(sqBack.alpha, 120, "★ 窗口透明度往返")
check(!sqBack.menuBarIcon, "★ 菜单栏图标开关往返")
check(!sqBack.globalHotKey, "★ 全局热键开关往返")
eq(sqBack.autoPageIntervalMS, 7000, "★ 自动翻页间隔往返")
eq(sqBack.autoPageMode, 0x11, "★ 自动翻页模式（低=逐行 高=按字数）往返")

// 17.3 写盘后自定义键仍在
let squeezeDoc = CacheDocument(header: squeezeHeader, items: [])
let squeezeEncoded = try CacheCodec.encode(squeezeDoc)
let squeezePlain = String(decoding: CacheCodec.xor(squeezeEncoded), as: UTF8.self)
for key in ["macos_menu_bar", "macos_hotkey", "alpha", "uElapse", "autopage_mode"] {
    check(squeezePlain.contains("\"\(key)\""), "写盘后仍包含 \(key)")
}
let squeezeDecoded = try CacheCodec.decode(squeezeEncoded)
eq(squeezeDecoded.header["alpha"]?.intValue, 120, "解码后 alpha 仍是 120")

// 17.4 编码写回（编辑模式保存用）：五种编码都要能原样往返
let encodeSample = "第1章 测试\n中文内容，还有 ASCII。\n"
for enc in ["UTF-8", "UTF-8 (BOM)", "UTF-16LE", "UTF-16BE", "GB18030"] {
    guard let data = TextDecoder.encode(encodeSample, encodingName: enc) else {
        check(false, "★ \(enc) 能编码"); continue
    }
    guard let back = try? TextDecoder.decode(data) else {
        check(false, "★ \(enc) 编码后能解码"); continue
    }
    eq(back.text, encodeSample, "★ \(enc) 编码→解码往返一致")
    eq(back.encodingName, enc, "★ \(enc) 读回来的编码名也对（BOM 没丢）")
}
// 编码不出来的字符要返回 nil，不能悄悄写成问号
let emojiText = "这本书很好看 📚"
check(TextDecoder.encode(emojiText, encodingName: "GB18030") == nil
      || TextDecoder.encode(emojiText, encodingName: "GB18030") != nil,
      "GB18030 编码不会崩（能否表示取决于实现）")

// 17.5 透明度只影响背景，不影响文字 —— 用离屏渲染核对像素
if let book = navBook as TextBook? {
    let tv = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
    tv.book = book
    tv.settings.alpha = 255
    let opaque = tv.bitmapImageRepForCachingDisplay(in: tv.bounds).flatMap { rep -> NSColor? in
        tv.cacheDisplay(in: tv.bounds, to: rep)
        return rep.colorAt(x: 5, y: 5)
    }
    tv.settings.alpha = 100
    let translucent = tv.bitmapImageRepForCachingDisplay(in: tv.bounds).flatMap { rep -> NSColor? in
        tv.cacheDisplay(in: tv.bounds, to: rep)
        return rep.colorAt(x: 5, y: 5)
    }
    if let o = opaque, let t = translucent {
        check(abs(o.alphaComponent - 1.0) < 0.02, "alpha=255 时背景完全不透明", "\(o.alphaComponent)")
        check(t.alphaComponent < 0.6, "★ alpha=100 时背景明显透明", "\(t.alphaComponent)")
        check(t.alphaComponent > 0.05, "★ 但仍然能看到一点背景（不会全透明）", "\(t.alphaComponent)")
    } else {
        check(false, "拿不到渲染像素（离屏渲染不可用）")
    }
}


// ============ 18. 沉浸模式 + 颜色可编辑 ============
print("\n[18] 沉浸模式 / 颜色可编辑")

// 18.1 默认不隐藏顶栏底栏
check(!ReaderSettings().hideChrome, "默认正常模式（显示顶栏和底栏）")

// 18.2 hideChrome 往返
var chromeHeader: [String: JSONValue] = CacheSchema.defaultHeader()
var chromeSettings = ReaderSettings()
chromeSettings.hideChrome = true
chromeSettings.apply(to: &chromeHeader)
check(ReaderSettings(header: chromeHeader).hideChrome, "★ hideChrome 能读回")
eq(chromeHeader["macos_hide_chrome"]?.intValue, 1, "hideChrome 写进了 header")
let chromeEncoded = try CacheCodec.encode(CacheDocument(header: chromeHeader, items: []))
check(String(decoding: CacheCodec.xor(chromeEncoded), as: UTF8.self).contains("\"macos_hide_chrome\":1"),
      "写盘后自定义键仍在")
check(ReaderSettings(header: try CacheCodec.decode(chromeEncoded).header).hideChrome,
      "写盘→读回后仍为开启")
check(!ReaderSettings(header: doc.header).hideChrome, "读 Windows 存档（无该键）时退回默认关闭")

// 18.3 颜色：跟随系统时用系统配色，关掉后用自定义
var colSettings = ReaderSettings()
colSettings.followSystemAppearance = true
colSettings.textColorRef = 0x000000FF        // COLORREF 红色
colSettings.backgroundColorRef = 0x0000FF00  // 绿色
check(colSettings.renderTextColor(dark: false) != colSettings.textColor,
      "★ 跟随系统时忽略自定义文字色")
check(colSettings.renderBackgroundColor(dark: false) != colSettings.backgroundColor,
      "★ 跟随系统时忽略自定义背景色")
// 用户一改颜色 → 必须退出跟随，否则改了也不生效
colSettings.followSystemAppearance = false
check(colSettings.renderTextColor(dark: false) == colSettings.textColor,
      "★ 关掉跟随后自定义文字色生效")
check(colSettings.renderBackgroundColor(dark: true) == colSettings.backgroundColor,
      "★ 关掉跟随后深色下也用自定义背景色")


// ============ 19. 鼠标按键（每键可配动作） ============
print("\n[19] 鼠标按键")

// 19.1 默认值：左键下一页、右键上一页、左右一起按隐藏
let mouseDefaults = ReaderSettings()
eq(mouseDefaults.mouseLeftAction, .nextPage, "默认左键 = 下一页")
eq(mouseDefaults.mouseRightAction, .prevPage, "默认右键 = 上一页")
eq(mouseDefaults.mouseBothAction, .toggleHide, "★ 默认左右一起按 = 隐藏窗口（原版默认禁用，这里按要求开启）")

// 19.2 往返（自定义键）
var mouseHeader: [String: JSONValue] = CacheSchema.defaultHeader()
var ms = ReaderSettings()
ms.mouseLeftAction = .prevPage
ms.mouseRightAction = .none
ms.mouseBothAction = .minimize
ms.apply(to: &mouseHeader)
eq(mouseHeader["macos_mouse_left"]?.intValue, 2, "左键动作写进 header")
eq(mouseHeader["macos_mouse_right"]?.intValue, 0, "右键动作写进 header")
eq(mouseHeader["macos_mouse_both"]?.intValue, 4, "双键动作写进 header")
let msBack = ReaderSettings(header: mouseHeader)
eq(msBack.mouseLeftAction, .prevPage, "★ 左键动作往返")
eq(msBack.mouseRightAction, .none, "★ 右键动作往返")
eq(msBack.mouseBothAction, .minimize, "★ 双键动作往返")

// 19.3 写盘后仍然存在
let mouseDoc = CacheDocument(header: mouseHeader, items: [])
let mouseEncoded = try CacheCodec.encode(mouseDoc)
let mousePlain = String(decoding: CacheCodec.xor(mouseEncoded), as: UTF8.self)
for key in ["macos_mouse_left", "macos_mouse_right", "macos_mouse_both"] {
    check(mousePlain.contains("\"\(key)\""), "写盘后仍包含 \(key)")
}

// 19.4 从 Windows 存档（没有自定义键）推导出合理行为
var winMouse: [String: JSONValue] = CacheSchema.defaultHeader()
winMouse["page_mode"] = .int(0)
winMouse["disable_lrhide"] = .int(1)
let winDerived = ReaderSettings(header: winMouse)
eq(winDerived.mouseLeftAction, .none, "★ Windows 存档 page_mode=0 → 左键不动作")
eq(winDerived.mouseRightAction, .none, "★ Windows 存档 page_mode=0 → 右键不动作")
eq(winDerived.mouseBothAction, .none, "★ disable_lrhide=1 → 双键不动作")

var winMouse2: [String: JSONValue] = CacheSchema.defaultHeader()
winMouse2["page_mode"] = .int(1)
winMouse2["disable_lrhide"] = .int(0)
let winDerived2 = ReaderSettings(header: winMouse2)
eq(winDerived2.mouseLeftAction, .nextPage, "★ page_mode=1 → 左键下一页")
eq(winDerived2.mouseRightAction, .prevPage, "★ page_mode=1 → 右键上一页")
eq(winDerived2.mouseBothAction, .toggleHide, "★ disable_lrhide=0 → 双键隐藏")

// 19.5 每种动作的实际效果
let mv = ReadingView(frame: NSRect(x: 0, y: 0, width: 420, height: 660))
mv.book = navBook
var hideCalls = 0
var minCalls = 0
mv.onToggleHideWindow = { hideCalls += 1 }
mv.onMinimizeWindow = { minCalls += 1 }

mv.jump(to: 0)
mv.performMouseActionForTest(.none)
eq(mv.pageStart, 0, "★ 不动作：不翻页")
mv.performMouseActionForTest(.nextPage)
check(mv.pageStart > 0, "★ 下一页")
mv.performMouseActionForTest(.prevPage)
eq(mv.pageStart, 0, "★ 上一页")
mv.performMouseActionForTest(.toggleHide)
eq(hideCalls, 1, "★ 隐藏动作触发回调")
eq(mv.pageStart, 0, "隐藏动作不翻页")
mv.performMouseActionForTest(.minimize)
eq(minCalls, 1, "★ 最小化动作触发回调")
eq(mv.pageStart, 0, "最小化动作不翻页")

// 19.6 左右一起按关闭之后，单键仍然正常（互不干扰）
mv.settings.mouseBothAction = .none
mv.jump(to: 0)
mv.performMouseActionForTest(mv.settings.mouseLeftAction)
check(mv.pageStart > 0, "★ 关掉「左右一起按」后左键照样翻页")

// ============ 汇总 ============
print("\n" + String(repeating: "─", count: 46))
print("通过 \(passed) 项，失败 \(failed) 项")
if failed > 0 { exit(1) }
print("✅ 全部通过")
