import SwiftUI
import OrderCore

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(AppModel.autoDeleteKey) private var autoDelete = false
    @State private var confirmingCleanup = false
    @State private var hasKey = AIKeyStore.hasKey

    private var aiStatus: String {
        if auth.isConnected { return "Mit ChatGPT verbunden" }
        return hasKey ? "Eigener API-Schlüssel" : "Nicht eingerichtet"
    }

    var body: some View {
        List {
            Section("Darstellung") {
                Picker("Modus", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("KI") {
                NavigationLink { AISettingsView() } label: { LabeledContent("KI-Zugang", value: aiStatus) }
                LabeledContent("Gelernte Routinen", value: "\(model.state.learned.count)")
                Text("Wenn die KI mal nicht erreichbar ist, plant die App aus ca. \(LocalPlanner.rules.count) eingebauten Routinen und denen, die die KI dir früher vorgeschlagen hat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zeit") {
                NavigationLink { TimerSettingsView() } label: { Label("Timer und Hinweise", systemImage: "bell") }
            }
            Section {
                LabeledContent("Fotos", value: "\(model.state.photos.count) · \(String(format: "%.1f MB", Double(model.state.photoBytes) / 1_000_000))")
                let old = model.state.allOutdatedPhotos
                if !old.isEmpty {
                    Button("Ausgewertete Fotos löschen (\(old.count) · \(RoomDetailView.megabytes(old)))", systemImage: "trash") {
                        confirmingCleanup = true
                    }
                }
                Toggle("Fotos nach der Auswertung automatisch löschen", isOn: $autoDelete)
            } header: {
                Text("Speicher")
            } footer: {
                Text("Die KI merkt sich, was sie auf den Fotos gesehen hat. Die Bilder selbst kannst du danach löschen, ohne dass das Wissen verloren geht. Ist die automatische Option an, löscht die App Fotos direkt nach der Auswertung.")
            }
            Section("Daten") {
                NavigationLink { DataSettingsView() } label: { Label("Sicherung und Wiederherstellung", systemImage: "externaldrive") }
            }
            Section("Über") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Text("Deine Wohnungsdaten bleiben auf diesem iPhone. Nur wenn du die KI benutzt, gehen die Fotos der gewählten Räume zur Auswertung an OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Einstellungen")
        .onAppear { hasKey = AIKeyStore.hasKey }
        .confirmationDialog("Ausgewertete Fotos löschen?", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("Fotos löschen", role: .destructive) { model.deleteAnalyzedPhotos() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Räume und Lagerorte behalten ihre Auswertung. Nur die Bilder werden gelöscht.")
        }
    }
}

struct TimerSettingsView: View {
    @AppStorage(TimerAlerts.soundKey) private var sound = true
    @AppStorage(TimerMilestone.half.defaultsKey) private var half = true
    @AppStorage(TimerMilestone.left10.defaultsKey) private var left10 = true
    @AppStorage(TimerMilestone.left5.defaultsKey) private var left5 = true
    @AppStorage(TimerMilestone.left2.defaultsKey) private var left2 = false
    @AppStorage(TimerMilestone.left1.defaultsKey) private var left1 = false
    @AppStorage(TimerMilestone.end.defaultsKey) private var end = true
    @State private var permission: String?

    var body: some View {
        Form {
            Section {
                Text("Während einer Aufräumrunde läuft ein Timer mit deiner gewählten Zeit. Hier legst du fest, wann dich die App erinnert. Die Hinweise kommen auch, wenn das iPhone gesperrt ist.")
                    .font(.callout)
            }
            Section("Wann soll ich dich erinnern?") {
                Toggle(TimerMilestone.half.label, isOn: $half)
                Toggle(TimerMilestone.left10.label, isOn: $left10)
                Toggle(TimerMilestone.left5.label, isOn: $left5)
                Toggle(TimerMilestone.left2.label, isOn: $left2)
                Toggle(TimerMilestone.left1.label, isOn: $left1)
                Toggle(TimerMilestone.end.label, isOn: $end)
            }
            Section {
                Toggle("Ton abspielen", isOn: $sound)
                Button("Testhinweis in 5 Sekunden", systemImage: "bell.badge") {
                    TimerAlerts.shared.scheduleTest()
                    Task { permission = nil; try? await Task.sleep(for: .seconds(1)); await loadPermission() }
                }
            } header: {
                Text("Ton")
            } footer: {
                if let permission { Text(permission) }
                else { Text("Zum Testen die App geöffnet lassen oder das iPhone sperren.") }
            }
        }
        .navigationTitle("Timer und Hinweise")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPermission() }
        .onChange(of: sound) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: half) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: left10) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: left5) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: left2) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: left1) { _, _ in TimerAlerts.shared.refresh() }
        .onChange(of: end) { _, _ in TimerAlerts.shared.refresh() }
    }

    private func loadPermission() async {
        switch await TimerAlerts.shared.authorizationStatus() {
        case .denied: permission = "Mitteilungen sind für den Ordnungsplaner ausgeschaltet. Erlaube sie in den iPhone-Einstellungen unter Mitteilungen, sonst kommen keine Hinweise."
        case .notDetermined: permission = "Beim ersten Hinweis fragt das iPhone, ob Mitteilungen erlaubt sind. Bitte erlauben."
        default: permission = nil
        }
    }
}

struct AISettingsView: View {
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(AIService.modelKey) private var apiModel = ""
    @AppStorage(AIService.chatGPTModelKey) private var chatGPTModel = ""
    @State private var keyInput = ""
    @State private var hasKey = AIKeyStore.hasKey
    @State private var models: [(slug: String, name: String)] = []
    @State private var message: String?
    @State private var messageIsError = false
    @State private var working = false
    @State private var signOutNote: String?

    var body: some View {
        Form {
            Section {
                if auth.isConnected {
                    Label(auth.email.map { "Verbunden als \($0)" } ?? "Mit ChatGPT verbunden", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Die KI nutzt dein ChatGPT-Abo (Plus oder Pro). Du brauchst keinen Schlüssel und kein API-Guthaben.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(working ? "Prüfe …" : "Verbindung testen", systemImage: "antenna.radiowaves.left.and.right") {
                        Task { await testChatGPT() }
                    }
                    .disabled(working)
                    if !models.isEmpty {
                        Picker("Modell", selection: $chatGPTModel) {
                            Text("Automatisch").tag("")
                            ForEach(models, id: \.slug) { Text($0.name).tag($0.slug) }
                        }
                    }
                    Button("Verbindung trennen", systemImage: "link.badge.minus", role: .destructive) {
                        Task { await disconnect() }
                    }
                    .disabled(working)
                } else {
                    Text("Verbinde den Ordnungsplaner einmal mit deinem ChatGPT-Konto. Danach rechnet die KI über dein ChatGPT-Abo – ohne Schlüssel, ohne extra Guthaben.")
                    Button {
                        Task { await connect() }
                    } label: {
                        Label(auth.busy ? "Warte auf ChatGPT …" : "Mit ChatGPT verbinden", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(auth.busy)
                    Text("Du brauchst ChatGPT Plus oder Pro. Beim Verbinden erlaubst du ausdrücklich, dass diese App dein Nutzungskontingent verwendet. Deine ChatGPT-Chats sieht die App nicht.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark")
                        .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                }
                if let signOutNote { Text(signOutNote).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("Das Kontingent teilt sich mit deinen normalen ChatGPT-Chats. In ChatGPT unter Einstellungen → Nutzung legst du fest, wie viel diese App höchstens verbrauchen darf.")
            }

            Section {
                DisclosureGroup("Stattdessen eigener API-Schlüssel (kostet extra)") {
                    Text("Nur nötig, wenn du kein ChatGPT Plus oder Pro hast. Die Abrechnung läuft getrennt über dein OpenAI-API-Konto.")
                        .font(.caption).foregroundStyle(.secondary)
                    if hasKey { Label("Schlüssel ist gespeichert", systemImage: "key.fill") }
                    SecureField("Schlüssel einfügen (sk-…)", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Schlüssel speichern", systemImage: "key") {
                        do {
                            try AIKeyStore.save(keyInput)
                            keyInput = ""
                            hasKey = true
                            show("Schlüssel gespeichert.", error: false)
                        } catch { show(error.localizedDescription, error: true) }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("Schlüssel testen", systemImage: "antenna.radiowaves.left.and.right") { Task { await testKey() } }
                            .disabled(working)
                        Button("Schlüssel löschen", systemImage: "trash", role: .destructive) {
                            AIKeyStore.delete()
                            hasKey = false
                            show("Schlüssel gelöscht.", error: false)
                        }
                    }
                    TextField(AIService.defaultModel, text: $apiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Modell für den Schlüssel; leer lassen für „\(AIService.defaultModel)“.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                if auth.isConnected && hasKey { Text("Solange ChatGPT verbunden ist, wird der Schlüssel nicht benutzt.") }
            }
        }
        .navigationTitle("KI")
        .task { if auth.isConnected && models.isEmpty { models = (try? await AIService.chatGPTModels()) ?? [] } }
    }

    private func show(_ text: String, error: Bool) { message = text; messageIsError = error }

    private func connect() async {
        message = nil
        signOutNote = nil
        do {
            try await auth.signIn()
            show("Verbunden. Die KI nutzt jetzt dein ChatGPT-Abo.", error: false)
            models = (try? await AIService.chatGPTModels()) ?? []
        } catch { show(error.localizedDescription, error: true) }
    }

    private func disconnect() async {
        working = true
        defer { working = false }
        let confirmed = await auth.signOut()
        models = []
        show("Getrennt.", error: false)
        signOutNote = confirmed ? nil
            : "Die Trennung konnte bei OpenAI nicht bestätigt werden. Du kannst die App zusätzlich in ChatGPT unter Einstellungen → Verbundene Apps entfernen."
    }

    private func testChatGPT() async {
        working = true
        defer { working = false }
        do {
            let name = try await AIService.checkChatGPT()
            models = (try? await AIService.chatGPTModels()) ?? models
            show("Verbindung klappt. Modell: \(name).", error: false)
        } catch let error as URLError { show(AIService.networkMessage(error), error: true) }
        catch { show(error.localizedDescription, error: true) }
    }

    private func testKey() async {
        working = true
        defer { working = false }
        do { try await AIService.checkAPIKey(); show("Schlüssel funktioniert.", error: false) }
        catch { show(error.localizedDescription, error: true) }
    }
}
