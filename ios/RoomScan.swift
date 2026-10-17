import SwiftUI
import RoomPlan
import UIKit
import AVFoundation

/// Public result of a room scan handed back to the host app for persistence.
struct RoomScanResult {
    let walls: Int
    let doors: Int
    let windows: Int
    let objects: Int
    let encodedRoom: Data
}

/// Sheet presented by the host app to let the user optionally scan a room
/// with RoomPlan (LiDAR devices) or fall back to a simple photo-based
/// explanation on unsupported hardware. The sheet owns its own dismissal;
/// the host only needs to provide `onSave` and present this in `.sheet`.
struct RoomScanSheet: View {
    let roomName: String
    let onSave: (RoomScanResult) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)

    /// Checked once per sheet lifetime; RoomPlan support does not change
    /// while the app is running.
    private let isRoomPlanSupported = RoomCaptureSession.isSupported

    var body: some View {
        NavigationStack {
            if isRoomPlanSupported && cameraAccess == .authorized {
                RoomPlanScanContainer(
                    roomName: roomName,
                    onCancel: { dismiss() },
                    onSave: { result in
                        try onSave(result)
                        dismiss()
                    }
                )
                .interactiveDismissDisabled()
            } else if !isRoomPlanSupported {
                UnsupportedDeviceFallback(roomName: roomName, onClose: { dismiss() })
            } else if cameraAccess == .notDetermined {
                ProgressView("Kamerazugriff wird angefragt…")
            } else {
                VStack(spacing: 16) {
                    Text("Kamerazugriff für den Raumscan")
                        .font(.headline)
                    Text("Erlaube die Kamera in den Einstellungen oder schließe den Scan und verwende vorhandene Fotos.")
                        .multilineTextAlignment(.center)
                    Link("Einstellungen öffnen", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Button("Schließen") { dismiss() }
                }
                .padding()
            }
        }
        .task {
            guard isRoomPlanSupported else { return }
            if cameraAccess == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraAccess = granted ? .authorized : .denied
            } else {
                cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

// MARK: - Fallback for devices without LiDAR / RoomPlan support

/// Explains that 3D room scanning is unavailable and that the existing
/// photo-based flow (owned by the host app) should be used instead.
/// Deliberately does not touch RoomCaptureView or any RoomPlan session.
private struct UnsupportedDeviceFallback: View {
    let roomName: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("3D-Scan nicht verfügbar")
                .font(.headline)
            Text("Dieses Gerät unterstützt keinen 3D-Raumscan (RoomPlan benötigt einen LiDAR-Scanner). Du kannst \(roomName) stattdessen mit normalen Fotos dokumentieren – das funktioniert auf jedem iPhone.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Schließen", action: onClose)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding()
        .navigationTitle(roomName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fertig", action: onClose)
            }
        }
    }
}

// MARK: - RoomPlan scan flow (supported devices only)

/// Drives the scan → stop → review → save/retry lifecycle. This view is
/// only ever instantiated when `RoomCaptureSession.isSupported` is true,
/// so `RoomCaptureView` is never created on unsupported hardware.
private struct RoomPlanScanContainer: View {
    let roomName: String
    let onCancel: () -> Void
    let onSave: (RoomScanResult) throws -> Void

    private enum Phase {
        case scanning
        case review(RoomScanResult)
        case failed(String)
    }

    @State private var phase: Phase = .scanning
    /// Holds the capture view coordinator across the view's lifetime so
    /// start/stop calls act on the same `RoomCaptureSession`.
    @State private var controller = RoomCaptureController()
    /// Guards against `onSave` firing twice from a rapid double tap on
    /// "Übernehmen" before the sheet has a chance to dismiss.
    @State private var hasConfirmed = false
    @State private var isProcessing = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .scanning:
                RoomCaptureRepresentable(controller: controller) { result in
                    switch result {
                    case .success(let summary):
                        buildResult(from: summary)
                    case .failure(let error):
                        phase = .failed(error.localizedDescription)
                    }
                }
                .id(controller.id)
                .overlay {
                    if isProcessing {
                        ProgressView("Scan wird verarbeitet…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .ignoresSafeArea(edges: .bottom)

                scanningToolbar

            case .review(let result):
                ReviewSummaryView(
                    roomName: roomName,
                    result: result,
                    saveError: saveError,
                    onRetry: {
                        controller.cancel()
                        controller = RoomCaptureController()
                        isProcessing = false
                        hasConfirmed = false
                        saveError = nil
                        phase = .scanning
                    },
                    onConfirm: {
                        guard !hasConfirmed else { return }
                        hasConfirmed = true
                        do { try onSave(result) }
                        catch {
                            hasConfirmed = false
                            saveError = "Der Scan konnte nicht gespeichert werden: \(error.localizedDescription)"
                        }
                    }
                )

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Scan fehlgeschlagen")
                        .font(.headline)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Erneut versuchen") {
                        controller.cancel()
                        controller = RoomCaptureController()
                        isProcessing = false
                        hasConfirmed = false
                        saveError = nil
                        phase = .scanning
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(roomName)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") {
                    controller.cancel()
                    onCancel()
                }
            }
        }
        .onDisappear { controller.cancel() }
        .task(id: isProcessing) {
            guard isProcessing else { return }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard case .scanning = phase, isProcessing else { return }
            controller.cancel()
            phase = .failed("Die Verarbeitung hat zu lange gedauert. Bitte versuche den Scan erneut.")
        }
    }

    @ViewBuilder
    private var scanningToolbar: some View {
        HStack {
            Spacer()
            Button {
                isProcessing = true
                controller.stop()
            } label: {
                Label("Scan beenden", systemImage: "stop.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
            .padding()
            Spacer()
        }
    }

    /// Preserve the complete geometry; counts alone cannot recreate a room.
    private func buildResult(from room: CapturedRoom) {
        do {
            let data = try JSONEncoder().encode(room)
            let result = RoomScanResult(
                walls: room.walls.count,
                doors: room.doors.count,
                windows: room.windows.count,
                objects: room.objects.count,
                encodedRoom: data
            )
            phase = .review(result)
        } catch {
            phase = .failed("Die Scan-Daten konnten nicht gespeichert werden: \(error.localizedDescription)")
        }
    }
}

// MARK: - Review step

/// Shown after a scan completes, before anything is persisted. The user
/// must explicitly confirm to hand the result to the host app, or choose
/// to discard it and scan again.
private struct ReviewSummaryView: View {
    let roomName: String
    let result: RoomScanResult
    let saveError: String?
    let onRetry: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Scan abgeschlossen")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(label: "Wände", value: result.walls)
                SummaryRow(label: "Türen", value: result.doors)
                SummaryRow(label: "Fenster", value: result.windows)
                SummaryRow(label: "Objekte", value: result.objects)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Nicht gespeichert: \(saveError)")
            }

            HStack(spacing: 12) {
                Button("Erneut scannen", action: onRetry)
                    .buttonStyle(.bordered)
                Button("Übernehmen", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

private struct SummaryRow: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .fontWeight(.semibold)
        }
    }
}

// MARK: - RoomCaptureView bridging

/// Thin controller shared between the SwiftUI container and the
/// `UIViewRepresentable` so "stop scanning" can be triggered from a
/// SwiftUI button without reaching into UIKit view internals.
private final class RoomCaptureController {
    let id = UUID()
    fileprivate weak var captureView: RoomCaptureView?
    fileprivate var hasStarted = false
    fileprivate var isCancelled = false

    func start() {
        guard !hasStarted, !isCancelled, let captureView else { return }
        hasStarted = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stop() {
        captureView?.captureSession.stop()
    }

    func cancel() {
        isCancelled = true
        stop()
    }
}

/// Bridges `RoomCaptureView` into SwiftUI. Starts the underlying
/// `RoomCaptureSession` exactly once when the view is created; subsequent
/// `updateUIView` calls (e.g. from SwiftUI state changes elsewhere in the
/// tree) never restart the session.
private struct RoomCaptureRepresentable: UIViewRepresentable {
    let controller: RoomCaptureController
    let onFinish: (Result<CapturedRoom, Error>) -> Void

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = context.coordinator
        controller.captureView = view
        controller.start()
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Intentionally empty: starting/stopping the session is driven
        // explicitly by the user via `controller.stop()` and the one-time
        // start in `makeUIView`'s coordinator setup, not by SwiftUI
        // re-rendering this representable.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onFinish: onFinish)
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        coordinator.controller.isCancelled = true
        uiView.captureSession.stop()
    }

    @objc(OrderRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureViewDelegate {
        let controller: RoomCaptureController
        let onFinish: (Result<CapturedRoom, Error>) -> Void
        /// Ensures the completion is only forwarded once, even if the
        /// delegate is invoked more than expected.
        private var didFinish = false

        init(controller: RoomCaptureController, onFinish: @escaping (Result<CapturedRoom, Error>) -> Void) {
            self.controller = controller
            self.onFinish = onFinish
            super.init()
        }

        // RoomCaptureViewDelegate inherits NSCoding. This delegate is created
        // only by UIViewRepresentable; it is never restored from an archive.
        required init?(coder: NSCoder) { return nil }
        func encode(with coder: NSCoder) {}

        // Called when the user stops the session (or it stops for another
        // reason) and RoomPlan is about to present its own results view.
        // true enables RoomPlan processing and its result preview. Returning
        // false would require our own RoomBuilder processing pipeline.
        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            guard !controller.isCancelled, !didFinish else { return false }
            if let error {
                finish(.failure(error))
                return false
            }
            return true
        }

        // Called once RoomPlan has finished processing the captured data
        // into a `CapturedRoom`. This is where the final result (or
        // error) becomes available.
        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            if let error {
                finish(.failure(error))
            } else {
                finish(.success(processedResult))
            }
        }

        private func finish(_ result: Result<CapturedRoom, Error>) {
            DispatchQueue.main.async { [self] in
                guard !didFinish, !controller.isCancelled else { return }
                didFinish = true
                onFinish(result)
            }
        }
    }
}
