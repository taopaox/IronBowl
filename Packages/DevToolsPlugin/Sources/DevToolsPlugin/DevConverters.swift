import CryptoKit
import Foundation

public nonisolated struct TimestampInfo: Sendable, Equatable {
    public let unitLabel: String
    public let seconds: Int64
    public let milliseconds: Int64
    public let localText: String
    public let utcText: String
    public let iso8601Text: String
}

public nonisolated struct DecodedJWTResult: Sendable, Equatable {
    public let headerJSON: String
    public let payloadJSON: String
    public let signature: String
    public let issuedAtText: String?
    public let expiresAtText: String?
    public let isExpired: Bool?
    public let expiryStatusText: String
}

public nonisolated struct DiffLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case unchanged
        case removed
        case added
    }

    public let id: Int
    public let kind: Kind
    public let leftLineNumber: Int?
    public let rightLineNumber: Int?
    public let text: String
}

/// 研发高频离线转换与文本对比纯函数集。
public nonisolated enum DevConverters {
    // MARK: - 时间戳

    public static func parseTimestamp(_ raw: String) -> TimestampInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let num = Double(trimmed), num.isFinite else { return nil }

        let isMillis = abs(num) >= 100_000_000_000 || (trimmed.replacingOccurrences(of: "-", with: "").count >= 12)
        let secondsDouble = isMillis ? num / 1000.0 : num
        let date = Date(timeIntervalSince1970: secondsDouble)

        return TimestampInfo(
            unitLabel: isMillis ? "毫秒 (ms)" : "秒 (s)",
            seconds: Int64(secondsDouble.rounded()),
            milliseconds: Int64((secondsDouble * 1000).rounded()),
            localText: formatDate(date, timeZone: .current),
            utcText: formatDate(date, timeZone: TimeZone(secondsFromGMT: 0)!),
            iso8601Text: ISO8601DateFormatter().string(from: date)
        )
    }

    public static func dateStringToTimestamp(_ raw: String) -> TimestampInfo? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: trimmed) {
            return parseTimestamp(String(Int64(d.timeIntervalSince1970)))
        }
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd",
        ]
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        for pattern in formats {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: trimmed) {
                return parseTimestamp(String(Int64(d.timeIntervalSince1970)))
            }
        }
        return nil
    }

    private static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    // MARK: - JWT 解析

    public static func decodeJWT(_ rawToken: String, now: Date = Date()) -> DecodedJWTResult? {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              let headerData = decodeBase64URL(parts[0]),
              let payloadData = decodeBase64URL(parts[1]) else {
            return nil
        }

        let headerJSON = prettyJSON(data: headerData) ?? String(decoding: headerData, as: UTF8.self)
        let payloadJSON = prettyJSON(data: payloadData) ?? String(decoding: payloadData, as: UTF8.self)
        let signature = parts.count >= 3 ? parts[2] : ""

        let payloadObj = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        let iatDate = (payloadObj?["iat"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let expDate = (payloadObj?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }

        var isExpired: Bool?
        var expiryStatusText = "未包含 exp 过期时间"
        if let expDate {
            let diff = expDate.timeIntervalSince(now)
            isExpired = diff < 0
            if diff < 0 {
                expiryStatusText = "已过期（\(formatDuration(abs(diff)))前）"
            } else {
                expiryStatusText = "有效（剩余 \(formatDuration(diff))）"
            }
        }

        return DecodedJWTResult(
            headerJSON: headerJSON,
            payloadJSON: payloadJSON,
            signature: signature,
            issuedAtText: iatDate.map { formatDate($0, timeZone: .current) },
            expiresAtText: expDate.map { formatDate($0, timeZone: .current) },
            isExpired: isExpired,
            expiryStatusText: expiryStatusText
        )
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 {
            s += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: s)
    }

    private static func prettyJSON(data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return nil
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let mins = totalMinutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分" }
        return "\(max(1, mins)) 分钟"
    }

    // MARK: - 编解码与哈希

    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    public static func base64Decode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = decodeBase64URL(trimmed),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    public static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func urlDecode(_ text: String) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    public static func unicodeEscape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                out.unicodeScalars.append(scalar)
            } else if scalar.value <= 0xFFFF {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                let v = scalar.value - 0x10000
                let high = 0xD800 + (v >> 10)
                let low = 0xDC00 + (v & 0x3FF)
                out += String(format: "\\u%04X\\u%04X", high, low)
            }
        }
        return out
    }

    public static func unicodeUnescape(_ text: String) -> String {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#) else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        var utf16Buffer: [unichar] = []
        func flushBuffer() {
            if !utf16Buffer.isEmpty {
                result += String(utf16CodeUnits: utf16Buffer, count: utf16Buffer.count)
                utf16Buffer.removeAll()
            }
        }
        for m in matches {
            if m.range.location > cursor {
                flushBuffer()
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            let hexStr = ns.substring(with: m.range(at: 1))
            if let code = UInt16(hexStr, radix: 16) {
                utf16Buffer.append(code)
            }
            cursor = m.range.location + m.range.length
        }
        flushBuffer()
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    public static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func generateUUIDs(count: Int = 5, uppercase: Bool = false) -> [String] {
        (0..<max(1, min(50, count))).map { _ in
            let s = UUID().uuidString
            return uppercase ? s.uppercased() : s.lowercased()
        }
    }

    // MARK: - 行级 Diff（LCS）

    public static func computeLineDiff(left: String, right: String, prettyJSON: Bool = false) -> [DiffLine] {
        let lText = prettyJSON ? (formatJSONString(left) ?? left) : left
        let rText = prettyJSON ? (formatJSONString(right) ?? right) : right
        let a = lText.components(separatedBy: .newlines)
        let b = rText.components(separatedBy: .newlines)

        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        var raw: [(DiffLine.Kind, Int?, Int?, String)] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                raw.append((.unchanged, i + 1, j + 1, a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                raw.append((.removed, i + 1, nil, a[i]))
                i += 1
            } else {
                raw.append((.added, nil, j + 1, b[j]))
                j += 1
            }
        }
        while i < n {
            raw.append((.removed, i + 1, nil, a[i]))
            i += 1
        }
        while j < m {
            raw.append((.added, nil, j + 1, b[j]))
            j += 1
        }

        return raw.enumerated().map { idx, tuple in
            DiffLine(id: idx, kind: tuple.0, leftLineNumber: tuple.1, rightLineNumber: tuple.2, text: tuple.3)
        }
    }

    private static func formatJSONString(_ raw: String) -> String? {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return prettyJSON(data: data)
    }
}
