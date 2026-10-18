import SwiftUI
import AVFoundation
import VisionKit
import OrderCore

/// Live QR reader (VisionKit). Reports each recognised text once per call of `onScan`.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    static var isUsable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                   qualityLevel: .balanced, recognizesMultipleItems: false,
                                                   isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
                                                   isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        DispatchQueue.main.async { try? controller.startScanning() }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        private var lastText = ""
        private var lastTime = Date.distantPast
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        private func handle(_ items: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue else { continue }
                // The same code stays in view for a while; report it once per two seconds.
                if text == lastText, Date().timeIntervalSince(lastTime) < 2 { continue }
                lastText = text; lastTime = Date()
                onScan(text)
                return
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { handle(addedItems) }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { handle([item]) }
    }
}

/// Camera view plus a field for typing the printed code, with a clear message when scanning is not possible.
struct ScanPanel: View {
    let prompt: String
    let onText: (String) -> Void
    @State private var camera: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(prompt).font(.headline).multilineTextAlignment(.center)
            Group {
                if camera == .denied || camera == .restricted {
                    unavailable("Die Kamera ist für den Ordnungsplaner ausgeschaltet. Erlaube sie in den iPhone-Einstellungen oder tippe den Code unten ein.")
                } else if !QRScannerView.isUsable && camera != .notDetermined {
                    unavailable("Auf diesem Gerät kann die App keine QR-Codes lesen. Tippe den Code unten ein oder scanne mit der iPhone-Kamera.")
                } else {
                    QRScannerView(onScan: onText)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(minHeight: 280, maxHeight: 420)
                }
            }
            HStack {
                TextField("Code eintippen, z. B. K07", text: $typed)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("OK") { onText(typed); typed = "" }
                    .buttonStyle(.bordered).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            if camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Scan one place and hand it back.
struct PlaceScanSheet: View {
    let prompt: String
    let onPlace: (StoragePlace) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScanPanel(prompt: prompt) { text in
                    if let place = model.state.place(forScan: text) {
                        message = nil
                        dismiss()
                        onPlace(place)
                    } else {
                        message = "Dieser Code gehört zu keinem deiner Lagerorte."
                    }
                }
                if let message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}
