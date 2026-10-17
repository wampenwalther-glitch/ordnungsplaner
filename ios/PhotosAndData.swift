import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import OrderCore
import UniformTypeIdentifiers

struct PhotoPointView: View {
    let point: PhotoPoint
    @EnvironmentObject private var model: AppModel
    @State private var selection: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var loading = false

    private var photos: [RoomPhoto] {
        model.state.photos.filter { $0.pointID == point.id }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            Section {
                Text(point.name).font(.headline)
                Text("Nutze möglichst dieselbe Standposition und Blickrichtung. Neue Fotos ändern keine Aufgaben und keine bestätigten Fundorte automatisch.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Foto aufnehmen", systemImage: "camera") {
                    Task {
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            model.error = "Hier ist keine Kamera verfügbar. Verwende ein vorhandenes Foto."; return
                        }
                        if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true }
                        else { model.error = "Kamerazugriff fehlt. Du kannst in den Einstellungen die Kamera erlauben oder ein Foto auswählen." }
                    }
                }
                PhotosPicker(selection: $selection, matching: .images) { Label("Foto auswählen", systemImage: "photo") }
                    .disabled(loading)
                if loading { ProgressView("Foto wird vorbereitet…") }
            }
            if let first = photos.first, let last = photos.last, photos.count > 1 {
                Section("Erstes und neuestes Foto") {
                    PhotoComparison(first: first, last: last).frame(height: 340)
                    Text("Vergleich anhand deiner Fotopunkt-Zuordnung. Abweichende Perspektiven werden noch nicht automatisch erkannt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Aufnahmen") {
                ForEach(photos.reversed()) { photo in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Erfasst: \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        if let image = UIImage(data: photo.jpegData) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Foto vom Fotopunkt \(point.name)")
                        }
                    }
                }
                if photos.isEmpty { Text("Noch keine Aufnahme an diesem Fotopunkt.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Fotopunkt")
        .onChange(of: selection) { _, item in
            guard let item else { return }
            loading = true
            Task {
                defer { loading = false; selection = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20_000_000,
                          let image = UIImage(data: data) else {
                        throw OrderError.invalid("Das Bild ist nicht lesbar oder größer als 20 MB.")
                    }
                    model.savePhoto(image, pointID: point.id)
                } catch { model.error = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in model.savePhoto(image, pointID: point.id) }
        }
    }
}

private struct PhotoComparison: View {
    let first: RoomPhoto
    let last: RoomPhoto
    @State private var fraction = 0.5
    var body: some View {
        VStack {
            GeometryReader { geometry in
                ZStack {
                    Color(.secondarySystemBackground)
                    if let image = UIImage(data: last.jpegData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if let image = UIImage(data: first.jpegData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                            .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * fraction) }
                    }
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: geometry.size.width * (fraction - 0.5))
                }.clipped()
            }
            Slider(value: $fraction, in: 0...1).accessibilityLabel("Anteil des ersten Fotos")
            HStack {
                Text("Erstes erfasst: \(first.createdAt.formatted(date: .abbreviated, time: .omitted))")
                Spacer()
                Text("Neu erfasst: \(last.createdAt.formatted(date: .abbreviated, time: .omitted))")
            }.font(.caption)
        }
    }
}

private struct CameraCapture: UIViewControllerRepresentable {
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
            Section("Stand dieses Prototyps") {
                Text("Räume, Lagerorte und Kisten; Aufgaben mit bestätigten Handgriffen; Pause und Fortsetzung; Fotos an festen Punkten und Vergleich; optionale LiDAR-Erfassung.")
                Text("Noch offen: KI-Fotoanalyse, Live-Referenzüberlagerung, Erinnerungen und Routinen, Gerätesynchronisation sowie zusätzliche Umzugsfunktionen.")
                    .foregroundStyle(.secondary)
                Text("Aufgaben werden ausschließlich aus deinen Eingaben ausgewählt. Es gibt keine versteckten Foto-Uploads und keinen eingebauten API-Schlüssel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Mehr")
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
