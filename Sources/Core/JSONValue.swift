import Foundation

/// 保序 JSON 值。
///
/// 为什么不用 `Codable`：`.cache.dat` 里还包含我们**尚未实现**的功能所对应的字段
/// （按键绑定、书源、自定义颜色、代理…）。如果只按固定结构体编解码，
/// macOS 版一存盘就会把这些设置全部抹掉，用户切回 Windows 会发现配置没了。
/// 所以持久化层用「保序字典 + 类型化访问器」，未知字段原样保留。
indirect enum JSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])
}

// MARK: - 从 JSONSerialization 的产物构造

extension JSONValue {
    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // ⚠️ 必须先判布尔：NSNumber(1) 也能 bridge 成 Bool
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            var out = [JSONValue]()
            out.reserveCapacity(a.count)
            for e in a {
                guard let v = JSONValue(any: e) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let d as [String: Any]:
            var out = [(String, JSONValue)]()
            for (k, v) in d {
                guard let jv = JSONValue(any: v) else { return nil }
                out.append((k, jv))
            }
            self = .object(out)
        default:
            return nil
        }
    }
}

// MARK: - 访问器

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return Int(v)
        case .bool(let v):   return v ? 1 : 0
        case .string(let s): return Int(s)
        default:             return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        default:             return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v):   return v
        case .int(let v):    return v != 0
        default:             return nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [(String, JSONValue)]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 取对象里的某个键（保序，缺失返回 nil）
    func field(_ key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        for (k, v) in o where k == key { return v }
        return nil
    }
}

// MARK: - 序列化（对齐 cJSON_PrintUnformatted：紧凑、无空白、非 ASCII 原样输出）

extension JSONValue {
    var compactJSON: String {
        switch self {
        case .null:           return "null"
        case .bool(let b):    return b ? "true" : "false"
        case .int(let i):     return String(i)
        case .double(let d):  return JSONValue.formatDouble(d)
        case .string(let s):  return JSONValue.escape(s)
        case .array(let a):
            return "[" + a.map { $0.compactJSON }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.map { JSONValue.escape($0.0) + ":" + $0.1.compactJSON }.joined(separator: ",") + "}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":      out += "\\\""
            case "\\":      out += "\\\\"
            case "\n":      out += "\\n"
            case "\r":      out += "\\r"
            case "\t":      out += "\\t"
            case "\u{08}":  out += "\\b"
            case "\u{0C}":  out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)   // cJSON 用小写十六进制
                } else {
                    out.unicodeScalars.append(scalar)                // 非 ASCII 原样输出
                }
            }
        }
        return out + "\""
    }

    static func formatDouble(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 {
            return String(Int64(d))          // 整数值不带小数点，与 cJSON 一致
        }
        return String(d)
    }
}
