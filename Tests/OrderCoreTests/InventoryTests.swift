import XCTest
@testable import OrderCore

final class InventoryTests: XCTestCase {
    private func fixture(_ storage: MemoryStorage = MemoryStorage()) throws -> (HouseholdRepository, Room, StoragePlace) {
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Keller")
        let room = try XCTUnwrap(repository.state.rooms.first)
        let place = StoragePlace(roomID: room.id, name: "Kabelkiste", kind: .box, code: "A07")
        try repository.addPlace(place)
        return (repository, room, place)
    }

    func testPlacePhotosStayOutOfRoomPhotos() throws {
        let (repository, room, place) = try fixture()
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([1]))
        try repository.addPlacePhoto(placeID: place.id, jpegData: Data([2]))
        try repository.addPlacePhoto(placeID: place.id, jpegData: Data([3]))
        XCTAssertEqual(repository.state.roomPhotos(room.id).count, 1)
        XCTAssertEqual(repository.state.placePhotos(place.id).count, 2)
        XCTAssertEqual(repository.state.photoPoints.count, 2)
        XCTAssertThrowsError(try repository.addPlacePhoto(placeID: UUID(), jpegData: Data([4])))
        XCTAssertEqual(repository.state.photos.count, 3)
    }

    func testInventoryRecordEditSearchAndPersistence() throws {
        let storage = MemoryStorage()
        let (repository, _, place) = try fixture(storage)
        try repository.recordInventory(PlaceInventory(placeID: place.id, photoIDs: [], summary: "Kabel und Netzteile",
            items: [PlaceInventoryItem(name: "USB-Kabel", count: "5", source: "ai"), PlaceInventoryItem(name: "Netzteil", source: "ai")]))
        XCTAssertEqual(repository.state.searchInventory("kabel").map(\.placeID), [place.id])
        XCTAssertTrue(repository.state.searchInventory("   ").isEmpty)

        try repository.addInventoryItem(placeID: place.id, name: "  Ladekabel ", count: "2")
        XCTAssertEqual(repository.state.latestInventory(place.id)?.items.count, 3)
        XCTAssertEqual(repository.state.searchInventory("Kabel").count, 2)
        XCTAssertThrowsError(try repository.addInventoryItem(placeID: place.id, name: "   "))

        let inventory = try XCTUnwrap(repository.state.latestInventory(place.id))
        try repository.removeInventoryItem(inventoryID: inventory.id, itemID: inventory.items[0].id)
        XCTAssertEqual(repository.state.searchInventory("kabel").count, 1)

        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertEqual(restarted.state.latestInventory(place.id)?.items.map(\.name), ["Netzteil", "Ladekabel"])
        XCTAssertEqual(restarted.state.latestInventory(place.id)?.items.last?.source, "manual")
    }

    func testManualItemCreatesInventoryAndOnlyThreeAreKept() throws {
        let (repository, _, place) = try fixture()
        try repository.addInventoryItem(placeID: place.id, name: "Schraubenzieher")
        XCTAssertEqual(repository.state.inventories.count, 1)
        for index in 1...4 {
            try repository.recordInventory(PlaceInventory(placeID: place.id, createdAt: Date(timeIntervalSinceNow: Double(index)),
                photoIDs: [], summary: "Stand \(index)", items: [PlaceInventoryItem(name: "Ding \(index)")]))
        }
        XCTAssertEqual(repository.state.inventories.count, 3)
        XCTAssertEqual(repository.state.latestInventory(place.id)?.summary, "Stand 4")
        XCTAssertThrowsError(try repository.recordInventory(PlaceInventory(placeID: UUID(), photoIDs: [], summary: "", items: [])))
    }

    func testOlderFilesWithoutInventoriesOrPhotoPointPlaceLoad() throws {
        let storage = MemoryStorage()
        let (repository, room, _) = try fixture(storage)
        try repository.addRoomPhoto(roomID: room.id, jpegData: Data([1]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        json.removeValue(forKey: "inventories")
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertTrue(restarted.state.inventories.isEmpty)
        XCTAssertEqual(restarted.state.roomPhotos(room.id).count, 1)
    }
}
