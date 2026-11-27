import AVFoundation
import SwiftUI
import VisionKit

/// Full-screen sheet that scans a `meterkat://pair` QR code with the camera
/// and hands back the parsed config. Present it with `.sheet` or
/// `.fullScreenCover`; it dismisses itself after a successful scan.
struct QRScannerSheet: View {
    var onScan: (CompanionConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint = "Point the camera at the QR code shown by the Meterkat menu bar app or `meterkat pair`."
    @State private var didScan = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .safeAreaInset(edge: .bottom) {
                Text(hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                    .padding()
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .authorized:
            if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                DataScannerRepresentable(onPayload: handle)
                    .ignoresSafeArea()
            } else {
                unavailable("This device can't scan codes right now. Paste the pairing link instead.")
            }
        case .notDetermined:
            ProgressView().tint(.white)
        default:
            VStack(spacing: 16) {
                unavailable("Camera access is off for Meterkat.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(message, systemImage: "camera.metering.unknown")
            .foregroundStyle(.white)
    }

    private func handle(_ payload: String) {
        guard !didScan else { return }
        guard let config = CompanionConfig(pairingString: payload) else {
            hint = "That QR code isn't a Meterkat pairing code."
            return
        }
        didScan = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan(config)
        dismiss()
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    var onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in addedItems {
                if let payload = code.payloadStringValue { onPayload(payload) }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case let .barcode(code) = item, let payload = code.payloadStringValue { onPayload(payload) }
        }
    }
}
