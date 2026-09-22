import SwiftUI

/// 首页主操作：大号圆形开锁按钮，忙碌时向外扩散涟漪。
struct UnlockButton: View {
    let phase: UnlockService.Phase
    let enabled: Bool
    let action: () -> Void

    @State private var ripple = false
    @State private var pressed = false

    private var tint: Color {
        switch phase {
        case .success: return Theme.brand
        case .failure: return Theme.danger
        default:       return enabled ? Theme.brand : Theme.textTertiary
        }
    }

    private var symbol: String {
        switch phase {
        case .success: return "checkmark"
        case .failure: return "exclamationmark"
        default:       return phase.isBusy ? "dot.radiowaves.left.and.right" : "lock.open.fill"
        }
    }

    private var caption: String {
        switch phase {
        case .success: return "已开锁"
        case .failure: return "重试"
        default:       return phase.isBusy ? "进行中" : "轻点开锁"
        }
    }

    var body: some View {
        ZStack {
            if phase.isBusy {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(tint.opacity(0.35), lineWidth: 2)
                        .frame(width: 208, height: 208)
                        .scaleEffect(ripple ? 1.45 : 0.85)
                        .opacity(ripple ? 0 : 0.9)
                        .animation(
                            .easeOut(duration: 2.1).repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.7),
                            value: ripple
                        )
                }
            }

            Circle()
                .fill(tint.opacity(0.10))
                .frame(width: 236, height: 236)

            Button(action: action) {
                VStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 54, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(caption)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(1)
                }
                .foregroundStyle(.white)
                .frame(width: 196, height: 196)
                .background(tint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled && !phase.isBusy)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
        }
        .frame(height: 260)
        .onChange(of: phase) { _, newValue in
            ripple = newValue.isBusy
        }
        .onAppear { ripple = phase.isBusy }
    }
}
