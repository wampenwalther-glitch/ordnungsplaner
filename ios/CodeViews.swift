import SwiftUI
import OrderCore

/// A scanned code that belongs to no place yet (a blank label, or one made in a printer app):
/// create a place for it or give it to an existing place.
struct UnassignedCodeSheet: View {
    let code: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var existing = false
    @State private var name = ""
    @State private var kind: PlaceKind = .box
    @State private var roomID: UUID?
    @State private var parentID: UUID?
    @State private var query = ""

    private var withoutCode: [StoragePlace] {
        model.state.places.filter { ($0.code ?? "").isEmpty }
            .filter { query.isEmpty || model.state.path(for: $0.id).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(code, systemImage: "qrcode").font(.headline.monospaced())
                    Text("Dieser Code gehört noch zu keinem Ort. Sag der App, wo das Etikett klebt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Was soll passieren?", selection: $existing) {
                    Text("Neuer Ort").tag(false)
                    Text("Vorhandener Ort").tag(true)
                }
                .pickerStyle(.segmented)

                if !existing {
                    Section("Der neue Ort") {
                        TextField("Name, z. B. Kabelkiste", text: $name)
                        Picker("Art", selection: $kind) { ForEach(PlaceKind.allCases) { Text($0.label).tag($0) } }
                        if model.state.rooms.isEmpty {
                            Text("Lege zuerst unter „Wohnung“ einen Raum an.").foregroundStyle(.orange)
                        } else {
                            Picker("Raum", selection: $roomID) {
                                ForEach(model.state.rooms) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Picker("Steht in", selection: $parentID) {
                                Text("Direkt im Raum").tag(Optional<UUID>.none)
                                ForEach(model.state.places.filter { $0.roomID == roomID }) {
                                    Text(model.state.path(for: $0.id)).tag(Optional($0.id))
                                }
                            }
                        }
                    }
                } else {
                    Section("Orte ohne Etikett") {
                        ForEach(withoutCode) { place in
                            Button { assign(to: place) } label: { PlaceRow(place: place) }.buttonStyle(.plain)
                        }
                        if withoutCode.isEmpty { Text("Alle Orte haben schon ein Etikett.").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Neues Etikett")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Ort suchen")
            .onAppear { if roomID == nil { roomID = model.state.rooms.first?.id } }
            .onChange(of: roomID) { _, _ in parentID = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                if !existing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Anlegen") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || roomID == nil)
                    }
                }
            }
        }
    }

    private func create() {
        guard let roomID else { return }
        let place = StoragePlace(roomID: roomID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                 parentID: parentID, code: code)
        if model.perform({ try $0.addPlace(place) }) { finish(place.id) }
    }

    private func assign(to place: StoragePlace) {
        if model.perform({ try $0.assignCode(placeID: place.id, code: code) }) { finish(place.id) }
    }

    /// Close this sheet, then open the place so its contents can be photographed right away.
    private func finish(_ id: UUID) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            model.openedPlace = AppModel.OpenedPlace(id: id)
        }
    }
}

struct CodeBatch: Identifiable {
    let id = UUID()
    let codes: [String]
}

/// Blank labels to print in advance: codes are reserved so a second batch never repeats them.
struct BlankLabelsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var count = 12
    @State private var prefix = "K"
    @State private var batch: CodeBatch?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Erzeuge Etiketten mit freien QR-Codes, drucke und klebe sie auf. Später scannst du sie mit der App und legst fest, was das für ein Ort ist und was drin liegt.")
                        .font(.callout)
                }
                Section("Wie viele?") {
                    Stepper("\(count) Etiketten", value: $count, in: 1...60)
                    Picker("Für", selection: $prefix) {
                        Text("Kisten (K01, K02 …)").tag("K")
                        Text("Schränke, Regale, Fächer (L01 …)").tag("L")
                    }
                }
                Section {
                    Button("Etiketten erstellen", systemImage: "qrcode") {
                        var made: [String] = []
                        if model.perform({ made = try $0.reserveCodes(prefix: prefix, count: count) }) {
                            batch = CodeBatch(codes: made)
                        }
                    }
                } footer: {
                    Text("Du hast schon einen Etikettendrucker mit eigener App? Dort kannst du auch eigene QR-Codes erzeugen, zum Beispiel mit dem Text K07. Die App liest sie ebenfalls und fragt beim ersten Scannen, wohin sie gehören.")
                }
            }
            .navigationTitle("Leere Etiketten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .sheet(item: $batch) { LabelSheet(placeIDs: [], blankCodes: $0.codes) }
        }
    }
}

/// Places that would profit from a label, pre-selected where it is obvious; the user decides.
struct LabelSuggestionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var printing = false
    @State private var loaded = false

    var body: some View {
        let suggestions = model.state.labelSuggestions()
        NavigationStack {
            List {
                Section {
                    Text("Diese Orte haben noch kein Etikett. Was in einer Kiste oder in einem Schrank mit Türen liegt, sieht man von außen nicht – dort hilft ein Etikett am meisten. Du kannst jeden Vorschlag an- oder abwählen.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(suggestions) { suggestion in
                        if let place = model.state.places.first(where: { $0.id == suggestion.placeID }) {
                            Toggle(isOn: Binding(get: { selected.contains(place.id) },
                                                 set: { if $0 { selected.insert(place.id) } else { selected.remove(place.id) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.state.path(for: place.id))
                                    Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if suggestions.isEmpty { Text("Alle Orte haben schon ein Etikett.").foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text("Vorschläge")
                        Spacer()
                        Button(selected.count == suggestions.count ? "Keine" : "Alle") {
                            selected = selected.count == suggestions.count ? [] : Set(suggestions.map(\.placeID))
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("Etiketten-Vorschläge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Etiketten (\(selected.count))") { printing = true }.disabled(selected.isEmpty)
                }
            }
            .onAppear {
                if !loaded { selected = Set(suggestions.filter(\.recommended).map(\.placeID)); loaded = true }
            }
            .sheet(isPresented: $printing) {
                LabelSheet(placeIDs: suggestions.map(\.placeID).filter { selected.contains($0) })
            }
        }
    }
}
