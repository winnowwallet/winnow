import AVFoundation
import SwiftUI
import VisionKit

/// Scanning supplies text to the editable form. It never approves a payment.
struct PaymentScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let scanned: (String) -> Void
    @State private var authorized = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if authorized && error == nil && DataScannerViewController.isAvailable {
                    PaymentScanner(scanned: scanned, failed: { error = $0 }).ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Camera scanning unavailable", systemImage: "qrcode.viewfinder",
                        description: Text(error ?? "You can paste or type the invoice instead."))
                }
            }
            .navigationTitle("Scan invoice")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("lightningScanCancel") } }
            .task {
                guard DataScannerViewController.isSupported else { return }
                authorized = await AVCaptureDevice.requestAccess(for: .video)
                if !authorized { error = "Allow camera access in Settings, or paste the invoice." }
            }
        }
    }
}

private struct PaymentScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void, failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let view = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        view.delegate = context.coordinator
        Task { @MainActor in do { try view.startScanning() } catch { failed(error.localizedDescription) } }
        return view
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ view: DataScannerViewController, coordinator: Coordinator) { view.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        var delivered = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered, let item = addedItems.first, case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { return }
            delivered = true; dataScanner.stopScanning(); scanned(text)
        }
    }
}
