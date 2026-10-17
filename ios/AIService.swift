import Foundation
import Security
import UIKit
import OrderCore

/// The user's own OpenAI API key, kept in the iOS keychain on this device only.
/// It is never part of the app bundle, a backup export or the household JSON.
enum AIKeyStore {
    private static let service = "local.ordnungsplaner.openai"
    private static let account = "api-key"

    static var key: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static var hasKey: Bool { key != nil }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw OrderError.invalid("Bitte einen gültigen Schlüssel einfügen.") }
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: Data(trimmed.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw OrderError.invalid("Der Schlüssel konnte nicht gespeichert werden (\(status)).") }
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// What the model must return for one room. Field names are German so the
/// schema reads naturally to the model; every field is required (strict mode).
struct AIRoomPlan: Decodable {
    struct Place: Decodable { let name: String; let art: String; let hinweis: String }
    struct Step: Decodable { let text: String; let zielort: String }
    struct Task: Decodable { let titel: String; let minuten: Int; let energie: String; let handgriffe: [Step] }
    let zusammenfassung: String
    let startpunkt: String
    let lagerorte: [Place]
    let problemzonen: [String]
    let aufgaben: [Task]
}

enum AIService {
    static let defaultModel = "gpt-5-mini"
    static let modelKey = "aiModel"

    static var model: String {
        let value = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModel : value
    }

    /// Smaller copies for the upload: enough detail for the model, far fewer bytes.
    static func uploadJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, 1024 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.6)
    }

    static func analyze(roomName: String, photos: [Data], knownPlaces: [String], goal: Goal,
                        minutes: Int, energy: Energy) async throws -> AIRoomPlan {
        guard let key = AIKeyStore.key else {
            throw OrderError.invalid("Für die KI fehlt noch dein OpenAI-Schlüssel. Trage ihn unter Einstellungen → KI ein.")
        }
        let images = photos.compactMap(uploadJPEG)
        guard !images.isEmpty else { throw OrderError.invalid("Für \(roomName) gibt es noch keine lesbaren Fotos.") }

        var content: [[String: Any]] = [["type": "input_text",
                                         "text": prompt(roomName: roomName, photoCount: images.count, knownPlaces: knownPlaces,
                                                        goal: goal, minutes: minutes, energy: energy)]]
        for image in images {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + image.base64EncodedString()])
        }
        let body: [String: Any] = [
            "model": model,
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "raumplan", "strict": true, "schema": schema]]
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OrderError.invalid(message(status: status, data: data)) }
        guard let text = outputText(data) else {
            throw OrderError.invalid("Die KI hat keine verwertbare Antwort geliefert. Bitte noch einmal versuchen.")
        }
        do { return try JSONDecoder().decode(AIRoomPlan.self, from: Data(text.utf8)) }
        catch { throw OrderError.invalid("Die Antwort der KI hatte ein unerwartetes Format. Bitte noch einmal versuchen.") }
    }

    /// Cheap call that only checks key and model, without photos.
    static func check() async throws {
        guard let key = AIKeyStore.key else { throw OrderError.invalid("Noch kein Schlüssel gespeichert.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/" + model)!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OrderError.invalid(message(status: status, data: data)) }
    }

    private static func outputText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else { return nil }
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }

    private static func message(status: Int, data: Data) -> String {
        let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return "OpenAI lehnt den Schlüssel ab. Bitte unter Einstellungen → KI prüfen."
        case 404: return "Das KI-Modell „\(model)“ ist für deinen Schlüssel nicht verfügbar. Unter Einstellungen → KI ein anderes Modell eintragen."
        case 429: return "OpenAI meldet ein Limit oder fehlendes Guthaben. Bitte später erneut versuchen oder das Konto prüfen."
        default: return "Die KI ist gerade nicht erreichbar (\(status)). " + (detail ?? "Bitte Internetverbindung prüfen.")
        }
    }

    private static func prompt(roomName: String, photoCount: Int, knownPlaces: [String], goal: Goal,
                               minutes: Int, energy: Energy) -> String {
        let goalText: String
        switch goal {
        case .order: goalText = "Dauerhafte Ordnung: Dingen feste, passende Plätze geben, Ablagen leeren, Ordnung soll bleiben."
        case .visitors: goalText = "Besuch kommt: zuerst sichtbare Flächen, Boden und Sitzplätze frei, schnell vorzeigbar. Nichts Großes aussortieren."
        case .moving: goalText = "Umzug vorbereiten: aussortieren (behalten / abgeben / prüfen), gleichartige Dinge zusammen verpacken, Kisten beschriften."
        case .cleaning: goalText = "Grundreinigung: erst Flächen und Boden freiräumen, dann von oben nach unten putzen."
        }
        let energyText: String
        switch energy {
        case .low: energyText = "wenig Energie: nur sehr kleine, leichte Handgriffe, nichts Schweres, viele kleine Erfolge."
        case .normal: energyText = "normale Energie."
        case .high: energyText = "viel Energie: auch größere Handgriffe sind in Ordnung."
        }
        let places = knownPlaces.isEmpty ? "keine" : knownPlaces.joined(separator: ", ")
        return """
        Du bist ein ruhiger, praktischer Aufräum-Coach. Du siehst \(photoCount) Fotos desselben Raums „\(roomName)“ \
        aus verschiedenen Blickwinkeln. Setze sie gedanklich zu einem Raum zusammen; Dinge, die auf mehreren Fotos \
        auftauchen, zählen nur einmal.

        Ziel: \(goalText)
        Zeit für diesen Raum: etwa \(minutes) Minuten. Energie: \(energyText)
        Bereits bekannte Lagerorte des Nutzers: \(places).

        Regeln:
        - Beschreibe nur, was wirklich zu sehen ist. Nichts erfinden. Bei Unsicherheit „vermutlich“ schreiben.
        - lagerorte: sichtbare Möbel oder Behälter, in die man etwas räumen kann (Regal, Schrank, Kommode, Kiste, Ablage). \
        art ist eines von: regal, schrank, kommode, kiste, ablage, sonstiges. Keine Aussage über freien Platz oder Inhalt.
        - problemzonen: kurze Stellen mit Unordnung oder Dingen ohne festen Platz, z. B. „Kleiderstapel auf dem Stuhl“.
        - startpunkt: ein konkreter Ort, wo man in einer Minute sichtbar Erfolg hat, mit kurzer Begründung.
        - aufgaben: in sinnvoller Reihenfolge, zusammen höchstens \(minutes) Minuten. Jede Aufgabe 2–6 Handgriffe.
        - Ein Handgriff ist ein einzelner, sofort ausführbarer Schritt, beginnt mit einem Verb und nennt den Gegenstand, \
        z. B. „Leg die drei Tassen vom Schreibtisch in die Küche“. zielort: wohin damit, oder leerer Text.
        - Wegwerfen oder Weggeben nie bestimmen, nur „aussortieren und prüfen“ vorschlagen.
        - energie je Aufgabe: wenig, normal oder viel. minuten: ganze Zahl 1–60.
        - Alles auf Deutsch, freundlich, kurz, in Du-Form.
        """
    }

    private static let schema: [String: Any] = {
        func str() -> [String: Any] { ["type": "string"] }
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": Array(props.keys), "additionalProperties": false]
        }
        let step = obj(["text": str(), "zielort": str()])
        let task = obj(["titel": str(), "minuten": ["type": "integer"], "energie": ["type": "string", "enum": ["wenig", "normal", "viel"]],
                        "handgriffe": ["type": "array", "items": step]])
        let place = obj(["name": str(), "art": ["type": "string", "enum": ["regal", "schrank", "kommode", "kiste", "ablage", "sonstiges"]],
                         "hinweis": str()])
        return obj(["zusammenfassung": str(), "startpunkt": str(), "lagerorte": ["type": "array", "items": place],
                    "problemzonen": ["type": "array", "items": str()], "aufgaben": ["type": "array", "items": task]])
    }()
}

extension AIRoomPlan {
    /// Converts the answer into stored data: an analysis record and tasks in the
    /// model's order, trimmed to the time budget (at least one task survives).
    func records(roomID: UUID, photoIDs: [UUID], goal: Goal, minutes: Int) -> (RoomAnalysis, [HouseholdTask]) {
        let analysis = RoomAnalysis(roomID: roomID, goal: goal, photoIDs: photoIDs, summary: zusammenfassung, startHint: startpunkt,
            detectedPlaces: lagerorte.map { DetectedPlace(name: $0.name, kind: $0.art, note: $0.hinweis) }, problemZones: problemzonen)
        var remaining = minutes
        var tasks: [HouseholdTask] = []
        for item in aufgaben {
            let steps = item.handgriffe.compactMap { step -> ActionStep? in
                let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hint = step.zielort.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : ActionStep(text: text, hint: hint.isEmpty ? nil : hint)
            }
            let title = item.titel.trimmingCharacters(in: .whitespacesAndNewlines)
            let length = min(max(item.minuten, 1), 60)
            guard !steps.isEmpty, !title.isEmpty else { continue }
            if !tasks.isEmpty && length > remaining { break }
            let energy: Energy = item.energie == "wenig" ? .low : item.energie == "viel" ? .high : .normal
            tasks.append(HouseholdTask(roomID: roomID, title: title, goal: goal, energy: energy,
                                       estimatedMinutes: length, steps: steps, source: .ai))
            remaining -= length
        }
        return (analysis, tasks)
    }
}
