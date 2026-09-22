import Foundation

/// 一套门禁参数。`key`（productKey）与 `mac`（macNum）来自官方 App 下发的门禁信息。
struct DoorConfig: Identifiable, Codable, Hashable {
    var id: String = "door_\(UUID().uuidString.prefix(8).lowercased())"
    var name: String = ""
    var mac: String = ""
    var key: String = ""
    /// iOS 上 CoreBluetooth 不暴露 MAC，必须靠蓝牙广播名匹配设备，因此此项必填。
    var bluetoothName: String = ""
    /// 上次成功连接的外设 UUID，用于跳过扫描直连。
    var cachedPeripheralID: String?

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名门禁" : name
    }

    var isUsable: Bool {
        Hex.isValidMac(mac) && Hex.isValidKey(key) && !bluetoothName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 用于列表展示的脱敏 MAC。
    func maskedMac(hidden: Bool) -> String {
        guard hidden, Hex.isValidMac(mac) else { return mac.isEmpty ? "未填写" : mac }
        let parts = mac.split(separator: ":").map(String.init)
        guard parts.count == 6 else { return mac }
        return (parts.prefix(2) + ["＊＊", "＊＊", "＊＊"] + [parts[5]]).joined(separator: ":")
    }

    func maskedKey(hidden: Bool) -> String {
        guard !key.isEmpty else { return "未填写" }
        guard hidden else { return key }
        return String(key.prefix(4)) + String(repeating: "＊", count: max(0, key.count - 8)) + String(key.suffix(4))
    }
}

/// 门禁列表 + 当前选中项。
struct DoorState: Codable {
    var version: Int = 2
    var currentID: String?
    var items: [DoorConfig] = []

    var current: DoorConfig? {
        guard let currentID else { return items.first }
        return items.first { $0.id == currentID } ?? items.first
    }
}
