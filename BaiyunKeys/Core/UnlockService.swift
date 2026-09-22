import CoreBluetooth
import Foundation
import Observation
import UIKit

/// 蓝牙开锁流程编排：扫描 → 连接 → 取随机数 → 握手 → 等待回执。
@Observable
final class UnlockService: NSObject {

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

    private(set) var phase: Phase = .idle
    private(set) var statusText: String = "准备就绪"
    private(set) var logs: [LogLine] = []
    private(set) var attempt: Int = 0
    private(set) var maxAttempts: Int = 1
    /// 蓝牙不可用时给界面的提示，nil 表示正常。
    private(set) var bluetoothIssue: String?

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

    // 扫描不按服务 UUID 过滤：不同门锁的 UUID 不一致，改按「同一服务里
    // 同时有 read + write 特征」认服务。
    private let connectTimeout: TimeInterval = 8
    private let seedTimeout: TimeInterval = 5
    private let ackTimeout: TimeInterval = 20
    private let maxLogLines = 200

    // MARK: - 内部状态

    // 以下均为流程内部状态，不需要参与 SwiftUI 的观察。

    private enum Stage { case idle, waitingSeed, waitingAck }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var target: DoorConfig?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var readCharacteristic: CBCharacteristic?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var pendingNotifySubscriptions = 0
    @ObservationIgnored private var stage: Stage = .idle
    @ObservationIgnored private var startPending = false
    @ObservationIgnored private var expectedDisconnect = false
    @ObservationIgnored private var scanTimer: DispatchWorkItem?
    @ObservationIgnored private var stepTimer: DispatchWorkItem?

    /// 特征发现阶段：还有多少个服务未回调、是否已选中可用服务。
    @ObservationIgnored private var pendingServiceDiscovery = 0
    @ObservationIgnored private var didChooseService = false

    /// 后台无头开锁用：完成时（无论成功失败）回一句 (Bool, String)，前台使用时留 nil 即可。
    @ObservationIgnored private var completion: ((Bool, String) -> Void)?
    /// 扫描时的服务过滤。前台走 `nil` 扫全部再按特征属性挑服务；
    /// 后台走已知 UUID（iOS 后台扫描强制要求指定 UUID）。
    @ObservationIgnored private var scanFilter: [CBUUID]?

    /// 快速模式候选池：不指定具体门锁，扫描到匹配池里任一条就把它当目标。
    /// 值为 nil 表示单门锁模式（走 `target`）。
    @ObservationIgnored private var candidatePool: [DoorConfig]?

    /// 静默模式：只走缓存设备直连；没缓存 / 蓝牙未开 / 连不上都静悄悄回到 idle，
    /// 不写日志错误、不震动、不进开锁记录。「切回也开锁」用这条路径。
    @ObservationIgnored private var silentOnly = false

    /// 协议协商过程中的分片缓存
    @ObservationIgnored private var handshakeOK = false
    @ObservationIgnored private var commBuffer = ""
    @ObservationIgnored private var timeBuffer = ""
    @ObservationIgnored private var sessionKey = ""

    @ObservationIgnored private let formatter: DateFormatter = {
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
            // 后台调用也要回一次 completion，避免挂起的 continuation 永不 resume。
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
            // 前置校验的失败不记入开锁记录
            fail("门禁参数不完整，请先在「配置」页填写 MAC、Key 与蓝牙名称", record: false)
            return
        }

        log("开始开锁流程 · \(config.displayName)")
        beginAttempt()
    }

    /// 快速模式入口：扫描附近的蓝牙设备，遇到匹配 `store.doors` 里任一门禁的
    /// 广播名或 MAC 就当目标去开。没有可用门禁则直接失败。
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

    /// 静默开锁：只用缓存的设备直连，没缓存就悄悄跳过。「切回也开锁」用这条路径。
    /// 不会弹设备选择器、不会启动扫描、失败不进开锁记录也不震动。
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

    /// 清空日志缓冲；下一次开锁前调用可以拿到干净的过程记录。
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

        // 单门锁模式：优先直连上次成功的外设，省掉扫描时间。
        // 快速模式不走缓存直连，要按现场信号强度选取候选池里最近的门锁。
        if candidatePool == nil, let target,
           let cached = target.cachedPeripheralID, let uuid = UUID(uuidString: cached),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            log("命中缓存设备，直接连接 \(cached.prefix(8))…")
            connect(known)
            return
        }

        // 静默模式没缓存就悄悄退回 idle，不进扫描
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

        // 握手回执
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

        // 通讯密钥协商失败
        if command == "08" {
            let word = String(hex.suffix(6).prefix(4)).uppercased()
            let hint = word == "E36F" ? "（门锁拒绝协商，通常是 Key 或授权信息不匹配）" : ""
            finish(success: false, message: "通讯密钥协商失败，设备返回码 0x\(word)\(hint)")
            return
        }

        // 开锁结果回执
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
        // 缓存必须在 teardown 之前取，teardown 会清空 peripheral
        if success, let target, let id = peripheral?.identifier.uuidString {
            store?.cachePeripheral(id, for: target.id)
        }
        // 静默模式下的失败不写历史、不震动、不设 .failure；成功仍然按正常路径走。
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
        // 后台调用方的一次性回调，先取出再清空避免重入
        let cb = completion
        completion = nil
        cb?(success, message)
        silentOnly = false
    }

    /// 扫描 / 连接类失败可自动重试，协议类失败直接结束。
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

    /// - Parameter record: 是否要把这次失败写进开锁记录。前置校验（如参数不完整）传 `false`。
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

    /// 静默模式下的软退出：没缓存 / 蓝牙未开等场景走这里，不产生用户可见输出，
    /// 也不写入开锁记录。跟 `fail` 的区别是这里只留一条 `.debug` 日志。
    private func silentAbort(_ reason: String) {
        log(reason, .debug)
        teardown()
        phase = .idle
        statusText = "准备就绪"
        silentOnly = false
    }

    /// 写一条开锁记录到 store。target / store 缺任何一个都放弃——记录本来就只是留档。
    private func recordHistory(ok: Bool, message: String) {
        guard let target, let store else { return }
        store.addUnlock(doorId: target.id, doorName: target.displayName, ok: ok, message: message)
    }

    private func teardown(keepCentral: Bool = true) {
        cancelTimer(&scanTimer)
        cancelTimer(&stepTimer)
        central?.stopScan()
        if let peripheral {
            // 主动断开会触发 didDisconnectPeripheral，标记一下避免被当成异常掉线再次重试
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

        // 快速模式：拿池里的每一条挨个试；命中就把它当目标继续走。
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

        // 单门锁模式
        guard let target else { return }
        guard matches(name: name, advertisement: advertisementData, door: target) else {
            log("发现设备 \(name.isEmpty ? "未知" : name) RSSI=\(RSSI)", .debug)
            return
        }
        log("匹配到门锁 \(name)（RSSI \(RSSI)）")
        connect(peripheral)
    }

    /// 判断某个广播是否属于给定门锁：优先看蓝牙名等值，其次看厂商数据里
    /// 是否含 MAC / 反序 MAC / 名字的 ASCII 编码。
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
        // 枚举全部服务后按特征属性挑，兼容服务 UUID 未知的门锁。
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
        // 每个服务都问一遍特征，等 didDiscoverCharacteristicsFor 里按属性挑
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        schedule(&stepTimer, after: connectTimeout) { [weak self] in
            self?.retryOrFail("蓝牙特征发现超时")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServiceDiscovery = max(0, pendingServiceDiscovery - 1)
        // 已选中一个可用服务后，忽略后续服务的回调，避免覆盖特征引用。
        if didChooseService { return }

        let characteristics = service.characteristics ?? []
        let read = characteristics.first { $0.properties.contains(.read) }
        let write = characteristics.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        let notifiable = characteristics.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }

        // 只认「同一个服务里同时有可读 + 可写特征」的那个；不合格就等下一个服务的回调
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
        // 若设备未回订阅确认，1.5 秒后继续读取随机数作为兜底。
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
    /// 总开关：直接读 UserDefaults，避开 AppStore 依赖，也让 Components 里的
    /// `.sensoryFeedback` 闭包能同步查到。默认 true（key 不存在时视为开启）。
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
