import Foundation

enum TextDecoderError: Error, CustomStringConvertible {
    case unsupportedUTF32
    case empty

    var description: String {
        switch self {
        case .unsupportedUTF32: return "暂不支持 UTF-32 编码（与原版 Book::DecodeText 行为一致）"
        case .empty: return "文件为空"
        }
    }
}

struct DecodedText {
    let text: String
    let encodingName: String
}

/// 对应原版 Book::DecodeText + Utils.cpp 的 check_bom / is_utf8 / ansi_to_utf16。
/// 分支顺序必须与原版一致，否则解码结果（进而所有字符偏移）会与原版不一致。
enum TextDecoder {

    static func decode(_ data: Data) throws -> DecodedText {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { throw TextDecoderError.empty }

        // ---- 1) BOM 检测 ----
        if bytes.count >= 4 {
            if bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 { throw TextDecoderError.unsupportedUTF32 }
            if bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF { throw TextDecoderError.unsupportedUTF32 }
        }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            let body = Data(bytes[3...])
            return DecodedText(text: String(decoding: body, as: UTF8.self), encodingName: "UTF-8 (BOM)")
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return DecodedText(text: decodeUTF16(Array(bytes[2...]), littleEndian: true), encodingName: "UTF-16LE")
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return DecodedText(text: decodeUTF16(Array(bytes[2...]), littleEndian: false), encodingName: "UTF-16BE")
        }

        // ---- 2) 无 BOM：取前 min(size, 4096) 字节做 UTF-8 合法性校验（对应 is_utf8）----
        let probe = Array(bytes.prefix(4096))
        if isValidUTF8(probe) {
            return DecodedText(text: String(decoding: data, as: UTF8.self), encodingName: "UTF-8")
        }

        // ---- 3) 回退：GB18030 ----
        // 原版走系统 ANSI 代码页（中文 Windows ≈ GBK）；GB18030 是 GBK 超集，
        // 对纯 GBK 内容结果相同，还能多解出生僻字。
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return DecodedText(text: s, encodingName: "GB18030")
        }

        // ---- 4) 兜底 ----
        return DecodedText(text: String(decoding: data, as: UTF8.self), encodingName: "UTF-8 (容错)")
    }

    private static func decodeUTF16(_ bytesIn: [UInt8], littleEndian: Bool) -> String {
        var bytes = bytesIn
        if bytes.count % 2 == 1 { bytes.append(0) }   // 奇数长度容错
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let lo = UInt16(bytes[i]), hi = UInt16(bytes[i + 1])
            units.append(littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 把文本按指定编码编码回字节 —— 编辑模式保存时用。
    ///
    /// 尽量保持文件原来的编码，别把一个 GBK 文件悄悄存成 UTF-8
    /// （那样别的软件又会读成乱码）。实在表示不了才退回 UTF-8。
    static func encode(_ text: String, encodingName: String) -> Data? {
        switch encodingName {
        case "UTF-8", "UTF-8 (容错)":
            return text.data(using: .utf8)
        case "UTF-8 (BOM)":
            guard let body = text.data(using: .utf8) else { return nil }
            return Data([0xEF, 0xBB, 0xBF]) + body
        case "UTF-16LE":
            // ⚠️ 必须补 BOM：解码端就是靠 BOM 认 UTF-16 的，
            // 不写 BOM 的话存回去再打开会被当成 UTF-8 读出乱码。
            guard let body = text.data(using: .utf16LittleEndian) else { return nil }
            return Data([0xFF, 0xFE]) + body
        case "UTF-16BE":
            guard let body = text.data(using: .utf16BigEndian) else { return nil }
            return Data([0xFE, 0xFF]) + body
        case "GB18030":
            let raw = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return text.data(using: String.Encoding(rawValue: raw))
        default:
            return text.data(using: .utf8)
        }
    }

    /// 严格 UTF-8 校验（对应原版 Utils.cpp 的 is_utf8）。
    /// 比 String(data:encoding:.utf8) != nil 更严格：拒绝 overlong 与非法续字节。
    static func isValidUTF8(_ b: [UInt8]) -> Bool {
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            var need = 0
            var lo2: UInt8 = 0x80, hi2: UInt8 = 0xBF
            switch c {
            case 0xC2...0xDF: need = 1
            case 0xE0:        need = 2; lo2 = 0xA0
            case 0xE1...0xEC: need = 2
            case 0xED:        need = 2; hi2 = 0x9F
            case 0xEE...0xEF: need = 2
            case 0xF0:        need = 3; lo2 = 0x90
            case 0xF1...0xF3: need = 3
            case 0xF4:        need = 3; hi2 = 0x8F
            default:          return false
            }
            if i + need >= n {
                // ⚠️ 截断在缓冲区末尾**不算非法**。
                // 探测窗口只取前 4096 字节，很可能正好把某个多字节字符切成两半
                // （中文 3 字节，踩中的概率约 2/3）。判成非法的话，
                // 任何超过 4096 字节的 UTF-8 文件都会被误判 → 轻则编码名标错，
                // 重则被当成 GB18030 解出乱码。
                //
                // 原版这里也是 break —— Utils.cpp 里作者留了注释
                // `break;//return 0; fixed bug.... substr`，说明他早就修过。
                // 移植时不要照搬更早的 `return 0`。
                break
            }
            if b[i + 1] < lo2 || b[i + 1] > hi2 { return false }
            if need >= 2 {
                for k in 2...need where b[i + k] < 0x80 || b[i + k] > 0xBF { return false }
            }
            i += need + 1
        }
        return true
    }
}
