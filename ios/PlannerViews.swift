import SwiftUI
import OrderCore

struct PlannerTabs: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("Aufräumen", systemImage: "sparkles") }
            NavigationStack { RoomsView() }.tabItem { Label("Wohnung", systemImage: "house") }
            NavigationStack { TasksView() }.tabItem { Label("Aufgaben", systemImage: "checklist") }
            NavigationStack { FindView() }.tabItem { Label("Finden", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }.tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .alert("Nicht gespeichert", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// Large, calm card used on the main screens.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Full-width primary button with a comfortable touch target.
struct BigButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var starting = false
    @State private var addingRoom = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let session = model.state.session, session.status != .finished,
                   let task = model.state.currentTask, let step = task.nextStep {
                    CurrentStepCard(session: session, task: task, step: step)
                } else {
                    Card {
                        if model.state.session?.status == .finished {
                            Label("Runde geschafft – gut gemacht!", systemImage: "checkmark.seal.fill")
                                .font(.headline).foregroundStyle(Color.accentColor)
                        }
                        Text("Bereit zum Aufräumen?").font(.title2.bold())
                        Text("Wähle Räume, Ziel, Zeit und Energie. Die KI schaut sich deine Raumfotos an und zeigt dir Handgriff für Handgriff, was zu tun ist.")
                            .foregroundStyle(.secondary)
                        BigButton("Aufräumen starten", systemImage: "play.fill") {
                            if model.state.rooms.isEmpty { addingRoom = true } else { starting = true }
                        }
                    }
                }
                if model.state.undoRecord != nil {
                    Button("Letzten Handgriff zurücknehmen", systemImage: "arrow.uturn.backward") {
                        model.perform { try $0.undoCompletion() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.state.rooms.isEmpty {
                    Card {
                        Label("So geht's", systemImage: "lightbulb").font(.headline)
                        Text("1. Raum anlegen\n2. Vier Fotos vom Raum machen\n3. Aufräumen starten")
                        Button("Ersten Raum anlegen", systemImage: "plus") { addingRoom = true }
                            .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 12) {
                    StatTile(value: model.state.events.count, label: "Handgriffe")
                    StatTile(value: model.state.tasks.filter(\.isComplete).count, label: "Aufgaben fertig")
                    StatTile(value: model.state.rooms.count, label: "Räume")
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Aufräumen")
        .sheet(isPresented: $starting) { StartFlowView() }
        .sheet(isPresented: $addingRoom) { NewRoomForm() }
    }
}

private struct StatTile: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CurrentStepCard: View {
    let session: WorkSession
    let task: HouseholdTask
    let step: ActionStep
    @EnvironmentObject private var model: AppModel

    private var roomName: String { model.state.rooms.first { $0.id == task.roomID }?.name ?? "Raum" }
    private var stepNumber: Int { (task.steps.firstIndex { $0.id == step.id } ?? 0) + 1 }
    private var taskNumber: Int { (session.taskIDs.firstIndex(of: task.id) ?? 0) + 1 }
    private var isVeryFirstStep: Bool { session.taskIDs.first == task.id && stepNumber == 1 }

    var body: some View {
        Card {
            HStack {
                Label(roomName, systemImage: "house").font(.subheadline.weight(.semibold))
                Spacer()
                Text(session.goal.label).font(.caption).foregroundStyle(.secondary)
            }
            if isVeryFirstStep, let hint = model.state.latestAnalysis(task.roomID)?.startHint, !hint.isEmpty {
                Label("Starte hier: \(hint)", systemImage: "mappin.and.ellipse")
                    .font(.callout).foregroundStyle(Color.accentColor)
            }
            Text(task.title).font(.subheadline).foregroundStyle(.secondary)
            Text(step.text).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if let hint = step.hint {
                Label(hint, systemImage: "arrow.right.circle").foregroundStyle(.secondary)
            } else if let target = step.targetPlaceID {
                Label(model.state.path(for: target), systemImage: "archivebox").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(stepNumber - 1), total: Double(max(task.steps.count, 1)))
            Text("Handgriff \(stepNumber) von \(task.steps.count) · Aufgabe \(taskNumber) von \(session.taskIDs.count)")
                .font(.caption).foregroundStyle(.secondary)

            if session.status == .paused {
                Text("Pausiert – du machst genau hier weiter.").foregroundStyle(.secondary)
                BigButton("Weitermachen", systemImage: "play.fill") { model.perform { try $0.resume() } }
            } else {
                BigButton("Erledigt", systemImage: "checkmark") {
                    model.perform { try $0.completeCurrentStep(expectedStepID: step.id) }
                }
                .sensoryFeedback(.success, trigger: model.state.events.count)
            }
            HStack {
                if session.status == .active {
                    Button("Pause", systemImage: "pause") { model.perform { try $0.pause() } }
                }
                Spacer()
                Button("Runde beenden", systemImage: "stop") { model.perform { try $0.endSession() } }
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    private var open: [HouseholdTask] { model.state.tasks.filter { !$0.isComplete } }
    var body: some View {
        List {
            Section {
                Text("Aufgaben entstehen normalerweise über „Aufräumen starten“. Eine noch unberührte Aufgabe löschst du, indem du nach links wischst.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Offen") {
                ForEach(open) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskRow(task: task) }
                        .swipeActions {
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                model.perform { try $0.removeTask(id: task.id) }
                            }
                        }
                }
                if open.isEmpty { Text("Keine offenen Aufgaben.").foregroundStyle(.secondary) }
            }
            Section("Erledigt") {
                ForEach(model.state.tasks.filter(\.isComplete)) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: {
                        Label(task.title, systemImage: "checkmark.circle.fill")
                    }
                }
            }
        }
        .navigationTitle("Aufgaben")
        .toolbar {
            Button("Eigene Aufgabe", systemImage: "plus") { adding = true }.disabled(model.state.rooms.isEmpty)
        }
        .sheet(isPresented: $adding) { NewTaskForm() }
    }
}

private struct TaskRow: View {
    let task: HouseholdTask
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title).font(.headline)
                if task.source == .ai {
                    Text("KI").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            Text("\(model.state.rooms.first { $0.id == task.roomID }?.name ?? "") · \(task.estimatedMinutes) Min. · \(task.steps.filter { $0.completedAt != nil }.count)/\(task.steps.count) Handgriffe")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TaskDetailView: View {
    let taskID: UUID
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if let task = model.state.tasks.first(where: { $0.id == taskID }) {
                Section(task.title) {
                    Text("\(task.goal.label) · ca. \(task.estimatedMinutes) Minuten · \(task.energy.label)")
                        .foregroundStyle(.secondary)
                    ForEach(task.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(step.text, systemImage: step.completedAt == nil ? "circle" : "checkmark.circle.fill")
                            if let hint = step.hint { Text("→ \(hint)").font(.caption).foregroundStyle(.secondary) }
                            if let target = step.targetPlaceID { Text(model.state.path(for: target)).font(.caption) }
                        }
                    }
                }
                if !task.isComplete, model.state.session == nil || model.state.session?.status == .finished {
                    Section {
                        Button("Nur diese Aufgabe starten", systemImage: "play.fill") {
                            model.perform { try $0.startSession(taskIDs: [task.id], goal: task.goal,
                                                                minutes: task.estimatedMinutes, energy: task.energy) }
                        }
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
            ForEach(model.state.places.filter {
                query.isEmpty || model.state.path(for: $0.id).localizedCaseInsensitiveContains(query)
            }) { place in
                Label(model.state.path(for: place.id), systemImage: place.kind == .box ? "shippingbox" : "archivebox")
            }
            if model.state.places.isEmpty {
                ContentUnavailableView("Noch keine Lagerorte", systemImage: "archivebox",
                    description: Text("Lass die KI einen Raum ansehen und übernimm die erkannten Regale, Schränke und Kisten."))
            }
        }
        .navigationTitle("Finden")
        .searchable(text: $query, prompt: "Kiste, Regal, Schrank …")
    }
}
