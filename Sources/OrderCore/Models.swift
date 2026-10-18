import Foundation

public enum Goal: String, Codable, CaseIterable, Identifiable, Hashable {
    case order, visitors, moving, cleaning
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .order: return "Dauerhafte Ordnung"
        case .visitors: return "Besuch kommt"
        case .moving: return "Umzug vorbereiten"
        case .cleaning: return "Grundreinigung"
        }
    }
}

public enum Energy: Int, Codable, CaseIterable, Identifiable, Hashable {
    case low = 0, normal = 1, high = 2
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .low: return "Wenig Energie"
        case .normal: return "Normal"
        case .high: return "Viel Energie"
        }
    }
}

public struct Room: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public enum PlaceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case storage, box
    public var id: String { rawValue }
    public var label: String { self == .box ? "Kiste" : "Lagerort" }
}

/// What is going to happen with a place and its contents (moving house, sorting out).
/// The place keeps its identity (and QR code); only the status changes.
public enum PlaceStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    // The raw values of the first ones are older and stay ("check" now reads "Noch sortieren").
    case check, stays, take, packed, sell, giveAway, donate, dispose, store
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .check: return "Noch sortieren"
        case .stays: return "Bleibt"
        case .take: return "Mitnehmen"
        case .packed: return "Bereits gepackt"
        case .sell: return "Verkaufen"
        case .giveAway: return "Verschenken"
        case .donate: return "Spenden"
        case .dispose: return "Entsorgen"
        case .store: return "Zwischenlagern"
        }
    }
    public var symbol: String {
        switch self {
        case .check: return "questionmark.circle"
        case .stays: return "house"
        case .take: return "arrow.right.circle"
        case .packed: return "shippingbox.fill"
        case .sell: return "eurosign.circle"
        case .giveAway: return "hands.sparkles"
        case .donate: return "gift"
        case .dispose: return "trash"
        case .store: return "archivebox"
        }
    }
}

/// Kinds of storage places the user can pick; they can add their own.
public enum PlaceTypes {
    public static let defaults = ["Schrank", "Regal", "Regalfach", "Schublade", "Kommode", "Kiste", "Box", "Behälter",
                                  "Kellerbereich", "Ablage", "Sonstiger Lagerort"]
    /// Types that are containers you open (they get the box icon and the K codes).
    private static let containers: Set<String> = ["kiste", "box", "behälter"]

    public static func kind(for typeName: String) -> PlaceKind { containers.contains(typeName.lowercased()) ? .box : .storage }

    /// A type name for what the AI saw ("kiste", "schrank" ...).
    public static func name(forForm form: String) -> String {
        switch form {
        case "kiste": return "Kiste"
        case "schrank": return "Schrank"
        case "regal": return "Regal"
        case "kommode": return "Kommode"
        case "ablage": return "Ablage"
        default: return "Sonstiger Lagerort"
        }
    }
}

public struct StoragePlace: Identifiable, Codable, Equatable {
    public let id: UUID
    public var roomID: UUID
    public var name: String
    public var kind: PlaceKind
    public var parentID: UUID?
    public var code: String?
    public var status: PlaceStatus?
    /// What the AI took it for ("schrank", "regal", "kommode", "kiste", "ablage" ...); nil if typed by hand.
    public var form: String?
    /// The type the user sees and can change (Schrank, Regalfach, Schublade, Kiste, an own type ...).
    public var typeName: String?
    public var note: String?
    /// Last time the place itself was changed (renamed, moved, status, code, note).
    public var changedAt: Date?
    public init(id: UUID = UUID(), roomID: UUID, name: String, kind: PlaceKind = .storage,
                parentID: UUID? = nil, code: String? = nil, status: PlaceStatus? = nil, form: String? = nil,
                typeName: String? = nil, note: String? = nil, changedAt: Date? = nil) {
        self.id = id; self.roomID = roomID; self.name = name
        self.kind = kind; self.parentID = parentID; self.code = code; self.status = status; self.form = form
        self.typeName = typeName; self.note = note; self.changedAt = changedAt
    }

    /// The type to show: the chosen one, else derived from what the AI saw, else from the kind.
    public var displayType: String {
        if let typeName, !typeName.isEmpty { return typeName }
        if let form { return PlaceTypes.name(forForm: form) }
        return kind == .box ? "Kiste" : "Lagerort"
    }
}

/// The text inside a place's QR code. Scanning it with the iPhone camera opens the
/// app at exactly this place; the app's own scanner reads the same text.
public enum PlaceLink {
    public static let scheme = "ordnungsplaner"

    public static func url(for placeID: UUID) -> URL {
        URL(string: "\(scheme)://place/\(placeID.uuidString)")!
    }

    /// Reads a scanned text: the link, a bare UUID, or nothing usable.
    public static func placeID(from text: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed) { return id }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == scheme, url.host?.lowercased() == "place" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// QR content of a label that is printed in advance and not yet tied to a place.
    public static func codeURL(for code: String) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "code"
        parts.path = "/" + code
        return parts.url ?? URL(string: "\(scheme)://code/")!
    }

    /// The code in a scanned text: our code link, or any short plain text (labels made in a
    /// printer app often just contain "K07"). Place links and empty or very long texts are not codes.
    public static func code(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, !trimmed.contains("\n"), placeID(from: trimmed) == nil else { return nil }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == scheme {
            guard url.host?.lowercased() == "code" else { return nil }
            let code = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            return code.isEmpty || code == "/" ? nil : code
        }
        return trimmed
    }
}

/// A place that would profit from a label, with the reason in plain words.
public struct LabelSuggestion: Identifiable, Equatable {
    public var id: UUID { placeID }
    public let placeID: UUID
    public let reason: String
    public let score: Int
    /// Obvious candidates are pre-selected in the UI; the user can change that.
    public var recommended: Bool { score >= 4 }
}

public struct ActionStep: Identifiable, Codable, Equatable {
    public let id: UUID
    public let text: String
    public let targetPlaceID: UUID?
    /// Free-text destination suggested by the AI ("ins obere Regalfach"); not a confirmed place.
    public let hint: String?
    public var completedAt: Date?
    public init(id: UUID = UUID(), text: String, targetPlaceID: UUID? = nil, hint: String? = nil) {
        self.id = id; self.text = text; self.targetPlaceID = targetPlaceID; self.hint = hint
    }
}

/// Where a task came from: typed by the user, planned by the AI, or built from
/// the built-in routines when the AI is unavailable.
public enum TaskSource: String, Codable, Equatable { case manual, ai, local }

public struct HouseholdTask: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public let title: String
    public let goal: Goal
    public let energy: Energy
    public let estimatedMinutes: Int
    public var steps: [ActionStep]
    public let createdAt: Date
    /// nil in data written before AI planning existed (treated as manual).
    public let source: TaskSource?
    public var isComplete: Bool { !steps.isEmpty && steps.allSatisfy { $0.completedAt != nil } }
    public var nextStep: ActionStep? { steps.first { $0.completedAt == nil } }
    public init(id: UUID = UUID(), roomID: UUID, title: String, goal: Goal = .order,
                energy: Energy = .normal, estimatedMinutes: Int = 5, steps: [ActionStep],
                createdAt: Date = Date(), source: TaskSource = .manual) {
        self.id = id; self.roomID = roomID; self.title = title; self.goal = goal
        self.energy = energy; self.estimatedMinutes = estimatedMinutes
        self.steps = steps; self.createdAt = createdAt; self.source = source
    }
}

public enum SessionStatus: String, Codable, Equatable { case active, paused, finished }

public struct WorkSession: Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskIDs: [UUID]
    public let goal: Goal
    public var timeBudget: Int
    public let energy: Energy
    public var status: SessionStatus
    public let startedAt: Date
    /// Seconds already worked while the clock was stopped (pauses excluded).
    /// nil only in sessions saved before the timer existed.
    public var elapsedSeconds: Double?
    /// Start of the current running stretch; nil while paused or finished.
    public var runningSince: Date?
    public init(taskIDs: [UUID], goal: Goal, timeBudget: Int, energy: Energy) {
        self.id = UUID(); self.taskIDs = taskIDs; self.goal = goal
        self.timeBudget = timeBudget; self.energy = energy; self.status = .active
        self.startedAt = Date()
        self.elapsedSeconds = 0
        self.runningSince = startedAt
    }

    private var clockStart: Date? {
        if let runningSince { return runningSince }
        return status == .active && elapsedSeconds == nil ? startedAt : nil
    }

    /// Worked time in seconds: banked time plus the running stretch.
    public func elapsed(at now: Date = Date()) -> TimeInterval {
        (elapsedSeconds ?? 0) + (clockStart.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Seconds left of the budget; negative once the time is over.
    public func remaining(at now: Date = Date()) -> TimeInterval {
        Double(timeBudget * 60) - elapsed(at: now)
    }

    public mutating func stopClock(at now: Date = Date()) {
        if let start = clockStart { elapsedSeconds = (elapsedSeconds ?? 0) + max(0, now.timeIntervalSince(start)) }
        runningSince = nil
    }

    public mutating func startClock(at now: Date = Date()) {
        if elapsedSeconds == nil { elapsedSeconds = elapsed(at: now) }
        runningSince = now
    }
}

public struct CompletionEvent: Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let stepID: UUID
    public let date: Date
}

public struct UndoRecord: Codable, Equatable {
    public let taskBefore: HouseholdTask
    public let sessionBefore: WorkSession?
    public let completionEventID: UUID
}

public struct PhotoPoint: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public let name: String
    /// Set for the automatic point that collects the photos of one storage place's contents.
    public let placeID: UUID?
    public init(id: UUID = UUID(), roomID: UUID, name: String, placeID: UUID? = nil) {
        self.id = id; self.roomID = roomID; self.name = name; self.placeID = placeID
    }
}

/// One thing the AI (or the user) lists as being in a storage place.
/// Observation, not a confirmed inventory: the user can correct or delete it.
public struct PlaceInventoryItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var count: String?
    public var note: String?
    /// "ai" or "manual"
    public let source: String?
    /// When the item was put on this list (nil for entries made before this was recorded).
    public var addedAt: Date?
    public var category: String?
    /// Extra search words ("Bohrer", "Akku" ...).
    public var tags: [String]?
    public var modifiedAt: Date?
    public init(id: UUID = UUID(), name: String, count: String? = nil, note: String? = nil, source: String? = nil,
                addedAt: Date? = nil, category: String? = nil, tags: [String]? = nil, modifiedAt: Date? = nil) {
        self.id = id; self.name = name; self.count = count; self.note = note; self.source = source; self.addedAt = addedAt
        self.category = category; self.tags = tags; self.modifiedAt = modifiedAt
    }
}

/// A stock-taking of one storage place, from photos of its contents or typed by hand.
public struct PlaceInventory: Identifiable, Codable, Equatable {
    public let id: UUID
    public let placeID: UUID
    public let createdAt: Date
    public let photoIDs: [UUID]
    public var summary: String
    public var items: [PlaceInventoryItem]
    public var tidyHints: [String]
    public init(id: UUID = UUID(), placeID: UUID, createdAt: Date = Date(), photoIDs: [UUID], summary: String,
                items: [PlaceInventoryItem], tidyHints: [String] = []) {
        self.id = id; self.placeID = placeID; self.createdAt = createdAt; self.photoIDs = photoIDs
        self.summary = summary; self.items = items; self.tidyHints = tidyHints
    }
}

/// Search hit: an item found in a storage place.
public struct InventoryHit: Identifiable, Equatable {
    public var id: UUID { item.id }
    public let item: PlaceInventoryItem
    public let placeID: UUID
}

public struct RoomPhoto: Identifiable, Codable, Equatable {
    public let id: UUID
    public let pointID: UUID
    public let createdAt: Date
    public let jpegData: Data
    public init(id: UUID = UUID(), pointID: UUID, createdAt: Date = Date(), jpegData: Data) {
        self.id = id; self.pointID = pointID; self.createdAt = createdAt; self.jpegData = jpegData
    }
}

public struct RoomScanRecord: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public let createdAt: Date
    public let walls: Int
    public let doors: Int
    public let windows: Int
    public let objects: Int
    public let encodedRoom: Data
    public init(roomID: UUID, walls: Int, doors: Int, windows: Int, objects: Int, encodedRoom: Data) {
        self.id = UUID(); self.roomID = roomID; self.createdAt = Date()
        self.walls = walls; self.doors = doors; self.windows = windows; self.objects = objects
        self.encodedRoom = encodedRoom
    }
}

/// A storage place the AI believes it saw on a photo. Observation only:
/// it becomes a StoragePlace exclusively through an explicit user action.
public struct DetectedPlace: Codable, Equatable, Hashable {
    public let name: String
    public let kind: String
    public let note: String
    public init(name: String, kind: String, note: String) { self.name = name; self.kind = kind; self.note = note }
}

/// Result of one AI look at a room's photos. Stored so the user can see what
/// the plan was based on; it never confirms contents, free space or disposal.
public struct RoomAnalysis: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public let createdAt: Date
    public let goal: Goal
    public let photoIDs: [UUID]
    public let summary: String
    public let startHint: String
    public let detectedPlaces: [DetectedPlace]
    public let problemZones: [String]
    /// Kinds of clutter the AI saw (`Clutter` raw values); this is what the
    /// offline planner builds on. nil in analyses saved before it existed.
    public let tags: [String]?
    public init(id: UUID = UUID(), roomID: UUID, createdAt: Date = Date(), goal: Goal, photoIDs: [UUID],
                summary: String, startHint: String, detectedPlaces: [DetectedPlace], problemZones: [String],
                tags: [String] = []) {
        self.id = id; self.roomID = roomID; self.createdAt = createdAt; self.goal = goal; self.photoIDs = photoIDs
        self.summary = summary; self.startHint = startHint
        self.detectedPlaces = detectedPlaces; self.problemZones = problemZones; self.tags = tags
    }
}

/// Recurring kinds of clutter. The AI reports them for a room, the user can tick
/// them by hand, and the built-in routines are keyed on them.
public enum Clutter: String, Codable, CaseIterable, Identifiable, Hashable {
    case dishes, laundry, trash, papers, shoes, toys, cables, bottles, clothes, bed
    case dust, floor, surfaces, fridge, cosmetics, towels, books, pets
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dishes: return "Geschirr und Gläser"
        case .laundry: return "Wäsche"
        case .trash: return "Müll"
        case .papers: return "Post und Papiere"
        case .shoes: return "Schuhe und Jacken"
        case .toys: return "Spielzeug"
        case .cables: return "Kabel und Ladegeräte"
        case .bottles: return "Flaschen und Pfand"
        case .clothes: return "Kleidung auf Stuhl oder Boden"
        case .bed: return "Ungemachtes Bett"
        case .dust: return "Staub"
        case .floor: return "Dinge auf dem Boden"
        case .surfaces: return "Volle Tische und Flächen"
        case .fridge: return "Kühlschrank"
        case .cosmetics: return "Kosmetik und Bad-Kram"
        case .towels: return "Handtücher"
        case .books: return "Bücher und Zeitschriften"
        case .pets: return "Haustierzeug"
        }
    }

    /// Lower-case word stems used to read the kind of clutter out of free text.
    var keywords: [String] {
        switch self {
        case .dishes: return ["teller", "geschirr", "tasse", "glas", "gläser", "besteck", "spüle"]
        case .laundry: return ["wäsche", "waesche", "wäschekorb", "socken"]
        case .trash: return ["müll", "muell", "verpackung", "abfall"]
        case .papers: return ["post", "papier", "briefe", "rechnung", "unterlagen"]
        case .shoes: return ["schuh", "jacke", "mantel"]
        case .toys: return ["spielzeug", "lego", "puppe"]
        case .cables: return ["kabel", "ladegerät", "ladegeraet"]
        case .bottles: return ["flasche", "pfand", "dose"]
        case .clothes: return ["kleidung", "kleider", "pullover", "hose", "shirt"]
        case .bed: return ["bett", "decke", "kissen"]
        case .dust: return ["staub"]
        case .floor: return ["boden", "teppich", "krümel"]
        case .surfaces: return ["tisch", "fläche", "flaeche", "arbeitsplatte", "ablage", "schreibtisch"]
        case .fridge: return ["kühlschrank", "kuehlschrank"]
        case .cosmetics: return ["kosmetik", "zahnbürste", "creme", "schminke"]
        case .towels: return ["handtuch", "handtücher"]
        case .books: return ["buch", "bücher", "zeitschrift"]
        case .pets: return ["katze", "hund", "futter", "haustier"]
        }
    }
}

/// Rough room type, read from the room's name; decides which routines fit.
public enum RoomKind: String, Codable, CaseIterable, Hashable {
    case kitchen, living, bedroom, bathroom, hallway, office, kids, storage, other

    public static func infer(_ name: String) -> RoomKind {
        let text = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["küche", "kueche"]) { return .kitchen }
        if has(["bad", "wc", "toilette", "dusche"]) { return .bathroom }
        if has(["schlaf", "gäste", "gaeste"]) { return .bedroom }
        if has(["kinder", "spielzimmer", "baby"]) { return .kids }
        if has(["arbeit", "büro", "buero", "office", "homeoffice"]) { return .office }
        if has(["flur", "diele", "eingang", "windfang"]) { return .hallway }
        if has(["keller", "abstell", "dachboden", "speicher", "garage", "lager"]) { return .storage }
        if has(["wohn", "stube", "ess", "salon"]) { return .living }
        return .other
    }
}

public struct LearnedStep: Codable, Equatable {
    public let text: String
    public let hint: String?
    public init(text: String, hint: String?) { self.text = text; self.hint = hint }
}

/// A routine the AI once proposed for this kind of room. Kept so the offline
/// planner can offer it again; it counts how often the AI suggested it.
public struct LearnedRoutine: Identifiable, Codable, Equatable {
    public let id: UUID
    public let title: String
    public let kind: RoomKind
    public let goal: Goal
    public let minutes: Int
    public let energy: Energy
    public let steps: [LearnedStep]
    public var seen: Int
    public var lastSeen: Date
}

public struct HouseholdState: Codable, Equatable {
    public static let currentSchema = 1
    public var schemaVersion = currentSchema
    public var rooms: [Room] = []
    public var places: [StoragePlace] = []
    public var tasks: [HouseholdTask] = []
    public var photoPoints: [PhotoPoint] = []
    public var photos: [RoomPhoto] = []
    public var scans: [RoomScanRecord] = []
    public var session: WorkSession?
    public var events: [CompletionEvent] = []
    public var undoRecord: UndoRecord?
    public var analyses: [RoomAnalysis] = []
    public var learned: [LearnedRoutine] = []
    public var inventories: [PlaceInventory] = []
    /// Codes printed on blank labels that are not tied to a place yet.
    public var reservedCodes: [String] = []
    /// Place types the user added to the built-in list.
    public var customPlaceTypes: [String] = []
    public init() {}

    // Files written before `analyses` existed stay readable (same schema version,
    // additive field only).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        rooms = try c.decode([Room].self, forKey: .rooms)
        places = try c.decode([StoragePlace].self, forKey: .places)
        tasks = try c.decode([HouseholdTask].self, forKey: .tasks)
        photoPoints = try c.decode([PhotoPoint].self, forKey: .photoPoints)
        photos = try c.decode([RoomPhoto].self, forKey: .photos)
        scans = try c.decode([RoomScanRecord].self, forKey: .scans)
        session = try c.decodeIfPresent(WorkSession.self, forKey: .session)
        events = try c.decode([CompletionEvent].self, forKey: .events)
        undoRecord = try c.decodeIfPresent(UndoRecord.self, forKey: .undoRecord)
        analyses = try c.decodeIfPresent([RoomAnalysis].self, forKey: .analyses) ?? []
        learned = try c.decodeIfPresent([LearnedRoutine].self, forKey: .learned) ?? []
        inventories = try c.decodeIfPresent([PlaceInventory].self, forKey: .inventories) ?? []
        reservedCodes = try c.decodeIfPresent([String].self, forKey: .reservedCodes) ?? []
        customPlaceTypes = try c.decodeIfPresent([String].self, forKey: .customPlaceTypes) ?? []
    }

    /// Remembers the AI-planned tasks as routines for the offline planner.
    /// The same routine (room type, goal, title) only raises its counter.
    public mutating func learn(from newTasks: [HouseholdTask], roomName: String, now: Date = Date()) {
        let kind = RoomKind.infer(roomName)
        for task in newTasks where task.source == .ai && !task.steps.isEmpty {
            let key = LocalPlanner.normalize(task.title)
            if let index = learned.firstIndex(where: { $0.kind == kind && $0.goal == task.goal && LocalPlanner.normalize($0.title) == key }) {
                learned[index].seen += 1
                learned[index].lastSeen = now
            } else {
                learned.append(LearnedRoutine(id: UUID(), title: task.title, kind: kind, goal: task.goal,
                                              minutes: task.estimatedMinutes, energy: task.energy,
                                              steps: task.steps.map { LearnedStep(text: $0.text, hint: $0.hint) },
                                              seen: 1, lastSeen: now))
            }
        }
        if learned.count > 150 {
            learned.sort { ($0.seen, $0.lastSeen) > ($1.seen, $1.lastSeen) }
            learned = Array(learned.prefix(150))
        }
    }

    /// Name of the automatic photo point that collects a room's overview photos.
    public static let roomPhotoPointName = "Raumfotos"

    /// Name of the automatic photo point that collects the photos of a storage place's contents.
    public static let placePhotoPointName = "Inhalt"

    public func roomPhotos(_ roomID: UUID) -> [RoomPhoto] {
        let points = Set(photoPoints.filter { $0.roomID == roomID && $0.placeID == nil }.map(\.id))
        return photos.filter { points.contains($0.pointID) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Photos of what is inside a storage place, oldest first.
    public func placePhotos(_ placeID: UUID) -> [RoomPhoto] {
        let points = Set(photoPoints.filter { $0.placeID == placeID }.map(\.id))
        return photos.filter { points.contains($0.pointID) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Finds the place a scan refers to: a QR link or UUID, otherwise the printed code (e.g. "K07").
    public func place(forScan text: String) -> StoragePlace? {
        if let id = PlaceLink.placeID(from: text) { return places.first { $0.id == id } }
        guard let code = PlaceLink.code(from: text)?.uppercased() else { return nil }
        return places.first { $0.code?.uppercased() == code }
    }

    /// Places that would profit from a label (no code yet), most useful first. Closed
    /// containers come before open shelves, because you cannot see into them.
    public func labelSuggestions() -> [LabelSuggestion] {
        places.filter { ($0.code ?? "").isEmpty }.map { place -> LabelSuggestion in
            var score: Int
            var reason: String
            switch place.form {
            case "kiste": score = 5; reason = "Geschlossene Kiste – von außen sieht man nicht, was drin ist."
            case "schrank": score = 4; reason = "Schrank mit Türen – der Inhalt ist von außen nicht zu sehen."
            case "kommode": score = 4; reason = "Kommode mit Schubladen – ein Etikett spart das Aufziehen."
            case "regal": score = 2; reason = "Offenes Regal – ein Etikett lohnt sich, wenn du den Inhalt erfassen willst."
            case "ablage": score = 1; reason = "Offene Ablage – meist reicht ein Blick."
            default:
                score = place.kind == .box ? 5 : 2
                reason = place.kind == .box ? "Kiste – von außen sieht man nicht, was drin ist." : "Lagerort ohne Etikett."
            }
            let count = latestInventory(place.id)?.items.count ?? 0
            if count > 0 { score += 2; reason += " Inhalt schon erfasst (\(count)) – mit Etikett findest du ihn per Scan." }
            else if !placePhotos(place.id).isEmpty { score += 1 }
            return LabelSuggestion(placeID: place.id, reason: reason, score: score)
        }
        .sorted { ($0.score, $1.placeID.uuidString) > ($1.score, $0.placeID.uuidString) }
    }

    /// Places with the given status (all places with any status when nil).
    public func places(with status: PlaceStatus?) -> [StoragePlace] {
        places.filter { status == nil ? $0.status != nil : $0.status == status }
    }

    /// Places directly inside the given place (or directly in the room when nil), by name.
    public func children(of placeID: UUID?, inRoom roomID: UUID? = nil) -> [StoragePlace] {
        places.filter { $0.parentID == placeID && (placeID != nil || roomID == nil || $0.roomID == roomID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// When anything about the place last changed: the place itself, its list, or its photos.
    public func lastChange(of placeID: UUID) -> Date? {
        var dates: [Date] = []
        if let place = places.first(where: { $0.id == placeID }), let changed = place.changedAt { dates.append(changed) }
        if let inventory = latestInventory(placeID) {
            dates.append(inventory.createdAt)
            dates.append(contentsOf: inventory.items.compactMap { $0.modifiedAt ?? $0.addedAt })
        }
        dates.append(contentsOf: placePhotos(placeID).map(\.createdAt))
        return dates.max()
    }

    /// Built-in and own place types, without duplicates.
    public var placeTypes: [String] {
        var seen = Set<String>()
        return (PlaceTypes.defaults + customPlaceTypes).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The place and everything inside it, as ids.
    public func subtree(of placeID: UUID) -> Set<UUID> {
        var found: Set<UUID> = [placeID]
        var frontier = [placeID]
        while let current = frontier.popLast() {
            for child in places where child.parentID == current && found.insert(child.id).inserted { frontier.append(child.id) }
        }
        return found
    }

    public func latestInventory(_ placeID: UUID) -> PlaceInventory? {
        inventories.filter { $0.placeID == placeID }.max { $0.createdAt < $1.createdAt }
    }

    /// Items (from each place's latest inventory) whose name contains the query.
    public func searchInventory(_ query: String) -> [InventoryHit] {
        let needle = LocalPlanner.normalize(query)
        guard !needle.isEmpty else { return [] }
        return places.flatMap { place -> [InventoryHit] in
            (latestInventory(place.id)?.items ?? [])
                .filter { item in
                    ([item.name, item.category ?? "", item.note ?? ""] + (item.tags ?? []))
                        .contains { LocalPlanner.normalize($0).contains(needle) }
                }
                .map { InventoryHit(item: $0, placeID: place.id) }
        }
    }

    public func latestAnalysis(_ roomID: UUID) -> RoomAnalysis? {
        analyses.filter { $0.roomID == roomID }.max { $0.createdAt < $1.createdAt }
    }

    /// Latest look by the AI at the room's photos (offline plans carry no photos and don't count).
    public func latestAIAnalysis(_ roomID: UUID) -> RoomAnalysis? {
        analyses.filter { $0.roomID == roomID && !$0.photoIDs.isEmpty }.max { $0.createdAt < $1.createdAt }
    }

    /// The photos the AI is shown for a room: the six newest.
    public func photosForAnalysis(_ roomID: UUID) -> [RoomPhoto] { Array(roomPhotos(roomID).suffix(6)) }

    /// True when the latest AI analysis already covers the room's photos: no photo was
    /// taken after it. Deleting old photos keeps it current – the knowledge stays.
    public func isAnalysisCurrent(_ roomID: UUID) -> Bool {
        guard let analysis = latestAIAnalysis(roomID) else { return false }
        return roomPhotos(roomID).allSatisfy { $0.createdAt <= analysis.createdAt }
    }

    /// Room photos the AI has already looked at (taken before its latest analysis).
    /// Safe to delete: the analysis keeps what was seen.
    public func outdatedRoomPhotos(_ roomID: UUID) -> [RoomPhoto] {
        guard let analysis = latestAIAnalysis(roomID) else { return [] }
        return roomPhotos(roomID).filter { $0.createdAt <= analysis.createdAt }
    }

    /// Photos of a storage place's contents that an AI stock-taking has already covered.
    public func outdatedPlacePhotos(_ placeID: UUID) -> [RoomPhoto] {
        guard let inventory = latestInventory(placeID), !inventory.photoIDs.isEmpty else { return [] }
        return placePhotos(placeID).filter { $0.createdAt <= inventory.createdAt }
    }

    /// Everything that can go without losing what the AI found.
    public var allOutdatedPhotos: [RoomPhoto] {
        rooms.flatMap { outdatedRoomPhotos($0.id) } + places.flatMap { outdatedPlacePhotos($0.id) }
    }

    public var photoBytes: Int { photos.reduce(0) { $0 + $1.jpegData.count } }

    /// What changed between the last two AI looks at a room. Only what the AI
    /// reported as kinds of clutter; "not seen any more" is not proof that it is done.
    public struct RoomProgress: Equatable {
        public let notSeenAnymore: [Clutter]
        public let stillSeen: [Clutter]
        public let newlySeen: [Clutter]
        public let before: Date
        public let after: Date
    }

    public func progress(_ roomID: UUID) -> RoomProgress? {
        let list = analyses.filter { $0.roomID == roomID && !$0.photoIDs.isEmpty }.sorted { $0.createdAt < $1.createdAt }
        guard list.count >= 2 else { return nil }
        func clutter(_ analysis: RoomAnalysis) -> Set<Clutter> {
            Set((analysis.tags ?? []).compactMap(Clutter.init(rawValue:)))
                .union(LocalPlanner.inferTags(from: analysis.problemZones))
        }
        let before = list[list.count - 2], after = list[list.count - 1]
        let old = clutter(before), new = clutter(after)
        func ordered(_ set: Set<Clutter>) -> [Clutter] { Clutter.allCases.filter { set.contains($0) } }
        guard !old.isEmpty || !new.isEmpty else { return nil }
        return RoomProgress(notSeenAnymore: ordered(old.subtracting(new)), stillSeen: ordered(old.intersection(new)),
                            newlySeen: ordered(new.subtracting(old)), before: before.createdAt, after: after.createdAt)
    }

    public var currentTask: HouseholdTask? {
        guard let session, session.status != .finished else { return nil }
        return session.taskIDs.compactMap { id in tasks.first { $0.id == id } }.first { !$0.isComplete }
    }

    public func path(for id: UUID) -> String {
        var names: [String] = []
        var cursor: UUID? = id
        var visited = Set<UUID>()
        while let current = cursor, visited.insert(current).inserted,
              let place = places.first(where: { $0.id == current }) {
            let code = place.code.map { "\($0) · " } ?? ""
            names.insert(code + place.name, at: 0)
            if place.parentID == nil, let room = rooms.first(where: { $0.id == place.roomID }) {
                names.insert(room.name, at: 0)
            }
            cursor = place.parentID
        }
        return names.isEmpty ? "Unbekannter Lagerort" : names.joined(separator: " › ")
    }
}

public enum OrderError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let text): return text }
    }
}
