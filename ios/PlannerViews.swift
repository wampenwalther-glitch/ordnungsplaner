import SwiftUI
import OrderCore

struct PlannerTabs: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("Aufräumen", systemImage: "sparkles") }
            NavigationStack { RoomsView() }.tabItem { Label("Wohnung", systemImage: "house") }
            NavigationStack { TasksView() }.tabItem { Label("Aufgaben", systemImage: "checklist") }
            NavigationStack { FindView() }.tabItem { Label("Wo ist was?", systemImage: "magnifyingglass") }
            NavigationStack { SettingsView() }.tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .tint(.accentColor)
        .sheet(item: $model.openedPlace) { opened in
            NavigationStack {
                PlaceDetailView(placeID: opened.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { model.openedPlace = nil } } }
            }
            .environmentObject(model)
        }
        .sheet(item: $model.pendingCode) { pending in
            UnassignedCodeSheet(code: pending.code).environmentObject(model)
        }
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
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
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
            SessionTimerView(session: session)
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

/// Live countdown of the round with a pace hint. Time stays correct in the
/// background because it is derived from stored timestamps, not from ticking.
private struct SessionTimerView: View {
    let session: WorkSession
    @EnvironmentObject private var model: AppModel

    /// Minutes still planned for the open steps of this round's tasks.
    private var plannedMinutesLeft: Double {
        session.taskIDs.compactMap { id in model.state.tasks.first { $0.id == id } }.reduce(0) { sum, task in
            let open = task.steps.filter { $0.completedAt == nil }.count
            return sum + Double(task.estimatedMinutes) * Double(open) / Double(max(task.steps.count, 1))
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let value = Int(abs(seconds).rounded(.down))
        let text = value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
        return seconds < 0 ? "+" + text : text
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = session.remaining(at: context.date)
            let total = Double(max(session.timeBudget, 1) * 60)
            let need = plannedMinutesLeft * 60
            let over = remaining <= 0
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: session.status == .paused ? "pause.circle" : "timer")
                    Text(clock(remaining))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                        .foregroundStyle(over ? Color.red : Color.primary)
                    Spacer()
                    Button("+5 Min.", systemImage: "plus") { model.perform { try $0.extendSession(minutes: 5) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                ProgressView(value: min(max(session.elapsed(at: context.date), 0), total), total: total)
                    .tint(over ? Color.red : Color.accentColor)
                if session.status == .paused {
                    Text("Pausiert – die Uhr steht.").font(.caption).foregroundStyle(.secondary)
                } else if over {
                    Text("Die Zeit ist um. Mach in Ruhe fertig, verlängere oder beende die Runde.").font(.caption).foregroundStyle(.red)
                } else if need <= remaining * 0.9 {
                    Label("Im Plan", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Color.accentColor)
                } else if need <= remaining * 1.15 {
                    Label("Knapp, aber machbar", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                } else {
                    Label("Eng: Die Zeit reicht vermutlich nicht für alles. Das Wichtigste steht vorne.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
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
                if task.source == .ai || task.source == .local {
                    Text(task.source == .ai ? "KI" : "Routine").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
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
                let open = task.steps.filter { $0.completedAt == nil }
                let done = task.steps.filter { $0.completedAt != nil }
                Section {
                    Text("\(task.goal.label) · ca. \(task.estimatedMinutes) Minuten · \(task.energy.label)")
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(done.count), total: Double(max(task.steps.count, 1)))
                    Text(open.isEmpty ? "Alles geschafft!" : "Noch \(open.count) von \(task.steps.count) Handgriffen offen – tippe einen an, wenn er erledigt ist.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !open.isEmpty {
                    Section("Noch zu tun") {
                        ForEach(open) { step in StepRow(task: task, step: step) }
                    }
                }
                if !done.isEmpty {
                    Section("Geschafft") {
                        ForEach(done) { step in StepRow(task: task, step: step) }
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
        .navigationTitle(model.state.tasks.first { $0.id == taskID }?.title ?? "Handgriffe")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: model.state.events.count)
    }
}

private struct StepRow: View {
    let task: HouseholdTask
    let step: ActionStep
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let isDone = step.completedAt != nil
        Button {
            withAnimation { _ = model.perform { try $0.setStepDone(taskID: task.id, stepID: step.id, done: !isDone) } }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.text)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = step.hint { Text("→ \(hint)").font(.caption).foregroundStyle(.secondary) }
                    if let target = step.targetPlaceID {
                        Text(model.state.path(for: target)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.text)
        .accessibilityValue(isDone ? "erledigt" : "offen")
        .accessibilityHint(isDone ? "Doppeltippen, um wieder auf offen zu setzen" : "Doppeltippen, um als erledigt abzuhaken")
    }
}

/// "Wo ist was?": search places and items, filter by moving status, scan labels, move things around.
struct FindView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var statusFilter: PlaceStatus?
    @State private var scanning = false
    @State private var moving = false
    @State private var printing = false
    @State private var suggesting = false
    @State private var blankLabels = false

    private var filteredPlaces: [StoragePlace] {
        model.state.places.filter { place in
            (statusFilter == nil || place.status == statusFilter)
                && (query.isEmpty || model.state.path(for: place.id).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let hits = statusFilter == nil ? model.state.searchInventory(query) : []
        let suggestionCount = model.state.labelSuggestions().count
        List {
            if suggestionCount > 0 {
                Section {
                    Button { suggesting = true } label: {
                        Label("Etiketten-Vorschläge ansehen (\(suggestionCount))", systemImage: "wand.and.stars")
                    }
                } footer: {
                    Text("Die App schlägt vor, welche Kisten und Schränke ein QR-Etikett verdienen. Du entscheidest.")
                }
            }
            if !model.state.places.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("Alle", symbol: "square.grid.2x2", selected: statusFilter == nil) { statusFilter = nil }
                            ForEach(PlaceStatus.allCases) { status in
                                let count = model.state.places(with: status).count
                                chip("\(status.label) (\(count))", symbol: status.symbol, selected: statusFilter == status) { statusFilter = status }
                            }
                        }
                    }
                } header: { Text("Umzugsstatus") }
            }
            if !hits.isEmpty {
                Section("Gegenstände") {
                    ForEach(hits) { hit in
                        NavigationLink { PlaceDetailView(placeID: hit.placeID) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.item.count.map { "\($0)× \(hit.item.name)" } ?? hit.item.name)
                                Label(model.state.path(for: hit.placeID), systemImage: "archivebox")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section(hits.isEmpty ? "" : "Lagerorte") {
                ForEach(filteredPlaces) { place in
                    NavigationLink { PlaceDetailView(placeID: place.id) } label: { PlaceRow(place: place) }
                }
            }
            if model.state.places.isEmpty {
                ContentUnavailableView("Noch keine Lagerorte", systemImage: "archivebox",
                    description: Text("Lass die KI einen Raum ansehen und übernimm die erkannten Regale, Schränke und Kisten. Dann kannst du hineinfotografieren, Etiketten drucken und per Scan umräumen."))
            } else if filteredPlaces.isEmpty && hits.isEmpty {
                Text(statusFilter == nil ? "Nichts gefunden. Gesucht wird in Lagerorten und in den erfassten Gegenständen."
                                         : "Kein Ort hat diesen Status.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Wo ist was?")
        .searchable(text: $query, prompt: "Gegenstand, Kiste, Regal …")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Leere Etiketten vorbereiten", systemImage: "qrcode") { blankLabels = true }
                    Button("Etiketten aller Lagerorte", systemImage: "printer") { printing = true }
                        .disabled(model.state.places.isEmpty)
                    Button("Umräumen per Scan", systemImage: "arrow.left.arrow.right") { moving = true }
                        .disabled(model.state.places.isEmpty)
                } label: { Label("Mehr", systemImage: "ellipsis.circle") }
                Button("QR-Etikett scannen", systemImage: "qrcode.viewfinder") { scanning = true }
            }
        }
        .sheet(isPresented: $scanning) {
            PlaceScanSheet(prompt: "Scanne das Etikett einer Kiste oder eines Regals", allowNewCode: true) { place in
                model.openedPlace = AppModel.OpenedPlace(id: place.id)
            }
        }
        .sheet(isPresented: $moving) { MoveByScanSheet() }
        .sheet(isPresented: $suggesting) { LabelSuggestionsSheet() }
        .sheet(isPresented: $blankLabels) { BlankLabelsSheet() }
        .sheet(isPresented: $printing) { LabelSheet(placeIDs: model.state.places.map(\.id)) }
    }

    private func chip(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.footnote) }
            .buttonStyle(.bordered)
            .tint(selected ? Color.accentColor : Color.secondary)
            .fontWeight(selected ? .bold : .regular)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
