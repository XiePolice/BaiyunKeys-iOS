import CoreBluetooth
import Foundation

/// 一个只做「看」的蓝牙扫描器：不连接、不写、不干开锁流程，只把周围广播的
/// 设备名和 RSSI 收集起来供 UI 展示。跟 `UnlockService` 各自持有独立
/// `CBCentralManager`，互不阻塞。
final class BluetoothScanner: NSObject, ObservableObject {

    struct Discovery: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date
    }

    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var isScanning = false
    /// 蓝牙不可用时的提示，nil 表示正常。
    @Published private(set) var issue: String?

    private var central: CBCentralManager?
    private var wantsScanning = false

    func start() {
        wantsScanning = true
        discoveries.removeAll()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfPossible()
        }
    }

    func stop() {
        wantsScanning = false
        central?.stopScan()
        isScanning = false
    }

    private func beginScanIfPossible() {
        guard let central, central.state == .poweredOn, wantsScanning else { return }
        issue = nil
        // allowDuplicates=true 才能持续拿到 RSSI 更新，让「信号强度」栏是动态的。
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }
}

extension BluetoothScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            issue = nil
            beginScanIfPossible()
        case .poweredOff:
            issue = "蓝牙已关闭，请在控制中心或设置中打开蓝牙"
            isScanning = false
        case .unauthorized:
            issue = "未授权使用蓝牙，请到「设置 → 隐私与安全性 → 蓝牙」允许"
            isScanning = false
        case .unsupported:
            issue = "当前设备不支持蓝牙低功耗"
            isScanning = false
        case .resetting:
            issue = "蓝牙正在重置，请稍候"
            isScanning = false
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "(未命名)"
        let entry = Discovery(id: peripheral.identifier,
                              name: name,
                              rssi: RSSI.intValue,
                              lastSeen: Date())
        if let idx = discoveries.firstIndex(where: { $0.id == entry.id }) {
            discoveries[idx] = entry
        } else {
            discoveries.append(entry)
        }
    }
}
