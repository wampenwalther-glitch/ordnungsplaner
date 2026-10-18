import SwiftUI
import OrderCore

private struct InlineSaveError: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let message = model.error {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityLabel("Nicht gespeichert: \(message)")
        }
    }
}

struct NewRoomForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                InlineSaveError()
                TextField("Raumname", text: $name)
                Section("Vorschläge") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(["Wohnzimmer", "Schlafzimmer", "Küche", "Bad", "Flur", "Arbeitszimmer", "Kinderzimmer", "Keller", "Abstellraum"], id: \.self) { suggestion in
                                Button(suggestion) { name = suggestion }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Text("Danach machst du im Raum vier Fotos – die KI erkennt daraus Regale, Schränke und Unordnung.")
                    .font(.caption).foregroundStyle(.secondary)
            }
                .navigationTitle("Neuer Raum")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Speichern") { if model.perform({ try $0.addRoom(name: name) }) { dismiss() } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

struct PlaceForm: View {
    let roomID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: PlaceKind = .storage
    @State private var code = ""
    @State private var parentID: UUID?
    var body: some View {
        NavigationStack {
            Form {
                InlineSaveError()
                TextField("Name, z. B. oberes Regalfach", text: $name)
                Picker("Art", selection: $kind) { ForEach(PlaceKind.allCases) { Text($0.label).tag($0) } }
                if kind == .box { TextField("Kennung, z. B. A07", text: $code).textInputAutocapitalization(.characters) }
                Picker("Steht in", selection: $parentID) {
                    Text("Direkt im Raum").tag(Optional<UUID>.none)
                    ForEach(model.state.places.filter { $0.roomID == roomID }) { Text(model.state.path(for: $0.id)).tag(Optional($0.id)) }
                }
                Text("Erfasse nur tatsächlich vorhandene Orte. Ein Name bestätigt noch keinen Inhalt oder freien Platz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Lagerort anlegen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let place = StoragePlace(roomID: roomID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                            parentID: parentID, code: kind == .box && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : nil)
                        if model.perform({ try $0.addPlace(place) }) { dismiss() }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct MovePlaceForm: View {
    let place: StoragePlace
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var parentID: UUID?
    init(place: StoragePlace) { self.place = place; _parentID = State(initialValue: place.parentID) }
    var body: some View {
        NavigationStack {
            Form {
                InlineSaveError()
                Text(model.state.path(for: place.id)).font(.headline)
                Picker("Neuer Standort", selection: $parentID) {
                    Text("Direkt im Raum").tag(Optional<UUID>.none)
                    ForEach(model.state.places.filter { $0.roomID == place.roomID && $0.id != place.id }) {
                        Text(model.state.path(for: $0.id)).tag(Optional($0.id))
                    }
                }
                Text("Bestätige erst, wenn du den Lagerort oder die Kiste tatsächlich dorthin gestellt hast. Andere Räume werden in diesem Prototyp noch nicht unterstützt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Standort bestätigen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bestätigen") {
                        if model.perform({ try $0.movePlace(id: place.id, parentID: parentID) }) { dismiss() }
                    }
                }
            }
        }
    }
}

struct NewTaskForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var roomID: UUID?
    @State private var targetID: UUID?
    @State private var goal: Goal = .order
    @State private var energy: Energy = .normal
    @State private var minutes = 5
    @State private var steps = ""
    var body: some View {
        NavigationStack {
            Form {
                InlineSaveError()
                Section("Aufgabe") {
                    TextField("Was möchtest du erledigen?", text: $title)
                    Picker("Raum", selection: $roomID) {
                        Text("Bitte wählen").tag(Optional<UUID>.none)
                        ForEach(model.state.rooms) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: roomID) { _, _ in targetID = nil }
                    Picker("Zielmodus", selection: $goal) { ForEach(Goal.allCases) { Text($0.label).tag($0) } }
                    Picker("Energiebedarf", selection: $energy) { ForEach(Energy.allCases) { Text($0.label).tag($0) } }
                    Stepper("Etwa \(minutes) Minuten", value: $minutes, in: 1...180)
                }
                Section("Handgriffe – einer pro Zeile") {
                    TextEditor(text: $steps).frame(minHeight: 140)
                        .accessibilityLabel("Handgriffe, einer pro Zeile")
                    Text("Zum Beispiel: Kiste öffnen. Dann in einer neuen Zeile: USB-Kabel hineinlegen. Die Reihenfolge bleibt gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Gemeinsamer Zielort, optional", selection: $targetID) {
                        Text("Kein gemeinsamer Zielort").tag(Optional<UUID>.none)
                        ForEach(model.state.places.filter { $0.roomID == roomID }) {
                            Text(model.state.path(for: $0.id)).tag(Optional($0.id))
                        }
                    }
                }
            }
            .navigationTitle("Neue Aufgabe")
            .onAppear { if roomID == nil { roomID = model.state.rooms.first?.id } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        guard let roomID else { return }
                        let actions = steps.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }.map { ActionStep(text: $0, targetPlaceID: targetID) }
                        let task = HouseholdTask(roomID: roomID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), goal: goal,
                            energy: energy, estimatedMinutes: minutes, steps: actions)
                        if model.perform({ try $0.addTask(task) }) { dismiss() }
                    }.disabled(roomID == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
