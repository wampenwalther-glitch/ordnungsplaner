import XCTest
@testable import OrderCore

final class WhereIsWhatTests: XCTestCase {
    private func twoRooms() throws -> (HouseholdRepository, MemoryStorage, Room, Room) {
        let storage = MemoryStorage()
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Arbeitszimmer")
        try repository.addRoom(name: "Keller")
        return (repository, storage, repository.state.rooms[0], repository.state.rooms[1])
    }

    func testPlaceLinkRoundTripAndForeignTextIsRejected() {
        let id = UUID()
        XCTAssertEqual(PlaceLink.url(for: id).absoluteString, "ordnungsplaner://place/\(id.uuidString)")
        XCTAssertEqual(PlaceLink.placeID(from: PlaceLink.url(for: id).absoluteString), id)
        XCTAssertEqual(PlaceLink.placeID(from: "  \(id.uuidString.lowercased()) \n"), id)
        XCTAssertNil(PlaceLink.placeID(from: "https://example.com/place/\(id.uuidString)"))
        XCTAssertNil(PlaceLink.placeID(from: "ordnungsplaner://room/\(id.uuidString)"))
        XCTAssertNil(PlaceLink.placeID(from: "ordnungsplaner://place/keine-uuid"))
        XCTAssertNil(PlaceLink.placeID(from: "Hallo"))
    }

    func testScanFindsPlaceByLinkUuidOrPrintedCode() throws {
        let (repository, _, room, _) = try twoRooms()
        let box = StoragePlace(roomID: room.id, name: "Kabel", kind: .box, code: "K07")
        try repository.addPlace(box)
        let state = repository.state
        XCTAssertEqual(state.place(forScan: PlaceLink.url(for: box.id).absoluteString)?.id, box.id)
        XCTAssertEqual(state.place(forScan: box.id.uuidString)?.id, box.id)
        XCTAssertEqual(state.place(forScan: " k07 ")?.id, box.id)
        XCTAssertNil(state.place(forScan: "K99"))
        XCTAssertNil(state.place(forScan: PlaceLink.url(for: UUID()).absoluteString))
        XCTAssertNil(state.place(forScan: ""))
    }

    func testLabelCodesAreAssignedOnceAndNeverClash() throws {
        let (repository, _, room, _) = try twoRooms()
        let first = StoragePlace(roomID: room.id, name: "Kiste 1", kind: .box)
        let second = StoragePlace(roomID: room.id, name: "Kiste 2", kind: .box)
        let shelf = StoragePlace(roomID: room.id, name: "Regal")
        let taken = StoragePlace(roomID: room.id, name: "Schon beschriftet", kind: .box, code: "k02")
        for place in [first, second, shelf, taken] { try repository.addPlace(place) }
        XCTAssertEqual(try repository.ensureLabelCode(placeID: first.id), "K01")
        XCTAssertEqual(try repository.ensureLabelCode(placeID: first.id), "K01")     // stable
        XCTAssertEqual(try repository.ensureLabelCode(placeID: second.id), "K03")    // K02 is taken (case-insensitive)
        XCTAssertEqual(try repository.ensureLabelCode(placeID: shelf.id), "L01")
        XCTAssertEqual(try repository.ensureLabelCode(placeID: taken.id), "k02")     // existing code is kept
        XCTAssertThrowsError(try repository.ensureLabelCode(placeID: UUID()))
    }

    func testStatusCanBeSetClearedAndListed() throws {
        let (repository, _, room, _) = try twoRooms()
        let a = StoragePlace(roomID: room.id, name: "A", kind: .box), b = StoragePlace(roomID: room.id, name: "B", kind: .box)
        try repository.addPlace(a); try repository.addPlace(b)
        try repository.setPlaceStatus(id: a.id, status: .take)
        try repository.setPlaceStatus(id: b.id, status: .donate)
        XCTAssertEqual(repository.state.places(with: .take).map(\.name), ["A"])
        XCTAssertEqual(Set(repository.state.places(with: nil).map(\.name)), ["A", "B"])
        try repository.setPlaceStatus(id: a.id, status: nil)
        XCTAssertEqual(repository.state.places(with: nil).map(\.name), ["B"])
        XCTAssertThrowsError(try repository.setPlaceStatus(id: UUID(), status: .sell))
        XCTAssertEqual(PlaceStatus.allCases.count, 6)
        XCTAssertTrue(PlaceStatus.allCases.allSatisfy { !$0.label.isEmpty && !$0.symbol.isEmpty })
    }

    func testMovingAShelfToAnotherRoomTakesEverythingAlong() throws {
        let (repository, storage, office, cellar) = try twoRooms()
        let shelf = StoragePlace(roomID: office.id, name: "Regal 2")
        let box = StoragePlace(roomID: office.id, name: "Elektronik", kind: .box, parentID: shelf.id, code: "K01")
        let other = StoragePlace(roomID: cellar.id, name: "Kellerregal")
        for place in [shelf, box, other] { try repository.addPlace(place) }
        try repository.addPlacePhoto(placeID: box.id, jpegData: Data([1]))
        var step = ActionStep(text: "Kabel in die Kiste", targetPlaceID: box.id, hint: "Elektronik")
        step.completedAt = Date(timeIntervalSince1970: 5)
        try repository.addTask(HouseholdTask(roomID: office.id, title: "Kabel", steps: [step, ActionStep(text: "Zweiter Schritt")]))

        XCTAssertThrowsError(try repository.movePlace(id: shelf.id, parentID: other.id))                 // other room without roomID
        XCTAssertThrowsError(try repository.movePlace(id: shelf.id, parentID: box.id))                   // into its own sub-place
        XCTAssertEqual(repository.state.places.first { $0.id == shelf.id }?.roomID, office.id)           // failed moves change nothing

        try repository.movePlace(id: shelf.id, parentID: other.id, roomID: cellar.id)
        let state = repository.state
        XCTAssertEqual(state.places.first { $0.id == shelf.id }?.roomID, cellar.id)
        XCTAssertEqual(state.places.first { $0.id == box.id }?.roomID, cellar.id)                         // sub-place followed
        XCTAssertEqual(state.places.first { $0.id == shelf.id }?.parentID, other.id)
        XCTAssertEqual(state.path(for: box.id), "Keller › Kellerregal › Regal 2 › K01 · Elektronik")
        XCTAssertEqual(state.photoPoints.first { $0.placeID == box.id }?.roomID, cellar.id)
        let moved = try XCTUnwrap(state.tasks.first?.steps.first)
        XCTAssertNil(moved.targetPlaceID)                                                                  // task stays valid
        XCTAssertEqual(moved.hint, "Elektronik")
        XCTAssertEqual(moved.completedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try HouseholdRepository(storage: storage).state.places.first { $0.id == box.id }?.roomID, cellar.id)

        try repository.movePlace(id: shelf.id, parentID: nil, roomID: office.id)                           // and straight into a room
        XCTAssertNil(repository.state.places.first { $0.id == shelf.id }?.parentID)
        XCTAssertEqual(repository.state.subtree(of: shelf.id), [shelf.id, box.id])
    }

    func testItemsMoveBetweenPlacesAndCanBeMarkedEmpty() throws {
        let (repository, _, room, _) = try twoRooms()
        let box = StoragePlace(roomID: room.id, name: "Kiste", kind: .box), shelf = StoragePlace(roomID: room.id, name: "Regal")
        try repository.addPlace(box); try repository.addPlace(shelf)
        try repository.addInventoryItem(placeID: box.id, name: "Akkuschrauber", count: "1")
        let inventory = try XCTUnwrap(repository.state.latestInventory(box.id))
        let item = inventory.items[0]
        XCTAssertNotNil(item.addedAt)

        XCTAssertThrowsError(try repository.moveInventoryItem(inventoryID: inventory.id, itemID: item.id, toPlace: box.id))
        XCTAssertThrowsError(try repository.moveInventoryItem(inventoryID: inventory.id, itemID: UUID(), toPlace: shelf.id))
        try repository.moveInventoryItem(inventoryID: inventory.id, itemID: item.id, toPlace: shelf.id)
        XCTAssertTrue(repository.state.latestInventory(box.id)?.items.isEmpty == true)
        let there = try XCTUnwrap(repository.state.latestInventory(shelf.id)?.items.first)
        XCTAssertEqual(there.name, "Akkuschrauber"); XCTAssertEqual(there.count, "1")
        XCTAssertEqual(repository.state.searchInventory("akkuschrauber").map(\.placeID), [shelf.id])

        try repository.markPlaceEmpty(placeID: shelf.id)
        XCTAssertTrue(repository.state.searchInventory("akkuschrauber").isEmpty)
        XCTAssertEqual(repository.state.latestInventory(shelf.id)?.summary, "Als leer markiert")
        XCTAssertThrowsError(try repository.markPlaceEmpty(placeID: UUID()))
    }

    func testOlderFilesWithoutStatusOrAddedDateStillLoad() throws {
        let (repository, storage, room, _) = try twoRooms()
        let box = StoragePlace(roomID: room.id, name: "Kiste", kind: .box, status: .check)
        try repository.addPlace(box)
        try repository.addInventoryItem(placeID: box.id, name: "Ding")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        var places = try XCTUnwrap(json["places"] as? [[String: Any]])
        places[0].removeValue(forKey: "status")
        json["places"] = places
        var inventories = try XCTUnwrap(json["inventories"] as? [[String: Any]])
        var items = try XCTUnwrap(inventories[0]["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "addedAt")
        inventories[0]["items"] = items
        json["inventories"] = inventories
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertNil(restarted.state.places[0].status)
        XCTAssertNil(restarted.state.inventories[0].items[0].addedAt)
    }
}
