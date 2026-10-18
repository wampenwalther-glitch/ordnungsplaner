import Foundation

// Pure logic around the AI answers: reading the JSON, turning it into stored
// data, reading the event stream and wording errors. No network, no UI – so it
// can be tested without a device.

/// What the model returns for one room. Field names are German so the schema
/// reads naturally to the model; every field is required in strict mode.
public struct AIRoomPlan: Decodable {
    struct Place: Decodable { let name: String; let art: String; let hinweis: String }
    struct Step: Decodable { let text: String; let zielort: String }
    struct Task: Decodable { let titel: String; let minuten: Int; let energie: String; let handgriffe: [Step] }
    let zusammenfassung: String
    let startpunkt: String
    let lagerorte: [Place]
    let problemzonen: [String]
    let aufgaben: [Task]
    /// Kinds of clutter seen (raw values of `Clutter`); optional because the
    /// fallback route without a strict schema may leave it out.
    let muster: [String]?

    public static func parse(_ text: String) throws -> AIRoomPlan { try AIJSON.decode(text, as: AIRoomPlan.self) }

    /// Converts the answer into stored data: an analysis record and tasks in the
    /// model's order, trimmed to the time budget (at least one task survives).
    public func records(roomID: UUID, photoIDs: [UUID], goal: Goal, minutes: Int) -> (RoomAnalysis, [HouseholdTask]) {
        let analysis = RoomAnalysis(roomID: roomID, goal: goal, photoIDs: photoIDs, summary: zusammenfassung, startHint: startpunkt,
            detectedPlaces: lagerorte.map { DetectedPlace(name: $0.name, kind: $0.art, note: $0.hinweis) }, problemZones: problemzonen,
            tags: (muster ?? []).filter { Clutter(rawValue: $0) != nil })
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

/// What the AI saw in one storage place.
public struct AIInventory: Decodable {
    struct Item: Decodable { let name: String; let anzahl: String?; let hinweis: String? }
    let zusammenfassung: String
    let gegenstaende: [Item]
    let aufraeumtipps: [String]?

    public static func parse(_ text: String) throws -> AIInventory { try AIJSON.decode(text, as: AIInventory.self) }

    /// Stored form; entries without a name are dropped and the list is capped.
    public func record(placeID: UUID, photoIDs: [UUID]) -> PlaceInventory {
        func clean(_ text: String?) -> String? {
            let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let items = gegenstaende.compactMap { entry -> PlaceInventoryItem? in
            guard let name = clean(entry.name) else { return nil }
            return PlaceInventoryItem(name: name, count: clean(entry.anzahl), note: clean(entry.hinweis), source: "ai")
        }
        return PlaceInventory(placeID: placeID, photoIDs: photoIDs, summary: zusammenfassung.trimmingCharacters(in: .whitespacesAndNewlines),
                              items: Array(items.prefix(60)), tidyHints: (aufraeumtipps ?? []).compactMap { clean($0) })
    }
}

enum AIJSON {
    /// Decodes the model's text; tolerates text or code fences around the JSON object.
    static func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end {
            candidate = String(candidate[start...end])
        }
        do { return try JSONDecoder().decode(T.self, from: Data(candidate.utf8)) }
        catch { throw OrderError.invalid("Die Antwort der KI hatte ein unerwartetes Format. Bitte noch einmal versuchen.") }
    }
}

public struct AIStreamFailure: Error {
    public let code: String?
    public let detail: String?
}

/// Reads the server-sent events of a streamed answer. Only `response.completed`
/// counts as success; failures and cut-off streams are reported, never guessed.
public struct AIStreamReader {
    private var text = ""
    private var finalText: String?
    private var completed = false
    public init() {}

    public mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "response.output_text.delta": text += json["delta"] as? String ?? ""
        case "response.output_text.done": finalText = json["text"] as? String
        case "response.completed": completed = true
        case "response.failed", "error", "response.incomplete":
            let error = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any]
            throw AIStreamFailure(code: error?["code"] as? String, detail: error?["message"] as? String)
        default: break
        }
    }

    public func finish() throws -> String {
        guard completed else { throw OrderError.invalid("Die Antwort der KI wurde unterbrochen. Bitte noch einmal versuchen.") }
        return finalText ?? text
    }
}

/// Plain-language error texts with a clear next step for the user.
public enum AIResponseText {
    public static func status(for code: String) -> Int {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return 429
        case "subscription_sharing_user_not_eligible": return 403
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return 503
        case "subscription_sharing_invalid_user": return 401
        default: return 500
        }
    }

    public static func network(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "Keine Internetverbindung. Bitte WLAN oder Mobilfunk prüfen und noch einmal versuchen."
        case .timedOut:
            return "Die KI hat zu lange gebraucht. Bitte noch einmal versuchen, am besten mit weniger oder kleineren Fotos."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "OpenAI ist gerade nicht erreichbar. Bitte später noch einmal versuchen."
        default:
            return "Netzwerkproblem (\(error.code.rawValue)). Bitte Verbindung prüfen und noch einmal versuchen."
        }
    }

    public static func message(status: Int, code: String?, param: String?, detail: String?, chatGPT: Bool) -> String {
        switch code {
        case "subscription_sharing_user_not_eligible":
            return "Dein ChatGPT-Konto kann hier nicht verwendet werden. Du brauchst ChatGPT Plus oder Pro (kein Firmen-Arbeitsbereich mit gesperrter Freigabe). Alternativ: unter Einstellungen → KI einen eigenen API-Schlüssel eintragen."
        case "subscription_sharing_usage_limit_exceeded":
            return "Dein ChatGPT-Nutzungslimit ist erreicht. Das kann das Wochenlimit für diese App oder dein Tarif sein. Prüfe in ChatGPT unter Einstellungen → Nutzung, oder versuche es später noch einmal."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return "ChatGPT kann die Nutzung gerade nicht abrechnen. Bitte in ein paar Minuten noch einmal versuchen. Deine Anmeldung bleibt erhalten."
        case "subscription_sharing_unsupported_capability":
            return "ChatGPT unterstützt diese Anfrage nicht\(param.map { " (\($0))" } ?? ""). Bitte unter Einstellungen → KI ein anderes Modell wählen."
        case "subscription_sharing_invalid_user":
            return "Deine ChatGPT-Anmeldung wird nicht akzeptiert. Bitte unter Einstellungen → KI trennen und neu verbinden."
        case "insufficient_quota":
            return "Dein OpenAI-API-Guthaben ist aufgebraucht. Lade Guthaben auf – oder verbinde stattdessen deinen ChatGPT-Tarif unter Einstellungen → KI."
        case "rate_limit_exceeded":
            return "Zu viele Anfragen in kurzer Zeit. Bitte eine Minute warten und noch einmal versuchen."
        default: break
        }
        switch status {
        case 401:
            return chatGPT
                ? "Deine ChatGPT-Anmeldung ist abgelaufen oder wurde widerrufen. Bitte unter Einstellungen → KI erneut verbinden."
                : "OpenAI lehnt den API-Schlüssel ab. Bitte unter Einstellungen → KI prüfen oder neu eintragen."
        case 403:
            return chatGPT
                ? "ChatGPT verweigert den Zugriff (Berechtigung oder Region). Bitte unter Einstellungen → KI neu verbinden und die Tarif-Nutzung bestätigen."
                : "OpenAI verweigert den Zugriff für diesen Schlüssel (Berechtigung oder Region)."
        case 404:
            return "Das gewählte KI-Modell ist nicht verfügbar. Bitte unter Einstellungen → KI ein anderes Modell wählen."
        case 429:
            return chatGPT
                ? "Dein ChatGPT-Nutzungslimit ist erreicht oder es kamen zu viele Anfragen. Bitte später noch einmal versuchen."
                : "OpenAI meldet ein Anfrage-Limit. Bitte kurz warten und noch einmal versuchen."
        case 500...599:
            return "OpenAI ist gerade gestört oder überlastet (\(status)). Bitte in ein paar Minuten noch einmal versuchen."
        default:
            return "Die KI-Anfrage ist fehlgeschlagen (\(status))." + (detail.map { " Meldung: \($0)" } ?? "")
        }
    }
}
