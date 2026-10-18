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
                    Button("Standort ändern", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { moving = place }
                        .buttonStyle(.bordered)
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
    }

    private func addItem() {
        let ok = model.perform { try $0.addInventoryItem(placeID: placeID, name: newItem, count: newCount) }
        if ok { newItem = ""; newCount = ""; message = nil }
    }
}
