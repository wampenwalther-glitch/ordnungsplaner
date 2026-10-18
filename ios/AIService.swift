import Foundation
import Security
import UIKit
import OrderCore

/// The user's own OpenAI API key (optional fallback), kept in the iOS keychain
/// on this device only. It is never part of the app bundle, a backup export or
/// the household JSON. Normal use goes through "Mit ChatGPT verbinden".
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
    /// Kinds of clutter seen (raw values of `Clutter`); optional because the
    /// fallback route without a strict schema may leave it out.
    let muster: [String]?
}

enum AIAccess {
    /// ChatGPT connection preferred; an API key is only the fallback.
    @MainActor static var isReady: Bool { ChatGPTAuth.shared.isConnected || AIKeyStore.hasKey }
}

@MainActor
enum AIService {
    static let defaultModel = "gpt-5-mini"
    static let modelKey = "aiModel"
    static let chatGPTModelKey = "chatgptModel"
    private static let base = "https://api.openai.com/v1"

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

    // MARK: Analysis

    /// With photos: the AI looks at them. Without photos but with `analysis`: text-only
    /// planning from what an earlier look saw (fast, no upload).
    static func analyze(roomName: String, photos: [Data], knownPlaces: [String], goal: Goal,
                        minutes: Int, energy: Energy, analysis: RoomAnalysis? = nil) async throws -> AIRoomPlan {
        guard ChatGPTAuth.shared.isConnected || AIKeyStore.hasKey else {
            throw OrderError.invalid("Die KI ist noch nicht eingerichtet. Verbinde dich unter Einstellungen → KI mit ChatGPT.")
        }
        let images = photos.compactMap(uploadJPEG)
        guard !images.isEmpty || analysis != nil else { throw OrderError.invalid("Für \(roomName) gibt es noch keine lesbaren Fotos.") }
        let text = prompt(roomName: roomName, photoCount: images.count, knownPlaces: knownPlaces,
                          goal: goal, minutes: minutes, energy: energy, analysis: analysis)
        return try decode(try await run(text: text, images: images, format: planFormat), as: AIRoomPlan.self)
    }

    /// What the user wants from a look into one storage place.
    enum InventoryMode { case inventoryOnly, tidy }

    /// Takes stock of what the photos of one storage place show.
    static func inventory(placeName: String, roomName: String, photos: [Data], mode: InventoryMode) async throws -> AIInventory {
        guard ChatGPTAuth.shared.isConnected || AIKeyStore.hasKey else {
            throw OrderError.invalid("Die KI ist noch nicht eingerichtet. Verbinde dich unter Einstellungen → KI mit ChatGPT.")
        }
        let images = photos.compactMap(uploadJPEG)
        guard !images.isEmpty else { throw OrderError.invalid("Für \(placeName) gibt es noch keine lesbaren Fotos.") }
        let tips = mode == .tidy
            ? "aufraeumtipps: 2 bis 6 konkrete Tipps, wie man den Inhalt ordnen könnte (Gleiches zusammen, beschriften, Aussortieren nur zum Prüfen vorschlagen, nie Wegwerfen bestimmen)."
            : "aufraeumtipps: immer eine leere Liste."
        let text = """
        Du machst eine Bestandsaufnahme. Du siehst \(images.count) Foto(s) vom Inhalt von „\(placeName)“ im Raum „\(roomName)“.

        Regeln:
        - gegenstaende: einzeln erkennbare Dinge oder Gruppen gleichartiger Dinge (z. B. „USB-Kabel“, „Winterpullover“, „Gesellschaftsspiele“). Gleichartiges zusammenfassen, höchstens 40 Einträge.
        - anzahl: nur wenn erkennbar, als Text wie „3“ oder „etwa 10“, sonst leer lassen.
        - hinweis: kurz, z. B. „oben links“, „vermutlich defekt“; sonst leer.
        - Nur beschreiben, was wirklich zu sehen ist. Nichts erfinden, nichts raten. Verdecktes oder Unklares nicht auflisten, sondern in der zusammenfassung erwähnen (z. B. „Hinten ist nichts erkennbar“).
        - Keine Aussage über freien Platz oder Prozentwerte.
        - zusammenfassung: ein bis zwei Sätze, was für ein Lagerort das ist und was hauptsächlich drin liegt.
        - \(tips)
        - Alles auf Deutsch, kurz, in Du-Form.
        """
        return try decode(try await run(text: text, images: images, format: inventoryFormat), as: AIInventory.self)
    }

    /// Sends one request over the ChatGPT plan (preferred) or the API key and returns the raw JSON text.
    private static func run(text: String, images: [Data], format: ResponseFormat) async throws -> String {
        do {
            if ChatGPTAuth.shared.isConnected { return try await viaChatGPT(text: text, images: images, format: format) }
            return try await viaAPIKey(text: text, images: images, format: format)
        } catch let error as URLError {
            throw OrderError.invalid(networkMessage(error))
        }
    }

    struct ResponseFormat {
        let name: String
        let schema: [String: Any]
        let hint: String
    }

    private static func content(text: String, images: [Data]) -> [[String: Any]] {
        var parts: [[String: Any]] = [["type": "input_text", "text": text]]
        for image in images {
            parts.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + image.base64EncodedString()])
        }
        return parts
    }

    // MARK: Route 1 – ChatGPT plan (official "Sign in with ChatGPT")

    private static func viaChatGPT(text: String, images: [Data], format: ResponseFormat) async throws -> String {
        var forceRefresh = false
        var structured = true
        var attempts = 0
        while true {
            attempts += 1
            let token = try await ChatGPTAuth.shared.validAccessToken(forceRefresh: forceRefresh)
            let model = try await chosenChatGPTModel(token: token)
            // Responses over this route must use store:false and stream:true.
            let prompt = structured ? text : text + "\n\nAntworte ausschließlich mit einem JSON-Objekt dieser Form (alle Felder Pflicht): "
                + format.hint
            var body: [String: Any] = [
                "model": model, "store": false, "stream": true,
                "input": [["role": "user", "content": content(text: prompt, images: images)]]
            ]
            if structured { body["text"] = ["format": ["type": "json_schema", "name": format.name, "strict": true, "schema": format.schema]] }
            var request = URLRequest(url: URL(string: base + "/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 240
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count > 20_000 { break } }
                let (code, param, detail) = errorInfo(data)
                if status == 401, attempts < 3, !forceRefresh { forceRefresh = true; continue }
                if code == "subscription_sharing_unsupported_capability", structured, attempts < 3 { structured = false; continue }
                throw OrderError.invalid(message(status: status, code: code, param: param, detail: detail, chatGPT: true))
            }
            do { return try await readStream(bytes) }
            catch let failure as StreamFailure {
                if failure.code == "subscription_sharing_unsupported_capability", structured, attempts < 3 { structured = false; continue }
                throw OrderError.invalid(message(status: failure.code == nil ? 500 : statusFor(code: failure.code!),
                                                 code: failure.code, param: nil, detail: failure.detail, chatGPT: true))
            }
        }
    }

    private struct StreamFailure: Error { let code: String?; let detail: String? }

    /// Reads the SSE stream to `response.completed`; anything else counts as failure.
    private static func readStream(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        var finalText: String?
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta": text += json["delta"] as? String ?? ""
            case "response.output_text.done": finalText = json["text"] as? String
            case "response.completed": completed = true
            case "response.failed", "error", "response.incomplete":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any] ?? json["error"] as? [String: Any]
                throw StreamFailure(code: error?["code"] as? String, detail: error?["message"] as? String)
            default: break
            }
        }
        guard completed else {
            throw OrderError.invalid("Die Antwort der KI wurde unterbrochen. Bitte noch einmal versuchen.")
        }
        return finalText ?? text
    }

    private static func chosenChatGPTModel(token: String) async throws -> String {
        let available = try await chatGPTModels(token: token)
        guard !available.isEmpty else {
            throw OrderError.invalid("Für dein ChatGPT-Konto wurden keine KI-Modelle gefunden.")
        }
        let wanted = UserDefaults.standard.string(forKey: chatGPTModelKey) ?? ""
        return available.first { $0.slug == wanted }?.slug ?? available[0].slug
    }

    /// Models the signed-in account may use, in the server's order.
    static func chatGPTModels(token: String? = nil) async throws -> [(slug: String, name: String)] {
        let resolved: String
        if let token { resolved = token } else { resolved = try await ChatGPTAuth.shared.validAccessToken() }
        var request = URLRequest(url: URL(string: base + "/models")!)
        request.setValue("Bearer " + resolved, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let (code, param, detail) = errorInfo(data)
            throw OrderError.invalid(message(status: status, code: code, param: param, detail: detail, chatGPT: true))
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let models = json["models"] as? [[String: Any]] {
            return models.compactMap { item in
                guard let slug = item["slug"] as? String, (item["visibility"] as? String ?? "list") == "list" else { return nil }
                return (slug, item["display_name"] as? String ?? slug)
            }
        }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return (id, id)
        }
    }

    /// Quick check without photos: sign-in valid, plan usage granted, models listed.
    static func checkChatGPT() async throws -> String {
        let models = try await chatGPTModels()
        guard let first = models.first else { throw OrderError.invalid("Verbunden, aber es sind keine Modelle freigegeben.") }
        let wanted = UserDefaults.standard.string(forKey: chatGPTModelKey) ?? ""
        return models.first { $0.slug == wanted }?.name ?? first.name
    }

    // MARK: Route 2 – own API key (optional fallback, billed separately by OpenAI)

    private static func viaAPIKey(text: String, images: [Data], format: ResponseFormat) async throws -> String {
        guard let key = AIKeyStore.key else { throw OrderError.invalid("Noch kein Schlüssel gespeichert.") }
        let body: [String: Any] = [
            "model": model,
            "input": [["role": "user", "content": content(text: text, images: images)]],
            "text": ["format": ["type": "json_schema", "name": format.name, "strict": true, "schema": format.schema]]
        ]
        var request = URLRequest(url: URL(string: base + "/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let (code, param, detail) = errorInfo(data)
            throw OrderError.invalid(message(status: status, code: code, param: param, detail: detail, chatGPT: false))
        }
        guard let output = outputText(data) else {
            throw OrderError.invalid("Die KI hat keine verwertbare Antwort geliefert. Bitte noch einmal versuchen.")
        }
        return output
    }

    /// Cheap call that only checks key and model, without photos.
    static func checkAPIKey() async throws {
        guard let key = AIKeyStore.key else { throw OrderError.invalid("Noch kein Schlüssel gespeichert.") }
        var request = URLRequest(url: URL(string: base + "/models/" + model)!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let (code, param, detail) = errorInfo(data)
                throw OrderError.invalid(message(status: status, code: code, param: param, detail: detail, chatGPT: false))
            }
        } catch let error as URLError { throw OrderError.invalid(networkMessage(error)) }
    }

    // MARK: Parsing and messages

    private static func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end {
            candidate = String(candidate[start...end])
        }
        do { return try JSONDecoder().decode(T.self, from: Data(candidate.utf8)) }
        catch { throw OrderError.invalid("Die Antwort der KI hatte ein unerwartetes Format. Bitte noch einmal versuchen.") }
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

    private static func errorInfo(_ data: Data) -> (code: String?, param: String?, detail: String?) {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let error = json["error"] as? [String: Any] ?? [:]
        return (error["code"] as? String ?? json["code"] as? String, error["param"] as? String, error["message"] as? String)
    }

    private static func statusFor(code: String) -> Int {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return 429
        case "subscription_sharing_user_not_eligible": return 403
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return 503
        case "subscription_sharing_invalid_user": return 401
        default: return 500
        }
    }

    static func networkMessage(_ error: URLError) -> String {
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

    private static func message(status: Int, code: String?, param: String?, detail: String?, chatGPT: Bool) -> String {
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

    // MARK: Prompt and schema

    private static func prompt(roomName: String, photoCount: Int, knownPlaces: [String], goal: Goal,
                               minutes: Int, energy: Energy, analysis: RoomAnalysis?) -> String {
        let intro: String
        if photoCount == 0, let analysis {
            let found = analysis.detectedPlaces.map(\.name).joined(separator: ", ")
            intro = """
            Du bist ein ruhiger, praktischer Aufräum-Coach. Du siehst keine Fotos, kennst aber den Raum „\(roomName)“ \
            aus einer früheren Auswertung seiner Fotos:
            Zusammenfassung: \(analysis.summary)
            Baustellen: \(analysis.problemZones.joined(separator: "; "))
            Aufbewahrung: \(found.isEmpty ? "keine erkannt" : found)
            Plane nur auf dieser Grundlage und erfinde nichts dazu.
            """
        } else {
            intro = """
            Du bist ein ruhiger, praktischer Aufräum-Coach. Du siehst \(photoCount) Fotos desselben Raums „\(roomName)“ \
            aus verschiedenen Blickwinkeln. Setze sie gedanklich zu einem Raum zusammen; Dinge, die auf mehreren Fotos \
            auftauchen, zählen nur einmal.
            """
        }
        let patterns = Clutter.allCases.map(\.rawValue).joined(separator: ", ")
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
        \(intro)

        Ziel: \(goalText)
        Zeit für diesen Raum: etwa \(minutes) Minuten. Energie: \(energyText)
        Bereits bekannte Lagerorte des Nutzers: \(places).

        Regeln:
        - Beschreibe nur, was wirklich zu sehen ist. Nichts erfinden. Bei Unsicherheit „vermutlich“ schreiben.
        - lagerorte: sichtbare Möbel oder Behälter, in die man etwas räumen kann (Regal, Schrank, Kommode, Kiste, Ablage). \
        art ist eines von: regal, schrank, kommode, kiste, ablage, sonstiges. Keine Aussage über freien Platz oder Inhalt.
        - problemzonen: kurze Stellen mit Unordnung oder Dingen ohne festen Platz, z. B. „Kleiderstapel auf dem Stuhl“.
        - muster: welche dieser Arten von Unordnung im Raum wirklich vorkommen (nur aus dieser Liste, sonst weglassen): \(patterns).
        - startpunkt: ein konkreter Ort, wo man in einer Minute sichtbar Erfolg hat, mit kurzer Begründung.
        - aufgaben: in sinnvoller Reihenfolge, zusammen höchstens \(minutes) Minuten. Jede Aufgabe 2–6 Handgriffe.
        - Ein Handgriff ist ein einzelner, sofort ausführbarer Schritt, beginnt mit einem Verb und nennt den Gegenstand, \
        z. B. „Leg die drei Tassen vom Schreibtisch in die Küche“. zielort: wohin damit, oder leerer Text.
        - Wegwerfen oder Weggeben nie bestimmen, nur „aussortieren und prüfen“ vorschlagen.
        - energie je Aufgabe: wenig, normal oder viel. minuten: ganze Zahl 1–60.
        - Alles auf Deutsch, freundlich, kurz, in Du-Form.
        """
    }

    private static let schemaHint = """
    {"zusammenfassung": string, "startpunkt": string, "lagerorte": [{"name": string, "art": "regal"|"schrank"|"kommode"|"kiste"|"ablage"|"sonstiges", "hinweis": string}], \
    "problemzonen": [string], "muster": [string], "aufgaben": [{"titel": string, "minuten": Zahl, "energie": "wenig"|"normal"|"viel", "handgriffe": [{"text": string, "zielort": string}]}]}
    """

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
                    "problemzonen": ["type": "array", "items": str()], "aufgaben": ["type": "array", "items": task],
                    "muster": ["type": "array", "items": ["type": "string", "enum": Clutter.allCases.map(\.rawValue)]]])
    }()

    private static var planFormat: ResponseFormat { ResponseFormat(name: "raumplan", schema: schema, hint: schemaHint) }

    private static let inventoryFormat: ResponseFormat = {
        func str() -> [String: Any] { ["type": "string"] }
        let item: [String: Any] = ["type": "object", "properties": ["name": str(), "anzahl": str(), "hinweis": str()],
                                   "required": ["name", "anzahl", "hinweis"], "additionalProperties": false]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["zusammenfassung": str(), "gegenstaende": ["type": "array", "items": item],
                           "aufraeumtipps": ["type": "array", "items": str()]],
            "required": ["zusammenfassung", "gegenstaende", "aufraeumtipps"], "additionalProperties": false
        ]
        return ResponseFormat(name: "bestandsaufnahme", schema: schema, hint: """
            {"zusammenfassung": string, "gegenstaende": [{"name": string, "anzahl": string, "hinweis": string}], "aufraeumtipps": [string]}
            """)
    }()
}

/// What the AI saw in one storage place.
struct AIInventory: Decodable {
    struct Item: Decodable { let name: String; let anzahl: String?; let hinweis: String? }
    let zusammenfassung: String
    let gegenstaende: [Item]
    let aufraeumtipps: [String]?

    /// Stored form; entries without a name are dropped and the list is capped.
    func record(placeID: UUID, photoIDs: [UUID]) -> PlaceInventory {
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

extension AIRoomPlan {
    /// Converts the answer into stored data: an analysis record and tasks in the
    /// model's order, trimmed to the time budget (at least one task survives).
    func records(roomID: UUID, photoIDs: [UUID], goal: Goal, minutes: Int) -> (RoomAnalysis, [HouseholdTask]) {
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
