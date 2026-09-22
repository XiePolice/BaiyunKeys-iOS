import CoreImage.CIFilterBuiltins
import UIKit

enum QRCode {

    /// 用 CoreImage 生成二维码。`correction` 走中等纠错（约 15% 容错），
    /// 门禁参数长度不大，选 `.h` 也没多少代价。
    static func image(from text: String, side: CGFloat = 512, correction: Correction = .m) -> UIImage? {
        guard let data = text.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = correction.rawValue

        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    enum Correction: String {
        case l = "L"   // 约 7%
        case m = "M"   // 约 15%
        case q = "Q"   // 约 25%
        case h = "H"   // 约 30%
    }
}
