import XCTest
@testable import OrderCore

final class AIParsingTests: XCTestCase {
    private func planJSON(tasks: String, muster: String = "[\"dishes\", \"unbekannt\", \"floor\"]") -> String {
        """
        {"zusammenfassung": "Viel Geschirr", "startpunkt": "Bei der Spüle", "lagerorte": [{"name": "Regal", "art": "regal", "hinweis": "links"}],
         "problemzonen": ["Teller auf dem Tisch"], "muster": \(muster), "aufgaben": [\(tasks)]}
        """
    }
    private func task(_ title: String, minutes: Int, energy: String = "normal", steps: [String]) -> String {
        let list = steps.map { "{\"text\": \"\($0)\", \"zielort\": \"Küche\"}" }.joined(separator: ",")
        return "{\"titel\": \"\(title)\", \"minuten\": \(minutes), \"energie\": \"\(energy)\", \"handgriffe\": [\(list)]}"
    }

    func testPlanParsesAndToleratesCodeFences() throws {
        let json = planJSON(tasks: task("Geschirr", minutes: 5, steps: ["Teller sammeln"]))
        let plain = try AIRoomPlan.parse(json)
        let fenced = try AIRoomPlan.parse("Hier ist dein Plan:\n```json\n\(json)\n```")
        XCTAssertEqual(plain.zusammenfassung, fenced.zusammenfassung)
        XCTAssertThrowsError(try AIRoomPlan.parse("kein JSON")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unerwartetes Format"))
        }
        XCTAssertThrowsError(try AIRoomPlan.parse("{\"zusammenfassung\": 5}"))
    }

    func testRecordsTrimToBudgetKeepOneTaskAndFilterTags() throws {
        let tasks = [task("A", minutes: 10, energy: "wenig", steps: ["a1", "a2"]),
                     task("B", minutes: 10, energy: "viel", steps: ["b1"]),
                     task("C", minutes: 10, steps: ["c1"])].joined(separator: ",")
        let plan = try AIRoomPlan.parse(planJSON(tasks: tasks))
        let room = UUID()
        let (analysis, list) = plan.records(roomID: room, photoIDs: [], goal: .order, minutes: 15)
        XCTAssertEqual(list.map(\.title), ["A"])                       // 10 used, next one (10) no longer fits 5
        XCTAssertEqual(list[0].energy, .low)
        XCTAssertEqual(list[0].source, .ai)
        XCTAssertEqual(list[0].steps.map(\.text), ["a1", "a2"])
        XCTAssertEqual(list[0].steps[0].hint, "Küche")
        XCTAssertEqual(analysis.tags, ["dishes", "floor"])             // unknown pattern dropped
        XCTAssertEqual(analysis.detectedPlaces.first?.name, "Regal")
        XCTAssertEqual(analysis.startHint, "Bei der Spüle")

        let big = try AIRoomPlan.parse(planJSON(tasks: task("Riesig", minutes: 99, steps: ["x"])))
        let (_, kept) = big.records(roomID: room, photoIDs: [], goal: .order, minutes: 5)
        XCTAssertEqual(kept.count, 1)                                  // at least one task survives
        XCTAssertEqual(kept[0].estimatedMinutes, 60)                   // minutes are capped
        let wide = plan.records(roomID: room, photoIDs: [], goal: .order, minutes: 60).1
        XCTAssertEqual(wide.map(\.energy), [.low, .high, .normal])
    }

    func testRecordsSkipEmptyTasksAndStepsAndMissingPatterns() throws {
        let tasks = [task("", minutes: 5, steps: ["x"]), task("Leer", minutes: 5, steps: []),
                     task("Gut", minutes: 5, steps: ["   ", "echter Schritt"])].joined(separator: ",")
        let plan = try AIRoomPlan.parse(planJSON(tasks: tasks, muster: "null"))
        let (analysis, list) = plan.records(roomID: UUID(), photoIDs: [], goal: .visitors, minutes: 30)
        XCTAssertEqual(list.map(\.title), ["Gut"])
        XCTAssertEqual(list[0].steps.map(\.text), ["echter Schritt"])
        XCTAssertEqual(analysis.tags, [])
    }

    func testInventoryRecordCleansAndCaps() throws {
        let items = (1...70).map { "{\"name\": \"Ding \($0)\", \"anzahl\": \"\($0 % 2 == 0 ? "etwa 3" : "")\", \"hinweis\": \"  \"}" }
        let json = "{\"zusammenfassung\": \" Kabelkiste \", \"gegenstaende\": [{\"name\": \"  \", \"anzahl\": \"\", \"hinweis\": \"\"}, \(items.joined(separator: ","))], \"aufraeumtipps\": [\"Kabel aufwickeln\", \" \"]}"
        let place = UUID()
        let record = try AIInventory.parse(json).record(placeID: place, photoIDs: [])
        XCTAssertEqual(record.summary, "Kabelkiste")
        XCTAssertEqual(record.items.count, 60)                         // nameless dropped, rest capped
        XCTAssertEqual(record.items[0].name, "Ding 1")
        XCTAssertNil(record.items[0].count)
        XCTAssertEqual(record.items[1].count, "etwa 3")
        XCTAssertNil(record.items[1].note)
        XCTAssertTrue(record.items.allSatisfy { $0.source == "ai" })
        XCTAssertEqual(record.tidyHints, ["Kabel aufwickeln"])
        let noTips = try AIInventory.parse("{\"zusammenfassung\": \"s\", \"gegenstaende\": []}").record(placeID: place, photoIDs: [])
        XCTAssertTrue(noTips.tidyHints.isEmpty)
    }

    func testStreamReaderCollectsTextOnlyWhenCompleted() throws {
        var reader = AIStreamReader()
        for line in ["event: response.output_text.delta", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\\\"a\\\":\"}",
                     "", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"1}\"}", ": keepalive",
                     "data: {\"type\":\"response.completed\"}", "data: [DONE]"] {
            try reader.consume(line)
        }
        XCTAssertEqual(try reader.finish(), "{\"a\":1}")

        var done = AIStreamReader()
        try done.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"teil\"}")
        try done.consume("data: {\"type\":\"response.output_text.done\",\"text\":\"ganz\"}")
        try done.consume("data: {\"type\":\"response.completed\"}")
        XCTAssertEqual(try done.finish(), "ganz")                     // the final text wins

        var cut = AIStreamReader()
        try cut.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"halb\"}")
        XCTAssertThrowsError(try cut.finish()) { XCTAssertTrue($0.localizedDescription.contains("unterbrochen")) }
    }

    func testStreamReaderReportsFailuresWithCode() {
        var reader = AIStreamReader()
        XCTAssertThrowsError(try reader.consume(
            "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"limit\"}}}")) { error in
            let failure = error as? AIStreamFailure
            XCTAssertEqual(failure?.code, "subscription_sharing_usage_limit_exceeded")
            XCTAssertEqual(failure?.detail, "limit")
        }
        var plainError = AIStreamReader()
        XCTAssertThrowsError(try plainError.consume("data: {\"type\":\"error\",\"error\":{\"code\":\"x\"}}"))
        var garbage = AIStreamReader()
        XCTAssertNoThrow(try garbage.consume("data: nicht json"))
    }

    func testErrorTextsAreDistinctPlainGermanAndNeverRawCodes() {
        let cases: [(Int, String?, Bool, String)] = [
            (429, "subscription_sharing_usage_limit_exceeded", true, "Nutzungslimit"),
            (403, "subscription_sharing_user_not_eligible", true, "Plus oder Pro"),
            (503, "subscription_sharing_usage_unavailable", true, "in ein paar Minuten"),
            (401, "subscription_sharing_invalid_user", true, "neu verbinden"),
            (402, "insufficient_quota", false, "Guthaben"),
            (429, "rate_limit_exceeded", false, "Minute warten"),
            (401, nil, true, "abgelaufen"),
            (401, nil, false, "API-Schlüssel"),
            (403, nil, true, "Tarif-Nutzung"),
            (404, nil, true, "Modell"),
            (429, nil, true, "ChatGPT-Nutzungslimit"),
            (502, nil, true, "gestört"),
        ]
        var seen = Set<String>()
        for (status, code, chatGPT, fragment) in cases {
            let text = AIResponseText.message(status: status, code: code, param: nil, detail: nil, chatGPT: chatGPT)
            XCTAssertTrue(text.contains(fragment), "\(status) \(code ?? "-"): \(text)")
            XCTAssertFalse(text.contains("subscription_sharing"), text)
            seen.insert(text)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 11)
        XCTAssertTrue(AIResponseText.message(status: 400, code: "subscription_sharing_unsupported_capability", param: "text.format",
                                             detail: nil, chatGPT: true).contains("text.format"))
        XCTAssertTrue(AIResponseText.message(status: 418, code: nil, param: nil, detail: "Teekanne", chatGPT: true).contains("Teekanne"))
        XCTAssertEqual(AIResponseText.status(for: "subscription_sharing_usage_limit_exceeded"), 429)
        XCTAssertEqual(AIResponseText.status(for: "subscription_sharing_invalid_user"), 401)
        XCTAssertEqual(AIResponseText.status(for: "anderes"), 500)
    }

    func testNetworkTexts() {
        XCTAssertTrue(AIResponseText.network(URLError(.notConnectedToInternet)).contains("Internetverbindung"))
        XCTAssertTrue(AIResponseText.network(URLError(.timedOut)).contains("zu lange"))
        XCTAssertTrue(AIResponseText.network(URLError(.cannotFindHost)).contains("nicht erreichbar"))
        XCTAssertTrue(AIResponseText.network(URLError(.badURL)).contains("Netzwerkproblem"))
    }
}
