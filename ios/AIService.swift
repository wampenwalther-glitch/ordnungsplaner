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
        return try AIRoomPlan.parse(try await run(text: text, images: images, format: planFormat))
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
        return try AIInventory.parse(try await run(text: text, images: images, format: inventoryFormat))
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
            catch let failure as AIStreamFailure {
                if failure.code == "subscription_sharing_unsupported_capability", structured, attempts < 3 { structured = false; continue }
                throw OrderError.invalid(message(status: failure.code == nil ? 500 : statusFor(code: failure.code!),
                                                 code: failure.code, param: nil, detail: failure.detail, chatGPT: true))
            }
        }
    }

    /// Reads the SSE stream to `response.completed`; anything else counts as failure.
    private static func readStream(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var reader = AIStreamReader()
        for try await line in bytes.lines { try reader.consume(line) }
        return try reader.finish()
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

    private static func statusFor(code: String) -> Int { AIResponseText.status(for: code) }

    static func networkMessage(_ error: URLError) -> String { AIResponseText.network(error) }

    private static func message(status: Int, code: String?, param: String?, detail: String?, chatGPT: Bool) -> String {
        AIResponseText.message(status: status, code: code, param: param, detail: detail, chatGPT: chatGPT)
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
