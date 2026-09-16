import SwiftUI
import VisionKit

/// In-app scanner for the pairing QR code on the device label. Works whether or not the system
/// Camera app knows how to open `garagelink://` links.
struct PairingQRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Point the camera at the QR code on the device."
    @State private var messageIsError = false
    @State private var handled = false
    let onLink: (PairingLink) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isAvailable {
                    QRScannerRepresentable { payload in
                        guard !handled else { return }
                        if let url = URL(string: payload), let link = PairingLink(url: url) {
                            handled = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onLink(link)
                            dismiss()
                        } else if !messageIsError {
                            message = "That QR code isn't a GarageLink pairing code."
                            messageIsError = true
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                    Text("Camera access is off. Enable it for GarageLink in Settings, or type the setup code instead.")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxHeight: .infinity)
                }

                Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // Scanning can only start once the view is in a window.
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                if let payload = barcode.payloadStringValue { onPayload(payload) }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue { onPayload(payload) }
        }
    }
}
