import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OrderCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: HouseholdState {
        // Keeps the timer notifications in step with every change of the running round.
        didSet { TimerAlerts.shared.sync(state.session) }
    }
    @Published var error: String?
    let repository: HouseholdRepository
    let fileURL: URL

    init() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ordnungsplaner", isDirectory: true)
        fileURL = directory.appendingPathComponent("household.json")
        repository = try HouseholdRepository(storage: FileStateStorage(fileURL: fileURL))
        state = repository.state
        TimerAlerts.shared.install()
        TimerAlerts.shared.sync(state.session)
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

    func addPhoto(_ image: UIImage, to target: PhotoTarget) throws {
        let data = try Self.normalizedJPEG(image)
        switch target {
        case .room(let id): try run { try $0.addRoomPhoto(roomID: id, jpegData: data) }
        case .place(let id): try run { try $0.addPlacePhoto(placeID: id, jpegData: data) }
        }
    }

    // MARK: Storage

    static let autoDeleteKey = "autoDeleteAnalyzedPhotos"

    /// Removes the photos the AI has already looked at; what it found stays.
    @discardableResult
    func deleteAnalyzedPhotos() -> Bool {
        perform { try $0.deletePhotos(ids: $0.state.allOutdatedPhotos.map(\.id)) }
    }

    /// Frees space right after an analysis when the user asked for it.
    private func autoCleanIfWanted() {
        if UserDefaults.standard.bool(forKey: Self.autoDeleteKey) { deleteAnalyzedPhotos() }
    }

    // MARK: Stock-taking of storage places

    @Published private(set) var inventoryStatus: [UUID: AnalysisStatus] = [:]

    /// The AI lists what the photos of one storage place show. Keeps running when
    /// the user leaves the screen; the result is saved.
    func inventoryPlace(_ placeID: UUID, mode: AIService.InventoryMode) {
        if inventoryStatus[placeID] == .running { return }
        guard let place = state.places.first(where: { $0.id == placeID }) else { return }
        let photos = Array(state.placePhotos(placeID).suffix(6))
        guard !photos.isEmpty else { inventoryStatus[placeID] = .failed("Mach zuerst ein Foto vom Inhalt."); return }
        inventoryStatus[placeID] = .running
        let roomName = state.rooms.first { $0.id == place.roomID }?.name ?? "Raum"
        let path = state.path(for: placeID)
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "KI-Bestandsaufnahme") {
            UIApplication.shared.endBackgroundTask(background)
        }
        let backgroundID = background
        Task { @MainActor in
            defer { if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) } }
            do {
                let answer = try await AIService.inventory(placeName: path, roomName: roomName,
                                                           photos: photos.map(\.jpegData), mode: mode)
                try run { try $0.recordInventory(answer.record(placeID: placeID, photoIDs: photos.map(\.id))) }
                inventoryStatus[placeID] = nil
                autoCleanIfWanted()
            } catch {
                inventoryStatus[placeID] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: AI planning

    @Published var planningStatus: String?

    /// Builds the plan for each selected room. Order of preference per room:
    /// 1. AI from the saved analysis (text only, fast) when the photos haven't changed,
    /// 2. AI looking at the photos,
    /// 3. the offline planner (built-in and learned routines) – used when the AI is not
    ///    connected, has no photos to look at, or fails (limit reached, no network, …).
    /// Nothing is stored here; the user sees the preview first and starts it explicitly.
    func makePlan(roomIDs: [UUID], goal: Goal, minutes: Int, energy: Energy,
                  observed: Set<Clutter> = []) async throws -> PlanPreview {
        defer { planningStatus = nil }
        let share = max(5, minutes / max(1, roomIDs.count))
        var parts: [RoomPlanPreview] = []
        for (index, id) in roomIDs.enumerated() {
            guard let room = state.rooms.first(where: { $0.id == id }) else { continue }
            let suffix = roomIDs.count > 1 ? " (\(index + 1) von \(roomIDs.count))" : ""
            var offlineReason: String?
            var result: (RoomAnalysis, [HouseholdTask])?

            if !AIAccess.isReady {
                offlineReason = "Die KI ist nicht verbunden."
            } else {
                let photos = state.photosForAnalysis(id)
                let known = state.places.filter { $0.roomID == id }.map { state.path(for: $0.id) }
                do {
                    if state.isAnalysisCurrent(id), let saved = state.latestAIAnalysis(id) {
                        planningStatus = "Die KI plant \(room.name) …\(suffix)"
                        let answer = try await AIService.analyze(roomName: room.name, photos: [], knownPlaces: known,
                                                                 goal: goal, minutes: share, energy: energy, analysis: saved)
                        result = answer.records(roomID: id, photoIDs: saved.photoIDs, goal: goal, minutes: share)
                    } else if photos.isEmpty {
                        offlineReason = "Für diesen Raum gibt es noch keine Fotos."
                    } else {
                        planningStatus = "Die KI schaut sich \(room.name) an …\(suffix)"
                        let answer = try await AIService.analyze(roomName: room.name, photos: photos.map(\.jpegData), knownPlaces: known,
                                                                 goal: goal, minutes: share, energy: energy)
                        result = answer.records(roomID: id, photoIDs: photos.map(\.id), goal: goal, minutes: share)
                    }
                } catch {
                    offlineReason = error.localizedDescription
                }
            }

            if let result, !result.1.isEmpty {
                parts.append(RoomPlanPreview(roomID: id, roomName: room.name, analysis: result.0, tasks: result.1, offlineReason: nil))
            } else {
                if result != nil && offlineReason == nil { offlineReason = "Die KI hat keine passenden Handgriffe vorgeschlagen." }
                planningStatus = "Plan aus Routinen für \(room.name) …\(suffix)"
                let outcome = LocalPlanner.plan(roomID: id, roomName: room.name, goal: goal, minutes: share, energy: energy,
                                                observed: observed, learned: state.learned, previous: state.latestAIAnalysis(id))
                parts.append(RoomPlanPreview(roomID: id, roomName: room.name, analysis: outcome.analysis, tasks: outcome.tasks,
                                             offlineReason: offlineReason ?? "Aus eingebauten Routinen."))
            }
        }
        return PlanPreview(rooms: parts, goal: goal, minutes: minutes, energy: energy)
    }

    func start(_ plan: PlanPreview) throws {
        try run { try $0.applyPlan(analyses: plan.rooms.map(\.analysis), tasks: plan.rooms.flatMap(\.tasks),
                                   goal: plan.goal, minutes: plan.minutes, energy: plan.energy) }
    }

    // MARK: Background analysis of room photos

    enum AnalysisStatus: Equatable {
        case queued, running
        case failed(String)
    }

    @Published private(set) var analysisStatus: [UUID: AnalysisStatus] = [:]
    /// Rooms finished / total in the current batch; nil when idle.
    @Published private(set) var analysisProgress: (done: Int, total: Int)?
    private var analysisQueue: [UUID] = []
    private var analysisWorker: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    var isAnalyzing: Bool { analysisProgress != nil }

    /// Rooms with photos the AI has not looked at in their current form.
    var roomsNeedingAnalysis: [Room] {
        state.rooms.filter { room in
            guard !state.roomPhotos(room.id).isEmpty, !state.isAnalysisCurrent(room.id) else { return false }
            switch analysisStatus[room.id] {
            case .queued, .running: return false
            default: return true
            }
        }
    }

    /// Queues rooms for the AI to look at. Keeps running when the user leaves the
    /// screen; the result is saved and feeds the offline planner later.
    func analyzeRooms(_ ids: [UUID]) {
        let fresh = ids.filter { id in
            guard let status = analysisStatus[id] else { return true }
            if case .failed = status { return true }
            return false
        }
        guard !fresh.isEmpty else { return }
        for id in fresh { analysisStatus[id] = .queued }
        analysisQueue.append(contentsOf: fresh)
        analysisProgress = (analysisProgress?.done ?? 0, (analysisProgress?.total ?? 0) + fresh.count)
        guard analysisWorker == nil else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KI-Auswertung") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        analysisWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while let id = self.analysisQueue.first {
                self.analysisQueue.removeFirst()
                await self.analyzeOne(id)
                if let progress = self.analysisProgress { self.analysisProgress = (progress.done + 1, progress.total) }
            }
            self.analysisProgress = nil
            self.analysisWorker = nil
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func analyzeOne(_ id: UUID) async {
        guard let room = state.rooms.first(where: { $0.id == id }) else { analysisStatus[id] = nil; return }
        analysisStatus[id] = .running
        let photos = state.photosForAnalysis(id)
        guard !photos.isEmpty else { analysisStatus[id] = .failed("Für diesen Raum gibt es noch keine Fotos."); return }
        do {
            let known = state.places.filter { $0.roomID == id }.map { state.path(for: $0.id) }
            let answer = try await AIService.analyze(roomName: room.name, photos: photos.map(\.jpegData), knownPlaces: known,
                                                     goal: .order, minutes: 20, energy: .normal)
            let (analysis, tasks) = answer.records(roomID: id, photoIDs: photos.map(\.id), goal: .order, minutes: 20)
            try run { try $0.recordAnalysis(analysis, learningFrom: tasks) }
            analysisStatus[id] = nil
            autoCleanIfWanted()
        } catch {
            analysisStatus[id] = .failed(error.localizedDescription)
        }
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
    /// Set when this room's plan was built without the AI; says why.
    let offlineReason: String?
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
