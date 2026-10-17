import SwiftUI
import OrderCore

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @State private var hasKey = AIKeyStore.hasKey

    var body: some View {
        List {
            Section("Darstellung") {
                Picker("Modus", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("KI") {
                NavigationLink { AISettingsView() } label: {
                    LabeledContent("KI-Zugang", value: hasKey ? "Eingerichtet" : "Nicht eingerichtet")
                }
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
    }
}

struct AISettingsView: View {
    @AppStorage(AIService.modelKey) private var modelName = ""
    @State private var keyInput = ""
    @State private var hasKey = AIKeyStore.hasKey
    @State private var message: String?
    @State private var messageIsError = false
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Text("Die KI wertet deine Raumfotos aus und schlägt Handgriffe vor. Dafür brauchst du einen eigenen Schlüssel von OpenAI. Er bleibt nur auf diesem iPhone im Schlüsselbund.")
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    Label("Schlüssel bei OpenAI erstellen", systemImage: "arrow.up.right.square")
                }
                Text("Abgerechnet wird über dein OpenAI-Konto, meist wenige Cent pro Raum.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Schlüssel") {
                if hasKey {
                    Label("Schlüssel ist gespeichert", systemImage: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                }
                SecureField(hasKey ? "Neuen Schlüssel einfügen" : "Schlüssel einfügen (beginnt mit sk-)", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Speichern", systemImage: "key") {
                    do {
                        try AIKeyStore.save(keyInput)
                        keyInput = ""
                        hasKey = true
                        show("Gespeichert.", error: false)
                    } catch { show(error.localizedDescription, error: true) }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button(testing ? "Prüfe …" : "Verbindung testen", systemImage: "antenna.radiowaves.left.and.right") {
                        Task { await test() }
                    }
                    .disabled(testing)
                    Button("Schlüssel löschen", systemImage: "trash", role: .destructive) {
                        AIKeyStore.delete()
                        hasKey = false
                        show("Schlüssel gelöscht.", error: false)
                    }
                }
                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark")
                        .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                }
            }
            Section {
                TextField(AIService.defaultModel, text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Modell (für Fortgeschrittene)")
            } footer: {
                Text("Leer lassen für den Standard „\(AIService.defaultModel)“. Das Modell muss Bilder verstehen können.")
            }
        }
        .navigationTitle("KI")
    }

    private func show(_ text: String, error: Bool) { message = text; messageIsError = error }

    private func test() async {
        testing = true
        defer { testing = false }
        do { try await AIService.check(); show("Verbindung klappt.", error: false) }
        catch { show(error.localizedDescription, error: true) }
    }
}
