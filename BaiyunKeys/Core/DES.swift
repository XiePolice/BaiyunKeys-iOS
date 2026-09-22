import CommonCrypto
import Foundation

/// 单块 DES/ECB/NoPadding。
enum DES {

    enum Failure: LocalizedError {
        case missingKey
        case shortKey
        case badBlock
        case cryptFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .missingKey:            return "缺少 DES 密钥"
            case .shortKey:              return "密钥长度不足 8 字节"
            case .badBlock:              return "DES 数据块必须为 8 字节（16 个十六进制字符）"
            case .cryptFailed(let code): return "DES 运算失败（\(code)）"
            }
        }
    }

    static func encryptBlock(keyHex: String, blockHex: String) throws -> String {
        try crypt(op: CCOperation(kCCEncrypt), keyHex: keyHex, blockHex: blockHex)
    }

    static func decryptBlock(keyHex: String, blockHex: String) throws -> String {
        try crypt(op: CCOperation(kCCDecrypt), keyHex: keyHex, blockHex: blockHex)
    }

    // MARK: - 内部实现

    private static func normalizedKey(_ keyHex: String) throws -> [UInt8] {
        let clean = keyHex.uppercased().filter { $0.isHexDigit }
        guard !clean.isEmpty else { throw Failure.missingKey }
        guard clean.count >= 16 else { throw Failure.shortKey }
        // 仅取密钥前 8 字节作为 DES 密钥
        return Hex.bytes(fromHex: String(clean.prefix(16)))
    }

    private static func crypt(op: CCOperation, keyHex: String, blockHex: String) throws -> String {
        let key = try normalizedKey(keyHex)
        let clean = blockHex.uppercased().filter { $0.isHexDigit }
        guard clean.count == 16 else { throw Failure.badBlock }
        let input = Hex.bytes(fromHex: clean)

        var output = [UInt8](repeating: 0, count: kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(
            op,
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),   // 不带 padding 选项 == NoPadding
            key, kCCKeySizeDES,
            nil,
            input, input.count,
            &output, output.count,
            &moved
        )
        // kCCSuccess 从匿名 enum 导入为 Int，而 CCCryptorStatus 是 Int32，必须显式转换
        guard status == CCCryptorStatus(kCCSuccess), moved == kCCBlockSizeDES else {
            throw Failure.cryptFailed(status)
        }
        return Hex.string(output)
    }
}
