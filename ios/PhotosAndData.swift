import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import OrderCore
import UniformTypeIdentifiers

struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapture
        init(parent: CameraCapture) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct DataSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument = HouseholdDocument()
    @State private var pendingRestore: Data?
    @State private var restoreSummary = ""
    @State private var confirmingRestore = false
    var body: some View {
        List {
            Section("Deine Daten") {
                Button("Sicherung exportieren", systemImage: "square.and.arrow.up") {
                    do { exportDocument = HouseholdDocument(data: try model.repository.exportData()); exporting = true }
                    catch { model.error = error.localizedDescription }
                }
                Button("Sicherung wiederherstellen", systemImage: "square.and.arrow.down") { importing = true }
                Text("Die JSON-Sicherung enthält auch private Fotos und Raumscans. Vor einer Wiederherstellung wird der bisherige Stand zusätzlich lokal gesichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sicherung")
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Ordnungsplaner-Sicherung") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 100_000_000 else { throw OrderError.invalid("Diese Sicherung ist größer als 100 MB.") }
                let data = try Data(contentsOf: url)
                let preview = try HouseholdRepository.decode(data)
                pendingRestore = data
                restoreSummary = "\(preview.rooms.count) Räume, \(preview.tasks.count) Aufgaben, \(preview.photos.count) Fotos. Dieser Stand ersetzt die aktuellen Daten."
                confirmingRestore = true
            } catch { model.error = error.localizedDescription }
        }
        .confirmationDialog("Sicherung übernehmen?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Aktuellen Stand ersetzen", role: .destructive) {
                if let bytes = pendingRestore { _ = model.restore(bytes) }
                pendingRestore = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRestore = nil }
        } message: { Text(restoreSummary) }
    }
}
