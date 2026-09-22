import AppIntents
import Foundation

/// 暴露给「快捷指令 / 操作按钮 / 轻点背面 / Siri」的开锁动作。
/// 蓝牙开锁必须在前台执行，因此打开 App 后由 RootView 接管实际流程。
struct UnlockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "立即开锁"
    static var description = IntentDescription("用当前选中的门禁参数执行一次蓝牙开锁。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "门禁")
    var door: DoorEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(door?.id ?? "", forKey: "pendingUnlockDoor")
        return .result()
    }
}

/// 供快捷指令挑选具体门禁。
struct DoorEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "门禁")
    static var defaultQuery = DoorQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct DoorQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DoorEntity] {
        allDoors().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DoorEntity] {
        allDoors()
    }

    private func allDoors() -> [DoorEntity] {
        guard let data = Keychain.load(account: "doorState"),
              let state = try? JSONDecoder().decode(DoorState.self, from: data) else { return [] }
        return state.items.map { DoorEntity(id: $0.id, name: $0.displayName) }
    }
}

struct BaiyunShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 前台入口：打开 App 后由 RootView 接管开锁流程。
        AppShortcut(
            intent: UnlockDoorIntent(),
            phrases: [
                "用 \(.applicationName) 开门",
                "\(.applicationName) 开锁"
            ],
            shortTitle: "立即开锁",
            systemImageName: "lock.open.fill"
        )
        // 独立后台入口：不打开 App，跑完蓝牙开锁后回一句提示。
        AppShortcut(
            intent: UnlockInBackgroundIntent(),
            phrases: [
                "用 \(.applicationName) 后台开锁",
                "\(.applicationName) 快速开门"
            ],
            shortTitle: "后台开锁",
            systemImageName: "lock.rotation"
        )
    }
}
