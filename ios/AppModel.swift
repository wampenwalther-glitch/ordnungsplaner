import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OrderCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: HouseholdState
    @Published var error: String?
    let repository: HouseholdRepository
    let fileURL: URL

    init() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ordnungsplaner", isDirectory: true)
        fileURL = directory.appendingPathComponent("household.json")
        repository = try HouseholdRepository(storage: FileStateStorage(fileURL: fileURL))
        state = repository.state
    }

    @discardableResult
    func perform(_ action: (HouseholdRepository) throws -> Void) -> Bool {
        do {
            try action(repository)
            state = repository.state
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func saveScan(_ scan: RoomScanResult, roomID: UUID) throws {
        try repository.addScan(RoomScanRecord(roomID: roomID, walls: scan.walls, doors: scan.doors,
            windows: scan.windows, objects: scan.objects, encodedRoom: scan.encodedRoom))
        state = repository.state
    }

    func savePhoto(_ image: UIImage, pointID: UUID) {
        guard image.size.width > 0, image.size.height > 0 else { error = "Das Foto konnte nicht gelesen werden."; return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.72), data.count <= 2_000_000 else {
            error = "Dieses Foto ist zu groß. Bitte wähle ein kleineres Bild."; return
        }
        perform { try $0.addPhoto(RoomPhoto(pointID: pointID, jpegData: data)) }
    }

    func restore(_ bytes: Data) -> Bool {
        perform { repository in
            let old = try repository.exportData()
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try old.write(to: backup.appendingPathComponent("before-restore-\(UUID().uuidString).json"), options: .atomic)
            try repository.replace(with: bytes)
        }
    }
}

struct HouseholdDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw OrderError.invalid("Datei nicht lesbar.") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class AppLoader: ObservableObject {
    @Published var model: AppModel?
    @Published var error: String?
    init() { load() }
    func load() {
        do { model = try AppModel(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

@main
struct OrdnungsplanerApp: App {
    @StateObject private var loader = AppLoader()
    var body: some Scene {
        WindowGroup {
            if let model = loader.model {
                PlannerTabs().environmentObject(model)
            } else {
                ContentUnavailableView {
                    Label("Daten konnten nicht geladen werden", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(loader.error ?? "Unbekannter Fehler")
                    Text("Die vorhandene Datei bleibt unverändert. Es wurde keine leere Wohnung darüber gespeichert.")
                } actions: {
                    Button("Erneut versuchen") { loader.load() }
                }
            }
        }
    }
}
