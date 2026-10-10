import CoreBluetooth
import Foundation
import UIKit

/// 蓝牙开锁流程编排：扫描 → 连接 → 取随机数 → 握手 → 等待回执。
final class UnlockService: NSObject, ObservableObject {

    // MARK: - 对外状态

    enum Phase: Equatable {
        case idle, preparing, scanning, connecting, negotiating, waiting, success, failure

        var isBusy: Bool {
            switch self {
            case .preparing, .scanning, .connecting, .negotiating, .waiting: return true
            default: return false
            }
        }
    }

    struct LogLine: Identifiable, Equatable {
        enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR", debug = "DEBUG" }
        let id = UUID()
        let time: String
        let level: Level
        let text: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText: String = "准备就绪"
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var attempt: Int = 0
    @Published private(set) var maxAttempts: Int = 1
    /// 蓝牙不可用时给界面的提示，nil 表示正常。
    @Published private(set) var bluetoothIssue: String?

    /// 汇总的蓝牙状态文案：优先展示开锁流程报出的 issue，其次读系统授权状态。
    /// `CBManager.authorization` 是静态查询，不会创建 CBCentralManager，也就不会误弹权限框。
    var bluetoothStatus: String {
        if let issue = bluetoothIssue { return issue }
        switch CBManager.authorization {
        case .notDetermined: return "尚未使用（首次开锁时确认）"
        case .denied:        return "未授权，请到「设置 → 隐私与安全性 → 蓝牙」允许"
        case .restricted:    return "受限（家长控制等）"
        case .allowedAlways: return "已授权"
        @unknown default:    return "未知状态"
        }
    }

    // MARK: - 常量

    private let connectTimeout: TimeInterval = 8
    private let seedTimeout: TimeInterval = 5
    private let ackTimeout: TimeInterval = 20
    private let maxLogLines = 200

    // MARK: - 内部状态

    private enum Stage { case idle, waitingSeed, waitingAck }

    private var central: CBCentralManager?
    private weak var store: AppStore?
    private var target: DoorConfig?
    private var peripheral: CBPeripheral?
    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingNotifySubscriptions = 0
    private var stage: Stage = .idle
    private var startPending = false
    private var expectedDisconnect = false
    private var scanTimer: DispatchWorkItem?
    private var stepTimer: DispatchWorkItem?

    private var pendingServiceDiscovery = 0
    private var didChooseService = false

    private var completion: ((Bool, String) -> Void)?
    private var scanFilter: [CBUUID]?
    private var candidatePool: [DoorConfig]?
    private var silentOnly = false

    private var handshakeOK = false
    private var commBuffer = ""
    private var timeBuffer = ""
    private var sessionKey = ""

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 入口

    func unlock(_ config: DoorConfig,
                store: AppStore,
                scanFilter: [CBUUID]? = nil,
                completion: ((Bool, String) -> Void)? = nil) {
        guard !phase.isBusy else {
            completion?(false, "开锁流程已在进行中")
            return
        }
        self.store = store
        self.target = config
        self.candidatePool = nil
        self.silentOnly = false
        self.scanFilter = scanFilter
        self.completion = completion
        self.maxAttempts = store.autoRetry ? max(1, store.autoRetryCount) : 1
        self.attempt = 0
        logs.removeAll()

        guard config.isUsable else {
            fail("门禁参数不完整，请先在「配置」页填写 MAC、Key 与蓝牙名称", record: false)
            return
        }

        log("开始开锁流程 · \(config.displayName)")
        beginAttempt()
    }

    func unlockAny(store: AppStore) {
        guard !phase.isBusy else { return }
        let pool = store.doors.filter(\.isUsable)
        self.store = store
        guard !pool.isEmpty else {
            self.target = nil
            fail("没有可用的门禁，无法自动开锁", record: false)
            return
        }
        self.candidatePool = pool
        self.target = pool.first
        self.silentOnly = false
        self.scanFilter = nil
        self.completion = nil
        self.maxAttempts = store.autoRetry ? max(1, store.autoRetryCount) : 1
        self.attempt = 0
        logs.removeAll()

        log("快速模式：扫描附近门禁（候选 \(pool.count) 个）")
        beginAttempt()
    }

    func unlockIfCached(_ config: DoorConfig, store: AppStore) {
        guard !phase.isBusy, config.isUsable else { return }
        guard config.cachedPeripheralID != nil else { return }

        self.store = store
        self.target = config
        self.candidatePool = nil
        self.silentOnly = true
        self.scanFilter = nil
        self.completion = nil
        self.maxAttempts = 1
        self.attempt = 0
        logs.removeAll()

        log("切回也开锁 · \(config.displayName)")
        beginAttempt()
    }

    func cancel() {
        guard phase.isBusy else { return }
        log("用户中断开锁流程", .warn)
        teardown()
        phase = .idle
        statusText = "已中断"
    }

    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
        statusText = "准备就绪"
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - 流程

    private func beginAttempt() {
        attempt += 1
        resetProtocolState()
        phase = .preparing
        statusText = attempt == 1 ? "正在初始化蓝牙…" : "第 \(attempt) 次尝试…"

        if central == nil {
            log("初始化蓝牙适配器")
            central = CBCentralManager(delegate: self, queue: .main)
            startPending = true
            return
        }
        guard central?.state == .poweredOn else {
            startPending = true
            reportBluetoothState(central?.state ?? .unknown)
            return
        }
        startScanOrConnect()
    }

    private func startScanOrConnect() {
        guard let central else { return }
        bluetoothIssue = nil

        if candidatePool == nil, let target,
           let cached = target.cachedPeripheralID, let uuid = UUID(uuidString: cached),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            log("命中缓存设备，直接连接 \(cached.prefix(8))…")
            connect(known)
            return
        }

        if silentOnly {
            silentAbort("静默模式无缓存设备，跳过")
            return
        }

        phase = .scanning
        statusText = candidatePool != nil ? "正在搜索附近门禁…" : "正在搜索门锁…"
        if let scanFilter, !scanFilter.isEmpty {
            log("开始扫描（服务 UUID 过滤，后台模式），超时 \(store?.scanTimeout ?? 10)s")
        } else {
            log("开始扫描（不按服务过滤，靠蓝牙名匹配），超时 \(store?.scanTimeout ?? 10)s")
        }
        central.scanForPeripherals(withServices: scanFilter, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        scheduleScanTimeout()
    }

    private func connect(_ peripheral: CBPeripheral) {
        cancelTimer(&scanTimer)
        central?.stopScan()

        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        statusText = "正在连接门锁…"
        log("连接设备 \(peripheral.name ?? peripheral.identifier.uuidString)")
        central?.connect(peripheral, options: nil)

        schedule(&stepTimer, after: connectTimeout) { [weak self] in
            self?.retryOrFail("连接门锁超时，请靠近门锁后重试")
        }
    }

    private func sendHandshake(seed: [UInt8]) {
        guard let target, let peripheral, let writeCharacteristic else { return }
        do {
            let header = try BLEProtocol.header(fromMac: target.mac)
            let key = Hex.sanitizeKey(target.key)
            let command = try BLEProtocol.handshakeCommand(random: seed, header: header, productKey: key)

            log("握手指令 \(Hex.string(command))", .debug)
            let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            peripheral.writeValue(command, for: writeCharacteristic, type: type)

            stage = .waitingAck
            phase = .waiting
            statusText = "已发送开锁指令，等待门锁响应…"
            schedule(&stepTimer, after: ackTimeout) { [weak self] in
                self?.retryOrFail("等待门锁回执超时")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - 通知解析

    private func processNotification(_ hex: String) {
        guard let target else { return }
        let header = hex.hexSlice(0, 2).uppercased()
        let command = hex.count >= 6 ? hex.hexSlice(4, 2).uppercased() : ""
        let type = hex.count >= 20 ? hex.hexSlice(18, 2).uppercased() : ""
        let tail = String(hex.suffix(2)).uppercased()

        log("收到 \(hex.count / 2)B header=\(header) cmd=\(command) type=\(type)", .debug)
        guard header == "A5" else { return }

        if command == "04" {
            cancelTimer(&stepTimer)
            guard hex.count > 24 else {
                let statusField = hex.hexSlice(14, 4)
                let word = (statusField.hexSlice(2, 2) + statusField.hexSlice(0, 2)).uppercased()
                let hint = word == "000B" ? "（Key 或设备标识不匹配，门锁拒绝握手）" : ""
                finish(success: false, message: "握手失败，设备返回码 0x\(word)\(hint)")
                return
            }
            handshakeOK = true
            log("握手成功")
            finish(success: true, message: "握手成功，门锁已执行开锁")
            return
        }

        if command == "08" {
            let word = String(hex.suffix(6).prefix(4)).uppercased()
            let hint = word == "E36F" ? "（门锁拒绝协商，通常是 Key 或授权信息不匹配）" : ""
            finish(success: false, message: "通讯密钥协商失败，设备返回码 0x\(word)\(hint)")
            return
        }

        if type == "87", tail == "5A" {
            let result = BLEProtocol.openResult(frameHex: hex, productKey: target.key)
            finish(success: result.isSuccess, message: result.message)
            return
        }

        guard handshakeOK else { return }

        switch type {
        case "89":
            commBuffer = hex
            log("门锁开始下发通讯密钥片段")
            return
        case "86":
            timeBuffer = hex
            log("门锁返回时间同步片段")
            return
        case "82":
            log("门锁返回黑名单同步片段", .debug)
            return
        default:
            break
        }

        if tail == "5A", !commBuffer.isEmpty {
            let merged = commBuffer + hex
            let key = BLEProtocol.commKey(fromBody: merged.hexSlice(24, 32), productKey: target.key)
            if key.isEmpty {
                commBuffer = merged
            } else {
                sessionKey = key
                commBuffer = ""
                log("通讯密钥协商成功")
            }
            return
        }

        if tail == "5A", !timeBuffer.isEmpty, !sessionKey.isEmpty {
            let merged = timeBuffer + hex
            let result = BLEProtocol.decrypt(bodyHex: merged.hexSlice(24, 16), sessionKey: sessionKey)
            if result == "0000000000000000" {
                timeBuffer = ""
                log("门锁时间同步成功")
                statusText = "时间同步完成，等待门锁最终回执…"
            } else {
                timeBuffer = merged
            }
        }
    }

    // MARK: - 结束处理

    private func finish(success: Bool, message: String) {
        if success, let target, let id = peripheral?.identifier.uuidString {
            store?.cachePeripheral(id, for: target.id)
        }
        let visible = !silentOnly || success
        if visible {
            recordHistory(ok: success, message: message)
            Haptics.notify(success ? .success : .error)
        }
        teardown()
        if visible {
            phase = success ? .success : .failure
            statusText = message
            log(message, success ? .info : .error)
        } else {
            phase = .idle
            statusText = "准备就绪"
            log(message, .debug)
        }
        let cb = completion
        completion = nil
        cb?(success, message)
        silentOnly = false
    }

    private func retryOrFail(_ message: String) {
        if attempt < maxAttempts {
            log("\(message)，自动重试（\(attempt)/\(maxAttempts)）", .warn)
            teardown(keepCentral: true)
            statusText = "重试中（\(attempt)/\(maxAttempts)）…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.phase != .idle else { return }
                self.beginAttempt()
            }
            return
        }
        finish(success: false, message: message)
    }

    private func fail(_ message: String, record: Bool = true) {
        if record && !silentOnly { recordHistory(ok: false, message: message) }
        teardown()
        if silentOnly {
            phase = .idle
            statusText = "准备就绪"
            log(message, .debug)
        } else {
            phase = .failure
            statusText = message
            log(message, .error)
            Haptics.notify(.error)
        }
        let cb = completion
        completion = nil
        cb?(false, message)
        silentOnly = false
    }

    private func silentAbort(_ reason: String) {
        log(reason, .debug)
        teardown()
        phase = .idle
        statusText = "准备就绪"
        silentOnly = false
    }

    private func recordHistory(ok: Bool, message: String) {
        guard let target, let store else { return }
        store.addUnlock(doorId: target.id, doorName: target.displayName, ok: ok, message: message)
    }

    private func teardown(keepCentral: Bool = true) {
        cancelTimer(&scanTimer)
        cancelTimer(&stepTimer)
        central?.stopScan()
        if let peripheral {
            expectedDisconnect = true
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        readCharacteristic = nil
        writeCharacteristic = nil
        stage = .idle
        startPending = false
        if !keepCentral { central = nil }
    }

    private func resetProtocolState() {
        handshakeOK = false
        commBuffer = ""
        timeBuffer = ""
        sessionKey = ""
        pendingNotifySubscriptions = 0
        pendingServiceDiscovery = 0
        didChooseService = false
        stage = .idle
    }

    // MARK: - 定时器

    private func scheduleScanTimeout() {
        let timeout = TimeInterval(store?.scanTimeout ?? 10)
        schedule(&scanTimer, after: timeout) { [weak self] in
            self?.retryOrFail("扫描超时，未找到门锁，请靠近后重试")
        }
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after seconds: TimeInterval, action: @escaping () -> Void) {
        cancelTimer(&slot)
        let item = DispatchWorkItem(block: action)
        slot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelTimer(_ slot: inout DispatchWorkItem?) {
        slot?.cancel()
        slot = nil
    }

    // MARK: - 日志

    private func log(_ text: String, _ level: LogLine.Level = .info) {
        logs.append(LogLine(time: formatter.string(from: Date()), level: level, text: text))
        if logs.count > maxLogLines { logs.removeFirst(logs.count - maxLogLines) }
    }

    var logText: String {
        logs.map { "\($0.time) [\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    private func reportBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOff:
            bluetoothIssue = "蓝牙已关闭，请在控制中心或设置中打开蓝牙"
        case .unauthorized:
            bluetoothIssue = "未授权使用蓝牙，请到「设置 → 隐私与安全性 → 蓝牙」中允许"
        case .unsupported:
            bluetoothIssue = "当前设备不支持蓝牙低功耗"
        default:
            bluetoothIssue = nil
        }
        if let bluetoothIssue, phase.isBusy {
            fail(bluetoothIssue)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension UnlockService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        reportBluetoothState(central.state)
        guard central.state == .poweredOn else { return }
        if startPending {
            startPending = false
            log("蓝牙适配器已就绪")
            startScanOrConnect()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard phase == .scanning else { return }

        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let name = (peripheral.name ?? localName).uppercased()

        if let pool = candidatePool {
            if let hit = pool.first(where: { matches(name: name, advertisement: advertisementData, door: $0) }) {
                target = hit
                candidatePool = nil
                store?.select(id: hit.id)
                log("快速模式命中：\(hit.displayName)（RSSI \(RSSI)）")
                connect(peripheral)
            }
            return
        }

        guard let target else { return }
        guard matches(name: name, advertisement: advertisementData, door: target) else {
            log("发现设备 \(name.isEmpty ? "未知" : name) RSSI=\(RSSI)", .debug)
            return
        }
        log("匹配到门锁 \(name)（RSSI \(RSSI)）")
        connect(peripheral)
    }

    private func matches(name: String, advertisement: [String: Any], door: DoorConfig) -> Bool {
        let wanted = door.bluetoothName.uppercased()
        if !wanted.isEmpty, name == wanted { return true }

        guard let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return false
        }
        let advHex = Hex.string(manufacturer)
        let macHex = door.mac.uppercased().filter { $0.isHexDigit }
        if !macHex.isEmpty, advHex.contains(macHex) || advHex.contains(Hex.reversedPairs(macHex)) {
            return true
        }
        if !wanted.isEmpty, advHex.contains(Hex.ascii(wanted)) {
            return true
        }
        return false
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelTimer(&stepTimer)
        log("蓝牙连接成功")
        phase = .negotiating
        statusText = "正在初始化蓝牙服务…"
        peripheral.discoverServices(nil)
        schedule(&stepTimer, after: connectTimeout) { [weak self] in
            self?.retryOrFail("蓝牙服务发现超时")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let target { store?.clearPeripheralCache(for: target.id) }
        retryOrFail("连接门锁失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if expectedDisconnect {
            expectedDisconnect = false
            return
        }
        guard phase.isBusy else { return }
        retryOrFail("门锁连接已断开：\(error?.localizedDescription ?? "设备主动断开")")
    }
}

// MARK: - CBPeripheralDelegate

extension UnlockService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        cancelTimer(&stepTimer)
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            retryOrFail("未发现任何蓝牙服务，请确认门锁正在广播")
            return
        }
        pendingServiceDiscovery = services.count
        didChooseService = false
        log("发现 \(services.count) 个服务，逐个枚举特征", .debug)
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        schedule(&stepTimer, after: connectTimeout) { [weak self] in
            self?.retryOrFail("蓝牙特征发现超时")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServiceDiscovery = max(0, pendingServiceDiscovery - 1)
        if didChooseService { return }

        let characteristics = service.characteristics ?? []
        let read = characteristics.first { $0.properties.contains(.read) }
        let write = characteristics.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        let notifiable = characteristics.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }

        guard let read, let write else {
            log("服务 \(service.uuid.uuidString) 缺可读或可写特征，跳过", .debug)
            if pendingServiceDiscovery == 0 {
                finish(success: false, message: "未找到可读写的蓝牙特征")
            }
            return
        }

        didChooseService = true
        cancelTimer(&stepTimer)
        readCharacteristic = read
        writeCharacteristic = write
        log("命中服务 \(service.uuid.uuidString)（read=\(read.uuid.uuidString) write=\(write.uuid.uuidString) notify=\(notifiable.count)）", .debug)

        guard !notifiable.isEmpty else {
            readSeed()
            return
        }
        pendingNotifySubscriptions = notifiable.count
        notifiable.forEach { peripheral.setNotifyValue(true, for: $0) }
        schedule(&stepTimer, after: 1.5) { [weak self] in
            guard let self, self.stage == .idle else { return }
            self.log("订阅回调超时，继续读取随机数", .warn)
            self.readSeed()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        pendingNotifySubscriptions = max(0, pendingNotifySubscriptions - 1)
        guard pendingNotifySubscriptions == 0, stage == .idle else { return }
        cancelTimer(&stepTimer)
        readSeed()
    }

    private func readSeed() {
        guard let peripheral, let readCharacteristic, stage == .idle else { return }
        stage = .waitingSeed
        statusText = "正在与门锁握手…"
        log("读取门锁随机数")
        peripheral.readValue(for: readCharacteristic)
        schedule(&stepTimer, after: seedTimeout) { [weak self] in
            self?.retryOrFail("读取门锁随机数超时")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }

        if stage == .waitingSeed, characteristic.uuid == readCharacteristic?.uuid {
            cancelTimer(&stepTimer)
            stage = .idle
            let seed = [UInt8](value)
            log("随机数 \(Hex.string(seed))")
            sendHandshake(seed: seed)
            return
        }
        processNotification(Hex.string(value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            retryOrFail("写入开锁指令失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 触感反馈

enum Haptics {
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "haptics") as? Bool) ?? true
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
