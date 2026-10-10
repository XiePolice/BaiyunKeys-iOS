import Foundation

/// 全局状态：门禁列表 + 偏好设置。
final class AppStore: ObservableObject {

    private enum Keys {
        static let doors = "doorState"
        static let hideSensitive = "hideSensitive"
        static let quickUnlock = "quickUnlock"
        static let autoRetry = "autoRetryEnabled"
        static let autoRetryCount = "autoRetryCount"
        static let scanTimeout = "scanTimeout"
        static let showAutoFetch = "showAutoFetch"
        static let showAutoFetchAt = "showAutoFetchAt"
        static let fetchMethod = "fetchMethod"
        static let openId = "openId"
        static let theme = "theme"
        static let history = "unlockHistory"
        static let saveHistory = "saveHistory"
        static let haptics = "haptics"
        static let unlockOnResume = "unlockOnResume"
        static let requireBiometric = "requireBiometric"
        static let elderMode = "elderMode"
        static let elderLocksDoorSelector = "elderLocksDoorSelector"
        static let autoUnlockOnForeground = "autoUnlockOnForeground"
        static let elderHidesLogs = "elderHidesLogs"
        static let elderHidesHistory = "elderHidesHistory"
        static let showLogsExpanded = "showLogsExpanded"
        static let showHistoryExpanded = "showHistoryExpanded"
        static let pendingUnlockDoor = "pendingUnlockDoor"
    }

    static let historyLimit = 50

    /// 一条开锁记录（时间 + 门禁 + 成功/失败 + 失败原因）。
    struct UnlockRecord: Codable, Identifiable, Hashable {
        var id: String = UUID().uuidString
        let at: Date
        let doorId: String
        let doorName: String
        let ok: Bool
        let message: String
    }

    /// 外观：跟随系统（默认）/ 强制浅色 / 强制深色。
    enum Theme: String, CaseIterable, Identifiable {
        case auto, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:  return "跟随系统"
            case .light: return "浅色"
            case .dark:  return "深色"
            }
        }
    }

    /// 「自动获取配置」显示状态的最长保留时间，超过则自动翻回隐藏。
    static let autoFetchTTL: TimeInterval = 24 * 60 * 60

    /// 「自动获取配置」的两种通道。
    enum FetchMethod: String, CaseIterable, Identifiable {
        case idcard
        case openid

        var id: String { rawValue }
        var pickerLabel: String {
            switch self {
            case .idcard: return "手机号 + 身份证"
            case .openid: return "手机号 + OpenID（免身份证）"
            }
        }
    }

    // MARK: - 门禁

    @Published private(set) var state = DoorState()

    var doors: [DoorConfig] { state.items }

    var current: DoorConfig? { state.current }

    /// 从首页「编辑」按钮跳转到配置页时，携带要打开编辑弹窗的门禁 ID。
    /// 只在内存里存一次性的意图，不落盘；配置页读到后立刻清空。
    @Published var pendingEditDoorID: String?

    // MARK: - 偏好
    //
    // iOS 16 兼容：@Observable 的 access/withMutation 宏不可用，
    // 改成 @Published + didSet 模式。存储属性必须初始化，所以先从
    // UserDefaults 读初值，didSet 里写回。

    /// 列表中掩码显示 MAC 与 Key。
    @Published var hideSensitive: Bool {
        didSet { defaults.set(hideSensitive, forKey: Keys.hideSensitive) }
    }

    /// 打开 App 后自动开锁一次。
    @Published var quickUnlock: Bool {
        didSet { defaults.set(quickUnlock, forKey: Keys.quickUnlock) }
    }

    /// 「打开即开锁」的子开关：从后台切回前台也静默尝试一次。
    @Published var unlockOnResume: Bool {
        didSet { defaults.set(unlockOnResume, forKey: Keys.unlockOnResume) }
    }

    /// 扫描或连接超时后自动重试。
    @Published var autoRetry: Bool {
        didSet { defaults.set(autoRetry, forKey: Keys.autoRetry) }
    }

    @Published var autoRetryCount: Int {
        didSet {
            let clamped = min(max(autoRetryCount, Self.autoRetryCountRange.lowerBound),
                              Self.autoRetryCountRange.upperBound)
            if clamped != autoRetryCount { autoRetryCount = clamped; return }
            defaults.set(autoRetryCount, forKey: Keys.autoRetryCount)
        }
    }

    @Published var scanTimeout: Int {
        didSet {
            let clamped = min(max(scanTimeout, Self.scanTimeoutRange.lowerBound),
                              Self.scanTimeoutRange.upperBound)
            if clamped != scanTimeout { scanTimeout = clamped; return }
            defaults.set(scanTimeout, forKey: Keys.scanTimeout)
        }
    }

    /// 「自动获取配置」是否可见。
    @Published var showAutoFetch: Bool {
        didSet { defaults.set(showAutoFetch, forKey: Keys.showAutoFetch) }
    }

    /// 显示开启时刻（Unix 秒）；隐藏时为 0。
    @Published var showAutoFetchAt: TimeInterval {
        didSet { defaults.set(max(0, showAutoFetchAt), forKey: Keys.showAutoFetchAt) }
    }

    /// 切换「自动获取配置」显示状态，并写入时间戳（开时=现在，关时=0）。
    func setAutoFetchVisible(_ visible: Bool) {
        showAutoFetch = visible
        showAutoFetchAt = visible ? Date().timeIntervalSince1970 : 0
    }

    /// 若「自动获取配置」已显示且距开启时间超过 24 小时，则自动翻回隐藏。
    @discardableResult
    func checkAutoFetchExpiry(now: Date = Date()) -> Bool {
        guard showAutoFetch, showAutoFetchAt > 0 else { return false }
        guard now.timeIntervalSince1970 - showAutoFetchAt > Self.autoFetchTTL else { return false }
        setAutoFetchVisible(false)
        return true
    }

    /// 自动获取配置的方式：身份证号 / 微信 OpenID。
    @Published var fetchMethod: FetchMethod {
        didSet { defaults.set(fetchMethod.rawValue, forKey: Keys.fetchMethod) }
    }

    /// 用于 OpenID 通道；本地记住，避免每次重填。空串代表未设置。
    @Published var openId: String {
        didSet {
            let trimmed = openId.trimmingCharacters(in: .whitespaces)
            if trimmed != openId { openId = trimmed; return }
            defaults.set(openId, forKey: Keys.openId)
        }
    }

    /// 是否把新的开锁结果写进「开锁记录」。
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Keys.saveHistory) }
    }

    /// 触感反馈总开关。
    @Published var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Keys.haptics) }
    }

    /// 长辈模式。
    @Published var elderMode: Bool {
        didSet { defaults.set(elderMode, forKey: Keys.elderMode) }
    }

    /// App 从后台回到前台时自动开锁一次。
    @Published var autoUnlockOnForeground: Bool {
        didSet { defaults.set(autoUnlockOnForeground, forKey: Keys.autoUnlockOnForeground) }
    }

    /// 长辈模式下是否禁用首页顶部的门禁下拉选择器。
    @Published var elderLocksDoorSelector: Bool {
        didSet { defaults.set(elderLocksDoorSelector, forKey: Keys.elderLocksDoorSelector) }
    }

    /// 长辈模式下是否连「运行日志」卡片也隐藏。
    @Published var elderHidesLogs: Bool {
        didSet { defaults.set(elderHidesLogs, forKey: Keys.elderHidesLogs) }
    }

    /// 长辈模式下是否连「开锁记录」卡片也隐藏。
    @Published var elderHidesHistory: Bool {
        didSet { defaults.set(elderHidesHistory, forKey: Keys.elderHidesHistory) }
    }

    /// 首页「运行日志」卡片是否展开。
    @Published var showLogsExpanded: Bool {
        didSet { defaults.set(showLogsExpanded, forKey: Keys.showLogsExpanded) }
    }

    /// 首页「开锁记录」卡片是否展开。
    @Published var showHistoryExpanded: Bool {
        didSet { defaults.set(showHistoryExpanded, forKey: Keys.showHistoryExpanded) }
    }

    /// 启动 App 时是否需要 Face ID / Touch ID 验证。
    @Published var requireBiometric: Bool {
        didSet { defaults.set(requireBiometric, forKey: Keys.requireBiometric) }
    }

    /// 外观偏好；默认跟随系统。
    @Published var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// 开锁历史，最新在前。启动时从 UserDefaults 读一次。
    @Published private(set) var history: [UnlockRecord] = []

    /// 记一条开锁结果。
    func addUnlock(doorId: String, doorName: String, ok: Bool, message: String) {
        guard saveHistory else { return }
        let entry = UnlockRecord(at: Date(), doorId: doorId, doorName: doorName, ok: ok, message: message)
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        history.removeAll()
        persistHistory()
    }

    /// 删单条开锁记录。
    func deleteUnlock(id: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history.remove(at: index)
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Keys.history)
    }

    private static func loadHistory() -> [UnlockRecord] {
        guard let data = UserDefaults.standard.data(forKey: Keys.history),
              let decoded = try? JSONDecoder().decode([UnlockRecord].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(historyLimit))
    }

    static let autoRetryCountRange = 1...20
    static let scanTimeoutRange = 3...60

    private let defaults = UserDefaults.standard

    init() {
        // 先给所有 @Published 属性读初值，再加载门禁和历史。
        let d = UserDefaults.standard

        self.hideSensitive = d.object(forKey: Keys.hideSensitive) as? Bool ?? true
        self.quickUnlock = d.object(forKey: Keys.quickUnlock) as? Bool ?? false
        self.unlockOnResume = d.object(forKey: Keys.unlockOnResume) as? Bool ?? false
        self.autoRetry = d.object(forKey: Keys.autoRetry) as? Bool ?? true
        self.autoRetryCount = min(max(d.object(forKey: Keys.autoRetryCount) as? Int ?? 5,
                                      Self.autoRetryCountRange.lowerBound),
                                  Self.autoRetryCountRange.upperBound)
        self.scanTimeout = min(max(d.object(forKey: Keys.scanTimeout) as? Int ?? 10,
                                   Self.scanTimeoutRange.lowerBound),
                               Self.scanTimeoutRange.upperBound)
        self.showAutoFetch = d.object(forKey: Keys.showAutoFetch) as? Bool ?? false
        self.showAutoFetchAt = d.double(forKey: Keys.showAutoFetchAt)
        self.fetchMethod = FetchMethod(rawValue: d.string(forKey: Keys.fetchMethod) ?? "") ?? .idcard
        self.openId = d.string(forKey: Keys.openId) ?? ""
        self.saveHistory = d.object(forKey: Keys.saveHistory) as? Bool ?? true
        self.haptics = d.object(forKey: Keys.haptics) as? Bool ?? true
        self.elderMode = d.object(forKey: Keys.elderMode) as? Bool ?? false
        self.autoUnlockOnForeground = d.object(forKey: Keys.autoUnlockOnForeground) as? Bool ?? false
        self.elderLocksDoorSelector = d.object(forKey: Keys.elderLocksDoorSelector) as? Bool ?? false
        self.elderHidesLogs = d.object(forKey: Keys.elderHidesLogs) as? Bool ?? false
        self.elderHidesHistory = d.object(forKey: Keys.elderHidesHistory) as? Bool ?? false
        self.showLogsExpanded = d.object(forKey: Keys.showLogsExpanded) as? Bool ?? true
        self.showHistoryExpanded = d.object(forKey: Keys.showHistoryExpanded) as? Bool ?? true
        self.requireBiometric = d.object(forKey: Keys.requireBiometric) as? Bool ?? false
        self.theme = Theme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .auto

        self.state = Self.loadState()
        self.history = Self.loadHistory()
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func clamped(_ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - 增删改

    @discardableResult
    func save(_ config: DoorConfig) -> DoorConfig {
        var normalized = config
        normalized.mac = Hex.formatMac(config.mac)
        normalized.key = Hex.sanitizeKey(config.key)
        normalized.bluetoothName = config.bluetoothName.trimmingCharacters(in: .whitespaces).uppercased()
        normalized.name = config.name.trimmingCharacters(in: .whitespaces)

        if let index = state.items.firstIndex(where: { $0.id == normalized.id }) {
            if state.items[index].mac == normalized.mac, state.items[index].bluetoothName == normalized.bluetoothName {
                normalized.cachedPeripheralID = state.items[index].cachedPeripheralID
            }
            state.items[index] = normalized
        } else {
            state.items.append(normalized)
        }
        state.currentID = normalized.id
        persist()
        return normalized
    }

    func delete(id: String) {
        state.items.removeAll { $0.id == id }
        if state.currentID == id { state.currentID = state.items.first?.id }
        persist()
    }

    func select(id: String) {
        guard state.items.contains(where: { $0.id == id }) else { return }
        state.currentID = id
        persist()
    }

    func cachePeripheral(_ uuid: String, for id: String) {
        guard let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].cachedPeripheralID != uuid else { return }
        state.items[index].cachedPeripheralID = uuid
        persist()
    }

    func clearPeripheralCache(for id: String) {
        guard let index = state.items.firstIndex(where: { $0.id == id }),
              state.items[index].cachedPeripheralID != nil else { return }
        state.items[index].cachedPeripheralID = nil
        persist()
    }

    /// 从「自动获取」或文本导入的门禁批量入库，按 MAC + Key 去重。
    @discardableResult
    func merge(_ incoming: [DoorConfig]) -> Int {
        var added = 0
        for var item in incoming {
            item.mac = Hex.formatMac(item.mac)
            item.key = Hex.sanitizeKey(item.key)
            guard Hex.isValidMac(item.mac), Hex.isValidKey(item.key) else { continue }
            if let index = state.items.firstIndex(where: { $0.mac == item.mac && $0.key == item.key }) {
                if state.items[index].bluetoothName.isEmpty { state.items[index].bluetoothName = item.bluetoothName }
                if state.items[index].name.isEmpty { state.items[index].name = item.name }
            } else {
                state.items.append(item)
                added += 1
            }
        }
        if state.currentID == nil { state.currentID = state.items.first?.id }
        persist()
        return added
    }

    // MARK: - 快捷开锁待办（由 App Intent 写入）

    var pendingUnlockDoorID: String? {
        get { defaults.string(forKey: Keys.pendingUnlockDoor) }
        set { defaults.set(newValue, forKey: Keys.pendingUnlockDoor) }
    }

    // MARK: - 持久化

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        Keychain.save(data, account: Keys.doors)
    }

    private static func loadState() -> DoorState {
        guard let data = Keychain.load(account: Keys.doors),
              let decoded = try? JSONDecoder().decode(DoorState.self, from: data) else {
            return DoorState()
        }
        return decoded
    }
}
