import Foundation

extension Optional where Wrapped == String {
    var nilIfEmpty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}

/// Where the household data lives. The main file holds everything except the
/// photo bytes; each photo is its own "blob", so a small change never rewrites
/// megabytes of images.
public protocol StateStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func saveBlob(_ data: Data, id: UUID) throws
    /// nil when no such blob exists.
    func loadBlob(id: UUID) throws -> Data?
    func deleteBlob(id: UUID)
}

public struct FileStateStorage: StateStorage {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    private var photoDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent("photos", isDirectory: true) }
    private func blobURL(_ id: UUID) -> URL { photoDirectory.appendingPathComponent(id.uuidString + ".jpg") }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }
    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
    public func saveBlob(_ data: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        try data.write(to: blobURL(id), options: .atomic)
    }
    public func loadBlob(id: UUID) throws -> Data? {
        guard FileManager.default.fileExists(atPath: blobURL(id).path) else { return nil }
        return try Data(contentsOf: blobURL(id))
    }
    public func deleteBlob(id: UUID) {
        try? FileManager.default.removeItem(at: blobURL(id))
    }
}

/// One synchronous transaction per user action. Publish UI state only AFTER
/// validation, encoding and the atomic file replacement have all succeeded.
/// The iOS host calls this repository exclusively on its main actor.
public final class HouseholdRepository {
    public private(set) var state: HouseholdState
    private let storage: StateStorage
    /// Photos whose bytes are already stored as blobs. Photos read from an old
    /// file (bytes inside the main file) are not in here and get moved on the next save.
    private var storedPhotos: Set<UUID> = []
    /// Photos the main file still lists but whose file is gone (cannot be restored).
    public private(set) var lostPhotoCount = 0

    public init(storage: StateStorage) throws {
        self.storage = storage
        if let bytes = try storage.load() {
            let raw = try Self.decodeRaw(bytes)
            var photos: [RoomPhoto] = []
            for photo in raw.photos {
                if !photo.jpegData.isEmpty {
                    photos.append(photo)            // old format: bytes inline
                } else if let blob = try storage.loadBlob(id: photo.id), !blob.isEmpty {
                    photos.append(RoomPhoto(id: photo.id, pointID: photo.pointID, createdAt: photo.createdAt, jpegData: blob))
                    storedPhotos.insert(photo.id)
                } else {
                    lostPhotoCount += 1
                }
            }
            var loaded = raw
            loaded.photos = photos
            try Self.validate(loaded)
            state = loaded
        } else {
            state = HouseholdState()
        }
    }

    private static func decodeRaw(_ data: Data) throws -> HouseholdState {
        struct Envelope: Decodable { let schemaVersion: Int }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == HouseholdState.currentSchema else {
            throw OrderError.invalid("Diese Datenversion wird noch nicht unterstützt. Die vorhandenen Daten wurden nicht verändert.")
        }
        return try JSONDecoder().decode(HouseholdState.self, from: data)
    }

    /// Writes new photo files first, then the main file, then removes files of deleted photos.
    private func persist(_ candidate: HouseholdState) throws {
        let present = Set(candidate.photos.map(\.id))
        let added = candidate.photos.filter { !storedPhotos.contains($0.id) }
        for photo in added { try storage.saveBlob(photo.jpegData, id: photo.id) }
        try storage.save(try Self.encode(candidate, stripPhotos: true))
        let removed = storedPhotos.subtracting(present)
        for id in removed { storage.deleteBlob(id: id) }
        storedPhotos.formUnion(added.map(\.id))
        storedPhotos.subtract(removed)
    }

    /// Reads a backup (photos inside) and checks it.
    public static func decode(_ data: Data) throws -> HouseholdState {
        let state = try decodeRaw(data)
        try validate(state)
        return state
    }

    /// Backup: one self-contained file with the photos inside.
    public func exportData() throws -> Data { try Self.encode(state, stripPhotos: false) }

    public func replace(with data: Data) throws {
        var restored = try Self.decode(data)
        restored.undoRecord = nil
        try persist(restored)
        state = restored
    }

    private static func encode(_ state: HouseholdState, stripPhotos: Bool) throws -> Data {
        var copy = state
        if stripPhotos {
            copy.photos = copy.photos.map { RoomPhoto(id: $0.id, pointID: $0.pointID, createdAt: $0.createdAt, jpegData: Data()) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(copy)
    }

    private func transaction(keepingUndo: Bool = false, _ change: (inout HouseholdState) throws -> Void) throws {
        var candidate = state
        if !keepingUndo { candidate.undoRecord = nil }
        try change(&candidate)
        try Self.validate(candidate)
        try persist(candidate)
        state = candidate
    }

    /// Deletes photos (their files too). The AI's findings stay; only the pictures go.
    public func deletePhotos(ids: [UUID]) throws {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        try transaction { state in
            state.photos.removeAll { doomed.contains($0.id) }
        }
    }

    public func addRoom(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try transaction { $0.rooms.append(Room(name: name)) }
    }

    public func addPlace(_ place: StoragePlace) throws {
        try transaction { $0.places.append(place) }
    }

    /// Moves a place (with everything inside it) under another place – or, with `parentID == nil`,
    /// directly into a room. `roomID` moves it to another room; its sub-places and
    /// photo sections follow. Steps of old tasks that aimed at it lose that aim (the hint stays).
    public func movePlace(id: UUID, parentID: UUID?, roomID: UUID? = nil) throws {
        try transaction { state in
            guard let index = state.places.firstIndex(where: { $0.id == id }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            let oldRoom = state.places[index].roomID
            let targetRoom = roomID ?? oldRoom
            guard state.rooms.contains(where: { $0.id == targetRoom }) else {
                throw OrderError.invalid("Dieser Raum existiert nicht mehr.")
            }
            let moved = state.subtree(of: id)
            if let parentID {
                guard let parent = state.places.first(where: { $0.id == parentID }) else {
                    throw OrderError.invalid("Der Ziel-Lagerort existiert nicht mehr.")
                }
                guard !moved.contains(parentID) else {
                    throw OrderError.invalid("Ein Lagerort darf nicht in sich selbst oder in einem seiner Unterorte stehen.")
                }
                guard parent.roomID == targetRoom else {
                    throw OrderError.invalid("Der Ziel-Lagerort liegt in einem anderen Raum.")
                }
            }
            if targetRoom != oldRoom {
                for i in state.places.indices where moved.contains(state.places[i].id) { state.places[i].roomID = targetRoom }
                state.photoPoints = state.photoPoints.map { point in
                    guard let placeID = point.placeID, moved.contains(placeID) else { return point }
                    return PhotoPoint(id: point.id, roomID: targetRoom, name: point.name, placeID: placeID)
                }
                for t in state.tasks.indices where state.tasks[t].roomID != targetRoom {
                    for s in state.tasks[t].steps.indices {
                        let old = state.tasks[t].steps[s]
                        guard let target = old.targetPlaceID, moved.contains(target) else { continue }
                        var rebuilt = ActionStep(id: old.id, text: old.text, targetPlaceID: nil, hint: old.hint)
                        rebuilt.completedAt = old.completedAt
                        state.tasks[t].steps[s] = rebuilt
                    }
                }
            }
            state.places[index].parentID = parentID
        }
    }

    public func setPlaceStatus(id: UUID, status: PlaceStatus?) throws {
        try transaction { state in
            guard let index = state.places.firstIndex(where: { $0.id == id }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            state.places[index].status = status
        }
    }

    /// The short printed code of a place (K07 for boxes, L03 for shelves …); assigned the first time it is needed.
    @discardableResult
    public func ensureLabelCode(placeID: UUID) throws -> String {
        if let code = state.places.first(where: { $0.id == placeID })?.code, !code.isEmpty { return code }
        try transaction { state in
            guard let index = state.places.firstIndex(where: { $0.id == placeID }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            let prefix = state.places[index].kind == .box ? "K" : "L"
            let used = Set(state.places.compactMap { $0.code?.uppercased() })
            var number = 1
            while used.contains("\(prefix)\(number < 10 ? "0" : "")\(number)") { number += 1 }
            state.places[index].code = "\(prefix)\(number < 10 ? "0" : "")\(number)"
        }
        return state.places.first(where: { $0.id == placeID })?.code ?? ""
    }

    /// Puts a list item into another place (new entry there, removed from the old list).
    public func moveInventoryItem(inventoryID: UUID, itemID: UUID, toPlace placeID: UUID) throws {
        try transaction { state in
            guard let inventoryIndex = state.inventories.firstIndex(where: { $0.id == inventoryID }),
                  let itemIndex = state.inventories[inventoryIndex].items.firstIndex(where: { $0.id == itemID }) else {
                throw OrderError.invalid("Dieser Eintrag existiert nicht mehr.")
            }
            guard state.places.contains(where: { $0.id == placeID }) else {
                throw OrderError.invalid("Der Ziel-Lagerort existiert nicht mehr.")
            }
            guard state.inventories[inventoryIndex].placeID != placeID else {
                throw OrderError.invalid("Dieser Gegenstand liegt schon dort.")
            }
            let old = state.inventories[inventoryIndex].items.remove(at: itemIndex)
            Self.append(PlaceInventoryItem(name: old.name, count: old.count, note: old.note, source: old.source, addedAt: Date()),
                        toPlace: placeID, in: &state)
        }
    }

    /// Records that the place has been checked and is empty.
    public func markPlaceEmpty(placeID: UUID) throws {
        try transaction { state in
            guard state.places.contains(where: { $0.id == placeID }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            state.inventories.append(PlaceInventory(placeID: placeID, photoIDs: [], summary: "Als leer markiert", items: []))
            let mine = state.inventories.filter { $0.placeID == placeID }.sorted { $0.createdAt > $1.createdAt }
            let drop = Set(mine.dropFirst(3).map(\.id))
            state.inventories.removeAll { drop.contains($0.id) }
        }
    }

    private static func append(_ item: PlaceInventoryItem, toPlace placeID: UUID, in state: inout HouseholdState) {
        let mine = state.inventories.enumerated().filter { $0.element.placeID == placeID }
        if let latest = mine.max(by: { $0.element.createdAt < $1.element.createdAt }) {
            state.inventories[latest.offset].items.append(item)
        } else {
            state.inventories.append(PlaceInventory(placeID: placeID, photoIDs: [], summary: "", items: [item]))
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

    /// Stores a photo of what is inside a storage place. The place's automatic
    /// photo point is created in the same transaction on first use.
    public func addPlacePhoto(placeID: UUID, jpegData: Data, at date: Date = Date()) throws {
        try transaction { state in
            guard let place = state.places.first(where: { $0.id == placeID }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            let pointID: UUID
            if let point = state.photoPoints.first(where: { $0.placeID == placeID }) {
                pointID = point.id
            } else {
                let point = PhotoPoint(roomID: place.roomID, name: HouseholdState.placePhotoPointName, placeID: placeID)
                state.photoPoints.append(point)
                pointID = point.id
            }
            state.photos.append(RoomPhoto(pointID: pointID, createdAt: date, jpegData: jpegData))
        }
    }

    /// Saves a stock-taking; only the three newest per place are kept.
    public func recordInventory(_ inventory: PlaceInventory) throws {
        try transaction { state in
            guard state.places.contains(where: { $0.id == inventory.placeID }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            state.inventories.append(inventory)
            let mine = state.inventories.filter { $0.placeID == inventory.placeID }.sorted { $0.createdAt > $1.createdAt }
            let drop = Set(mine.dropFirst(3).map(\.id))
            state.inventories.removeAll { drop.contains($0.id) }
        }
    }

    /// Adds a hand-typed item to the place's latest inventory (creating a manual one if needed).
    public func addInventoryItem(placeID: UUID, name: String, count: String? = nil) throws {
        try transaction { state in
            guard state.places.contains(where: { $0.id == placeID }) else {
                throw OrderError.invalid("Dieser Lagerort existiert nicht mehr.")
            }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw OrderError.invalid("Bitte gib einen Namen für den Gegenstand ein.") }
            let item = PlaceInventoryItem(name: clean, count: (count?.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty,
                                          source: "manual", addedAt: Date())
            Self.append(item, toPlace: placeID, in: &state)
        }
    }

    public func removeInventoryItem(inventoryID: UUID, itemID: UUID) throws {
        try transaction { state in
            guard let index = state.inventories.firstIndex(where: { $0.id == inventoryID }),
                  let itemIndex = state.inventories[index].items.firstIndex(where: { $0.id == itemID }) else {
                throw OrderError.invalid("Dieser Eintrag existiert nicht mehr.")
            }
            state.inventories[index].items.remove(at: itemIndex)
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
            for room in state.rooms {
                state.learn(from: tasks.filter { $0.roomID == room.id }, roomName: room.name)
            }
            state.session = WorkSession(taskIDs: tasks.map(\.id), goal: goal, timeBudget: minutes, energy: energy)
        }
    }

    /// Stores a room analysis from a background AI look. The tasks the AI
    /// proposed in the same answer are not added to the list; they are only
    /// remembered as routines for the offline planner.
    public func recordAnalysis(_ analysis: RoomAnalysis, learningFrom tasks: [HouseholdTask]) throws {
        try transaction { state in
            guard let room = state.rooms.first(where: { $0.id == analysis.roomID }) else {
                throw OrderError.invalid("Dieser Raum existiert nicht mehr.")
            }
            state.analyses.append(analysis)
            state.learn(from: tasks, roomName: room.name)
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

    public func pause(at date: Date = Date()) throws {
        try transaction { state in
            guard state.session?.status == .active else { throw OrderError.invalid("Keine aktive Sitzung.") }
            state.session?.stopClock(at: date)
            state.session?.status = .paused
        }
    }

    public func resume(at date: Date = Date()) throws {
        try transaction { state in
            guard state.session?.status == .paused else { throw OrderError.invalid("Keine pausierte Sitzung.") }
            state.session?.startClock(at: date)
            state.session?.status = .active
        }
    }

    public func endSession(at date: Date = Date()) throws {
        try transaction { state in
            state.session?.stopClock(at: date)
            state.session?.status = .finished
        }
    }

    /// Adds time to the running round (5-minute steps from the UI).
    public func extendSession(minutes: Int) throws {
        try transaction { state in
            guard let session = state.session, session.status != .finished, minutes > 0 else {
                throw OrderError.invalid("Es läuft keine Runde, die verlängert werden kann.")
            }
            state.session?.timeBudget = min(session.timeBudget + minutes, 600)
        }
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
            if state.currentTask == nil {
                state.session?.stopClock(at: date)
                state.session?.status = .finished
            }
        }
    }

    /// Ticks a single step off (or back on) from the task list, in any order.
    /// Independent of a running session; a running session that has nothing
    /// left to do is finished in the same transaction.
    public func setStepDone(taskID: UUID, stepID: UUID, done: Bool, at date: Date = Date()) throws {
        try transaction { state in
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
                  let stepIndex = state.tasks[taskIndex].steps.firstIndex(where: { $0.id == stepID }) else {
                throw OrderError.invalid("Dieser Handgriff existiert nicht mehr.")
            }
            let isDone = state.tasks[taskIndex].steps[stepIndex].completedAt != nil
            guard isDone != done else { return }
            if done {
                state.tasks[taskIndex].steps[stepIndex].completedAt = date
                state.events.append(CompletionEvent(id: UUID(), taskID: taskID, stepID: stepID, date: date))
            } else {
                state.tasks[taskIndex].steps[stepIndex].completedAt = nil
                state.events.removeAll { $0.stepID == stepID }
            }
            if let session = state.session, session.status != .finished, state.currentTask == nil {
                state.session?.stopClock(at: date)
                state.session?.status = .finished
            }
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
            for step in task.steps {
                try require(text(step.text) && allStepIDs.insert(step.id).inserted, "Handgriffe benötigen Text und eindeutige Kennungen.")
                if let id = step.targetPlaceID {
                    try require(state.places.contains { $0.id == id && $0.roomID == task.roomID }, "Zielort fehlt oder gehört zu einem anderen Raum.")
                }
            }
        }
        for point in state.photoPoints {
            try require(roomIDs.contains(point.roomID) && text(point.name), "Fotopunkt benötigt Raum und Beschreibung.")
            if let placeID = point.placeID {
                try require(placeIDs.contains(placeID), "Ein Foto-Abschnitt verweist auf einen unbekannten Lagerort.")
            }
        }
        try require(Set(state.inventories.map(\.id)).count == state.inventories.count &&
                    state.inventories.allSatisfy { placeIDs.contains($0.placeID) && $0.items.allSatisfy { text($0.name) } },
                    "Ungültige Bestandsaufnahme.")
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
