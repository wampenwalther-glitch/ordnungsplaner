import XCTest
@testable import OrderCore

final class InventoryEditTests: XCTestCase {
    private func setup() throws -> (HouseholdRepository, MemoryStorage, Room, StoragePlace) {
        let storage = MemoryStorage()
        let repository = try HouseholdRepository(storage: storage)
        try repository.addRoom(name: "Arbeitszimmer")
        let room = try XCTUnwrap(repository.state.rooms.first)
        let place = StoragePlace(roomID: room.id, name: "Elektronik", kind: .box)
        try repository.addPlace(place)
        return (repository, storage, room, place)
    }

    func testEditingAnItemKeepsItFindableByCategoryTagsAndNote() throws {
        let (repository, storage, _, place) = try setup()
        try repository.addInventoryItem(placeID: place.id, name: "Akkuschrauber", count: "1")
        let inventory = try XCTUnwrap(repository.state.latestInventory(place.id))
        let item = inventory.items[0]

        try repository.updateInventoryItem(inventoryID: inventory.id, itemID: item.id, name: " Akkuschrauber Bosch ", count: " 2 ",
                                           note: "Ladegerät fehlt", category: "Werkzeug", tags: ["Bohrer", " ", "Akku"])
        let edited = try XCTUnwrap(repository.state.latestInventory(place.id)?.items.first)
        XCTAssertEqual(edited.name, "Akkuschrauber Bosch")
        XCTAssertEqual(edited.count, "2")
        XCTAssertEqual(edited.category, "Werkzeug")
        XCTAssertEqual(edited.tags, ["Bohrer", "Akku"])
        XCTAssertNotNil(edited.modifiedAt)
        XCTAssertEqual(edited.id, item.id)

        for query in ["bosch", "werkzeug", "bohrer", "Ladegerät", "AKKU"] {
            XCTAssertEqual(repository.state.searchInventory(query).map(\.placeID), [place.id], query)
        }
        XCTAssertTrue(repository.state.searchInventory("hammer").isEmpty)

        try repository.updateInventoryItem(inventoryID: inventory.id, itemID: item.id, name: "Akkuschrauber", count: nil, note: nil,
                                           category: nil, tags: [])
        let cleared = try XCTUnwrap(repository.state.latestInventory(place.id)?.items.first)
        XCTAssertNil(cleared.count); XCTAssertNil(cleared.note); XCTAssertNil(cleared.category); XCTAssertNil(cleared.tags)
        XCTAssertThrowsError(try repository.updateInventoryItem(inventoryID: inventory.id, itemID: item.id, name: "  ", count: nil,
                                                                note: nil, category: nil, tags: []))
        XCTAssertThrowsError(try repository.updateInventoryItem(inventoryID: inventory.id, itemID: UUID(), name: "x", count: nil,
                                                                note: nil, category: nil, tags: []))
        XCTAssertEqual(try HouseholdRepository(storage: storage).state.latestInventory(place.id)?.items.first?.name, "Akkuschrauber")
    }

    func testPlaceTypesNotesAndLastChange() throws {
        let (repository, storage, room, place) = try setup()
        XCTAssertEqual(repository.state.places[0].displayType, "Kiste")
        XCTAssertNil(repository.state.lastChange(of: place.id))

        try repository.updatePlace(id: place.id, name: " Elektronik und Kabel ", typeName: "Regalfach", note: " Oben links ")
        var current = try XCTUnwrap(repository.state.places.first)
        XCTAssertEqual(current.name, "Elektronik und Kabel")
        XCTAssertEqual(current.displayType, "Regalfach")
        XCTAssertEqual(current.kind, .storage)                                  // Regalfach is not a container type
        XCTAssertEqual(current.note, "Oben links")
        XCTAssertNotNil(current.changedAt)
        XCTAssertNotNil(repository.state.lastChange(of: place.id))

        try repository.updatePlace(id: place.id, name: "Kabel", typeName: "Box", note: "  ")
        current = try XCTUnwrap(repository.state.places.first)
        XCTAssertEqual(current.kind, .box); XCTAssertNil(current.note)
        XCTAssertThrowsError(try repository.updatePlace(id: place.id, name: " ", typeName: nil, note: nil))
        XCTAssertThrowsError(try repository.updatePlace(id: UUID(), name: "x", typeName: nil, note: nil))

        // own types join the list once, without duplicates of built-in ones
        try repository.addPlaceType("Werkzeugwagen")
        try repository.addPlaceType("werkzeugwagen")
        try repository.addPlaceType("SCHRANK")
        XCTAssertEqual(repository.state.customPlaceTypes, ["Werkzeugwagen"])
        XCTAssertTrue(repository.state.placeTypes.contains("Werkzeugwagen"))
        XCTAssertEqual(repository.state.placeTypes.filter { $0.lowercased() == "schrank" }.count, 1)
        XCTAssertThrowsError(try repository.addPlaceType("  "))

        // last change also follows photos and the list
        try repository.addInventoryItem(placeID: place.id, name: "Kabel")
        let afterItem = try XCTUnwrap(repository.state.lastChange(of: place.id))
        try repository.addPlacePhoto(placeID: place.id, jpegData: Data([1]), at: afterItem.addingTimeInterval(60))
        XCTAssertEqual(repository.state.lastChange(of: place.id), afterItem.addingTimeInterval(60))

        // children, sorted by name; nil parent lists places directly in a room
        let drawer = StoragePlace(roomID: room.id, name: "Zweite Schublade", parentID: place.id)
        let drawer2 = StoragePlace(roomID: room.id, name: "Erste Schublade", parentID: place.id)
        try repository.addPlace(drawer); try repository.addPlace(drawer2)
        XCTAssertEqual(repository.state.children(of: place.id).map(\.name), ["Erste Schublade", "Zweite Schublade"])
        XCTAssertEqual(repository.state.children(of: nil, inRoom: room.id).map(\.name), ["Kabel"])
        XCTAssertEqual(try HouseholdRepository(storage: storage).state.customPlaceTypes, ["Werkzeugwagen"])
    }

    func testAllNineMovingStatusesKeepOlderStoredValues() throws {
        XCTAssertEqual(PlaceStatus.allCases.map(\.label), ["Noch sortieren", "Bleibt", "Mitnehmen", "Bereits gepackt", "Verkaufen",
                                                           "Verschenken", "Spenden", "Entsorgen", "Zwischenlagern"])
        for old in ["stays", "packed", "take", "sell", "donate", "check"] {
            XCTAssertNotNil(PlaceStatus(rawValue: old), old)                        // values saved by earlier versions
        }
        let (repository, _, _, place) = try setup()
        for status in PlaceStatus.allCases {
            try repository.setPlaceStatus(id: place.id, status: status)
            XCTAssertEqual(repository.state.places[0].status, status)
        }
    }

    func testAiPlacesGetTypeNamesAndOlderFilesStillLoad() throws {
        let (repository, storage, room, _) = try setup()
        try repository.adoptDetectedPlaces(roomID: room.id, [DetectedPlace(name: "Schrank links", kind: "schrank", note: ""),
                                                             DetectedPlace(name: "Etwas", kind: "sonstiges", note: "")])
        XCTAssertEqual(repository.state.places.first { $0.name == "Schrank links" }?.displayType, "Schrank")
        XCTAssertEqual(repository.state.places.first { $0.name == "Etwas" }?.displayType, "Sonstiger Lagerort")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.data)) as? [String: Any])
        json.removeValue(forKey: "customPlaceTypes")
        var places = try XCTUnwrap(json["places"] as? [[String: Any]])
        for index in places.indices { places[index].removeValue(forKey: "typeName") }
        json["places"] = places
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let restarted = try HouseholdRepository(storage: storage)
        XCTAssertTrue(restarted.state.customPlaceTypes.isEmpty)
        XCTAssertEqual(restarted.state.places.first { $0.name == "Schrank links" }?.displayType, "Schrank")   // derived from the AI form
        XCTAssertEqual(restarted.state.places.first { $0.name == "Elektronik" }?.displayType, "Kiste")        // derived from the kind
    }
}
