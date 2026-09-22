import SwiftUI

@main
struct BaiyunKeysApp: App {
    @State private var store = AppStore()
    @State private var unlocker = UnlockService()

    init() {
        // iOS 15+ 起 UITabBar 有 standard / scrollEdge 两套 appearance，
        // scrollEdge 默认透明——ScrollView 滚到边缘时会切成它，看起来就是
        // tab bar 变透明。把两套统一成不透明的默认样式，避免边缘触发透明。
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(unlocker)
                .tint(Theme.brand)
                .onOpenURL(perform: handleIncomingURL)
        }
    }

    /// 处理 URL scheme 触发的开锁。格式：
    /// - `baiyunkeys://unlock`               开当前默认门禁
    /// - `baiyunkeys://unlock?door=<门禁 id>`  开指定门禁
    ///
    /// 通过写入 `pendingUnlockDoorID`，走跟快捷指令完全一样的通路——
    /// `RootView.handlePendingIntent()` 会在场景变 active 时接管。
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "baiyunkeys" else { return }

        let host = url.host?.lowercased()
        let firstPath = url.pathComponents.dropFirst().first?.lowercased()
        guard host == "unlock" || firstPath == "unlock" else { return }

        let doorID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "door" })?
            .value
        // 空串表示「用当前默认门禁」；RootView 里查不到 id 时也自动 fallback
        store.pendingUnlockDoorID = doorID ?? ""
    }
}
