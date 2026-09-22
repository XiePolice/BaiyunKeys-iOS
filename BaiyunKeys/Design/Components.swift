import SwiftUI

// MARK: - 卡片

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
    }
}

struct CardHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = Theme.brand

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 表单

struct FlatField: View {
    let title: String
    var hint: String?
    var placeholder: String = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            TextField(placeholder, text: $text)
                .font(.system(size: 16, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
        }
    }
}

struct FlatToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            HapticGatedSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { isOn.toggle() }
            Haptics.tap(.light)
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 自绘开关：视觉上贴近系统 UISwitch，但完全不走 UIKit，因此不携带 UISwitch
/// 那条无法禁用的系统触感。统一通过 `Haptics.tap(.light)` 出声，可被总开关关闭。
struct HapticGatedSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    private let trackWidth: CGFloat = 51
    private let trackHeight: CGFloat = 31
    private let thumbInset: CGFloat = 2

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Theme.brand : Color(uiColor: .tertiarySystemFill))
                .frame(width: trackWidth, height: trackHeight)
            Circle()
                .fill(Color.white)
                .frame(width: trackHeight - thumbInset * 2, height: trackHeight - thumbInset * 2)
                .padding(.horizontal, thumbInset)
                .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { isOn.toggle() }
            Haptics.tap(.light)
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? Text("已开启") : Text("已关闭"))
    }
}

struct StepperRow: View {
    let title: String
    var subtitle: String?
    var unit: String = ""
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Text("\(value)\(unit)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
                .monospacedDigit()
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
        .sensoryFeedback(trigger: value) { _, _ in Haptics.enabled ? .increase : nil }
    }
}

/// 左侧标题 + 副标题、右侧 Menu 按钮显示当前项 + 下拉图标的行。
/// 菜单内容由调用方提供（通常是一个 Picker）。
struct PrefMenuRow<MenuContent: View>: View {
    let title: String
    var subtitle: String?
    let current: String
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Menu {
                menuContent()
            } label: {
                HStack(spacing: 4) {
                    Text(current)
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Theme.surfaceAlt, in: Capsule())
            }
        }
        .sensoryFeedback(trigger: current) { _, _ in Haptics.enabled ? .selection : nil }
    }
}

// MARK: - 按钮

struct FilledButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.brand
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap(.light)
            action()
        } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(tint.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct QuietButton: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.textSecondary
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(tint.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 其它

struct Badge: View {
    let text: String
    var tint: Color = Theme.brand

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String
    var monospaced: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
