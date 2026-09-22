import Foundation

/// 门锁私有协议帧构造与解析。
enum BLEProtocol {

    enum Failure: LocalizedError {
        case badBluetoothName
        case badHeader
        case badMac

        var errorDescription: String? {
            switch self {
            case .badBluetoothName: return "蓝牙名称格式不合法，无法解析设备标识"
            case .badHeader:        return "握手指令头部需提供 4 个字节"
            case .badMac:           return "MAC 地址格式不合法，无法生成握手标识"
            }
        }
    }

    struct OpenResult {
        let code: String
        let message: String
        var isSuccess: Bool { code == "00" || code == "02" }
    }

    // MARK: - 设备标识

    /// 从蓝牙名称的第 4~11 位解析出 4 字节设备标识。
    static func deviceIdParts(fromBluetoothName name: String) throws -> [UInt8] {
        let clean = name.uppercased().filter { $0.isNumber || $0.isLetter }
        guard clean.count >= 11 else { throw Failure.badBluetoothName }
        return [3, 5, 7, 9].map { offset in
            UInt8(clean.hexSlice(offset, 2), radix: 16) ?? 0
        }
    }

    /// 取 MAC 的后 4 个字节作为帧头标识。
    static func header(fromMac mac: String) throws -> [UInt8] {
        let compact = mac.uppercased().filter { $0.isHexDigit }
        guard compact.count == 12 else { throw Failure.badMac }
        return Array(Hex.bytes(fromHex: compact).dropFirst(2))
    }

    /// 由蓝牙名称推出一个「够用」的 MAC。握手帧只吃 MAC 的后 4 字节，
    /// 且蓝牙名的第 4~11 位正好是这 4 字节；前 2 字节填什么都不影响开锁，
    /// 这里补 0 占位。填了蓝牙名却没抄 MAC 时省一次手抄。
    static func macFromBluetoothName(_ name: String) -> String? {
        let clean = name.uppercased().filter { $0.isNumber || $0.isLetter }
        guard clean.count >= 11 else { return nil }

        let tailStart = clean.index(clean.startIndex, offsetBy: 3)
        let tailEnd = clean.index(clean.startIndex, offsetBy: 11)
        let tail = String(clean[tailStart..<tailEnd])
        guard tail.count == 8, tail.allSatisfy(\.isHexDigit) else { return nil }

        let nibbleChar = clean[clean.index(clean.startIndex, offsetBy: 2)]
        let nibble: String = nibbleChar.isHexDigit ? String(nibbleChar) : "0"
        return Hex.formatMac("000" + nibble + tail)
    }

    // MARK: - 指令构造

    /// 握手指令：A5 14 05 | 设备标识×4 | 00 01 07 | DES(随机数校验块) | 校验和 5A
    static func handshakeCommand(random: [UInt8], header: [UInt8], productKey: String) throws -> Data {
        guard header.count == 4 else { throw Failure.badHeader }

        var sum = random.reduce(0) { $0 + Int($1) }
        sum += Hex.bytes(fromHex: Hex.normalize(productKey)).reduce(0) { $0 + Int($1) }

        let block: [UInt8] = [
            UInt8(sum & 0xFF), UInt8((sum >> 8) & 0xFF),
            random.at(0), random.at(1), random.at(2), random.at(3),
            0x00, 0x00
        ]
        let encrypted = Hex.bytes(fromHex: try DES.encryptBlock(keyHex: productKey, blockHex: Hex.string(block)))

        var frame: [UInt8] = [0xA5, 0x14, 0x05]
        frame += header
        frame += [0x00, 0x01, 0x07]
        frame += encrypted
        frame += [0x00, 0x5A]
        return Data(sealed(frame))
    }

    /// 通讯密钥协商指令（type = 0x09）。
    static func commKeyCommand(random: [UInt8], bluetoothName: String, productKey: String) throws -> Data {
        let ids = try deviceIdParts(fromBluetoothName: bluetoothName)
        let pivot: [UInt8] = [random.at(0), random.at(1), random.at(2), random.at(3), 0x00, 0x00, 0x00, 0x00]
        let encrypted = Hex.bytes(fromHex: try DES.encryptBlock(keyHex: productKey, blockHex: Hex.string(pivot)))

        let body = ids + [0x00, 0x00] + random
        return Data(sealed(payloadFrame(ids: ids, body: body, type: 0x09, encrypted: encrypted)))
    }

    /// 时间同步指令（type = 0x06），使用协商出的会话密钥加密。
    static func timeSyncCommand(timeBytes: [UInt8], bluetoothName: String, sessionKey: String) throws -> Data {
        let ids = try deviceIdParts(fromBluetoothName: bluetoothName)
        let payload = timeBytes + [UInt8](repeating: 0, count: max(0, 8 - timeBytes.count))
        let encrypted = Hex.bytes(fromHex: try DES.encryptBlock(keyHex: sessionKey, blockHex: Hex.string(Array(payload.prefix(8)))))

        let body = ids + [0x00, 0x00] + timeBytes
        return Data(sealed(payloadFrame(ids: ids, body: body, type: 0x06, encrypted: encrypted)))
    }

    /// BCD 编码的当前时间：年 月 日 时 分 秒 星期。
    static func timeHex(for date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)

        let year = (c.year ?? 2000) - 2000
        let yearByte = UInt8(((year / 10) << 4) | (year % 10))
        let weekday = ((c.weekday ?? 1) - 1)   // Calendar 的周日为 1，协议里周日为 0

        return String(format: "%02X%02d%02d%02d%02d%02d%02d",
                      yearByte, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, weekday)
    }

    // MARK: - 报文解析

    /// 从设备下发的密钥片段中还原会话密钥。
    static func commKey(fromBody bodyHex: String, productKey: String) -> String {
        guard let decrypted = try? DES.decryptBlock(keyHex: productKey, blockHex: bodyHex),
              decrypted.count >= 32 else { return "" }
        return decrypted.hexSlice(16, 16).uppercased()
    }

    static func decrypt(bodyHex: String, sessionKey: String) -> String {
        (try? DES.decryptBlock(keyHex: sessionKey, blockHex: bodyHex)) ?? ""
    }

    /// 解析开锁回执。
    static func openResult(frameHex: String, productKey: String) -> OpenResult {
        let clean = Hex.normalize(frameHex)
        guard clean.count >= 36 else {
            return OpenResult(code: "FF", message: "数据长度不足，无法解析回执")
        }
        let body = clean.hexSlice(20, 16)
        guard let decrypted = try? DES.decryptBlock(keyHex: productKey, blockHex: body), decrypted.count == 16 else {
            return OpenResult(code: "FF", message: "回执解密失败")
        }
        switch decrypted.hexSlice(4, 2) {
        case "00": return OpenResult(code: "00", message: "开门成功")
        case "02": return OpenResult(code: "02", message: "门已打开")
        case let other: return OpenResult(code: other, message: "开门失败，密码无效")
        }
    }

    // MARK: - 私有

    /// 带 sum / xor 校验位的通用负载帧。
    private static func payloadFrame(ids: [UInt8], body: [UInt8], type: UInt8, encrypted: [UInt8]) -> [UInt8] {
        let sumBody = UInt8(body.reduce(0) { $0 + Int($1) } & 0xFF)
        let xorBody = body.dropFirst().reduce(body.first ?? 0) { $0 ^ $1 }

        var frame: [UInt8] = [0xA5, 0x16, 0x01]
        frame += ids
        frame += [0x00, 0x00, sumBody, xorBody, type]
        frame += encrypted
        frame += [0x00, 0x5A]
        return frame
    }

    /// 写入末位校验和（各字节之和的反码）。
    private static func sealed(_ frame: [UInt8]) -> [UInt8] {
        var frame = frame
        let checksum = frame.reduce(0) { $0 + Int($1) }
        frame[frame.count - 2] = UInt8(~checksum & 0xFF)
        return frame
    }
}

private extension Array where Element == UInt8 {
    func at(_ index: Int) -> UInt8 { indices.contains(index) ? self[index] : 0 }
}
