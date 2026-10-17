import SwiftUI
import OrderCore

extension Goal {
    var symbol: String {
        switch self {
        case .order: return "square.grid.2x2"
        case .visitors: return "person.2"
        case .moving: return "shippingbox"
        case .cleaning: return "sparkles"
        }
    }
}

extension Energy {
    var symbol: String {
        switch self {
        case .low: return "battery.25"
        case .normal: return "battery.50"
        case .high: return "battery.100"
        }
    }
    var shortLabel: String {
        switch self {
        case .low: return "Wenig"
        case .normal: return "Normal"
        case .high: return "Viel"
        }
    }
}

/// Big selectable tile used for rooms, goals and energy.
struct ChoiceTile: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StartFlowView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRooms: Set<UUID> = []
    @State private var goal: Goal = .order
    @State private var minutes = 20
    @State private var energy: Energy = .normal
    @State private var photosFor: Room?
    @State private var preview: PlanPreview?
    @State private var working = false
    @State private var errorText: String?
    @State private var hasKey = AIKeyStore.hasKey

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private var orderedSelection: [UUID] { model.state.rooms.map(\.id).filter { selectedRooms.contains($0) } }
    private var roomsWithoutPhotos: [Room] {
        model.state.rooms.filter { selectedRooms.contains($0.id) && model.state.roomPhotos($0.id).isEmpty }
    }
    private var sessionRunning: Bool {
        if let status = model.state.session?.status { return status != .finished }
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if let preview { PlanPreviewView(plan: preview, errorText: $errorText, onBack: { self.preview = nil }, onStart: start) }
                else if working { planningView }
                else { form }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(preview == nil ? "Aufräumen starten" : "Dein Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
            .sheet(item: $photosFor) { room in NavigationStack { RoomPhotosSheet(roomID: room.id) } }
            .onAppear {
                hasKey = AIKeyStore.hasKey
                if selectedRooms.isEmpty, model.state.rooms.count == 1 { selectedRooms = [model.state.rooms[0].id] }
            }
        }
    }

    private var planningView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(model.planningStatus ?? "Die KI denkt nach …").font(.headline).multilineTextAlignment(.center)
            Text("Das dauert meist 20 bis 60 Sekunden pro Raum.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if sessionRunning {
                    Card {
                        Label("Es läuft noch eine Runde", systemImage: "exclamationmark.circle").font(.headline)
                        Text("Mach dort weiter oder beende sie, bevor du eine neue planst.").foregroundStyle(.secondary)
                        Button("Laufende Runde beenden", systemImage: "stop") { model.perform { try $0.endSession() } }
                            .buttonStyle(.bordered)
                    }
                }

                section("1  Welche Räume?") {
                    if model.state.rooms.count > 1 {
                        Button(selectedRooms.count == model.state.rooms.count ? "Keinen auswählen" : "Alle Räume auswählen") {
                            selectedRooms = selectedRooms.count == model.state.rooms.count ? [] : Set(model.state.rooms.map(\.id))
                        }
                        .font(.subheadline)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.state.rooms) { room in
                            let count = model.state.roomPhotos(room.id).count
                            ChoiceTile(title: room.name, systemImage: "house",
                                       subtitle: count == 0 ? "Noch keine Fotos" : "\(count) Fotos",
                                       selected: selectedRooms.contains(room.id)) {
                                if selectedRooms.contains(room.id) { selectedRooms.remove(room.id) } else { selectedRooms.insert(room.id) }
                            }
                        }
                    }
                    ForEach(roomsWithoutPhotos) { room in
                        Button { photosFor = room } label: {
                            Label("Fotos für \(room.name) machen", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }

                section("2  Was ist dein Ziel?") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Goal.allCases) { item in
                            ChoiceTile(title: item.label, systemImage: item.symbol, selected: goal == item) { goal = item }
                        }
                    }
                }

                section("3  Wie viel Zeit hast du?") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach([5, 10, 20, 30, 45, 60, 90], id: \.self) { value in
                                Button("\(value) Min.") { minutes = value }
                                    .buttonStyle(.bordered)
                                    .tint(minutes == value ? Color.accentColor : Color.secondary)
                                    .fontWeight(minutes == value ? .bold : .regular)
                            }
                        }
                    }
                }

                section("4  Wie viel Energie hast du?") {
                    HStack(spacing: 12) {
                        ForEach(Energy.allCases) { item in
                            ChoiceTile(title: item.shortLabel, systemImage: item.symbol, selected: energy == item) { energy = item }
                        }
                    }
                }

                if !hasKey {
                    Card {
                        Label("KI noch nicht eingerichtet", systemImage: "key").font(.headline)
                        Text("Einmalig deinen OpenAI-Schlüssel eintragen, dann kann die KI deine Fotos auswerten.")
                            .foregroundStyle(.secondary)
                        NavigationLink { AISettingsView() } label: { Label("KI einrichten", systemImage: "arrow.right") }
                            .buttonStyle(.bordered)
                    }
                }

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                BigButton("Plan erstellen", systemImage: "wand.and.stars") { Task { await plan() } }
                    .disabled(selectedRooms.isEmpty || !roomsWithoutPhotos.isEmpty || !hasKey || sessionRunning)
                Text("Die Fotos der gewählten Räume werden zur Auswertung an OpenAI geschickt. Gespeichert wird erst, wenn du den Plan startest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            content()
        }
    }

    private func plan() async {
        errorText = nil
        working = true
        defer { working = false }
        do { preview = try await model.makePlan(roomIDs: orderedSelection, goal: goal, minutes: minutes, energy: energy) }
        catch { errorText = error.localizedDescription }
    }

    private func start() {
        guard let preview else { return }
        do { try model.start(preview); dismiss() }
        catch { errorText = error.localizedDescription }
    }
}

private struct PlanPreviewView: View {
    let plan: PlanPreview
    @Binding var errorText: String?
    let onBack: () -> Void
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(plan.taskCount) Aufgaben · \(plan.stepCount) Handgriffe · \(plan.goal.label) · \(plan.minutes) Min.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(plan.rooms) { part in
                    Card {
                        Text(part.roomName).font(.title3.bold())
                        Text(part.analysis.summary)
                        if !part.analysis.startHint.isEmpty {
                            Label("Starte hier: \(part.analysis.startHint)", systemImage: "mappin.and.ellipse")
                                .foregroundStyle(Color.accentColor)
                        }
                        if !part.analysis.problemZones.isEmpty {
                            Text("Erkannte Baustellen").font(.subheadline.weight(.semibold))
                            ForEach(part.analysis.problemZones, id: \.self) { Label($0, systemImage: "exclamationmark.circle") }
                        }
                        Divider()
                        if part.tasks.isEmpty {
                            Text("Für diesen Raum gab es keine passenden Handgriffe.").foregroundStyle(.secondary)
                        }
                        ForEach(part.tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(task.title) · \(task.estimatedMinutes) Min.").font(.headline)
                                ForEach(task.steps) { Text("• \($0.text)").font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                BigButton("Los geht's", systemImage: "play.fill", action: onStart)
                    .disabled(plan.taskCount == 0)
                Button("Neu planen", systemImage: "arrow.counterclockwise", action: onBack)
                    .frame(maxWidth: .infinity)
                Text("Die KI kann sich irren. Was weg soll, entscheidest immer du.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
