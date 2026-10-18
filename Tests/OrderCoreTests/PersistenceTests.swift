import XCTest
@testable import OrderCore

final class PersistenceTests: XCTestCase {
    private func tempStorage() -> (FileStateStorage, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ordnungsplaner-test-\(UUID().uuidString)", isDirectory: true)
        return (FileStateStorage(fileURL: dir.appendingPathComponent("household.json")), dir)
    }

    func testPhotosLiveInOwnFilesAndMainFileStaysSmall() throws {
        let (storage, dir) = tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Flur")
        let room = try XCTUnwrap(repository.state.rooms.first)
        let big = Data(repeating: 7, count: 400_000)
        try repository.addRoomPhoto(roomID: room.id, jpegData: big)
        let id = try XCTUnwrap(repository.state.roomPhotos(room.id).first?.id)

        let main = try Data(contentsOf: dir.appendingPathComponent("household.json"))
        XCTAssertLessThan(main.count, 5_000)                       // no image bytes in the main file
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("photos/\(id.uuidString).jpg")), big)

        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.state.roomPhotos(room.id).first?.jpegData, big)
        XCTAssertEqual(restarted.lostPhotoCount, 0)

        try restarted.deletePhotos(ids: [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/\(id.uuidString).jpg").path))
        XCTAssertTrue(try HouseholdRepository(storage: storage).state.roomPhotos(room.id).isEmpty)
    }

    func testOldFileWithInlinePhotosIsMovedOnNextSave() throws {
        let (storage, dir) = tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        // build an old-style file: photo bytes inside the main file
        let memory = MemoryStorage()
        let source = try HouseholdRepository(storage: memory)
        try source.addRoom(name: "Bad")
        let room = try XCTUnwrap(source.state.rooms.first)
        try source.addRoomPhoto(roomID: room.id, jpegData: Data([1, 2, 3, 4]))
        try storage.save(try source.exportData())                  // export keeps photos inline

        let repository = try HouseholdRepository(storage: storage)
        XCTAssertEqual(repository.state.roomPhotos(room.id).first?.jpegData, Data([1, 2, 3, 4]))
        try repository.addRoom(name: "Küche")                       // any save migrates
        let id = try XCTUnwrap(repository.state.roomPhotos(room.id).first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/\(id.uuidString).jpg").path))
        let again = try HouseholdRepository(storage: storage)
        XCTAssertEqual(again.state.rooms.count, 2)
        XCTAssertEqual(again.state.roomPhotos(room.id).first?.jpegData, Data([1, 2, 3, 4]))
    }

    func testMissingPhotoFileDoesNotBlockLoadingAndIsCounted() throws {
        let (storage, dir) = tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Flur")
        let room = try XCTUnwrap(repository.state.rooms.first)
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([9]))
        let id = try XCTUnwrap(repository.state.roomPhotos(room.id).first?.id)
        storage.deleteBlob(id: id)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.lostPhotoCount, 1)
        XCTAssertEqual(restarted.state.rooms.count, 1)
        XCTAssertTrue(restarted.state.roomPhotos(room.id).isEmpty)
    }

    func testExportKeepsPhotosAndRestoreWritesThemAsFiles() throws {
        let (storage, dir) = tempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = MemoryStorage()
        let source = try HouseholdRepository(storage: memory)
        try source.addRoom(name: "Flur")
        let room = try XCTUnwrap(source.state.rooms.first)
        try source.addRoomPhoto(roomID: room.id, jpegData: Data([5, 5, 5]))
        let backup = try source.exportData()
        XCTAssertTrue(try HouseholdRepository.decode(backup).photos.allSatisfy { !$0.jpegData.isEmpty })

        let target = try HouseholdRepository(storage: storage)
        try target.replace(with: backup)
        let id = try XCTUnwrap(target.state.roomPhotos(room.id).first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/\(id.uuidString).jpg").path))
        XCTAssertEqual(try HouseholdRepository(storage: storage).state.roomPhotos(room.id).first?.jpegData, Data([5, 5, 5]))
    }

    func testFailedWriteLeavesNoHalfState() throws {
        let storage = MemoryStorage()
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Flur")
        let room = try XCTUnwrap(repository.state.rooms.first)
        storage.failWrites = true
        XCTAssertThrowsError(try repository.addRoomPhoto(roomID: room.id, jpegData: Data([1])))
        XCTAssertTrue(repository.state.photos.isEmpty)
        storage.failWrites = false
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([1]))
        XCTAssertEqual(storage.blobs.count, 1)
    }

    func testOutdatedPhotosKeepKnowledgeAndProgressComparesLooks() throws {
        let repository = try HouseholdRepository(storage: MemoryStorage())
        try repository.addRoom(name: "Küche")
        let room = try XCTUnwrap(repository.state.rooms.first)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([1]), at: t0)
        let firstPhoto = repository.state.roomPhotos(room.id)[0]
        XCTAssertFalse(repository.state.isAnalysisCurrent(room.id))
        XCTAssertTrue(repository.state.outdatedRoomPhotos(room.id).isEmpty)

        try repository.addAnalysis(RoomAnalysis(roomID: room.id, createdAt: t0.addingTimeInterval(60), goal: .order,
            photoIDs: [firstPhoto.id], summary: "Voll", startHint: "", detectedPlaces: [], problemZones: ["Teller"],
            tags: ["dishes", "laundry", "papers"]))
        XCTAssertTrue(repository.state.isAnalysisCurrent(room.id))
        XCTAssertEqual(repository.state.outdatedRoomPhotos(room.id).count, 1)
        XCTAssertEqual(repository.state.allOutdatedPhotos.count, 1)
        XCTAssertNil(repository.state.progress(room.id))            // only one look so far

        try repository.deletePhotos(ids: repository.state.allOutdatedPhotos.map(\.id))
        XCTAssertTrue(repository.state.isAnalysisCurrent(room.id))  // knowledge survives deleting the pictures
        XCTAssertEqual(repository.state.photoBytes, 0)

        // after tidying: new photo, new look
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([2]), at: t0.addingTimeInterval(3_600))
        XCTAssertFalse(repository.state.isAnalysisCurrent(room.id))
        let secondPhoto = repository.state.roomPhotos(room.id)[0]
        try repository.addAnalysis(RoomAnalysis(roomID: room.id, createdAt: t0.addingTimeInterval(3_660), goal: .order,
            photoIDs: [secondPhoto.id], summary: "Besser", startHint: "", detectedPlaces: [], problemZones: [],
            tags: ["papers", "dust"]))
        let progress = try XCTUnwrap(repository.state.progress(room.id))
        XCTAssertEqual(progress.notSeenAnymore, [.dishes, .laundry])
        XCTAssertEqual(progress.stillSeen, [.papers])
        XCTAssertEqual(progress.newlySeen, [.dust])

        // a place's stock-taking covers its photos the same way
        let place = StoragePlace(roomID: room.id, name: "Kiste", kind: .box)
        try repository.addPlace(place)
        try repository.addPlacePhoto(placeID: place.id, jpegData: Data([3]), at: t0)
        let placePhoto = repository.state.placePhotos(place.id)[0]
        XCTAssertTrue(repository.state.outdatedPlacePhotos(place.id).isEmpty)
        try repository.recordInventory(PlaceInventory(placeID: place.id, createdAt: t0.addingTimeInterval(10), photoIDs: [placePhoto.id],
                                                      summary: "", items: [PlaceInventoryItem(name: "Kabel")]))
        XCTAssertEqual(repository.state.outdatedPlacePhotos(place.id).count, 1)
    }
}
