import Foundation

/// 零依赖 ZIP 读取（M7 EPUB 原型）。
///
/// 不自己写 inflate：调 macOS 自带的 `ditto -x -k` 解到临时目录，用完即删。
/// 优点：DEFLATE / ZIP64 / 数据描述符 / 扩展属性全都不用管，也不引入任何库；
/// 缺点：解包期间会落盘（一本 EPUB 约等于解压后的体积），并且依赖系统 ditto。
///
/// 这是路线图 M7 前置条件 2 的**原型**：先用它验证「EPUB 值不值得做」。
/// 如果决定继续，再评估要不要用 libz 自己读中央目录 + inflate，去掉临时目录。
enum ZipArchiveError: Error, CustomStringConvertible {
    case notReadable(String)
    case extractFailed(code: Int32, message: String)
    case missingEntry(String)

    var description: String {
        switch self {
        case .notReadable(let path):
            return "读不到压缩包：\(path)"
        case .extractFailed(let code, let message):
            let detail = message.isEmpty ? "" : "：\(message)"
            return "解压失败（ditto 退出码 \(code)）\(detail)"
        case .missingEntry(let name):
            return "压缩包里缺少 \(name)"
        }
    }
}

enum ZipArchive {

    /// 把 zip 解到临时目录，执行 `body`，返回前**删除临时目录**。
    ///
    /// 临时目录用 `FileManager.temporaryDirectory` + UUID，不会碰用户的存档
    /// （`READER_CACHE_PATH` 那套重定向对这里无关：这里只放解包出来的书）。
    static func withExtractedTree<T>(_ zipURL: URL, _ body: (URL) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw ZipArchiveError.notReadable(zipURL.path)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-unzip-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            throw ZipArchiveError.notReadable(zipURL.path)
        }
        defer { try? FileManager.default.removeItem(at: dest) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ZipArchiveError.extractFailed(code: -1, message: "无法启动 ditto")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ZipArchiveError.extractFailed(code: process.terminationStatus, message: message)
        }
        return try body(dest)
    }

    /// 解包后的相对路径必须存在，否则给出一个能看懂的错误（而不是 subsequent 的 nil）。
    static func requireEntry(_ root: URL, _ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ZipArchiveError.missingEntry(relativePath)
        }
        return url
    }

    // MARK: - 内存解包（A 档默认路径）

    /// 把 zip 读成「内部路径 → 内容」，交给 `body`，**不落盘、不起子进程**。
    ///
    /// 优先用 `ZipReader`（自己读中央目录 + 系统 zlib）；遇到它不支持的 zip
    /// （ZIP64 / 加密 / 非 store-deflate）自动回退到 `ditto` 解临时目录再读进内存，
    /// 保证兼容性 —— 用户不会因为「这本书的 ZIP 特别」而打不开。
    static func withFileMap<T>(_ zipURL: URL, _ body: ([String: Data]) throws -> T) throws -> T {
        if let files = try? ZipReader.read(zipURL) {
            return try body(files)
        }
        return try withExtractedTree(zipURL) { root in
            try body(try readTree(root))
        }
    }

    /// 把解包目录递归读成「相对路径（`/` 分隔）→ 内容」。
    static func readTree(_ root: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else {
            throw ZipArchiveError.notReadable(root.path)
        }
        let rootPath = root.standardizedFileURL.path
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if let data = try? Data(contentsOf: url) {
                files[relative] = data
            }
        }
        return files
    }
}
