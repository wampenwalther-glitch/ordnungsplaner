import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import RoomPlan
import OrderCore

struct RoomsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            if model.state.rooms.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Räume", systemImage: "house")
                } description: {
                    Text("Lege einen Raum an und mach vier Fotos davon. Mehr braucht die KI nicht.")
                } actions: {
                    Button("Raum anlegen", systemImage: "plus") { adding = true }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            }
            AnalysisBanner().padding(.horizontal).padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.state.rooms) { room in
                    NavigationLink { RoomDetailView(roomID: room.id) } label: { RoomCard(room: room) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Wohnung")
        .toolbar { Button("Raum hinzufügen", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { NewRoomForm() }
    }
}

/// Shows how far the AI is with looking at the rooms' photos, or offers to start it.
private struct AnalysisBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = ChatGPTAuth.shared
    var body: some View {
        if let progress = model.analysisProgress {
            Card {
                Label("KI wertet deine Fotos aus", systemImage: "eye").font(.headline)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("\(progress.done) von \(progress.total) Räumen fertig. Du kannst die App ruhig verlassen – das Ergebnis wird gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if AIAccess.isReady || auth.isConnected, !model.roomsNeedingAnalysis.isEmpty {
            let rooms = model.roomsNeedingAnalysis
            Card {
                Label("Neue Fotos warten", systemImage: "photo.badge.checkmark").font(.headline)
                Text("Die KI kann sich \(rooms.count == 1 ? "diesen Raum" : "diese \(rooms.count) Räume") ansehen und merkt sich, was dort typischerweise rumliegt. Das hilft auch, wenn die KI mal nicht erreichbar ist.")
                    .font(.callout).foregroundStyle(.secondary)
                BigButton("Von der KI ansehen lassen", systemImage: "eye") { model.analyzeRooms(rooms.map(\.id)) }
            }
        }
    }
}

private struct RoomCard: View {
    let room: Room
    @EnvironmentObject private var model: AppModel

    @ViewBuilder private var statusLine: some View {
        let photos = model.state.roomPhotos(room.id)
        switch model.analysisStatus[room.id] {
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("KI schaut …").font(.caption) }
        case .queued:
            Label("Wartet auf die KI", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("Auswertung fehlgeschlagen", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case nil:
            if let analysis = model.state.latestAIAnalysis(room.id), model.state.isAnalysisCurrent(room.id) {
                Label("Von der KI ausgewertet · \(analysis.createdAt.formatted(.relative(presentation: .named)))",
                      systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor)
            } else if photos.isEmpty {
                Text("Fotos fehlen").font(.caption).foregroundStyle(Color.orange)
            } else {
                Text("\(photos.count) Fotos · noch nicht ausgewertet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        let photos = model.state.roomPhotos(room.id)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.accentColor.opacity(0.12)
                if let last = photos.last, let image = UIImage(data: last.jpegData) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "camera").font(.title).foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 110)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.headline).lineLimit(1)
                statusLine
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Photo capture block: big camera button, multi-select import and the
/// photo grid. Used in the room screen and from the start flow.
enum PhotoTarget {
    case room(UUID)
    case place(UUID)
}

struct RoomPhotosSection: View {
    let target: PhotoTarget
    init(roomID: UUID) { target = .room(roomID) }
    init(placeID: UUID) { target = .place(placeID) }
    @EnvironmentObject private var model: AppModel
    @State private var showingCamera = false
    @State private var askMore = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var viewing: RoomPhoto?
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        let photos: [RoomPhoto] = {
            switch target {
            case .room(let id): return model.state.roomPhotos(id)
            case .place(let id): return model.state.placePhotos(id)
            }
        }()
        VStack(alignment: .leading, spacing: 12) {
            Group {
                switch target {
                case .room:
                    Text(photos.count >= 4
                         ? "\(photos.count) Fotos – das reicht für einen guten Plan. Mehr Fotos machen ihn genauer."
                         : "Am besten 4 Fotos: aus jeder Ecke eins, Blick in den Raum. Bisher \(photos.count) von 4.")
                case .place:
                    Text(photos.isEmpty
                         ? "Öffne den Schrank, das Regal, die Schublade oder die Kiste und fotografiere hinein – von vorn oder von oben. Bei großen Orten gern mehrere Fotos."
                         : "\(photos.count) Foto(s). Je näher und heller, desto besser erkennt die KI den Inhalt.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if !photos.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(photos) { photo in
                        Button { viewing = photo } label: {
                            if let image = UIImage(data: photo.jpegData) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(height: 96).frame(maxWidth: .infinity).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            BigButton("Foto aufnehmen", systemImage: "camera.fill") { Task { await openCamera() } }
            PhotosPicker(selection: $picked, maxSelectionCount: 8, matching: .images) {
                Label("Aus der Mediathek wählen", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(loading)
            if loading { ProgressView("Fotos werden vorbereitet …") }
            if let errorText { Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            loading = true
            Task {
                defer { loading = false; picked = [] }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), data.count <= 30_000_000,
                              let image = UIImage(data: data) else { throw OrderError.invalid("Ein Bild war nicht lesbar.") }
                        try model.addPhoto(image, to: target)
                    } catch { errorText = error.localizedDescription }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                do { try model.addPhoto(image, to: target); askMore = true }
                catch { errorText = error.localizedDescription }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Foto gespeichert. Noch eins?", isPresented: $askMore, titleVisibility: .visible) {
            Button("Nächstes Foto") { showingCamera = true }
            Button("Fertig", role: .cancel) {}
        }
        .sheet(item: $viewing) { photo in PhotoViewer(photo: photo) }
    }

    private func openCamera() async {
        errorText = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorText = "Hier ist keine Kamera verfügbar. Wähle Fotos aus der Mediathek."; return
        }
        if await AVCaptureDevice.requestAccess(for: .video) { showingCamera = true }
        else { errorText = "Die Kamera ist nicht erlaubt. In den iPhone-Einstellungen beim Ordnungsplaner die Kamera erlauben." }
    }
}

private struct PhotoViewer: View {
    let photo: RoomPhoto
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack {
                if let image = UIImage(data: photo.jpegData) { Image(uiImage: image).resizable().scaledToFit() }
                Text("Aufgenommen: \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        if model.perform({ try $0.removePhoto(id: photo.id) }) { dismiss() }
                    }
                }
            }
        }
    }
}

/// Wrapper so the start flow can show the photo block in its own sheet.
struct RoomPhotosSheet: View {
    let roomID: UUID
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView { RoomPhotosSection(roomID: roomID).padding() }
            .navigationTitle("Fotos: \(model.state.rooms.first { $0.id == roomID }?.name ?? "Raum")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
    }
}

struct RoomDetailView: View {
    let roomID: UUID
    @EnvironmentObject private var model: AppModel
    @State private var addingPlace = false
    @State private var showingScan = false
    @State private var lookError: String?
    @State private var adoptedMessage: String?
    @State private var confirmingDelete = false
    @ObservedObject private var auth = ChatGPTAuth.shared
    private let lidar = RoomCaptureSession.isSupported

    static func megabytes(_ photos: [RoomPhoto]) -> String {
        let bytes = photos.reduce(0) { $0 + $1.jpegData.count }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    var body: some View {
        let places = model.state.places.filter { $0.roomID == roomID }
        let analysis = model.state.latestAIAnalysis(roomID)
        let status = model.analysisStatus[roomID]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Text("Fotos").font(.title3.bold())
                    RoomPhotosSection(roomID: roomID)
                    let old = model.state.outdatedRoomPhotos(roomID)
                    if !old.isEmpty {
                        Divider()
                        Text("Die KI hat \(old.count == 1 ? "dieses Foto" : "diese \(old.count) Fotos") schon ausgewertet. Was sie gesehen hat, bleibt gespeichert – die Bilder brauchst du nur noch zum Ansehen.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Ausgewertete Fotos löschen (\(Self.megabytes(old)))", systemImage: "trash") {
                            confirmingDelete = true
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Nach dem Aufräumen: neue Fotos machen und auswerten lassen. Dann zeigt die App unten, was sich verändert hat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .confirmationDialog("Ausgewertete Fotos löschen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Fotos löschen", role: .destructive) {
                        model.perform { try $0.deletePhotos(ids: $0.state.outdatedRoomPhotos(roomID).map(\.id)) }
                    }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("Die Auswertung der KI bleibt erhalten. Nur die Bilder werden gelöscht und Speicher wird frei.")
                }

                if let progress = model.state.progress(roomID) {
                    Card {
                        Text("Seit dem letzten Mal").font(.title3.bold())
                        Text("Vergleich der beiden letzten Auswertungen (\(progress.before.formatted(date: .abbreviated, time: .omitted)) → \(progress.after.formatted(date: .abbreviated, time: .omitted))).")
                            .font(.caption).foregroundStyle(.secondary)
                        if !progress.notSeenAnymore.isEmpty {
                            Label("Nicht mehr zu sehen: " + progress.notSeenAnymore.map(\.label).joined(separator: ", "),
                                  systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                        if !progress.stillSeen.isEmpty {
                            Label("Noch zu sehen: " + progress.stillSeen.map(\.label).joined(separator: ", "),
                                  systemImage: "circle.dashed")
                        }
                        if !progress.newlySeen.isEmpty {
                            Label("Neu dazugekommen: " + progress.newlySeen.map(\.label).joined(separator: ", "),
                                  systemImage: "plus.circle").foregroundStyle(.orange)
                        }
                        Text("Das ist, was die KI auf den Fotos erkannt hat – kein Beweis, dass etwas wirklich erledigt ist.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card {
                    Text("Was die KI sieht").font(.title3.bold())
                    if let analysis {
                        Text(analysis.summary)
                        if !analysis.startHint.isEmpty {
                            Label("Guter Start: \(analysis.startHint)", systemImage: "mappin.and.ellipse").foregroundStyle(Color.accentColor)
                        }
                        ForEach(analysis.problemZones, id: \.self) { Label($0, systemImage: "exclamationmark.circle") }
                        if !analysis.detectedPlaces.isEmpty {
                            Text("Erkannte Aufbewahrung").font(.subheadline.weight(.semibold))
                            ForEach(analysis.detectedPlaces, id: \.self) { place in
                                Label(place.note.isEmpty ? place.name : "\(place.name) – \(place.note)",
                                      systemImage: place.kind == "kiste" ? "shippingbox" : "archivebox")
                            }
                            Button("Als Lagerorte übernehmen", systemImage: "checkmark.circle") {
                                do {
                                    var added = 0
                                    try model.run { added = try $0.adoptDetectedPlaces(roomID: roomID, analysis.detectedPlaces) }
                                    adoptedMessage = added == 0 ? "Alle waren schon übernommen." : "\(added) Lagerorte übernommen."
                                } catch { lookError = error.localizedDescription }
                            }
                            .buttonStyle(.bordered)
                            if let adoptedMessage { Text(adoptedMessage).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text("Stand: \(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Die KI erkennt Regale, Schränke und Kisten und zeigt, wo Unordnung ist.")
                            .foregroundStyle(.secondary)
                    }
                    switch status {
                    case .running:
                        HStack { ProgressView(); Text("Die KI schaut sich den Raum an – das läuft im Hintergrund weiter.") }
                    case .queued:
                        Label("Wartet, bis die KI an der Reihe ist.", systemImage: "clock").foregroundStyle(.secondary)
                    default:
                        if analysis != nil && model.state.isAnalysisCurrent(roomID) {
                            Label("Alle aktuellen Fotos sind ausgewertet.", systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(Color.accentColor)
                        }
                        Button(analysis == nil ? "Raum von der KI ansehen lassen" : "Neu ansehen lassen", systemImage: "eye") {
                            lookError = nil
                            model.analyzeRooms([roomID])
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.state.roomPhotos(roomID).isEmpty || !(AIAccess.isReady || auth.isConnected))
                        if !(AIAccess.isReady || auth.isConnected) {
                            Text("Dafür die KI unter Einstellungen → KI verbinden.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if case .failed(let message) = status {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if let lookError { Label(lookError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Card {
                    Text("Lagerorte").font(.title3.bold())
                    if places.isEmpty {
                        Text("Noch keine. Übernimm die von der KI erkannten (siehe oben) oder leg selbst welche an.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tippe einen Lagerort an, um hineinzufotografieren und den Inhalt erfassen zu lassen.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(places) { place in
                        NavigationLink { PlaceDetailView(placeID: place.id) } label: { PlaceRow(place: place) }
                            .buttonStyle(.plain)
                    }
                    Button("Lagerort oder Kiste hinzufügen", systemImage: "plus") { addingPlace = true }
                }

                if lidar {
                    Card {
                        Text("3D-Raumscan (optional)").font(.title3.bold())
                        Text("Dein iPhone hat LiDAR. Ein Scan erfasst Wände, Türen und Möbel genauer.")
                            .foregroundStyle(.secondary)
                        Button("Raumscan starten", systemImage: "viewfinder") { showingScan = true }.buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.state.rooms.first { $0.id == roomID }?.name ?? "Raum")
        .sheet(isPresented: $addingPlace) { PlaceForm(roomID: roomID) }
        .sheet(isPresented: $showingScan) {
            RoomScanSheet(roomName: model.state.rooms.first { $0.id == roomID }?.name ?? "Raum") { scan in
                try model.saveScan(scan, roomID: roomID)
            }
        }
    }
}
