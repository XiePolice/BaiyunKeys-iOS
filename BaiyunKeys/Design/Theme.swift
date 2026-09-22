import SwiftUI

/// 扁平化配色：纯色表面 + 细分割线，不用玻璃拟态和阴影堆叠。
enum Theme {

    static let brand        = dynamic(light: 0x0FB981, dark: 0x2DD4A0)
    static let brandSoft    = dynamic(light: 0xE7F8F1, dark: 0x0F2E26)
    static let info         = dynamic(light: 0x2F6BFF, dark: 0x5B8CFF)
    static let infoSoft     = dynamic(light: 0xEAF0FF, dark: 0x131E3A)
    static let danger       = dynamic(light: 0xE5484D, dark: 0xFF6369)
    static let dangerSoft   = dynamic(light: 0xFDECEC, dark: 0x33191B)
    static let warn         = dynamic(light: 0xC77D14, dark: 0xF5B14C)

    static let background   = dynamic(light: 0xF2F4F7, dark: 0x0A0C10)
    static let surface      = dynamic(light: 0xFFFFFF, dark: 0x151A21)
    static let surfaceAlt   = dynamic(light: 0xF5F7FA, dark: 0x1D232C)
    static let separator    = dynamic(light: 0xE7EBF0, dark: 0x252C36)

    static let textPrimary   = dynamic(light: 0x0F1419, dark: 0xF3F6F9)
    static let textSecondary = dynamic(light: 0x69747F, dark: 0x99A4B0)
    static let textTertiary  = dynamic(light: 0x9AA3AD, dark: 0x6C7783)

    static let cardRadius: CGFloat = 26
    static let fieldRadius: CGFloat = 16
    static let pagePadding: CGFloat = 20

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
