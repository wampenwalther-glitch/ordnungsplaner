import SwiftUI
import OrderCore

/// All printer profiles: add, edit, delete. Used from the settings and from every print preview.
struct PrinterProfilesView: View {
    var asSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var profiles = PrinterProfiles.load()

    var body: some View {
        List {
            Section {
                Text("Lege fest, welche Etiketten oder welches Papier dein Drucker nimmt. Die App erzeugt Etiketten und Bons genau in dieser Größe. Pro Drucker ein Profil.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Profile") {
                ForEach($profiles) { $profile in
                    NavigationLink { PrinterProfileEditor(profile: $profile) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text("\(profile.kind.title) · \(Int(profile.widthMM)) × \(profile.heightMM > 0 ? "\(Int(profile.heightMM))" : "auto") mm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: profile.kind.systemImage) }
                    }
                }
                .onDelete { offsets in if profiles.count > offsets.count { profiles.remove(atOffsets: offsets) } }
                Button("Profil hinzufügen", systemImage: "plus") {
                    profiles.append(PrinterProfile(name: "Neues Profil", kind: .label, widthMM: 40, heightMM: 20, qrMM: 16))
                }
                Button("Standardprofile wiederherstellen", systemImage: "arrow.counterclockwise", role: .destructive) {
                    profiles = PrinterProfile.defaults
                }
            }
        }
        .navigationTitle("Druckerprofile")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: profiles) { _, new in PrinterProfiles.save(new) }
        .toolbar {
            if asSheet { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            else { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        }
    }
}

struct PrinterProfileEditor: View {
    @Binding var profile: PrinterProfile

    private static let sample = LabelContent(code: "K07", name: "Elektronik und Kabel",
                                             path: "Arbeitszimmer › Regal 2 › Fach 3",
                                             link: "ordnungsplaner://place/00000000-0000-0000-0000-000000000000",
                                             roomName: "Arbeitszimmer", typeName: "Kiste")

    var body: some View {
        Form {
            Section("Drucker") {
                TextField("Name", text: $profile.name)
                Picker("Art", selection: $profile.kind) { ForEach(PrinterProfile.Kind.allCases) { Text($0.title).tag($0) } }
            }
            Section {
                Stepper("Breite: \(Int(profile.widthMM)) mm", value: $profile.widthMM, in: 15...220, step: 1)
                Stepper(profile.heightMM == 0 ? "Höhe: automatisch" : "Höhe: \(Int(profile.heightMM)) mm",
                        value: $profile.heightMM, in: 0...300, step: 1)
                Stepper("QR-Code: \(Int(profile.qrMM)) mm", value: $profile.qrMM, in: 8...80, step: 1)
                Stepper("Rand: \(String(format: "%.1f", profile.marginMM)) mm", value: $profile.marginMM, in: 0...12, step: 0.5)
                VStack(alignment: .leading) {
                    Text("Schriftgröße: \(Int(profile.fontScale * 100)) %")
                    Slider(value: $profile.fontScale, in: 0.6...1.8, step: 0.05)
                }
                Toggle("Quer drucken (Etikett drehen)", isOn: $profile.landscape)
            } header: {
                Text("Maße")
            } footer: {
                Text(profile.kind == .receipt ? "Bei Bon-Rollen gibt die Breite die Papierbreite an, die Länge ergibt sich aus dem Inhalt (Höhe 0)."
                                              : "Bei Etiketten sind Breite und Höhe die Maße eines Etiketts. Auf A4-Bögen ordnet die App so viele Etiketten wie möglich an.")
            }
            Section("Vorschau") {
                let sample = PrinterProfileEditor.sample
                if let image = LabelRenderer.preview(LabelView(content: sample, profile: profile)) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 320)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5)))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Vorschau eines Etiketts mit diesen Maßen")
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The daily slip: today's to-dos on the receipt printer, independent of the inventory.
struct SlipSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int> = []
    @State private var extra = ""
    @State private var loaded = false

    /// Open tasks, the running round first.
    private var candidates: [String] {
        let running = Set(model.state.session?.taskIDs ?? [])
        let open = model.state.tasks.filter { !$0.isComplete }
        let ordered = open.filter { running.contains($0.id) } + open.filter { !running.contains($0.id) }
        return ordered.map { task in
            if let step = task.nextStep, task.steps.count > 1 { return "\(task.title): \(step.text)" }
            return task.title
        }
    }

    private var lines: [String] {
        let list = candidates
        let picked = list.indices.filter { chosen.contains($0) }.map { list[$0] }
        let own = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return picked + (own.isEmpty ? [] : [own])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ein kurzer Bon für heute. Wähle aus, was draufstehen soll, und drucke ihn auf deinem Bon-Drucker.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Was steht drauf?") {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { index, line in
                        Toggle(line, isOn: Binding(get: { chosen.contains(index) },
                                                   set: { if $0 { chosen.insert(index) } else { chosen.remove(index) } }))
                    }
                    TextField("Eigene Zeile, z. B. Paket wegbringen", text: $extra)
                }
                Section("Vorschau und Druck") {
                    PrintPanel(kinds: [.receipt], jobName: "Tagesbon") { profile in
                        [SlipView(title: "HEUTE", date: Date().formatted(date: .complete, time: .omitted), lines: lines, profile: profile)]
                    }
                    .id(lines)
                }
            }
            .navigationTitle("Tagesbon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear {
                if !loaded { chosen = Set(candidates.indices.prefix(8)); loaded = true }
            }
        }
    }
}
