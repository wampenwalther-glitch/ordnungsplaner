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

private struct RoomCard: View {
    let room: Room
    @EnvironmentObject private var model: AppModel
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
                Text(photos.isEmpty ? "Fotos fehlen" : "\(photos.count) Fotos")
                    .font(.caption).foregroundStyle(photos.isEmpty ? Color.orange : Color.secondary)
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Photo capture block: big camera button, multi-select import and the
/// photo grid. Used in the room screen and from the start flow.
struct RoomPhotosSection: View {
    let roomID: UUID
    @EnvironmentObject private var model: AppModel
    @State private var showingCamera = false
    @State private var askMore = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var viewing: RoomPhoto?
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        let photos = model.state.roomPhotos(roomID)
        VStack(alignment: .leading, spacing: 12) {
            Text(photos.count >= 4
                 ? "\(photos.count) Fotos – das reicht für einen guten Plan. Mehr Fotos machen ihn genauer."
                 : "Am besten 4 Fotos: aus jeder Ecke eins, Blick in den Raum. Bisher \(photos.count) von 4.")
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
                        try model.addRoomPhoto(image, roomID: roomID)
                    } catch { errorText = error.localizedDescription }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture { image in
                do { try model.addRoomPhoto(image, roomID: roomID); askMore = true }
                catch { errorText = error.localizedDescription }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Foto gespeichert (\(photos.count)). Noch eins?", isPresented: $askMore, titleVisibility: .visible) {
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
    @State private var movingPlace: StoragePlace?
    @State private var looking = false
    @State private var lookError: String?
    @State private var adoptedMessage: String?
    private let lidar = RoomCaptureSession.isSupported

    var body: some View {
        let places = model.state.places.filter { $0.roomID == roomID }
        let analysis = model.state.latestAnalysis(roomID)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Text("Fotos").font(.title3.bold())
                    RoomPhotosSection(roomID: roomID)
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
                    if looking {
                        HStack { ProgressView(); Text(model.planningStatus ?? "Die KI schaut …") }
                    } else {
                        Button(analysis == nil ? "Raum von der KI ansehen lassen" : "Neu ansehen lassen", systemImage: "eye") {
                            Task { await look() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.state.roomPhotos(roomID).isEmpty)
                    }
                    if let lookError { Label(lookError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }

                Card {
                    Text("Lagerorte").font(.title3.bold())
                    if places.isEmpty {
                        Text("Noch keine. Übernimm die von der KI erkannten oder leg selbst welche an.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(places) { place in
                        Button { movingPlace = place } label: {
                            Label(model.state.path(for: place.id), systemImage: place.kind == .box ? "shippingbox" : "archivebox")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
        .sheet(item: $movingPlace) { MovePlaceForm(place: $0) }
        .sheet(isPresented: $showingScan) {
            RoomScanSheet(roomName: model.state.rooms.first { $0.id == roomID }?.name ?? "Raum") { scan in
                try model.saveScan(scan, roomID: roomID)
            }
        }
    }

    private func look() async {
        lookError = nil
        adoptedMessage = nil
        looking = true
        defer { looking = false }
        do { try await model.lookAtRoom(roomID) } catch { lookError = error.localizedDescription }
    }
}
