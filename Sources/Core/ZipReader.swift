import Foundation

/// 零第三方依赖的 ZIP 读取（A 档：只读 ZIP 容器结构 + 调系统 zlib 解压）。
///
/// ZIP 结构本身很简单，自己读中央目录比调 `ditto` 起子进程更好：
/// - **不落盘**：解出来的内容只进内存（`[路径: Data]` 交给 EPUB 解析）；
/// - 没有临时目录、没有子进程，打开更快，也不会在用户磁盘上留东西；
/// - 出问题时有明确的错误，不用猜 `ditto` 的退出码。
///
/// 只支持 EPUB 实际会遇到的子集：store（0）/ deflate（8）、非 ZIP64、非加密。
/// 其余情况（ZIP64、加密、bzip2/lzma、数据描述符）抛 `unsupported`，
/// 由 `ZipArchive.withFileMap` 自动回退到系统 `ditto`，保证「书一定能打开」。
enum ZipReaderError: Error, CustomStringConvertible {
    case notZip
    case unsupported(String)
    case corrupt(String)
    case inflateFailed(Int32)

    var description: String {
        switch self {
        case .notZip:
            return "这不是一个 zip 容器（找不到中央目录）"
        case .unsupported(let reason):
            return "ZIP 用了暂不支持的特性（\(reason)），已回退系统解压"
        case .corrupt(let reason):
            return "ZIP 结构损坏（\(reason)）"
        case .inflateFailed(let code):
            return "ZIP 解压失败（zlib 错误码 \(code)）"
        }
    }
}

enum ZipReader {

    /// 把整个 zip 读成「内部路径 → 未压缩内容」。路径统一用 `/` 分隔。
    ///
    /// - Note: 不校验 CRC32（坏数据靠解压大小 + 上层解析兜底；
    ///   真坏了会落到 `ditto` 回退路径或报解析错误）。
    static func read(_ url: URL) throws -> [String: Data] {
        guard let data = try? Data(contentsOf: url), data.count >= 22 else {
            throw ZipReaderError.notZip
        }

        let eocd = try findEndOfCentralDirectory(data)
        let total = Int(u16(data, eocd + 10))
        let cdSize = Int(u32(data, eocd + 12))
        let cdOffset = Int(u32(data, eocd + 16))
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipReaderError.unsupported("ZIP64")
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw ZipReaderError.corrupt("中央目录越界")
        }

        var files: [String: Data] = [:]
        var pos = cdOffset
        for _ in 0..<total {
            guard pos + 46 <= data.count, u32(data, pos) == 0x0201_4b50 else {
                throw ZipReaderError.corrupt("中央目录条目 0x\(String(u32(data, pos), radix: 16))")
            }
            let flags = u16(data, pos + 8)
            let method = u16(data, pos + 10)
            let compressedSize = Int(u32(data, pos + 20))
            let uncompressedSize = Int(u32(data, pos + 24))
            let nameLength = Int(u16(data, pos + 28))
            let extraLength = Int(u16(data, pos + 30))
            let commentLength = Int(u16(data, pos + 32))
            let localOffset = Int(u32(data, pos + 42))
            guard pos + 46 + nameLength <= data.count else {
                throw ZipReaderError.corrupt("文件名越界")
            }

            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLength))
            pos += 46 + nameLength + extraLength + commentLength

            let name = normalizeName(
                String(data: nameData, encoding: .utf8)
                    ?? String(decoding: nameData, as: UTF8.self))
            if name.hasSuffix("/") || name.isEmpty { continue }   // 目录条目

            if flags & 0x0001 != 0 {
                throw ZipReaderError.unsupported("加密条目")
            }
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF {
                throw ZipReaderError.unsupported("ZIP64 条目")
            }
            guard method == 0 || method == 8 else {
                throw ZipReaderError.unsupported("压缩方式 \(method)")
            }
            guard localOffset + 30 <= data.count, u32(data, localOffset) == 0x0403_4b50 else {
                throw ZipReaderError.corrupt("本地文件头缺失：\(name)")
            }
            let localNameLength = Int(u16(data, localOffset + 26))
            let localExtraLength = Int(u16(data, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else {
                throw ZipReaderError.corrupt("条目数据越界：\(name)")
            }

            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))
            let contents: Data
            if method == 0 {
                contents = payload
            } else {
                contents = try inflate(payload, expected: uncompressedSize)
            }
            if contents.count != uncompressedSize {
                throw ZipReaderError.corrupt("解压后大小不符：\(name)")
            }
            files[name] = contents
        }
        return files
    }

    // MARK: - 内部

    /// 从文件尾部往回找 EOCD 签名（zip 注释最多 64 KB）。
    private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
        let count = data.count
        let lowerBound = max(0, count - 22 - 65535)
        var offset = count - 22
        while offset >= lowerBound {
            if u32(data, offset) == 0x0605_4b50 { return offset }
            offset -= 1
        }
        throw ZipReaderError.notZip
    }

    private static func inflate(_ payload: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data(count: expected)
        let status: Int32 = output.withUnsafeMutableBytes { out in
            payload.withUnsafeBytes { input in
                reader_inflate_raw(input.bindMemory(to: UInt8.self).baseAddress,
                                   payload.count,
                                   out.bindMemory(to: UInt8.self).baseAddress,
                                   expected)
            }
        }
        guard status == 0 else { throw ZipReaderError.inflateFailed(status) }
        return output
    }

    private static func normalizeName(_ name: String) -> String {
        var value = name.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
