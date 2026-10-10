import SwiftUI

struct DoorEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let config: DoorConfig
    let onSave: (DoorConfig) -> Void

    @State private var name = ""
    @State private var mac = ""
    @State private var key = ""
    @State private var bluetoothName = ""
    /// 由蓝牙名推得、并已写入 mac 的值。用户手动改动后清空，之后不再覆盖。
    @State private var autoFilledMac: String?

    private var macValid: Bool { Hex.isValidMac(Hex.formatMac(mac)) }
    private var macAutoFilled: Bool {
        guard let autoFilledMac else { return false }
        return mac == autoFilledMac
    }
    private var keyValid: Bool { Hex.isValidKey(key) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && macValid && keyValid
            && !bluetoothName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    Card {
                        CardHeader(title: "蓝牙门禁参数", subtitle: "对应官方数据表中的字段", symbol: "key.fill")

                        FlatField(title: "门禁名称", placeholder: "如 一号楼大门", text: $name,
                                  autocapitalization: .sentences)
                        FlatField(title: "门禁 MAC", hint: "macNum", placeholder: "AA:BB:CC:DD:EE:FF",
                                  text: $mac, autocapitalization: .characters, monospaced: true)
                            .onChange(of: mac) { _, newValue in
                                // 用户手动改过 MAC 后就不再自动覆盖
                                if let filled = autoFilledMac, newValue != filled {
                                    autoFilledMac = nil
                                }
                            }
                        validationHint(ok: macValid,
                                       text: macValid
                                        ? (macAutoFilled ? "已按蓝牙名自动填入，前两段不参与开锁" : "格式正确")
                                        : "需为 6 组两位十六进制，冒号可省略")

                        FlatField(title: "门禁 Key", hint: "productKey", placeholder: "16~32 位十六进制",
                                  text: $key, autocapitalization: .characters, monospaced: true)
                        validationHint(ok: keyValid, text: keyValid ? "格式正确（\(Hex.sanitizeKey(key).count) 位）" : "需为 16~32 位偶数长度十六进制")

                        FlatField(title: "蓝牙名称", hint: "bluetoothName · iOS 必填", placeholder: "如 BLE12345678",
                                  text: $bluetoothName, autocapitalization: .characters, monospaced: true)
                            .onChange(of: bluetoothName) { _, newValue in
                                autoFillMacIfNeeded(from: newValue)
                            }
                    }

                    Card {
                        CardHeader(title: "为什么 iOS 必须填蓝牙名称", symbol: "info.circle", tint: Theme.info)
                        Text("iOS 的 CoreBluetooth 不向 App 暴露外设的 MAC 地址，只提供一个随机化的设备 UUID。因此扫描阶段只能靠广播名称（或广播数据里出现的 MAC）来定位你的门锁，MAC 仍用于生成握手帧的设备标识。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 8)
            }
            .background(Theme.background)
            .navigationTitle(config.name.isEmpty ? "新增门禁" : "编辑门禁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = config
                        updated.name = name
                        updated.mac = Hex.formatMac(mac)
                        updated.key = Hex.sanitizeKey(key)
                        updated.bluetoothName = bluetoothName.trimmingCharacters(in: .whitespaces).uppercased()
                        onSave(updated)
                        Haptics.notify(.success)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            name = config.name
            mac = config.mac
            key = config.key
            bluetoothName = config.bluetoothName
        }
    }

    private func validationHint(ok: Bool, text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(ok ? Theme.brand : Theme.textTertiary)
    }

    /// 蓝牙名变化时，如果 MAC 还空着（或还是上次自动填的），用推导值覆盖一次。
    private func autoFillMacIfNeeded(from bluetoothName: String) {
        let trimmed = mac.trimmingCharacters(in: .whitespaces)
        let canOverride = trimmed.isEmpty || (autoFilledMac != nil && trimmed == autoFilledMac)
        guard canOverride else { return }

        if let derived = BLEProtocol.macFromBluetoothName(bluetoothName) {
            mac = derived
            autoFilledMac = derived
        } else if autoFilledMac != nil {
            // 蓝牙名被清空或改短了，把之前自动填的 MAC 也一并清掉
            mac = ""
            autoFilledMac = nil
        }
    }
}
