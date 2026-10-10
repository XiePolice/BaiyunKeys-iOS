import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
@EnvironmentObject private var unlocker: UnlockService
    @Environment(\.openURL) private var openURL

    @Binding var selectedTab: RootView.Tab

    @State private var homeToast: Toast?
    @State private var homeToastDismissTask: Task<Void, Never>?
    /// 开启长辈模式前的确认弹窗（勾选禁用/隐藏项）
    @State private var showElderSetup = false
    /// 开启快速模式前的确认弹窗（说明行为 + 单门锁的速度警告）
    @State private var showQuickModeSetup = false
    /// 版本更新检查状态
    @State private var checkingUpdate = false
    @State private var showUpdateSheet = false
    @State private var latestRelease: UpdateChecker.Release?
    /// 首页顶栏的扫码导入弹窗
    @State private var showImportScanSheet = false
    /// 蓝牙状态查看弹窗
    @State private var showBluetoothInfo = false
    @State private var pendingLockDoorSelector = false
    @State private var pendingHideLogs = false
    @State private var pendingHideHistory = false

    private var current: DoorConfig? { store.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    doorSelector
                    unlockSection
                    if let current {
                        parameterCard(current)
                    } else {
                        emptyCard
                    }
                    if !(store.elderMode && store.elderHidesLogs) { logCard }
                    if !(store.elderMode && store.elderHidesHistory) { historyCard }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("白云钥匙")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // 左上角：检查更新 + 蓝牙状态 + 扫码导入（长辈模式下都藏起来）
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    if !store.elderMode {
                        Button {
                            Task { await checkForUpdate() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .rotationEffect(.degrees(checkingUpdate ? 360 : 0))
                                .animation(checkingUpdate
                                           ? .linear(duration: 1).repeatForever(autoreverses: false)
                                           : .default,
                                           value: checkingUpdate)
                        }
                        .tint(Theme.textSecondary)
                        .disabled(checkingUpdate)

                        Button {
                            showBluetoothInfo = true
                        } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        .tint(Theme.textSecondary)

                        Button {
                            showImportScanSheet = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                        }
                        .tint(Theme.textSecondary)
                    }
                }

                // 右上角：长辈模式、快速模式、掩码
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 长辈模式开关：开启和关闭都需长按 3 秒（防误触）。用
                    // highPriorityGesture 让长按拿到优先级，成功后 Button 的 tap 不再触发。
                    Button {
                        flashHomeToast("长按 3 秒切换长辈模式")
                    } label: {
                        Image(systemName: store.elderMode ? "hand.raised.fill" : "hand.raised")
                    }
                    .tint(store.elderMode ? Theme.brand : Theme.textSecondary)
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 3).onEnded { _ in
                            handleElderLongPress()
                        }
                    )

                    // 快速模式：开启和关闭都需长按 3 秒；开启前弹确认框说明行为。
                    Button {
                        flashHomeToast("长按 3 秒切换快速模式")
                    } label: {
                        Image(systemName: store.autoUnlockOnForeground ? "bolt.fill" : "bolt")
                    }
                    .tint(store.autoUnlockOnForeground ? Theme.brand : Theme.textSecondary)
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 3).onEnded { _ in
                            handleQuickModeLongPress()
                        }
                    )

                    Button {
                        store.hideSensitive.toggle()
                        Haptics.tap(.light)
                    } label: {
                        Image(systemName: store.hideSensitive ? "eye.slash" : "eye")
                    }
                    .tint(Theme.textSecondary)
                }
            }
        }
        .overlay(alignment: .top) {
            if let homeToast {
                ToastView(toast: homeToast)
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: homeToast)
        .sheet(isPresented: $showElderSetup) {
            elderSetupSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuickModeSetup) {
            quickModeSetupSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showUpdateSheet) {
            updateSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showImportScanSheet) {
            ImportSheet(initialMode: .qr) { text in
                let parsed = DoorTextParser.parse(text)
                if parsed.isEmpty {
                    flashHomeToast("未能从内容识别出门禁参数", isError: true)
                    return false
                }
                let added = store.merge(parsed)
                flashHomeToast("识别 \(parsed.count) 条，新增 \(added) 条")
                return true
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBluetoothInfo) {
            BluetoothScanSheet(fallbackStatus: unlocker.bluetoothStatus)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// 开启快速模式前的确认单：说明行为 + 单门锁场景的速度警告。
    private var quickModeSetupSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("快速模式会自动识别你门锁列表里可开的门。冷启动和从后台切回时都会尝试开锁，谁近开谁——不用手动切当前门锁。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)

                Text("开启后")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    bullet("覆盖「打开即开锁」和「切回也开锁」两个偏好，都视为开")
                    bullet("开锁目标从「当前默认门锁」变成「门锁列表里任一近的门」")
                    Label {
                        Text("门锁列表里只有一个门锁时，因为跳过了缓存直连、每次都要重新扫描，开锁速度反而会比不开快速模式更慢。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warn)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    QuietButton(title: "取消", symbol: "xmark", tint: Theme.textSecondary) {
                        showQuickModeSetup = false
                    }
                    Spacer()
                    FilledButton(title: "开启快速模式", symbol: "bolt.fill", tint: Theme.brand) {
                        confirmQuickModeOn()
                    }
                    .frame(maxWidth: 220)
                }
            }
            .padding(20)
            .navigationTitle("开启快速模式")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// 开启长辈模式前的确认单：说明 + 两个可选卡片隐藏 + 「取消 / 开启」按钮。
    private var elderSetupSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("开启后：门禁列表右侧的进入配置按钮、当前门禁参数的编辑按钮、日志和记录的清空 / 单条删除都会隐藏，切「配置」页也会被拦。关闭仍需长按 3 秒。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)

                Text("可选：进一步隐藏这些卡片")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 4)

                FlatToggle(title: "禁用门锁选择功能", subtitle: "选择器仍显示当前门锁，但不能点开切换", isOn: $pendingLockDoorSelector)
                FlatToggle(title: "隐藏运行日志卡片", isOn: $pendingHideLogs)
                FlatToggle(title: "隐藏开锁记录卡片", isOn: $pendingHideHistory)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    QuietButton(title: "取消", symbol: "xmark", tint: Theme.textSecondary) {
                        showElderSetup = false
                    }
                    Spacer()
                    FilledButton(title: "开启长辈模式", symbol: "hand.raised.fill", tint: Theme.brand) {
                        confirmElderOn()
                    }
                    .frame(maxWidth: 220)
                }
            }
            .padding(20)
            .navigationTitle("开启长辈模式")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 长辈模式交互

    /// 长按 3 秒触发：关掉直接生效；开启前先弹确认框让用户勾选禁用/隐藏项。
    private func handleElderLongPress() {
        if store.elderMode {
            store.elderMode = false
            flashHomeToast("已关闭长辈模式")
        } else {
            pendingLockDoorSelector = store.elderLocksDoorSelector
            pendingHideLogs = store.elderHidesLogs
            pendingHideHistory = store.elderHidesHistory
            showElderSetup = true
            Haptics.tap(.light)
        }
    }

    // MARK: - 版本检查

    private func checkForUpdate() async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Haptics.tap(.light)
        defer { checkingUpdate = false }

        do {
            let release = try await UpdateChecker.fetchLatest()
            let current = Self.currentAppVersion
            if UpdateChecker.isNewer(latest: release.tag, current: current) {
                latestRelease = release
                showUpdateSheet = true
                Haptics.notify(.success)
            } else {
                flashHomeToast("已是最新版本 v\(current)")
            }
        } catch let error as UpdateChecker.Failure {
            flashHomeToast(error.localizedDescription, isError: true)
        } catch {
            flashHomeToast("检查更新失败：\(error.localizedDescription)", isError: true)
        }
    }

    private static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// 发现新版本时弹的确认单：显示新版号、发布说明、去 GitHub Release 页下载。
    @ViewBuilder
    private var updateSheet: some View {
        NavigationStack {
            if let release = latestRelease {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(release.tag)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                        Spacer()
                        Text("当前 v\(Self.currentAppVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if !release.title.isEmpty, release.title != release.tag {
                        Text(release.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    if release.notes.isEmpty {
                        Text("这个版本没写发布说明。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ScrollView {
                            Text(release.notes)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        QuietButton(title: "稍后再说", symbol: "xmark", tint: Theme.textSecondary) {
                            showUpdateSheet = false
                        }
                        Spacer()
                        FilledButton(title: "前往 Release", symbol: "arrow.down.circle", tint: Theme.brand) {
                            openURL(release.webURL)
                            showUpdateSheet = false
                        }
                        .frame(maxWidth: 200)
                    }
                }
                .padding(20)
                .navigationTitle("发现新版本")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - 快速模式交互

    private func handleQuickModeLongPress() {
        if store.autoUnlockOnForeground {
            store.autoUnlockOnForeground = false
            flashHomeToast("已关闭快速模式")
        } else {
            showQuickModeSetup = true
            Haptics.tap(.light)
        }
    }

    private func confirmQuickModeOn() {
        store.autoUnlockOnForeground = true
        showQuickModeSetup = false
        flashHomeToast("已开启快速模式")
    }

    // MARK: - 首页 toast

    /// 弹一次自动消失的 toast。已经在显示时不重启计时、也不再震动，
    /// 避免快速连点不断重置计时。
    private func flashHomeToast(_ text: String, isError: Bool = false) {
        guard homeToast == nil else { return }
        Haptics.notify(isError ? .warning : .success)
        homeToast = Toast(text: text, isError: isError)
        homeToastDismissTask?.cancel()
        homeToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { homeToast = nil }
            homeToastDismissTask = nil
        }
    }

    private func confirmElderOn() {
        store.elderLocksDoorSelector = pendingLockDoorSelector
        store.elderHidesLogs = pendingHideLogs
        store.elderHidesHistory = pendingHideHistory
        store.elderMode = true
        showElderSetup = false
        flashHomeToast("已开启长辈模式")
    }

    // MARK: - 门禁选择

    private var doorSelector: some View {
        let locked = store.elderMode && store.elderLocksDoorSelector
        return HStack(spacing: 12) {
            Menu {
                ForEach(store.doors) { door in
                    Button {
                        store.select(id: door.id)
                        unlocker.reset()
                    } label: {
                        Label(door.displayName, systemImage: door.id == current?.id ? "checkmark" : "door.left.hand.closed")
                    }
                }
                if store.doors.isEmpty {
                    Text("暂无门禁").font(.footnote)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "door.left.hand.closed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text(current?.displayName ?? "未配置门禁")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // 禁用状态下改用锁形图标，提示不可点击。
                    Image(systemName: locked ? "lock.fill" : "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                )
            }
            .disabled(locked)

            if !store.elderMode {
                Button {
                    selectedTab = .config
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.info)
                        .frame(width: 54, height: 54)
                        .background(Theme.infoSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 开锁区

    private var unlockSection: some View {
        VStack(spacing: 16) {
            UnlockButton(phase: unlocker.phase, enabled: current?.isUsable == true) {
                handleUnlockTap()
            }

            Text(unlocker.statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.2), value: unlocker.statusText)
                .frame(minHeight: 40)
                .padding(.horizontal, 8)

            if unlocker.phase.isBusy {
                QuietButton(title: "中断", symbol: "stop.fill", tint: Theme.danger) {
                    unlocker.cancel()
                }
            }

            if let issue = unlocker.bluetoothIssue, !unlocker.phase.isBusy {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var statusColor: Color {
        switch unlocker.phase {
        case .success: return Theme.brand
        case .failure: return Theme.danger
        default:       return Theme.textSecondary
        }
    }

    private func handleUnlockTap() {
        if unlocker.phase.isBusy { return }
        guard let current else {
            selectedTab = .config
            return
        }
        Haptics.tap()
        unlocker.unlock(current, store: store)
    }

    // MARK: - 参数卡

    private func parameterCard(_ door: DoorConfig) -> some View {
        Card {
            CardHeader(title: "当前门禁参数", subtitle: door.isUsable ? "参数完整，可以开锁" : "参数不完整，请补全后再试", symbol: "key.horizontal.fill")

            HStack(spacing: 12) {
                KeyValueRow(label: "门禁 MAC", value: door.maskedMac(hidden: store.hideSensitive))
                KeyValueRow(label: "蓝牙名称", value: door.bluetoothName.isEmpty ? "未填写" : door.bluetoothName)
            }
            KeyValueRow(label: "门禁 Key", value: door.maskedKey(hidden: store.hideSensitive))

            HStack(spacing: 8) {
                Badge(text: "BLE", tint: Theme.info)
                if door.cachedPeripheralID != nil {
                    Badge(text: "已缓存设备", tint: Theme.brand)
                }
                if !door.isUsable {
                    Badge(text: "参数缺失", tint: Theme.danger)
                }
                Spacer()
                if !store.elderMode {
                    QuietButton(title: "编辑", symbol: "square.and.pencil", tint: Theme.info) {
                        store.pendingEditDoorID = door.id
                        selectedTab = .config
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        Card {
            EmptyStateView(
                symbol: "key.slash",
                title: "还没有门禁参数",
                message: "前往「配置」页，通过自动获取或手动录入你的门禁信息。"
            )
            FilledButton(title: "去配置门禁", symbol: "arrow.right") {
                selectedTab = .config
            }
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        Card {
            Button {
                withAnimation(.snappy(duration: 0.25)) { store.showLogsExpanded.toggle() }
            } label: {
                HStack {
                    CardHeader(title: "运行日志", subtitle: "开锁过程的逐步记录", symbol: "text.alignleft", tint: Theme.info)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(store.showLogsExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if store.showLogsExpanded {
                if unlocker.logs.isEmpty {
                    Text("暂无日志。点击开锁后，过程会实时显示在这里。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(unlocker.logs) { line in
                                    logRow(line)
                                }
                            }
                            .padding(12)
                        }
                        .frame(height: 240)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onChange(of: unlocker.logs.count) { _ in
                            if let last = unlocker.logs.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        QuietButton(title: "复制日志", symbol: "doc.on.doc", tint: Theme.info) {
                            UIPasteboard.general.string = unlocker.logText
                            Haptics.notify(.success)
                        }
                        if !store.elderMode {
                            QuietButton(title: "清空", symbol: "trash", tint: Theme.textSecondary) {
                                unlocker.clearLogs()
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    /// 一条日志：第 1 行时间 + 级别（级别按 info 绿 / warn 橙 / error 红 / debug 灰上色），
    /// 第 2 行完整消息，独占整行、可换行。避免级别被压得竖着显示。
    private func logRow(_ line: UnlockService.LogLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(line.time)
                    .foregroundStyle(Theme.textTertiary)
                Text(line.level.rawValue)
                    .fontWeight(.semibold)
                    .foregroundStyle(color(for: line.level))
            }
            .font(.system(size: 11, design: .monospaced))

            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(line.id)
    }

    private func color(for level: UnlockService.LogLine.Level) -> Color {
        switch level {
        case .info:  return Theme.brand
        case .warn:  return Theme.warn
        case .error: return Theme.danger
        case .debug: return Theme.textTertiary
        }
    }

    // MARK: - 开锁记录

    /// 首页日志下面这张卡。没有记录时整张卡不显示；有记录时可折叠 / 展开，
    /// 超过 `historyInlineThreshold` 条时列表内部滚动。
    @ViewBuilder
    private var historyCard: some View {
        if !store.history.isEmpty {
            Card {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { store.showHistoryExpanded.toggle() }
                } label: {
                    HStack {
                        CardHeader(title: "开锁记录",
                                   subtitle: "最近 \(min(store.history.count, Self.historyShownLimit)) 条",
                                   symbol: "clock.arrow.circlepath",
                                   tint: Theme.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(store.showHistoryExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)

                if store.showHistoryExpanded {
                    ScrollView(showsIndicators: true) {
                        historyList
                            .padding(12)
                    }
                    .frame(height: Self.historyScrollHeight)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 10) {
                        QuietButton(title: "复制记录", symbol: "doc.on.doc", tint: Theme.info) {
                            UIPasteboard.general.string = historyText
                            Haptics.notify(.success)
                        }
                        if !store.elderMode {
                            QuietButton(title: "清空", symbol: "trash", tint: Theme.textSecondary) {
                                store.clearHistory()
                                Haptics.tap(.light)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var historyList: some View {
        VStack(spacing: 10) {
            ForEach(store.history.prefix(Self.historyShownLimit)) { record in
                historyRow(record)
            }
        }
    }

    /// 复制到剪贴板用的纯文本格式：一条一行，`时间 ✓/✗ 门禁名 · 消息`。
    private var historyText: String {
        store.history.prefix(Self.historyShownLimit).map { record in
            let time = Self.historyFormatter.string(from: record.at)
            let mark = record.ok ? "✓" : "✗"
            let name = record.doorName.isEmpty ? "门禁" : record.doorName
            return record.message.isEmpty
                ? "\(time) \(mark) \(name)"
                : "\(time) \(mark) \(name) · \(record.message)"
        }.joined(separator: "\n")
    }

    private static let historyShownLimit = 20
    /// 记录列表固定高度，跟运行日志盒子一致；内容超高时内部滚动。
    private static let historyScrollHeight: CGFloat = 240

    /// 一条开锁记录：第 1 行 ✓/✗ + 门禁名（✓ 绿 / ✗ 红），第 2 行「时间 · 结果消息」，
    /// 无论成败都显示消息；右侧一个删除按钮，可单独删这一条。
    private func historyRow(_ record: AppStore.UnlockRecord) -> some View {
        let name = record.doorName.isEmpty ? "门禁" : record.doorName
        let time = Self.historyFormatter.string(from: record.at)
        let detail = record.message.isEmpty ? time : "\(time) · \(record.message)"
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.ok ? "✓" : "✗")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(record.ok ? Theme.brand : Theme.danger)
                        .frame(width: 14)
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if !store.elderMode {
                Button {
                    store.deleteUnlock(id: record.id)
                    Haptics.tap(.light)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除这条记录")
            }
        }
    }

    private static let historyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}
