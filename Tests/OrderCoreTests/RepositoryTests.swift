import XCTest
@testable import OrderCore

final class MemoryStorage: StateStorage {
    var data: Data?
    var failWrites = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if failWrites { throw OrderError.invalid("Datenträger nicht verfügbar") }
        self.data = data
    }
}

final class RepositoryTests: XCTestCase {
    private func fixture(_ storage: MemoryStorage = MemoryStorage()) throws -> (HouseholdRepository, HouseholdTask) {
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Arbeitszimmer")
        let room = try XCTUnwrap(repository.state.rooms.first)
        let shelf = StoragePlace(roomID: room.id, name: "Oberes Regalfach")
        try repository.addPlace(shelf)
        let box = StoragePlace(roomID: room.id, name: "Kabel", kind: .box, parentID: shelf.id, code: "A07")
        try repository.addPlace(box)
        let task = HouseholdTask(roomID: room.id, title: "Kabel wegräumen", estimatedMinutes: 3, steps: [
            ActionStep(text: "Kiste öffnen", targetPlaceID: box.id),
            ActionStep(text: "USB-Kabel hineinlegen", targetPlaceID: box.id),
            ActionStep(text: "Kiste ins Fach zurückstellen", targetPlaceID: shelf.id)
        ])
        try repository.addTask(task)
        try repository.startSession(taskIDs: [task.id], goal: .order, minutes: 10, energy: .normal)
        return (repository, task)
    }

    func testCompleteRestartResumeAndUndo() throws {
        let storage = MemoryStorage()
        let (repository, task) = try fixture(storage)
        try repository.completeCurrentStep(expectedStepID: task.steps[0].id)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.state.currentTask?.nextStep?.id, task.steps[1].id)
        XCTAssertEqual(restarted.state.events.count, 1)
        try restarted.undoCompletion()
        XCTAssertEqual(restarted.state.currentTask?.nextStep?.id, task.steps[0].id)
        XCTAssertEqual(restarted.state.events.count, 0)
        XCTAssertNil(restarted.state.undoRecord)
    }

    func testDiskFailureDoesNotPublishCompletedStep() throws {
        let storage = MemoryStorage()
        let (repository, task) = try fixture(storage)
        let priorState = repository.state
        let priorBytes = storage.data
        storage.failWrites = true
        XCTAssertThrowsError(try repository.completeCurrentStep(expectedStepID: task.steps[0].id))
        XCTAssertEqual(repository.state, priorState)
        XCTAssertEqual(storage.data, priorBytes)
    }

    func testDuplicateTapCannotCompleteTheNextStep() throws {
        let (repository, task) = try fixture()
        try repository.completeCurrentStep(expectedStepID: task.steps[0].id)
        XCTAssertThrowsError(try repository.completeCurrentStep(expectedStepID: task.steps[0].id))
        XCTAssertEqual(repository.state.currentTask?.nextStep?.id, task.steps[1].id)
        XCTAssertEqual(repository.state.events.count, 1)
    }

    func testPausePersistsAndBlocksCompletionUntilResumed() throws {
        let storage = MemoryStorage()
        let (repository, task) = try fixture(storage)
        try repository.pause()
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.state.session?.status, .paused)
        XCTAssertThrowsError(try restarted.completeCurrentStep(expectedStepID: task.steps[0].id))
        try restarted.resume()
        try restarted.completeCurrentStep(expectedStepID: task.steps[0].id)
        XCTAssertEqual(restarted.state.currentTask?.nextStep?.id, task.steps[1].id)
    }

    func testFinishAndUndoRestoreTheLastActiveStep() throws {
        let (repository, task) = try fixture()
        for step in task.steps { try repository.completeCurrentStep(expectedStepID: step.id) }
        XCTAssertEqual(repository.state.session?.status, .finished)
        XCTAssertTrue(repository.state.tasks[0].isComplete)
        try repository.undoCompletion()
        XCTAssertEqual(repository.state.session?.status, .active)
        XCTAssertEqual(repository.state.currentTask?.nextStep?.id, task.steps[2].id)
    }

    func testLocationCycleIsRejectedWithoutSaving() throws {
        let storage = MemoryStorage()
        let (repository, _) = try fixture(storage)
        let shelf = repository.state.places[0]
        let box = repository.state.places[1]
        let bytes = storage.data
        XCTAssertThrowsError(try repository.movePlace(id: shelf.id, parentID: box.id))
        XCTAssertEqual(storage.data, bytes)
        XCTAssertEqual(repository.state.path(for: box.id), "Arbeitszimmer › Oberes Regalfach › A07 · Kabel")
    }

    func testDuplicateBoxCodeCaseInsensitiveIsRejected() throws {
        let (repository, _) = try fixture()
        let room = repository.state.rooms[0]
        XCTAssertThrowsError(try repository.addPlace(StoragePlace(roomID: room.id, name: "Zweite Kiste", kind: .box, code: "a07")))
        XCTAssertEqual(repository.state.places.count, 2)
    }

    func testBudgetEnergyAndGoalFilterDoNotInventTasks() throws {
        let (repository, task) = try fixture()
        XCTAssertEqual(repository.suggestedTasks(goal: .order, minutes: 5, energy: .normal).map(\.id), [task.id])
        XCTAssertTrue(repository.suggestedTasks(goal: .order, minutes: 5, energy: .low).isEmpty)
        XCTAssertTrue(repository.suggestedTasks(goal: .visitors, minutes: 20, energy: .high).isEmpty)
        XCTAssertTrue(repository.suggestedTasks(goal: .order, minutes: 2, energy: .high).isEmpty)
    }

    func testSecondSessionCannotReplaceActiveOrPausedWork() throws {
        let (repository, task) = try fixture()
        XCTAssertThrowsError(try repository.startSession(taskIDs: [task.id], goal: .order, minutes: 10, energy: .normal))
        try repository.pause()
        XCTAssertThrowsError(try repository.startSession(taskIDs: [task.id], goal: .order, minutes: 10, energy: .normal))
    }

    func testUnknownSchemaAndCorruptDataAreNotOverwritten() throws {
        let storage = MemoryStorage()
        storage.data = Data("{\"schemaVersion\":99}".utf8)
        XCTAssertThrowsError(try HouseholdRepository(storage: storage))
        XCTAssertEqual(storage.data, Data("{\"schemaVersion\":99}".utf8))
        storage.data = Data("not json".utf8)
        XCTAssertThrowsError(try HouseholdRepository(storage: storage))
        XCTAssertEqual(storage.data, Data("not json".utf8))
    }

    func testPhotoAndScanSurviveExportAndRestore() throws {
        let (repository, _) = try fixture()
        let room = repository.state.rooms[0]
        let point = PhotoPoint(roomID: room.id, name: "Türrahmen Richtung Fenster")
        try repository.addPhotoPoint(point)
        try repository.addPhoto(RoomPhoto(pointID: point.id, jpegData: Data([0xff, 0xd8, 0xff, 0xd9])))
        try repository.addScan(RoomScanRecord(roomID: room.id, walls: 4, doors: 1, windows: 1, objects: 3, encodedRoom: Data("geometry".utf8)))
        let restored = try HouseholdRepository(storage: MemoryStorage())
        try restored.replace(with: repository.exportData())
        XCTAssertEqual(restored.state.photos, repository.state.photos)
        XCTAssertEqual(restored.state.scans, repository.state.scans)
        XCTAssertEqual(restored.state.currentTask?.nextStep?.id, repository.state.currentTask?.nextStep?.id)
    }

    func testRealFileRestartAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileStateStorage(fileURL: directory.appendingPathComponent("state.json"))
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Küche")
        let task = HouseholdTask(roomID: repository.state.rooms[0].id, title: "Fläche frei", steps: [
            ActionStep(text: "Geschirr zusammenstellen"), ActionStep(text: "Fläche wischen")
        ])
        try repository.addTask(task)
        try repository.startSession(taskIDs: [task.id], goal: .order, minutes: 10, energy: .normal)
        try repository.completeCurrentStep(expectedStepID: task.steps[0].id)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.state.currentTask?.nextStep?.id, task.steps[1].id)
        try restarted.undoCompletion()
        XCTAssertEqual(try HouseholdRepository(storage: storage).state.currentTask?.nextStep?.id, task.steps[0].id)
    }
}
