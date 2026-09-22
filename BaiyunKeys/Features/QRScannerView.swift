import SwiftUI
import VisionKit

/// 用 VisionKit 的 `DataScannerViewController` 扫码。识别到第一个二维码就 `onScan`
/// 一次，接着 `dismiss` 关闭 sheet。需要 iOS 16+ + A12 及以上设备；
/// 用前先看 `isSupported`。
struct QRScannerView: UIViewControllerRepresentable {

    /// 系统是否支持 DataScannerViewController。老设备（iPhone X 及以前）不支持，
    /// 调用方看到 false 就用别的路径。
    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    let onScan: (String) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onDismiss: () -> Void
        /// 防止扫到之后 delegate 再回调导致连续触发。
        private var hasHit = false

        init(onScan: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
            self.onScan = onScan
            self.onDismiss = onDismiss
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !hasHit else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    hasHit = true
                    dataScanner.stopScanning()
                    onScan(payload)
                    onDismiss()
                    return
                }
            }
        }
    }
}
