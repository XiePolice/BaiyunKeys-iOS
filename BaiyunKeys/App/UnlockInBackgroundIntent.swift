import AppIntents
import CoreBluetooth
import Foundation

/// 与 `UnlockDoorIntent` 并存的独立后台入口：不打开 App 直接跑一次蓝牙开锁，
/// 用 `.result(dialog:)` 回一句提示。iOS 后台扫描强制要求指定服务 UUID，
/// 因此这条路径用已知的两个门锁服务 UUID，不能享受前台的「按特征属性挑服务」放宽。
struct UnlockInBackgroundIntent: AppIntent {
    static var title: LocalizedStringResource = "后台开锁"
    static var description = IntentDescription("不打开 App，直接执行一次蓝牙开锁；完成后回一句提示。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "门禁")
    var door: DoorEntity?

    /// 后台扫描 iOS 必须指定服务 UUID。这里用当前已知的两个白云门锁服务。
    /// 如果日后遇到不认识的 UUID，这条后台路径会扫不到——前台路径不受影响。
    private static let backgroundScanFilter: [CBUUID] = [
        CBUUID(string: "0734594A-A8E7-4B1A-A6B1-CD5243059A57"),
        CBUUID(string: "14839AC4-7D7E-415C-9A42-167340CF2339")
    ]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 用户没在快捷指令里指定门禁时，取当前默认门禁。
        let store = AppStore()
        let target: DoorConfig? = {
            if let id = door?.id, let match = store.doors.first(where: { $0.id == id }) {
                return match
            }
            return store.current
        }()

        guard let target, target.isUsable else {
            return .result(dialog: "门禁参数不完整，请先在 App 内配置")
        }

        // 用一个短命的独立实例跑，跟 UI 上那个绑到环境的 UnlockService 不共享状态
        let unlocker = UnlockService()
        let (success, message): (Bool, String) = await withCheckedContinuation { continuation in
            unlocker.unlock(target,
                            store: store,
                            scanFilter: Self.backgroundScanFilter) { ok, msg in
                continuation.resume(returning: (ok, msg))
            }
        }

        let prefix = success ? "已开锁" : "开锁失败"
        return .result(dialog: "\(target.displayName)：\(prefix)。\(message)")
    }
}
