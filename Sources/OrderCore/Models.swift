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

public struct StoragePlace: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public var name: String
    public var kind: PlaceKind
    public var parentID: UUID?
    public var code: String?
    public init(id: UUID = UUID(), roomID: UUID, name: String, kind: PlaceKind = .storage,
                parentID: UUID? = nil, code: String? = nil) {
        self.id = id; self.roomID = roomID; self.name = name
        self.kind = kind; self.parentID = parentID; self.code = code
    }
}

public struct ActionStep: Identifiable, Codable, Equatable {
    public let id: UUID
    public let text: String
    public let targetPlaceID: UUID?
    public var completedAt: Date?
    public init(id: UUID = UUID(), text: String, targetPlaceID: UUID? = nil) {
        self.id = id; self.text = text; self.targetPlaceID = targetPlaceID
    }
}

public struct HouseholdTask: Identifiable, Codable, Equatable {
    public let id: UUID
    public let roomID: UUID
    public let title: String
    public let goal: Goal
    public let energy: Energy
    public let estimatedMinutes: Int
    public var steps: [ActionStep]
    public let createdAt: Date
    public var isComplete: Bool { !steps.isEmpty && steps.allSatisfy { $0.completedAt != nil } }
    public var nextStep: ActionStep? { steps.first { $0.completedAt == nil } }
    public init(id: UUID = UUID(), roomID: UUID, title: String, goal: Goal = .order,
                energy: Energy = .normal, estimatedMinutes: Int = 5, steps: [ActionStep],
                createdAt: Date = Date()) {
        self.id = id; self.roomID = roomID; self.title = title; self.goal = goal
        self.energy = energy; self.estimatedMinutes = estimatedMinutes
        self.steps = steps; self.createdAt = createdAt
    }
}

public enum SessionStatus: String, Codable, Equatable { case active, paused, finished }

public struct WorkSession: Identifiable, Codable, Equatable {
    public let id: UUID
    public let taskIDs: [UUID]
    public let goal: Goal
    public let timeBudget: Int
    public let energy: Energy
    public var status: SessionStatus
    public let startedAt: Date
    public init(taskIDs: [UUID], goal: Goal, timeBudget: Int, energy: Energy) {
        self.id = UUID(); self.taskIDs = taskIDs; self.goal = goal
        self.timeBudget = timeBudget; self.energy = energy; self.status = .active
        self.startedAt = Date()
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
    public init(id: UUID = UUID(), roomID: UUID, name: String) {
        self.id = id; self.roomID = roomID; self.name = name
    }
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
    public init() {}

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
