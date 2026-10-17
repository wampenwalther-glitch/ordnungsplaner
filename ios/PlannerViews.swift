import SwiftUI
import OrderCore

struct PlannerTabs: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("Heute", systemImage: "sun.max") }
            NavigationStack { RoomsView() }.tabItem { Label("Wohnung", systemImage: "house") }
            NavigationStack { TasksView() }.tabItem { Label("Aufgaben", systemImage: "checklist") }
            NavigationStack { FindView() }.tabItem { Label("Finden", systemImage: "magnifyingglass") }
            NavigationStack { DataSettingsView() }.tabItem { Label("Mehr", systemImage: "ellipsis") }
        }
        .tint(.teal)
        .alert("Nicht gespeichert", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var goal: Goal = .order
    @State private var energy: Energy = .normal
    @State private var minutes = 10

    var body: some View {
        List {
            if let session = model.state.session, session.status != .finished {
                Section(session.status == .paused ? "Hier hast du aufgehört" : "Dein nächster Handgriff") {
                    if let task = model.state.currentTask, let step = task.nextStep {
                        Text(task.title).font(.headline)
                        Text(step.text).font(.title2)
                        if let target = step.targetPlaceID {
                            Label(model.state.path(for: target), systemImage: "archivebox")
                        }
                        Text("\(task.steps.filter { $0.completedAt != nil }.count) von \(task.steps.count) Handgriffen bestätigt")
                            .foregroundStyle(.secondary)
                        if session.status == .paused {
                            Button("Hier weitermachen") { model.perform { try $0.resume() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Erledigt – bestätigen") { model.perform { try $0.completeCurrentStep(expectedStepID: step.id) } }
                                .buttonStyle(.borderedProminent)
                            Button("Pause") { model.perform { try $0.pause() } }
                        }
                        Button("Für heute beenden") { model.perform { try $0.endSession() } }
                        Text("Offene Schritte bleiben für die nächste Sitzung erhalten.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                if model.state.session?.status == .finished {
                    Section { Label("Sitzung beendet", systemImage: "checkmark.circle") }
                }
                Section("Was passt gerade?") {
                    Picker("Ziel", selection: $goal) {
                        ForEach(Goal.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Zeit", selection: $minutes) {
                        ForEach([5, 10, 20, 45, 90], id: \.self) { Text("\($0) Minuten").tag($0) }
                    }
                    Picker("Energie", selection: $energy) {
                        ForEach(Energy.allCases) { Text($0.label).tag($0) }
                    }
                    let suggestions = model.repository.suggestedTasks(goal: goal, minutes: minutes, energy: energy)
                    if suggestions.isEmpty {
                        Text("Für diese Auswahl ist noch keine passende Aufgabe erfasst. Füge unter Aufgaben einen kleinen Handgriff hinzu oder ändere Zeit und Energie.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(suggestions) { task in
                            Label("\(task.title) · ca. \(task.estimatedMinutes) Min.", systemImage: "circle")
                        }
                        Button("Was mache ich jetzt?") {
                            model.perform { try $0.startSession(taskIDs: suggestions.map(\.id), goal: goal, minutes: minutes, energy: energy) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Auswahl aus deinen erfassten Aufgaben. Ein kurzer Abschlusspuffer bleibt frei. Noch keine KI-Fotoanalyse.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.state.undoRecord != nil {
                Section {
                    Button("Letzte Erledigung rückgängig machen", systemImage: "arrow.uturn.backward") {
                        model.perform { try $0.undoCompletion() }
                    }
                }
            }
            Section("Dein bisheriger Fortschritt") {
                LabeledContent("Bestätigte Handgriffe", value: "\(model.state.events.count)")
                LabeledContent("Abgeschlossene Aufgaben", value: "\(model.state.tasks.filter(\.isComplete).count)")
                LabeledContent("Räume erfasst", value: "\(model.state.rooms.count)")
            }
            if model.state.rooms.isEmpty {
                Section {
                    Text("Beginne unter Wohnung mit einem Raum. Du kannst die übrige Wohnung später ergänzen.")
                }
            }
        }
        .navigationTitle("Heute")
    }
}

struct RoomsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    var body: some View {
        List {
            if model.state.rooms.isEmpty {
                ContentUnavailableView("Dein erster Raum", systemImage: "house", description: Text("Ein Raum und ein bekannter Lagerort reichen zum Anfangen."))
            }
            ForEach(model.state.rooms) { room in
                NavigationLink { RoomDetailView(roomID: room.id) } label: {
                    VStack(alignment: .leading) {
                        Text(room.name).font(.headline)
                        Text("\(model.state.places.filter { $0.roomID == room.id }.count) Lagerorte · \(model.state.tasks.filter { $0.roomID == room.id && !$0.isComplete }.count) offene Aufgaben")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Wohnung")
        .toolbar { Button("Raum hinzufügen", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { NewRoomForm() }
    }
}

struct RoomDetailView: View {
    let roomID: UUID
    @EnvironmentObject private var model: AppModel
    @State private var addingPlace = false
    @State private var addingPoint = false
    @State private var showingScan = false
    @State private var movingPlace: StoragePlace?
    var body: some View {
        List {
            Section("Lagerorte und Kisten") {
                ForEach(model.state.places.filter { $0.roomID == roomID }) { place in
                    Button { movingPlace = place } label: {
                        Label(model.state.path(for: place.id), systemImage: place.kind == .box ? "shippingbox" : "archivebox")
                    }.tint(.primary)
                }
                Button("Lagerort oder Kiste hinzufügen", systemImage: "plus") { addingPlace = true }
            }
            Section("Feste Fotopunkte") {
                ForEach(model.state.photoPoints.filter { $0.roomID == roomID }) { point in
                    NavigationLink { PhotoPointView(point: point) } label: {
                        Label(point.name, systemImage: "camera")
                    }
                }
                Button("Fotopunkt anlegen", systemImage: "plus") { addingPoint = true }
                Text("Zum Beispiel: im Türrahmen, Blick zum Fenster. Folgeaufnahmen möglichst aus derselben Perspektive machen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optionaler Raumscan") {
                Button("LiDAR-Raumscan öffnen", systemImage: "viewfinder") { showingScan = true }
                if let scan = model.state.scans.last(where: { $0.roomID == roomID }) {
                    Text("Zuletzt bestätigt: \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("\(scan.walls) Wände · \(scan.doors) Türen · \(scan.windows) Fenster · \(scan.objects) grobe Objekte")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Auf Geräten ohne LiDAR verwendest du die Fotopunkte. Ein Scan bestätigt keine freien Fächer oder Kisteninhalte.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.state.rooms.first { $0.id == roomID }?.name ?? "Raum")
        .sheet(isPresented: $addingPlace) { PlaceForm(roomID: roomID) }
        .sheet(isPresented: $addingPoint) { NewPhotoPointForm(roomID: roomID) }
        .sheet(item: $movingPlace) { MovePlaceForm(place: $0) }
        .sheet(isPresented: $showingScan) {
            RoomScanSheet(roomName: model.state.rooms.first { $0.id == roomID }?.name ?? "Raum") { scan in
                try model.saveScan(scan, roomID: roomID)
            }
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    var body: some View {
        List {
            Section("Offen") {
                ForEach(model.state.tasks.filter { !$0.isComplete }) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: {
                        VStack(alignment: .leading) {
                            Text(task.title)
                            Text("\(task.goal.label) · \(task.estimatedMinutes) Min. · \(task.energy.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.state.tasks.filter({ !$0.isComplete }).isEmpty {
                    Text("Keine offenen Aufgaben. Du kannst jederzeit eine ergänzen.").foregroundStyle(.secondary)
                }
            }
            Section("Abgeschlossen") {
                ForEach(model.state.tasks.filter(\.isComplete)) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: {
                        Label(task.title, systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .navigationTitle("Aufgaben")
        .toolbar { Button("Aufgabe hinzufügen", systemImage: "plus") { adding = true }.disabled(model.state.rooms.isEmpty) }
        .safeAreaInset(edge: .bottom) {
            if model.state.rooms.isEmpty {
                Text("Lege zuerst unter Wohnung einen Raum an.").font(.callout).padding().background(.regularMaterial)
            }
        }
        .sheet(isPresented: $adding) { NewTaskForm() }
    }
}

struct TaskDetailView: View {
    let taskID: UUID
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if let task = model.state.tasks.first(where: { $0.id == taskID }) {
                Section(task.title) {
                    Text("\(task.goal.label) · ca. \(task.estimatedMinutes) Minuten")
                    ForEach(task.steps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(step.text, systemImage: step.completedAt == nil ? "circle" : "checkmark.circle.fill")
                            if let target = step.targetPlaceID { Text(model.state.path(for: target)).font(.caption) }
                            if let date = step.completedAt {
                                Text("Bestätigt: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !task.isComplete {
                        Button("Diese Aufgabe als Sitzung starten") {
                            model.perform { try $0.startSession(taskIDs: [task.id], goal: task.goal,
                                minutes: task.estimatedMinutes, energy: task.energy) }
                        }
                        Text("Danach unter Heute Handgriff für Handgriff fortsetzen.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Handgriffe")
    }
}

struct FindView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    var body: some View {
        List {
            Section {
                Text("Durchsucht deine erfassten Lagerorte und Kistenkennungen. Einzelne Gegenstände und Kisteninhalte sind in diesem Stand noch nicht inventarisiert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.state.places.filter {
                query.isEmpty || model.state.path(for: $0.id).localizedCaseInsensitiveContains(query)
            }) { place in
                Label(model.state.path(for: place.id), systemImage: place.kind == .box ? "shippingbox" : "archivebox")
            }
        }
        .navigationTitle("Finden")
        .searchable(text: $query, prompt: "Kiste oder Lagerort")
    }
}
