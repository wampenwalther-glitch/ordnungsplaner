import Foundation

public protocol StateStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public struct FileStateStorage: StateStorage {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }
    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// One synchronous transaction per user action. Publish UI state only AFTER
/// validation, encoding and the atomic file replacement have all succeeded.
/// The iOS host calls this repository exclusively on its main actor.
public final class HouseholdRepository {
    public private(set) var state: HouseholdState
    private let storage: StateStorage

    public init(storage: StateStorage) throws {
        self.storage = storage
        if let bytes = try storage.load() {
            state = try Self.decode(bytes)
        } else {
            state = HouseholdState()
        }
    }

    public static func decode(_ data: Data) throws -> HouseholdState {
        struct Envelope: Decodable { let schemaVersion: Int }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == HouseholdState.currentSchema else {
            throw OrderError.invalid("Diese Datenversion wird noch nicht unterstützt. Die vorhandenen Daten wurden nicht verändert.")
        }
        let state = try JSONDecoder().decode(HouseholdState.self, from: data)
        try validate(state)
        return state
    }

    public func exportData() throws -> Data { try Self.encode(state) }

    public func replace(with data: Data) throws {
        var restored = try Self.decode(data)
        restored.undoRecord = nil
        let bytes = try Self.encode(restored)
        try storage.save(bytes)
        state = restored
    }

    private static func encode(_ state: HouseholdState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    private func transaction(keepingUndo: Bool = false, _ change: (inout HouseholdState) throws -> Void) throws {
        var candidate = state
        if !keepingUndo { candidate.undoRecord = nil }
        try change(&candidate)
        try Self.validate(candidate)
        let bytes = try Self.encode(candidate)
        try storage.save(bytes)
        state = candidate
    }

    public func addRoom(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try transaction { $0.rooms.append(Room(name: name)) }
    }

    public func addPlace(_ place: StoragePlace) throws {
        try transaction { $0.places.append(place) }
    }

    public func movePlace(id: UUID, parentID: UUID?) throws {
        try transaction { state in
            guard let index = state.places.firstIndex(where: { $0.id == id }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            state.places[index].parentID = parentID
        }
    }

    public func addTask(_ task: HouseholdTask) throws {
        try transaction { $0.tasks.append(task) }
    }

    public func addPhotoPoint(_ point: PhotoPoint) throws {
        try transaction { $0.photoPoints.append(point) }
    }

    public func addPhoto(_ photo: RoomPhoto) throws {
        try transaction { $0.photos.append(photo) }
    }

    public func addScan(_ scan: RoomScanRecord) throws {
        try transaction { $0.scans.append(scan) }
    }

    /// Stores an overview photo of a room. The room's automatic photo point is
    /// created in the same transaction on first use.
    public func addRoomPhoto(roomID: UUID, jpegData: Data, at date: Date = Date()) throws {
        try transaction { state in
            guard state.rooms.contains(where: { $0.id == roomID }) else {
                throw OrderError.invalid("Dieser Raum existiert nicht mehr.")
            }
            let pointID: UUID
            if let point = state.photoPoints.first(where: { $0.roomID == roomID && $0.name == HouseholdState.roomPhotoPointName }) {
                pointID = point.id
            } else {
                let point = PhotoPoint(roomID: roomID, name: HouseholdState.roomPhotoPointName)
                state.photoPoints.append(point)
                pointID = point.id
            }
            state.photos.append(RoomPhoto(pointID: pointID, createdAt: date, jpegData: jpegData))
        }
    }

    public func removePhoto(id: UUID) throws {
        try transaction { state in
            guard let index = state.photos.firstIndex(where: { $0.id == id }) else {
                throw OrderError.invalid("Dieses Foto existiert nicht mehr.")
            }
            state.photos.remove(at: index)
        }
    }

    /// Removes an open task nobody has worked on yet (e.g. an old AI suggestion).
    /// Tasks with confirmed steps or inside the running session stay.
    public func removeTask(id: UUID) throws {
        try transaction { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else {
                throw OrderError.invalid("Diese Aufgabe existiert nicht mehr.")
            }
            if let session = state.session, session.status != .finished, session.taskIDs.contains(id) {
                throw OrderError.invalid("Diese Aufgabe gehört zur laufenden Runde. Beende die Runde zuerst.")
            }
            guard !state.events.contains(where: { $0.taskID == id }) else {
                throw OrderError.invalid("Hier wurden schon Handgriffe bestätigt. Die Aufgabe bleibt als Verlauf erhalten.")
            }
            state.tasks.remove(at: index)
            if let session = state.session, session.taskIDs.contains(id) { state.session = nil }
        }
    }

    public func addAnalysis(_ analysis: RoomAnalysis) throws {
        try transaction { $0.analyses.append(analysis) }
    }

    /// Saves the AI analyses with their tasks and starts one session over all
    /// of them – all or nothing, so a failed write never leaves half a plan.
    public func applyPlan(analyses: [RoomAnalysis], tasks: [HouseholdTask], goal: Goal, minutes: Int, energy: Energy) throws {
        try transaction { state in
            guard state.session == nil || state.session?.status == .finished else {
                throw OrderError.invalid("Es läuft noch eine Aufräumrunde. Mach dort weiter oder beende sie zuerst.")
            }
            guard !tasks.isEmpty, minutes > 0 else {
                throw OrderError.invalid("Es wurden keine Handgriffe vorgeschlagen. Versuche es mit anderen Fotos oder mehr Zeit.")
            }
            state.analyses.append(contentsOf: analyses)
            state.tasks.append(contentsOf: tasks)
            state.session = WorkSession(taskIDs: tasks.map(\.id), goal: goal, timeBudget: minutes, energy: energy)
        }
    }

    /// Turns places the AI observed into real storage places. Only called after
    /// an explicit user action; names already present in the room are skipped.
    @discardableResult
    public func adoptDetectedPlaces(roomID: UUID, _ detected: [DetectedPlace]) throws -> Int {
        var added = 0
        try transaction { state in
            added = 0
            for item in detected {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !state.places.contains(where: {
                    $0.roomID == roomID && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) else { continue }
                state.places.append(StoragePlace(roomID: roomID, name: name, kind: item.kind == "kiste" ? .box : .storage))
                added += 1
            }
        }
        return added
    }

    public func suggestedTasks(goal: Goal, minutes: Int, energy: Energy) -> [HouseholdTask] {
        var remaining = max(0, minutes - (minutes >= 10 ? 2 : 1))
        var selected: [HouseholdTask] = []
        for task in state.tasks.sorted(by: { $0.createdAt < $1.createdAt })
        where !task.isComplete && task.goal == goal && task.energy.rawValue <= energy.rawValue {
            // Full original estimate is conservative for partly completed tasks.
            guard task.estimatedMinutes <= remaining else { continue }
            selected.append(task)
            remaining -= task.estimatedMinutes
            if selected.count == 3 { break }
        }
        return selected
    }

    public func startSession(taskIDs: [UUID], goal: Goal, minutes: Int, energy: Energy) throws {
        try transaction { state in
            guard state.session == nil || state.session?.status == .finished else {
                throw OrderError.invalid("Es gibt bereits eine Sitzung. Setze sie fort oder beende sie zuerst.")
            }
            guard !taskIDs.isEmpty, Set(taskIDs).count == taskIDs.count, minutes > 0 else {
                throw OrderError.invalid("Wähle mindestens eine offene Aufgabe und ein Zeitbudget.")
            }
            for id in taskIDs {
                guard let task = state.tasks.first(where: { $0.id == id }), !task.isComplete else {
                    throw OrderError.invalid("Eine ausgewählte Aufgabe ist nicht mehr offen.")
                }
            }
            state.session = WorkSession(taskIDs: taskIDs, goal: goal, timeBudget: minutes, energy: energy)
        }
    }

    public func pause() throws {
        try transaction { state in
            guard state.session?.status == .active else { throw OrderError.invalid("Keine aktive Sitzung.") }
            state.session?.status = .paused
        }
    }

    public func resume() throws {
        try transaction { state in
            guard state.session?.status == .paused else { throw OrderError.invalid("Keine pausierte Sitzung.") }
            state.session?.status = .active
        }
    }

    public func endSession() throws {
        try transaction { state in state.session?.status = .finished }
    }

    public func completeCurrentStep(expectedStepID: UUID, at date: Date = Date()) throws {
        try transaction { state in
            guard state.session?.status == .active,
                  let current = state.currentTask,
                  let step = current.nextStep, step.id == expectedStepID,
                  let taskIndex = state.tasks.firstIndex(where: { $0.id == current.id }),
                  let stepIndex = state.tasks[taskIndex].steps.firstIndex(where: { $0.id == step.id }) else {
                throw OrderError.invalid("Dieser Schritt ist nicht mehr der aktive Schritt. Der Zustand wurde nicht verändert.")
            }
            let event = CompletionEvent(id: UUID(), taskID: current.id, stepID: step.id, date: date)
            state.undoRecord = UndoRecord(taskBefore: current, sessionBefore: state.session, completionEventID: event.id)
            state.tasks[taskIndex].steps[stepIndex].completedAt = date
            state.events.append(event)
            if state.currentTask == nil { state.session?.status = .finished }
        }
    }

    public func undoCompletion() throws {
        try transaction(keepingUndo: true) { state in
            guard let undo = state.undoRecord, state.events.last?.id == undo.completionEventID,
                  let index = state.tasks.firstIndex(where: { $0.id == undo.taskBefore.id }) else {
                throw OrderError.invalid("Diese Erledigung kann nicht mehr zurückgenommen werden.")
            }
            state.tasks[index] = undo.taskBefore
            state.session = undo.sessionBefore
            state.events.removeLast()
            state.undoRecord = nil
        }
    }

    public static func validate(_ state: HouseholdState) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw OrderError.invalid(message) }
        }
        func text(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let roomIDs = Set(state.rooms.map(\.id))
        let placeIDs = Set(state.places.map(\.id))
        let taskIDs = Set(state.tasks.map(\.id))
        let pointIDs = Set(state.photoPoints.map(\.id))
        try require(state.schemaVersion == HouseholdState.currentSchema, "Unbekannte Datenversion.")
        try require(roomIDs.count == state.rooms.count && placeIDs.count == state.places.count &&
                    taskIDs.count == state.tasks.count && pointIDs.count == state.photoPoints.count,
                    "Doppelte interne Kennungen sind nicht erlaubt.")
        try require(Set(state.photos.map(\.id)).count == state.photos.count &&
                    Set(state.scans.map(\.id)).count == state.scans.count &&
                    Set(state.events.map(\.id)).count == state.events.count, "Doppelte Ereignis- oder Bildkennungen.")
        try require(state.rooms.allSatisfy { text($0.name) }, "Bitte gib dem Raum einen Namen.")
        var codes = Set<String>()
        for place in state.places {
            try require(roomIDs.contains(place.roomID) && text(place.name), "Lagerort benötigt Raum und Namen.")
            if let code = place.code {
                let key = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                try require(text(key) && codes.insert(key).inserted, "Eine Kistenkennung muss eindeutig sein.")
            }
            var visited: Set<UUID> = [place.id]
            var parent = place.parentID
            while let id = parent {
                try require(visited.insert(id).inserted, "Ein Lagerort darf nicht in sich selbst oder einem seiner Unterorte stehen.")
                guard let ancestor = state.places.first(where: { $0.id == id }), ancestor.roomID == place.roomID else {
                    throw OrderError.invalid("Der übergeordnete Lagerort muss im selben Raum existieren.")
                }
                parent = ancestor.parentID
            }
        }
        var allStepIDs = Set<UUID>()
        for task in state.tasks {
            try require(roomIDs.contains(task.roomID) && text(task.title), "Aufgabe benötigt Raum und Titel.")
            try require(task.estimatedMinutes > 0 && task.estimatedMinutes <= 1440 && !task.steps.isEmpty,
                        "Aufgabe benötigt eine Dauer und mindestens einen Handgriff.")
            var foundIncomplete = false
            for step in task.steps {
                try require(text(step.text) && allStepIDs.insert(step.id).inserted, "Handgriffe benötigen Text und eindeutige Kennungen.")
                if step.completedAt == nil { foundIncomplete = true }
                else { try require(!foundIncomplete, "Handgriffe müssen in ihrer Reihenfolge bestätigt werden.") }
                if let id = step.targetPlaceID {
                    try require(state.places.contains { $0.id == id && $0.roomID == task.roomID }, "Zielort fehlt oder gehört zu einem anderen Raum.")
                }
            }
        }
        for point in state.photoPoints {
            try require(roomIDs.contains(point.roomID) && text(point.name), "Fotopunkt benötigt Raum und Beschreibung.")
        }
        for photo in state.photos {
            try require(pointIDs.contains(photo.pointID) && !photo.jpegData.isEmpty && photo.jpegData.count <= 2_000_000,
                        "Foto fehlt, ist zu groß oder hat keinen gültigen Fotopunkt.")
        }
        try require(Set(state.analyses.map(\.id)).count == state.analyses.count &&
                    state.analyses.allSatisfy { roomIDs.contains($0.roomID) }, "Ungültige Raumanalyse.")
        for scan in state.scans {
            try require(roomIDs.contains(scan.roomID) && !scan.encodedRoom.isEmpty &&
                        [scan.walls, scan.doors, scan.windows, scan.objects].allSatisfy { $0 >= 0 }, "Ungültiger Raumscan.")
        }
        for event in state.events {
            try require(state.tasks.contains { task in
                task.id == event.taskID && task.steps.contains { $0.id == event.stepID && $0.completedAt != nil }
            }, "Erledigungsereignis ohne bestätigten Handgriff.")
        }
        if let session = state.session {
            try require(!session.taskIDs.isEmpty && Set(session.taskIDs).count == session.taskIDs.count &&
                        session.taskIDs.allSatisfy { taskIDs.contains($0) } && session.timeBudget > 0,
                        "Sitzung enthält ungültige Aufgaben.")
            if session.status != .finished {
                try require(state.currentTask != nil, "Eine offene Sitzung benötigt einen offenen Handgriff.")
            }
        }
        if let undo = state.undoRecord {
            try require(state.events.last?.id == undo.completionEventID && taskIDs.contains(undo.taskBefore.id),
                        "Ungültiger Rücknahmestand.")
            // Never trust a modified backup to inject invalid tasks through Undo.
            var previous = state
            previous.undoRecord = nil
            previous.tasks[previous.tasks.firstIndex { $0.id == undo.taskBefore.id }!] = undo.taskBefore
            previous.session = undo.sessionBefore
            previous.events.removeLast()
            try validate(previous)
        }
    }
}
