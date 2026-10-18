import XCTest
@testable import OrderCore

final class LocalPlannerTests: XCTestCase {
    func testRulesAreWellFormed() {
        XCTAssertGreaterThanOrEqual(LocalPlanner.rules.count, 60)
        XCTAssertEqual(Set(LocalPlanner.rules.map(\.id)).count, LocalPlanner.rules.count)
        for rule in LocalPlanner.rules {
            XCTAssertFalse(rule.steps.isEmpty, rule.id)
            XCTAssertTrue(rule.minutes > 0 && rule.minutes <= 60, rule.id)
            for step in rule.steps { XCTAssertFalse(step.trimmingCharacters(in: .whitespaces).isEmpty, rule.id) }
        }
        // every room type and every goal has something to offer, even with little energy
        for kind in RoomKind.allCases {
            for goal in Goal.allCases {
                let fits = LocalPlanner.rules.filter { ($0.kinds.isEmpty || $0.kinds.contains(kind)) && ($0.goals.isEmpty || $0.goals.contains(goal)) && $0.energy == .low }
                XCTAssertFalse(fits.isEmpty, "\(kind) \(goal)")
            }
        }
    }

    func testRoomKindFromName() {
        XCTAssertEqual(RoomKind.infer("Küche"), .kitchen)
        XCTAssertEqual(RoomKind.infer("Badezimmer"), .bathroom)
        XCTAssertEqual(RoomKind.infer("Arbeitszimmer"), .office)
        XCTAssertEqual(RoomKind.infer("Kinderzimmer"), .kids)
        XCTAssertEqual(RoomKind.infer("Schlafzimmer"), .bedroom)
        XCTAssertEqual(RoomKind.infer("Flur"), .hallway)
        XCTAssertEqual(RoomKind.infer("Keller"), .storage)
        XCTAssertEqual(RoomKind.infer("Wohnzimmer"), .living)
        XCTAssertEqual(RoomKind.infer("Mein Raum"), .other)
    }

    func testPlanFitsTimeAndEnergyAndPrefersObservedClutter() {
        let room = UUID()
        let outcome = LocalPlanner.plan(roomID: room, roomName: "Küche", goal: .order, minutes: 20, energy: .low,
                                        observed: [.dishes], learned: [], previous: nil)
        XCTAssertFalse(outcome.tasks.isEmpty)
        XCTAssertLessThanOrEqual(outcome.tasks.reduce(0) { $0 + $1.estimatedMinutes }, 20)
        XCTAssertTrue(outcome.tasks.allSatisfy { $0.energy == .low && $0.source == .local && !$0.steps.isEmpty && $0.roomID == room })
        XCTAssertTrue(outcome.tasks[0].title.contains("Geschirr") || outcome.tasks[0].title.contains("Spülmaschine"))
        XCTAssertEqual(outcome.analysis.tags, ["dishes"])
        XCTAssertTrue(outcome.analysis.summary.contains("nicht ausgewertet"))
        XCTAssertNotNil(outcome.tasks[0].steps.first { $0.hint != nil })
    }

    func testVeryShortBudgetStillGivesOneTask() {
        let outcome = LocalPlanner.plan(roomID: UUID(), roomName: "Wohnzimmer", goal: .visitors, minutes: 1, energy: .low,
                                        observed: [], learned: [], previous: nil)
        XCTAssertEqual(outcome.tasks.count, 1)
    }

    func testEveryGoalGivesAPlanForEveryRoomType() {
        for name in ["Küche", "Bad", "Schlafzimmer", "Flur", "Arbeitszimmer", "Kinderzimmer", "Keller", "Wohnzimmer", "Mein Raum"] {
            for goal in Goal.allCases {
                for energy in Energy.allCases {
                    let outcome = LocalPlanner.plan(roomID: UUID(), roomName: name, goal: goal, minutes: 30, energy: energy,
                                                    observed: [], learned: [], previous: nil)
                    XCTAssertFalse(outcome.tasks.isEmpty, "\(name) \(goal) \(energy)")
                    XCTAssertLessThanOrEqual(outcome.tasks.count, 6)
                }
            }
        }
    }

    func testPreviousAiAnalysisFeedsTheOfflinePlan() {
        let room = UUID()
        let previous = RoomAnalysis(roomID: room, goal: .order, photoIDs: [], summary: "Viel los", startHint: "",
                                    detectedPlaces: [], problemZones: ["Wäschestapel am Boden"], tags: ["dishes"])
        let outcome = LocalPlanner.plan(roomID: room, roomName: "Schlafzimmer", goal: .order, minutes: 30, energy: .normal,
                                        observed: [], learned: [], previous: previous)
        XCTAssertTrue(outcome.analysis.tags?.contains("laundry") == true)
        XCTAssertTrue(outcome.analysis.tags?.contains("dishes") == true)
        XCTAssertTrue(outcome.analysis.summary.contains("KI"))
    }

    func testInferTagsFromText() {
        XCTAssertEqual(LocalPlanner.inferTags(from: ["Teller auf dem Schreibtisch", "Kabel überall"]),
                       [.dishes, .surfaces, .cables])
    }

    func testAiTasksAreLearnedAndReusedOffline() throws {
        let repository = try HouseholdRepository(storage: MemoryStorage())
        try repository.addRoom(name: "Küche")
        let room = try XCTUnwrap(repository.state.rooms.first)
        func aiTask() -> HouseholdTask {
            HouseholdTask(roomID: room.id, title: "Gewürze nach Art sortieren", goal: .order, estimatedMinutes: 6,
                          steps: [ActionStep(text: "Nimm alle Gewürze heraus", hint: "Küchentisch")], source: .ai)
        }
        try repository.applyPlan(analyses: [], tasks: [aiTask()], goal: .order, minutes: 10, energy: .normal)
        XCTAssertEqual(repository.state.learned.count, 1)
        XCTAssertEqual(repository.state.learned[0].kind, .kitchen)
        try repository.endSession()
        try repository.applyPlan(analyses: [], tasks: [aiTask()], goal: .order, minutes: 10, energy: .normal)
        XCTAssertEqual(repository.state.learned.count, 1)
        XCTAssertEqual(repository.state.learned[0].seen, 2)
        try repository.endSession()

        let outcome = LocalPlanner.plan(roomID: room.id, roomName: "Küche", goal: .order, minutes: 90, energy: .normal,
                                        observed: [], learned: repository.state.learned, previous: nil)
        let reused = try XCTUnwrap(outcome.tasks.first { $0.title == "Gewürze nach Art sortieren" })
        XCTAssertEqual(reused.steps[0].hint, "Küchentisch")
        XCTAssertEqual(reused.source, .local)

        // offline tasks are never learned from, and a background look keeps the task list unchanged
        let local = HouseholdTask(roomID: room.id, title: "Nur lokal", steps: [ActionStep(text: "x")], source: .local)
        try repository.applyPlan(analyses: [], tasks: [local], goal: .order, minutes: 10, energy: .normal)
        XCTAssertEqual(repository.state.learned.count, 1)
        try repository.endSession()
        let taskCount = repository.state.tasks.count
        let analysis = RoomAnalysis(roomID: room.id, goal: .order, photoIDs: [], summary: "s", startHint: "",
                                    detectedPlaces: [], problemZones: [], tags: ["trash"])
        try repository.recordAnalysis(analysis, learningFrom: [HouseholdTask(roomID: room.id, title: "Müll prüfen", steps: [ActionStep(text: "y")], source: .ai)])
        XCTAssertEqual(repository.state.tasks.count, taskCount)
        XCTAssertEqual(repository.state.learned.count, 2)
        XCTAssertEqual(repository.state.latestAnalysis(room.id)?.tags, ["trash"])
    }

    func testOlderFilesWithoutLearnedOrTagsStillLoad() throws {
        let storage = MemoryStorage()
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Bad")
        let room = try XCTUnwrap(repository.state.rooms.first)
        try repository.addAnalysis(RoomAnalysis(roomID: room.id, goal: .order, photoIDs: [], summary: "s", startHint: "",
                                                detectedPlaces: [], problemZones: []))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        json.removeValue(forKey: "learned")
        var analyses = try XCTUnwrap(json["analyses"] as? [[String: Any]])
        analyses[0].removeValue(forKey: "tags")
        json["analyses"] = analyses
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertTrue(restarted.state.learned.isEmpty)
        XCTAssertNil(restarted.state.analyses[0].tags)
    }
}
