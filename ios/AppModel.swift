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

    /// Throwing variant for sheets: the caller shows the message inline,
    /// because the tab-level alert cannot appear above a presented sheet.
    func run(_ action: (HouseholdRepository) throws -> Void) throws {
        try action(repository)
        state = repository.state
    }

    static func normalizedJPEG(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else { throw OrderError.invalid("Das Foto konnte nicht gelesen werden.") }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.72), data.count <= 2_000_000 else {
            throw OrderError.invalid("Dieses Foto ist zu groß. Bitte wähle ein kleineres Bild.")
        }
        return data
    }

    func savePhoto(_ image: UIImage, pointID: UUID) {
        do {
            let data = try Self.normalizedJPEG(image)
            perform { try $0.addPhoto(RoomPhoto(pointID: pointID, jpegData: data)) }
        } catch { self.error = error.localizedDescription }
    }

    func addRoomPhoto(_ image: UIImage, roomID: UUID) throws {
        let data = try Self.normalizedJPEG(image)
        try run { try $0.addRoomPhoto(roomID: roomID, jpegData: data) }
    }

    // MARK: AI planning

    @Published var planningStatus: String?

    /// Asks the AI about each selected room in turn. Nothing is stored here;
    /// the user sees the preview first and starts it explicitly.
    func makePlan(roomIDs: [UUID], goal: Goal, minutes: Int, energy: Energy) async throws -> PlanPreview {
        defer { planningStatus = nil }
        let share = max(5, minutes / max(1, roomIDs.count))
        var parts: [RoomPlanPreview] = []
        for (index, id) in roomIDs.enumerated() {
            guard let room = state.rooms.first(where: { $0.id == id }) else { continue }
            planningStatus = roomIDs.count > 1
                ? "Die KI schaut sich \(room.name) an … (\(index + 1) von \(roomIDs.count))"
                : "Die KI schaut sich \(room.name) an …"
            let photos = Array(state.roomPhotos(id).suffix(6))
            let known = state.places.filter { $0.roomID == id }.map { state.path(for: $0.id) }
            let answer = try await AIService.analyze(roomName: room.name, photos: photos.map(\.jpegData), knownPlaces: known,
                                                     goal: goal, minutes: share, energy: energy)
            let (analysis, tasks) = answer.records(roomID: id, photoIDs: photos.map(\.id), goal: goal, minutes: share)
            parts.append(RoomPlanPreview(roomID: id, roomName: room.name, analysis: analysis, tasks: tasks))
        }
        return PlanPreview(rooms: parts, goal: goal, minutes: minutes, energy: energy)
    }

    func start(_ plan: PlanPreview) throws {
        try run { try $0.applyPlan(analyses: plan.rooms.map(\.analysis), tasks: plan.rooms.flatMap(\.tasks),
                                   goal: plan.goal, minutes: plan.minutes, energy: plan.energy) }
    }

    /// Room overview without starting a session: what is there, where are the problems.
    func lookAtRoom(_ roomID: UUID) async throws {
        let plan = try await makePlan(roomIDs: [roomID], goal: .order, minutes: 20, energy: .normal)
        guard let part = plan.rooms.first else { return }
        try run { try $0.addAnalysis(part.analysis) }
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

struct RoomPlanPreview: Identifiable {
    var id: UUID { roomID }
    let roomID: UUID
    let roomName: String
    let analysis: RoomAnalysis
    let tasks: [HouseholdTask]
}

struct PlanPreview {
    let rooms: [RoomPlanPreview]
    let goal: Goal
    let minutes: Int
    let energy: Energy
    var taskCount: Int { rooms.reduce(0) { $0 + $1.tasks.count } }
    var stepCount: Int { rooms.reduce(0) { $0 + $1.tasks.reduce(0) { $0 + $1.steps.count } } }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "Wie iPhone" : self == .light ? "Hell" : "Dunkel" }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
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
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            Group {
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
            .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
    }
}
