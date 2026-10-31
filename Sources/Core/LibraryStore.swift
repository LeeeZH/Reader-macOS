import Foundation

/// 把 Windows 版存档里的路径重新定位到 macOS 上。
/// `.cache.dat` 里存的是 `D:\小说\某本书.txt` 这种绝对路径，换平台必然失效。
/// 策略：先按原路径试；不行就按文件名在常见目录里做有界搜索。
enum BookPathResolver {

    static func isWindowsStyle(_ p: String) -> Bool {
        if p.contains("\\") { return true }
        let chars = Array(p)
        return chars.count >= 2 && chars[1] == ":"
    }

    static func baseName(_ p: String) -> String {
        (p.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }

    /// 有界搜索：只在这几个根目录下找，最大深度 3，最多访问 20000 个条目
    static func searchRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        for d in [FileManager.SearchPathDirectory.documentDirectory,
                  .downloadsDirectory,
                  .desktopDirectory] {
            if let u = fm.urls(for: d, in: .userDomainMask).first { roots.append(u) }
        }
        return roots
    }

    static func resolve(stored: String, extraRoots: [URL] = []) -> URL? {
        guard !stored.isEmpty else { return nil }
        let fm = FileManager.default

        // 1) 原样能打开就用原样（macOS 自己存的路径走这条）
        let unified = stored.replacingOccurrences(of: "\\", with: "/")
        if fm.fileExists(atPath: unified) { return URL(fileURLWithPath: unified) }

        // 2) 按文件名搜索
        let name = baseName(stored)
        guard !name.isEmpty else { return nil }
        let roots = extraRoots + searchRoots()
        var budget = 20000

        for root in roots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if en.level > 3 { en.skipDescendants(); continue }
                budget -= 1
                if budget <= 0 { return nil }
                if url.lastPathComponent == name { return url }
            }
        }
        return nil
    }
}

/// `.cache.dat` 的读写与阅读列表管理。
/// 对应原版 `Cache` 类（Cache.cpp）。
final class LibraryStore {

    /// 全局单例。
    ///
    /// ⚠️ 开发工具（`--*-selftest`、`--render-*`）会设 `READER_CACHE_PATH`
    /// 指向临时文件。没有这一层的话，跑一次自检就会把**用户的真实存档**
    /// 覆盖成测试数据 —— 这个坑真的踩过。
    static let shared: LibraryStore = {
        if let p = ProcessInfo.processInfo.environment["READER_CACHE_PATH"], !p.isEmpty {
            return LibraryStore(fileURL: URL(fileURLWithPath: p))
        }
        return LibraryStore()
    }()

    private(set) var document = CacheDocument()
    private(set) var fileURL: URL

    /// 存档加载失败时保留的备份路径（用于提示用户）
    private(set) var recoveredBackupURL: URL?

    private var pendingSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "reader.library.io")

    // MARK: - 位置

    /// App 所在的目录（`…/Reader.app` 的父目录）
    static var appFolder: URL? {
        let bundle = Bundle.main.bundleURL
        // 只在真的是 .app 包里时才算，避免直接跑二进制时误判到构建目录
        guard bundle.pathExtension.lowercased() == "app" else { return nil }
        return bundle.deletingLastPathComponent()
    }

    /// 便携模式的开关：App 同目录下有没有一个叫 `portable` 的文件。
    ///
    /// **只看这一个文件**，规则简单到不用记：
    ///   · 有 `portable` → 便携模式，存档写在 App 旁边
    ///   · 没有         → 标准位置 `~/Library/Application Support/Reader/`
    ///
    /// 之前是「有 portable 或者已有 .cache.dat」都算，结果想切回标准位置
    /// 得删两个东西，容易以为没生效 —— 所以改成只认那一个标记。
    static var portableLocation: URL? {
        guard let folder = appFolder else { return nil }
        let fm = FileManager.default
        let marker = folder.appendingPathComponent("portable")
        guard fm.fileExists(atPath: marker.path) else { return nil }
        // 目录得能写。App 如果是从只读的 DMG / 未解锁的加密卷里直接跑的，
        // 硬用便携位置会导致「保存静默失败」，那比丢设置更糟 —— 退回标准位置。
        guard fm.isWritableFile(atPath: folder.path) else {
            NSLog("LibraryStore: 便携目录不可写，退回标准位置")
            return nil
        }
        return folder.appendingPathComponent(".cache.dat")
    }

    /// 存档位置，优先级从高到低：
    ///   1. 环境变量 `READER_CACHE_PATH`（脚本 / 自检 / 高度定制）
    ///   2. 便携模式：App 同目录（U 盘、同步盘，双击也生效）
    ///   3. 标准位置：`~/Library/Application Support/Reader/.cache.dat`
    static func defaultLocation() -> URL {
        if let p = ProcessInfo.processInfo.environment["READER_CACHE_PATH"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        if let portable = portableLocation {
            return portable
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Reader", isDirectory: true)
                   .appendingPathComponent(".cache.dat")
    }

    /// 当前用的是哪种位置（设置界面里显示，免得用户搞不清存档去哪了）
    static func locationKind(for url: URL) -> String {
        if let env = ProcessInfo.processInfo.environment["READER_CACHE_PATH"], !env.isEmpty {
            return "自定义（环境变量 READER_CACHE_PATH）"
        }
        if let portable = portableLocation, portable.standardizedFileURL == url.standardizedFileURL {
            return "便携模式（与 App 同一目录）"
        }
        return "标准位置"
    }

    init(fileURL: URL = LibraryStore.defaultLocation()) {
        self.fileURL = fileURL
    }

    // MARK: - 访问

    var items: [CacheItem] { document.items }
    var settings: ReaderSettings { ReaderSettings(header: document.header) }

    /// 当前打开的书（MRU 队首）。原版启动时也是打开 `get_item(0)`。
    var mostRecent: CacheItem? { document.items.first }

    // MARK: - 载入 / 保存

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            document = CacheDocument()
            return
        }
        do {
            let raw = try Data(contentsOf: fileURL)
            document = try CacheCodec.decode(raw)
        } catch {
            // 存档损坏：备份后从空白开始，绝不静默丢弃用户数据
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".cache.dat.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? fm.copyItem(at: fileURL, to: backup)
            recoveredBackupURL = backup
            document = CacheDocument()
        }
        refreshAvailability()
    }

    /// 立即落盘（原子写：临时文件 + 替换，避免掉电写坏存档）
    @discardableResult
    func save() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            let data = try CacheCodec.encode(document)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".cache.dat.tmp-\(ProcessInfo.processInfo.processIdentifier)")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            return true
        } catch {
            NSLog("LibraryStore: 保存失败 \(error)")
            return false
        }
    }

    /// 原版是「每次变更立即 PostMessage(WM_SAVE_CACHE)」。
    /// 这里做 0.6s 防抖，避免快速翻页时疯狂写盘（SSD 寿命 + 卡顿）。
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// 修改设置并写回 header（供字号调整等使用）
    func updateSettings(_ mutate: (inout ReaderSettings) -> Void) {
        var s = settings
        mutate(&s)
        s.apply(to: &document.header)
        scheduleSave()
    }

    // MARK: - 阅读列表（MRU：最近打开的排最前）

    private func renumber() {
        for i in document.items.indices { document.items[i].id = i }
        document.syncItemCount()
        document.currentItemIndex = document.items.isEmpty ? -1 : 0
    }

    func index(ofFileName name: String) -> Int? {
        document.items.firstIndex { $0.fileName == name }
    }

    /// 打开（或新加入）一本书，把它移到队首。返回其在列表中的下标（恒为 0）。
    /// 对应原版 `Cache::new_item` + `Cache::open_item`。
    @discardableResult
    func touch(fileName: String) -> Int {
        if let i = index(ofFileName: fileName) {
            let it = document.items.remove(at: i)
            document.items.insert(it, at: 0)
        } else {
            var it = CacheItem()
            it.fileName = fileName
            it.index = 0
            it.isNew = 1
            document.items.insert(it, at: 0)
        }
        renumber()
        scheduleSave()
        return 0
    }

    func remove(at index: Int) {
        guard document.items.indices.contains(index) else { return }
        document.items.remove(at: index)
        renumber()
        scheduleSave()
    }

    func removeAll() {
        document.items.removeAll()
        renumber()
        refreshAvailability()
        scheduleSave()
    }

    // MARK: - 缓存：渲染路径必须是便宜的

    /// 路径 → 本机可用的 URL。只由 `refreshAvailability()` 填充（只做 fileExists）。
    private var availabilityCache: [String: URL] = [:]
    /// 路径 → 规范化后的总字符数，用于把字符偏移显示成百分比
    private var lengthCache: [String: Int] = [:]
    private let workQueue = DispatchQueue(label: "reader.library.work", qos: .utility)

    /// ⚠️ 便宜的可用性刷新：**只做 fileExists，绝不做目录遍历**。
    /// 表格渲染、缺失统计只能读这个缓存。
    /// 之前直接在 `viewFor` 和 `missingCount` 里调 `BookPathResolver.resolve`，
    /// 那会为每一本找不到的书递归遍历 ~/Documents、~/Downloads、~/Desktop ——
    /// 一次重绘就有十几个目录遍历压在主线程上，界面直接假死
    ///（表现就是「书架窗口关不掉、按钮点不动」）。
    func refreshAvailability() {
        var cache: [String: URL] = [:]
        let fm = FileManager.default
        for item in document.items where !item.fileName.isEmpty {
            if fm.fileExists(atPath: item.fileName) {
                cache[item.fileName] = URL(fileURLWithPath: item.fileName)
            }
        }
        availabilityCache = cache
    }

    /// 取某本书在本机可用的 URL（只查缓存，不做搜索）
    func availableURL(forStoredPath path: String) -> URL? { availabilityCache[path] }

    /// 缺失的本机文件数量（只查缓存）
    var missingFileCount: Int {
        document.items.reduce(0) { $0 + (availabilityCache[$1.fileName] == nil ? 1 : 0) }
    }

    /// 兼容旧调用（只查缓存，不再做目录遍历）
    func missingCount() -> Int { missingFileCount }

    /// 获取缓存的书籍总字数（用于显示百分比）
    func bookLength(forStoredPath path: String) -> Int? { lengthCache[path] }

    /// 已经算过总字数的书籍数量（用于限制后台预取的总量）
    var cachedLengthCount: Int { lengthCache.count }

    /// 打开成功后把已知的总字数直接回填进缓存。
    ///
    /// 否则书架窗口的 `prefetchLengths` 会为了同一个数字，把刚打开的整本书
    /// 再 `Data + decode + format` 一遍（47MB 文件要多花几百毫秒后台 CPU）。
    func seedLength(_ length: Int, forStoredPath path: String) {
        guard length > 0 else { return }
        lengthCache[path] = length
    }

    /// 后台按文件名搜索缺失的文件。**昂贵，绝不能在渲染路径上调用。**
    func searchMissingFiles(completion: @escaping (Int) -> Void) {
        let targets = document.items.filter { availableURL(forStoredPath: $0.fileName) == nil }
        guard !targets.isEmpty else { completion(0); return }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            var found: [String: URL] = [:]
            for item in targets {
                if let url = BookPathResolver.resolve(stored: item.fileName) { found[item.fileName] = url }
            }
            DispatchQueue.main.async {
                for (stored, url) in found {
                    self.availabilityCache[stored] = url
                    // 找到后顺手把记录里的路径更新掉，下次就不用再找
                    if let i = self.document.items.firstIndex(where: { $0.fileName == stored }) {
                        self.document.items[i].fileName = url.path
                        self.availabilityCache[url.path] = url
                    }
                }
                if !found.isEmpty { self.scheduleSave() }
                completion(found.count)
            }
        }
    }

    /// 后台计算书籍总字数（用于把字符偏移显示成百分比）。
    /// 只处理还没有缓存的、且文件存在的书。算完在主线程回调。
    func prefetchLengths(limit: Int = 80, completion: @escaping () -> Void) {
        let pending = document.items
            .filter { lengthCache[$0.fileName] == nil && availableURL(forStoredPath: $0.fileName) != nil }
            .prefix(limit)
            .map { ($0.fileName, self.availableURL(forStoredPath: $0.fileName)!) }
        guard !pending.isEmpty else { completion(); return }

        workQueue.async { [weak self] in
            guard let self = self else { return }
            var computed: [String: Int] = [:]
            for (path, url) in pending {
                // 走 BookLoader，不在这里写死 TXT 解码 —— 接 EPUB 时只需改那一处
                if let length = BookLoader.totalLength(ofFileAt: url) {
                    // 口径由 BookLoader 保证与 ReadingView 一致：FormatText 之后的码元数
                    computed[path] = length
                }
            }
            DispatchQueue.main.async {
                for (k, v) in computed { self.lengthCache[k] = v }
                completion()
            }
        }
    }

    // MARK: - 进度与书签

    func updateProgress(offset: Int, at index: Int) {
        guard document.items.indices.contains(index) else { return }
        guard document.items[index].index != offset else { return }
        document.items[index].index = offset
        document.items[index].isNew = 0
        document.currentItemIndex = index
        scheduleSave()
    }

    @discardableResult
    func addBookmark(offset: Int, at index: Int) -> Bool {
        guard document.items.indices.contains(index) else { return false }
        guard document.items[index].marks.count < 256 else { return false }
        guard !document.items[index].marks.contains(offset) else { return false }
        document.items[index].marks.append(offset)
        document.items[index].marks.sort()
        scheduleSave()
        return true
    }

    func removeBookmark(offset: Int, at index: Int) {
        guard document.items.indices.contains(index) else { return }
        document.items[index].marks.removeAll { $0 == offset }
        scheduleSave()
    }

    // MARK: - 主窗口位置（存在 header.placement，与原版同字段）

    /// 读取上次的窗口 frame。没设置过 / 已失效（屏幕变了）时返回 nil。
    func mainWindowFrame(primaryScreenHeight: CGFloat, screenFrames: [CGRect]) -> CGRect? {
        guard let placement = document.header["placement"],
              let rc = placement.field("rcNormalPosition") else { return nil }
        let left = rc.field("left")?.intValue ?? 0
        let top = rc.field("top")?.intValue ?? 0
        let right = rc.field("right")?.intValue ?? 0
        let bottom = rc.field("bottom")?.intValue ?? 0
        guard !WindowPlacement.isUnset(left: left, top: top, right: right, bottom: bottom),
              let rect = WindowPlacement.toNSRect(left: left, top: top, right: right,
                                                  bottom: bottom,
                                                  primaryScreenHeight: primaryScreenHeight),
              WindowPlacement.isUsable(rect, screenFrames: screenFrames) else { return nil }
        return rect
    }

    func setMainWindowFrame(_ frame: CGRect, primaryScreenHeight: CGFloat) {
        guard case .object(var fields)? = document.header["placement"] else { return }
        let (l, t, r, b) = WindowPlacement.toWinRect(frame, primaryScreenHeight: primaryScreenHeight)
        let newRect = JSONValue.object([
            ("left", .int(l)), ("top", .int(t)), ("right", .int(r)), ("bottom", .int(b)),
        ])
        var replaced = false
        for i in fields.indices where fields[i].0 == "rcNormalPosition" {
            fields[i].1 = newRect
            replaced = true
        }
        if !replaced { fields.append(("rcNormalPosition", newRect)) }
        document.header["placement"] = .object(fields)
        scheduleSave()
    }

    /// 把某条记录指向用户新指认的文件。进度与书签是字符偏移，与路径无关，所以原样保留。
    func relocate(index: Int, to url: URL) {
        guard document.items.indices.contains(index) else { return }
        document.items[index].fileName = url.path
        availabilityCache[url.path] = url
        scheduleSave()
    }

}
