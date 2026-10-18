import SwiftUI
import OrderCore

/// One line for a storage place with what is known about its contents.
struct PlaceRow: View {
    let place: StoragePlace
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let photos = model.state.placePhotos(place.id).count
        let items = model.state.latestInventory(place.id)?.items.count ?? 0
        let unknown = photos == 0 && items == 0
        let photoWord = photos == 1 ? "Foto" : "Fotos"
        let itemWord = items == 1 ? "Gegenstand" : "Gegenstände"
        HStack(spacing: 12) {
            Image(systemName: place.kind == .box ? "shippingbox" : "archivebox").frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.path(for: place.id)).multilineTextAlignment(.leading)
                Text(unknown ? "Inhalt noch nicht erfasst" : "\(photos) \(photoWord) · \(items) \(itemWord)")
                    .font(.caption).foregroundStyle(unknown ? Color.orange : Color.secondary)
                if let status = place.status {
                    Label(status.label, systemImage: status.symbol).font(.caption.bold()).foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// A storage place: photograph into it, let the AI list what is there
/// (optionally with tidy-up tips), correct the list, move it.
struct PlaceDetailView: View {
    let placeID: UUID
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = ChatGPTAuth.shared
    @State private var tidy = false
    @State private var moving: StoragePlace?
    @State private var newItem = ""
    @State private var newCount = ""
    @State private var message: String?
    @State private var confirmingDelete = false
    @State private var confirmingEmpty = false
    @State private var labeling = false
    @State private var movingItem: MovingItem?

    struct MovingItem: Identifiable {
        let id = UUID()
        let inventoryID: UUID
        let item: PlaceInventoryItem
    }

    var body: some View {
        if let place = model.state.places.first(where: { $0.id == placeID }) {
            content(place)
        } else {
            ContentUnavailableView("Lagerort nicht gefunden", systemImage: "archivebox")
        }
    }

    private var aiReady: Bool { AIAccess.isReady || auth.isConnected }

    @ViewBuilder private func content(_ place: StoragePlace) -> some View {
        let photos = model.state.placePhotos(placeID)
        let inventory = model.state.latestInventory(placeID)
        let status = model.inventoryStatus[placeID]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Label(model.state.path(for: placeID), systemImage: place.kind == .box ? "shippingbox" : "archivebox")
                        .font(.headline)
                    if let code = place.code { Text("Code: \(code)").font(.subheadline.monospaced()).foregroundStyle(.secondary) }
                    if let added = inventory?.items.compactMap(\.addedAt).max() {
                        Text("Zuletzt hinzugefügt: \(added.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Kein Status", systemImage: "xmark") { model.perform { try $0.setPlaceStatus(id: placeID, status: nil) } }
                        ForEach(PlaceStatus.allCases) { item in
                            Button(item.label, systemImage: item.symbol) { model.perform { try $0.setPlaceStatus(id: placeID, status: item) } }
                        }
                    } label: {
                        Label(place.status?.label ?? "Status für den Umzug wählen", systemImage: place.status?.symbol ?? "tag")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Button("Standort ändern", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { moving = place }
                        Button("Etikett", systemImage: "qrcode") { labeling = true }
                    }
                    .buttonStyle(.bordered)
                    Button("Als leer markieren", systemImage: "tray") { confirmingEmpty = true }
                        .buttonStyle(.bordered)
                }
                .confirmationDialog("Als leer markieren?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
                    Button("Ja, ist leer") { model.perform { try $0.markPlaceEmpty(placeID: placeID) } }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Die Gegenstandsliste dieses Ortes wird geleert. Frühere Listen bleiben als Verlauf erhalten.")
                }

                Card {
                    Text("Inhalt fotografieren").font(.title3.bold())
                    RoomPhotosSection(placeID: placeID)
                    let old = model.state.outdatedPlacePhotos(placeID)
                    if !old.isEmpty {
                        Divider()
                        Text("Die KI hat \(old.count == 1 ? "dieses Foto" : "diese \(old.count) Fotos") schon erfasst. Die Liste bleibt gespeichert – die Bilder brauchst du nur noch zum Ansehen.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Erfasste Fotos löschen (\(RoomDetailView.megabytes(old)))", systemImage: "trash") { confirmingDelete = true }
                            .buttonStyle(.bordered)
                    }
                }
                .confirmationDialog("Erfasste Fotos löschen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Fotos löschen", role: .destructive) {
                        model.perform { try $0.deletePhotos(ids: $0.state.outdatedPlacePhotos(placeID).map(\.id)) }
                    }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Die Liste der Gegenstände bleibt erhalten. Nur die Bilder werden gelöscht.")
                }

                Card {
                    Text("Bestandsaufnahme").font(.title3.bold())
                    Picker("Was soll die KI tun?", selection: $tidy) {
                        Text("Nur erfassen").tag(false)
                        Text("Erfassen + Aufräumtipps").tag(true)
                    }
                    .pickerStyle(.segmented)
                    switch status {
                    case .running:
                        HStack { ProgressView(); Text("Die KI sieht sich den Inhalt an – das läuft im Hintergrund weiter.") }
                    default:
                        Button(inventory?.photoIDs.isEmpty == false ? "Neu erfassen lassen" : "Inhalt von der KI erfassen lassen",
                               systemImage: "eye") {
                            message = nil
                            model.inventoryPlace(placeID, mode: tidy ? .tidy : .inventoryOnly)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(photos.isEmpty || !aiReady)
                    }
                    if photos.isEmpty {
                        Text("Mach zuerst ein Foto vom Inhalt.").font(.caption).foregroundStyle(.secondary)
                    } else if !aiReady {
                        Text("Die KI ist nicht verbunden (Einstellungen → KI). Du kannst Gegenstände auch selbst eintragen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if case .failed(let text) = status {
                        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }

                    if let inventory {
                        if !inventory.summary.isEmpty { Text(inventory.summary) }
                        if inventory.items.isEmpty {
                            Text("Noch keine Gegenstände eingetragen.").foregroundStyle(.secondary)
                        }
                        ForEach(inventory.items) { item in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.count.map { "\($0)× \(item.name)" } ?? item.name)
                                        if item.source == "ai" {
                                            Text("KI").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                        }
                                    }
                                    if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                Button { movingItem = MovingItem(inventoryID: inventory.id, item: item) } label: {
                                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.name) verschieben")
                                Button {
                                    model.perform { try $0.removeInventoryItem(inventoryID: inventory.id, itemID: item.id) }
                                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.name) entfernen")
                            }
                        }
                        Text("Stand: \(inventory.createdAt.formatted(date: .abbreviated, time: .shortened)) · Die KI schreibt auf, was sie sieht. Sie kann sich irren oder Verdecktes übersehen – korrigiere Einträge einfach.")
                            .font(.caption).foregroundStyle(.secondary)

                        if !inventory.tidyHints.isEmpty {
                            Divider()
                            Text("Aufräumtipps").font(.subheadline.weight(.semibold))
                            ForEach(inventory.tidyHints, id: \.self) { Label($0, systemImage: "lightbulb") }
                            Button("Als Aufgabe anlegen", systemImage: "plus.circle") {
                                let task = HouseholdTask(roomID: place.roomID, title: "\(place.name) aufräumen", goal: .order,
                                                         energy: .normal, estimatedMinutes: max(5, inventory.tidyHints.count * 4),
                                                         steps: inventory.tidyHints.map { ActionStep(text: $0, targetPlaceID: placeID) },
                                                         source: .ai)
                                if model.perform({ try $0.addTask(task) }) { message = "Aufgabe angelegt – du findest sie unter „Aufgaben“." }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()
                    Text("Selbst eintragen").font(.subheadline.weight(.semibold))
                    HStack {
                        TextField("Gegenstand", text: $newItem).textFieldStyle(.roundedBorder)
                        TextField("Anzahl", text: $newCount).textFieldStyle(.roundedBorder).frame(width: 80)
                            .keyboardType(.numbersAndPunctuation)
                        Button { addItem() } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                            .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Gegenstand hinzufügen")
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $moving) { MovePlaceForm(place: $0) }
        .sheet(isPresented: $labeling) { LabelSheet(placeIDs: [placeID]) }
        .sheet(item: $movingItem) { moving in
            PlacePickerSheet(title: "Wohin mit „\(moving.item.name)“?", excluding: placeID) { target in
                model.perform { try $0.moveInventoryItem(inventoryID: moving.inventoryID, itemID: moving.item.id, toPlace: target) }
            }
        }
    }

    private func addItem() {
        let ok = model.perform { try $0.addInventoryItem(placeID: placeID, name: newItem, count: newCount) }
        if ok { newItem = ""; newCount = ""; message = nil }
    }
}

/// Choose a place from the list (searchable) or by scanning its label.
struct PlacePickerSheet: View {
    let title: String
    let excluding: UUID?
    let onPick: (UUID) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scanning = false

    private var places: [StoragePlace] {
        model.state.places.filter { $0.id != excluding }
            .filter { query.isEmpty || model.state.path(for: $0.id).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Etikett des Ziels scannen", systemImage: "qrcode.viewfinder") { scanning = true }
                }
                Section("Lagerorte") {
                    ForEach(places) { place in
                        Button { onPick(place.id); dismiss() } label: { PlaceRow(place: place) }.buttonStyle(.plain)
                    }
                    if places.isEmpty { Text("Keine passenden Lagerorte.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Ziel suchen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                PlaceScanSheet(prompt: "Scanne das Etikett des Ziels") { target in
                    if target.id != excluding { onPick(target.id); dismiss() }
                }
            }
        }
    }
}

/// "Umräumen": scan what you moved, then scan where it stands now.
struct MoveByScanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var moved: StoragePlace?
    @State private var done: String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let moved {
                    Card {
                        Label("Du verschiebst", systemImage: "shippingbox").font(.subheadline).foregroundStyle(.secondary)
                        Text(model.state.path(for: moved.id)).font(.headline)
                        Button("Anderen Ort wählen", systemImage: "arrow.uturn.backward") { self.moved = nil; note = nil }
                            .buttonStyle(.bordered)
                    }
                    ScanPanel(prompt: "Scanne jetzt den neuen Standort") { text in
                        guard let target = model.state.place(forScan: text) else {
                            note = "Dieser Code gehört zu keinem deiner Lagerorte."; return
                        }
                        if model.state.subtree(of: moved.id).contains(target.id) {
                            note = "Ein Ort kann nicht in sich selbst stehen."; return
                        }
                        if model.perform({ try $0.movePlace(id: moved.id, parentID: target.id, roomID: target.roomID) }) {
                            done = "„\(moved.name)“ steht jetzt in \(model.state.path(for: target.id))."
                            self.moved = nil; note = nil
                        }
                    }
                    Menu {
                        ForEach(model.state.rooms) { room in
                            Button(room.name) {
                                if model.perform({ try $0.movePlace(id: moved.id, parentID: nil, roomID: room.id) }) {
                                    done = "„\(moved.name)“ steht jetzt direkt im Raum \(room.name)."
                                    self.moved = nil
                                }
                            }
                        }
                    } label: { Label("Direkt in einen Raum stellen …", systemImage: "house") }
                } else {
                    if let done { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    ScanPanel(prompt: done == nil ? "Scanne das Etikett der Kiste oder des Ortes, den du verschiebst"
                                                  : "Nächste Kiste scannen – oder fertig") { text in
                        if let place = model.state.place(forScan: text) { moved = place; done = nil; note = nil }
                        else { note = "Dieser Code gehört zu keinem deiner Lagerorte." }
                    }
                }
                if let note { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Umräumen per Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
