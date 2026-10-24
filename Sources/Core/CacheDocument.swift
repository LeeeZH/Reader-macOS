import Foundation

/// 阅读列表里的一本书。对应原版 `item_t`（types.h:78-86）。
struct CacheItem {
    /// 列表内的序号。原版 `move_item` 会把 id 重排成下标，所以 id 恒等于下标。
    var id: Int = 0
    /// ★ 阅读进度：**经 `TextNormalizer.format` 处理之后**文本的 UTF-16 字符偏移。
    ///   不是页码、不是字节偏移。与 Windows 版逐字段等价。
    var index: Int = 0
    /// 书籍的绝对路径（Windows 版是 `D:\小说\a.txt` 这种）
    var fileName: String = ""
    /// 书签，最多 256 个，元素同为字符偏移
    var marks: [Int] = []
    /// 是否「未读」标记
    var isNew: Int = 0

    var displayName: String {
        (fileName as NSString).lastPathComponent.replacingOccurrences(of: ".txt", with: "")
    }
}

/// `.cache.dat` 的完整文档模型。
/// 对应原版根结构：`{"header":{...47 键...},"items":[...]}`
struct CacheDocument {
    /// 保序无关（写盘时按 `CacheSchema.headerKeyOrder` 重新排列），但保留全部未知字段
    var header: [String: JSONValue] = CacheSchema.defaultHeader()
    var items: [CacheItem] = []

    var itemCount: Int { items.count }
    /// 当前打开的书在列表中的下标；-1 表示没有
    var currentItemIndex: Int {
        get { header["item_id"]?.intValue ?? -1 }
        set { header["item_id"] = .int(newValue) }
    }

    mutating func syncItemCount() { header["item_count"] = .int(items.count) }
}

// MARK: - Schema：键名、顺序、默认值（全部照搬原版 Jsondata.cpp / Cache.cpp）

enum CacheSchema {

    /// `header` 的键顺序，与 `json_header_t` 构造函数里的插入顺序完全一致（Jsondata.cpp:572+）。
    /// 保持一致的目的是让写出的文件与 Windows 版逐字节接近，便于比对与排查。
    static let headerKeyOrder: [String] = [
        "version", "item_count", "item_id",
        "style", "exstyle", "fs_style", "fs_exstyle",
        "char_gap", "line_gap", "paragraph_gap", "left_line_count",
        "font_color", "font_color_title", "use_same_font",
        "bg_color", "alpha", "meun_font_follow",
        "wheel_speed", "page_mode", "autopage_mode", "uElapse",
        "hide_taskbar", "show_systray", "disable_lrhide", "disable_eschide",
        "word_wrap", "line_indent", "blank_lines", "chapter_page",
        "ingore_version", "checkver_time", "global_key",
        "cust_colors", "keyset",
        "placement", "fs_placement", "fs_rect", "internal_border",
        "font", "font_title", "bg_image", "proxy", "chapter_rule",
        "tag_count", "tags", "book_source_count", "book_sources",
    ]

    /// `items[]` 的键顺序，与 `json_item_t` 一致（Jsondata.cpp:1034+）
    static let itemKeyOrder: [String] = ["id", "index", "file_name", "mark_size", "is_new", "mark"]

    // MARK: Win32 常量（仅为让写出的文件与原版一致）
    private static let WS_OVERLAPPEDWINDOW = 0x00CF0000
    private static let WS_EX_ACCEPTFILES = 0x00000010
    private static let WS_EX_LAYERED = 0x00080000
    private static let FW_LIGHT = 300
    private static let OUT_STROKE_PRECIS = 3
    private static let CLIP_STROKE_PRECIS = 2
    private static let PROOF_QUALITY = 2
    private static let VARIABLE_PITCH_FF_SWISS = 0x22

    /// 原版 `g_Keysets[].defval`，即 `MAKEWORD(按键, 修饰键)` 的 18 个默认值（Keyset.cpp:34-54）
    static let defaultKeysetValues: [Int] = [
        0x0448, // KI_HIDE        Alt+H
        0x007B, // KI_BORDER      F12
        0x007A, // KI_FULLSCREEN  F11
        0x0254, // KI_TOP         Ctrl+T
        0x024F, // KI_OPEN        Ctrl+O
        0x024D, // KI_ADDMARK     Ctrl+M
        0x0020, // KI_AUTOPAGE    Space
        0x0246, // KI_SEARCH      Ctrl+F
        0x0247, // KI_JUMP        Ctrl+G
        0x0245, // KI_EDIT        Ctrl+E
        0x0125, // KI_PAGEUP      ←
        0x0127, // KI_PAGEDOWN    →
        0x0126, // KI_LINEUP      ↑
        0x0128, // KI_LINEDOWN    ↓
        0x0325, // KI_CHAPTERUP   Ctrl+←
        0x0327, // KI_CHAPTERDOWN Ctrl+→
        0x02BB, // KI_FONTZOOMIN  Ctrl++
        0x02BD, // KI_FONTZOOMOUT Ctrl+-
    ]
    static let keysetCount = 18

    /// 注意：这里是**新建存档**时的默认字体。原版默认是 "Segoe UI Light"，
    /// 但 macOS 上没有这个字体，沿用会导致每次启动都提示回退。
    /// 读取 Windows 存档时不受影响（那份文件里带自己的 lfFaceName，会原样保留）。
    static func logoFont(face: String = ReaderDefaults.fontName, pixelHeight: Int = -19) -> JSONValue {
        .object([
            ("lfHeight", .int(pixelHeight)),
            ("lfWidth", .int(0)),
            ("lfEscapement", .int(0)),
            ("lfOrientation", .int(0)),
            ("lfWeight", .int(FW_LIGHT)),
            ("lfItalic", .int(0)),
            ("lfUnderline", .int(0)),
            ("lfStrikeOut", .int(0)),
            ("lfCharSet", .int(0)),
            ("lfOutPrecision", .int(OUT_STROKE_PRECIS)),
            ("lfClipPrecision", .int(CLIP_STROKE_PRECIS)),
            ("lfQuality", .int(PROOF_QUALITY)),
            ("lfPitchAndFamily", .int(VARIABLE_PITCH_FF_SWISS)),
            ("lfFaceName", .string(face)),
        ])
    }

    private static func rect(_ l: Int, _ t: Int, _ r: Int, _ b: Int) -> JSONValue {
        .object([("left", .int(l)), ("top", .int(t)), ("right", .int(r)), ("bottom", .int(b))])
    }

    private static func placement() -> JSONValue {
        .object([
            ("length", .int(44)),
            ("flags", .int(0)),
            ("showCmd", .int(1)),
            ("ptMinPosition", .object([("x", .int(-1)), ("y", .int(-1))])),
            ("ptMaxPosition", .object([("x", .int(-1)), ("y", .int(-1))])),
            ("rcNormalPosition", rect(0, 0, 300, 500)),
        ])
    }

    /// 完整默认 header（47 键），全部对应原版 `Cache::default_header`（Cache.cpp:317-392）
    static func defaultHeader() -> [String: JSONValue] {
        var h: [String: JSONValue] = [:]
        h["version"] = .string("2.0.0.5")
        h["item_count"] = .int(0)
        h["item_id"] = .int(-1)
        h["style"] = .int(WS_OVERLAPPEDWINDOW)
        h["exstyle"] = .int(WS_EX_ACCEPTFILES | WS_EX_LAYERED)
        h["fs_style"] = .int(WS_OVERLAPPEDWINDOW)
        h["fs_exstyle"] = .int(WS_EX_ACCEPTFILES | WS_EX_LAYERED)
        h["char_gap"] = .int(0)
        h["line_gap"] = .int(5)
        h["paragraph_gap"] = .int(15)
        h["left_line_count"] = .int(0)
        h["font_color"] = .int(0x000000)
        h["font_color_title"] = .int(0x000000)
        h["use_same_font"] = .int(1)
        h["bg_color"] = .int(0x00FFFFFF)
        h["alpha"] = .int(0xFF)
        h["meun_font_follow"] = .int(0)
        h["wheel_speed"] = .int(0)
        h["page_mode"] = .int(1)
        h["autopage_mode"] = .int(0)
        h["uElapse"] = .int(3000)
        h["hide_taskbar"] = .int(0)
        h["show_systray"] = .int(0)
        h["disable_lrhide"] = .int(0)   // 我们默认开启「左右键一起按隐藏窗口」
        h["disable_eschide"] = .int(1)
        h["word_wrap"] = .int(0)
        h["line_indent"] = .int(1)
        h["blank_lines"] = .int(1)
        h["chapter_page"] = .int(0)
        h["ingore_version"] = .string("")
        h["checkver_time"] = .int(0)
        h["global_key"] = .int(0)
        h["cust_colors"] = .array(Array(repeating: .int(0x00FFFFFF), count: 16))
        h["keyset"] = .array(defaultKeysetValues.map { v in
            .object([("value", .int(v)), ("is_disable", .int(0))])
        })
        h["placement"] = placement()
        h["fs_placement"] = placement()
        h["fs_rect"] = rect(0, 0, 0, 0)
        h["internal_border"] = rect(0, 0, 0, 0)
        h["font"] = logoFont()
        h["font_title"] = logoFont()
        h["bg_image"] = .object([("enable", .int(0)), ("mode", .int(0)), ("file_name", .string(""))])
        h["proxy"] = .object([
            ("enable", .int(0)), ("port", .int(0)),
            ("addr", .string("")), ("user", .string("")), ("pass", .string("")),
        ])
        h["chapter_rule"] = .object([("rule", .int(0)), ("keyword", .string("")), ("regex", .string(""))])
        h["tag_count"] = .int(0)
        h["tags"] = .array([])
        h["book_source_count"] = .int(0)
        h["book_sources"] = .array([])
        return h
    }

    /// 缺字段时用默认值补齐，保证输出包含全部 47 键（避免 Windows 版读到空值）。
    /// 规范表之外的键（例如将来 Windows 版新增的字段）**原样追加在末尾**，
    /// 绝不静默丢弃 —— 否则一旦存盘就会破坏用户的其他设置。
    static func normalizedHeader(_ raw: [String: JSONValue]) -> [(String, JSONValue)] {
        let def = defaultHeader()
        var out: [(String, JSONValue)] = []
        out.reserveCapacity(headerKeyOrder.count + 4)
        for key in headerKeyOrder {
            out.append((key, raw[key] ?? def[key] ?? .null))
        }
        let known = Set(headerKeyOrder)
        let extra = raw.keys.filter { !known.contains($0) }.sorted()
        for key in extra {
            if let v = raw[key] { out.append((key, v)) }
        }
        return out
    }

    static func item(from obj: JSONValue) -> CacheItem {
        var it = CacheItem()
        it.id = obj.field("id")?.intValue ?? 0
        it.index = obj.field("index")?.intValue ?? 0
        it.fileName = obj.field("file_name")?.stringValue ?? ""
        it.isNew = obj.field("is_new")?.intValue ?? 0
        if let arr = obj.field("mark")?.arrayValue {
            it.marks = arr.compactMap { $0.intValue }
        }
        return it
    }

    static func json(from item: CacheItem) -> JSONValue {
        .object([
            ("id", .int(item.id)),
            ("index", .int(item.index)),
            ("file_name", .string(item.fileName)),
            ("mark_size", .int(item.marks.count)),
            ("is_new", .int(item.isNew)),
            ("mark", .array(item.marks.map { .int($0) })),
        ])
    }
}

// MARK: - 编解码（XOR 0x3a + 紧凑 JSON）

enum CacheCodecError: Error, CustomStringConvertible {
    case notJSON
    case badRoot

    var description: String {
        switch self {
        case .notJSON:  return "内容不是合法的 JSON（可能不是 .cache.dat，或文件已损坏）"
        case .badRoot:  return "JSON 根节点结构不对（缺少 header）"
        }
    }
}

enum CacheCodec {
    /// 原版 `Cache::encode` / `Cache::decode`：整字节 XOR 异或
    static let xorKey: UInt8 = 0x3A

    static func xor(_ data: Data) -> Data {
        var out = data
        for i in out.indices { out[i] ^= xorKey }
        return out
    }

    static func decode(_ raw: Data) throws -> CacheDocument {
        let jsonData = xor(raw)
        guard let any = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
            throw CacheCodecError.notJSON
        }
        guard let root = JSONValue(any: any), root.objectValue != nil else {
            throw CacheCodecError.badRoot
        }
        var doc = CacheDocument()
        if let headerVal = root.field("header"), let hf = headerVal.objectValue {
            var h: [String: JSONValue] = [:]
            for (k, v) in hf { h[k] = v }
            doc.header = h
        }
        if let itemsVal = root.field("items"), let arr = itemsVal.arrayValue {
            doc.items = arr.map { CacheSchema.item(from: $0) }
            // 原版要求 item_count 与数组长度一致，否则整体丢弃
            if let declared = doc.header["item_count"]?.intValue, declared != doc.items.count {
                doc.items = []
            }
        }
        doc.syncItemCount()
        return doc
    }

    static func encode(_ doc: CacheDocument) throws -> Data {
        var root: [(String, JSONValue)] = [("header", .object(CacheSchema.normalizedHeader(doc.header)))]
        // 原版仅在 item_count > 0 时才写 items 键（Jsondata.cpp:create_json）
        if !doc.items.isEmpty {
            root.append(("items", .array(doc.items.map { CacheSchema.json(from: $0) })))
        }
        let json = JSONValue.object(root).compactJSON
        guard let utf8 = json.data(using: .utf8) else { throw CacheCodecError.badRoot }
        return xor(utf8)
    }
}
