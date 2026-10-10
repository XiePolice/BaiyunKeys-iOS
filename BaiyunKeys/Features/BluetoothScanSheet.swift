import SwiftUI

/// 顶栏蓝牙按钮点开的弹窗：现场扫描周围广播，按 RSSI 从强到弱列出来，
/// 方便调试／对号入座「哪台设备信号最好」。不发起连接、也不干扰开锁流程。
struct BluetoothScanSheet: View {
    /// 蓝牙未初始化时的兜底状态文案（用 `UnlockService.bluetoothStatus` 传进来）。
    let fallbackStatus: String

    @Environment(\.dismiss) private var dismiss
    @State private var scanner = BluetoothScanner()

    private var sorted: [BluetoothScanner.Discovery] {
        scanner.discoveries.sorted { $0.rssi > $1.rssi }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                statusRow

                if let issue = scanner.issue {
                    Text(issue)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .padding(.vertical, 4)
                } else if sorted.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(sorted) { d in
                                row(d)
                            }
                        }
                    }
                    Text("RSSI 越接近 0 越近；一般小于 -80 dBm 就比较远了。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("蓝牙扫描")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: scanner.isScanning ? "dot.radiowaves.left.and.right" : "wave.3.right")
                .foregroundStyle(scanner.isScanning ? Theme.brand : Theme.textSecondary)
            Text(scanner.isScanning ? "扫描中…共 \(scanner.discoveries.count) 台" : fallbackStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("尚未扫描到设备，靠近门锁再看看。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func row(_ d: BluetoothScanner.Discovery) -> some View {
        HStack(spacing: 12) {
            signalIcon(rssi: d.rssi)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(d.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(d.id.uuidString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            Text("\(d.rssi) dBm")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(rssiColor(d.rssi))
        }
        .padding(12)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 4 格信号：>= -55 → 4 格；-70..-55 → 3 格；-85..-70 → 2 格；否则 1 格。
    private func signalIcon(rssi: Int) -> some View {
        let level: Int
        if rssi >= -55 {
            level = 4
        } else if rssi >= -70 {
            level = 3
        } else if rssi >= -85 {
            level = 2
        } else {
            level = 1
        }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= level ? rssiColor(rssi) : Theme.textTertiary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -55 { return Theme.brand }
        if rssi >= -75 { return Theme.info }
        if rssi >= -90 { return Theme.warn }
        return Theme.danger
    }
}
