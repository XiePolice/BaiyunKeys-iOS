import Foundation

/// 十六进制 / MAC 地址工具。
enum Hex {

    // MARK: - 转换

    static func bytes(fromHex hex: String) -> [UInt8] {
        let clean = normalize(hex)
        var result: [UInt8] = []
        result.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            result.append(UInt8(clean[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }

    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func string(_ data: Data) -> String {
        string([UInt8](data))
    }

    /// 去掉非法字符并补齐奇数长度。
    static func normalize(_ hex: String) -> String {
        let clean = hex.uppercased().filter { $0.isHexDigit }
        return clean.count % 2 == 0 ? clean : "0" + clean
    }

    static func ascii(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%02X", $0.value & 0xFF) }.joined()
    }

    /// 按字节倒序，用于匹配部分设备反序广播的 MAC。
    static func reversedPairs(_ hex: String) -> String {
        stride(from: hex.count, to: 0, by: -2).map { end -> String in
            let start = hex.index(hex.startIndex, offsetBy: end - 2)
            let stop = hex.index(hex.startIndex, offsetBy: end)
            return String(hex[start..<stop])
        }.joined()
    }

    // MARK: - 校验

    static func sanitizeMacInput(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit || $0 == ":" }
    }

    static func isValidMac(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    static func sanitizeKey(_ value: String) -> String {
        value.uppercased().filter { $0.isHexDigit }
    }

    static func isValidKey(_ value: String) -> Bool {
        let sanitized = sanitizeKey(value)
        return sanitized.count >= 16 && sanitized.count <= 32 && sanitized.count % 2 == 0
    }

    /// 自动为纯十六进制串补上冒号，方便粘贴 `AABBCCDDEEFF` 这类格式。
    static func formatMac(_ value: String) -> String {
        let compact = value.uppercased().filter { $0.isHexDigit }
        guard compact.count == 12 else { return sanitizeMacInput(value) }
        return stride(from: 0, to: 12, by: 2).map { offset -> String in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return String(compact[start..<end])
        }.joined(separator: ":")
    }
}

extension String {
    /// 按十六进制字符位取子串，等价于 JS 的 `substr`。
    func hexSlice(_ start: Int, _ length: Int) -> String {
        guard start >= 0, start < count else { return "" }
        let from = index(startIndex, offsetBy: start)
        let to = index(from, offsetBy: min(length, count - start))
        return String(self[from..<to])
    }
}
