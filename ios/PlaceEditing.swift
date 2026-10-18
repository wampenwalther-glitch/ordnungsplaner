import SwiftUI
import OrderCore

/// Type picker with the built-in types, the user's own types and "add own type".
struct PlaceTypePicker: View {
    @Binding var typeName: String
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var newType = ""

    var body: some View {
        Picker("Typ", selection: $typeName) {
            ForEach(model.state.placeTypes, id: \.self) { Text($0).tag($0) }
            if !typeName.isEmpty && !model.state.placeTypes.contains(where: { $0.caseInsensitiveCompare(typeName) == .orderedSame }) {
                Text(typeName).tag(typeName)
            }
        }
        Button("Eigenen Typ hinzufügen …", systemImage: "plus") { adding = true }
            .alert("Neuer Typ", isPresented: $adding) {
                TextField("z. B. Werkzeugwagen", text: $newType)
                Button("Hinzufügen") {
                    let clean = newType.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty, model.perform({ try $0.addPlaceType(clean) }) { typeName = clean }
                    newType = ""
                }
                Button("Abbrechen", role: .cancel) { newType = "" }
            } message: { Text("Der Typ steht danach bei allen Orten zur Auswahl.") }
    }
}

/// Name, type and note of a place.
struct PlaceEditSheet: View {
    let place: StoragePlace
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var typeName: String
    @State private var note: String

    init(place: StoragePlace) {
        self.place = place
        _name = State(initialValue: place.name)
        _typeName = State(initialValue: place.displayType)
        _note = State(initialValue: place.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ort") {
                    TextField("Name", text: $name)
                    PlaceTypePicker(typeName: $typeName)
                }
                Section("Notiz") {
                    TextField("z. B. Oben links, Schlüssel liegt im Fach daneben", text: $note, axis: .vertical).lineLimit(2...6)
                }
            }
            .navigationTitle("Ort bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        if model.perform({ try $0.updatePlace(id: place.id, name: name, typeName: typeName, note: note) }) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Edit one entry of a place's list: name, amount, category, search words and note.
struct ItemEditSheet: View {
    let inventoryID: UUID
    let item: PlaceInventoryItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var count: String
    @State private var category: String
    @State private var tags: String
    @State private var note: String

    private static let defaultCategories = ["Werkzeug", "Elektronik", "Kabel", "Kleidung", "Papiere und Dokumente", "Küche", "Bad",
                                            "Spielzeug", "Bücher", "Deko", "Sonstiges"]

    init(inventoryID: UUID, item: PlaceInventoryItem) {
        self.inventoryID = inventoryID
        self.item = item
        _name = State(initialValue: item.name)
        _count = State(initialValue: item.count ?? "")
        _category = State(initialValue: item.category ?? "")
        _tags = State(initialValue: (item.tags ?? []).joined(separator: ", "))
        _note = State(initialValue: item.note ?? "")
    }

    private var categories: [String] {
        let used = model.state.inventories.flatMap(\.items).compactMap(\.category)
        var seen = Set<String>()
        return (Self.defaultCategories + used).filter { seen.insert($0.lowercased()).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gegenstand") {
                    TextField("Name", text: $name)
                    TextField("Menge, z. B. 3 oder etwa 10", text: $count)
                }
                Section("Ordnen und finden") {
                    TextField("Kategorie", text: $category)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(categories.prefix(14), id: \.self) { entry in
                                Button(entry) { category = entry }.buttonStyle(.bordered).font(.footnote)
                            }
                        }
                    }
                    TextField("Suchbegriffe, durch Komma getrennt", text: $tags)
                    TextField("Notiz", text: $note, axis: .vertical).lineLimit(1...4)
                }
                if item.source == "ai" {
                    Text("Diesen Eintrag hat die KI vorgeschlagen. Du kannst ihn ändern.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Gegenstand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let words = tags.split(separator: ",").map { String($0) }
                        if model.perform({ try $0.updateInventoryItem(inventoryID: inventoryID, itemID: item.id, name: name, count: count,
                                                                      note: note, category: category, tags: words) }) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// "Schnelles Einräumen": the box stays selected while you add one thing after another
/// (typed or dictated with the keyboard's microphone). Scan another box to switch.
struct QuickAddSheet: View {
    @State var placeID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var count = ""
    @State private var addedNames: [String] = []
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Card {
                    Label("Du räumst ein in", systemImage: "shippingbox").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.state.path(for: placeID)).font(.headline)
                    Button("Andere Kiste scannen", systemImage: "qrcode.viewfinder") { scanning = true }.buttonStyle(.bordered)
                }
                HStack {
                    TextField("Gegenstand (oder diktieren)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { add() }
                    TextField("Anzahl", text: $count).textFieldStyle(.roundedBorder).frame(width: 80)
                        .keyboardType(.numbersAndPunctuation)
                }
                BigButton("Hinzufügen", systemImage: "plus") { add() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !addedNames.isEmpty {
                    List {
                        Section("Gerade eingeräumt (\(addedNames.count))") {
                            ForEach(Array(addedNames.reversed().enumerated()), id: \.offset) { _, entry in
                                Label(entry, systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    Text("Tippe den ersten Gegenstand ein und bestätige mit „Hinzufügen“. Die Kiste bleibt ausgewählt, bis du fertig bist.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Einräumen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear { focused = true }
            .sheet(isPresented: $scanning) {
                PlaceScanSheet(prompt: "Scanne die Kiste, in die du jetzt einräumst") { place in
                    placeID = place.id
                    addedNames = []
                    focused = true
                }
            }
        }
    }

    private func add() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if model.perform({ try $0.addInventoryItem(placeID: placeID, name: clean, count: count) }) {
            addedNames.append(count.trimmingCharacters(in: .whitespaces).isEmpty ? clean : "\(count)× \(clean)")
            name = ""; count = ""
            focused = true
        }
    }
}
