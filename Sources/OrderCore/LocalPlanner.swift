import Foundation

/// One built-in routine. `steps` are written "Handgriff → Zielort"; the part
/// after the arrow is only a hint, never a confirmed storage place.
public struct CleanRule: Equatable {
    public let id: String
    public let title: String
    public let kinds: [RoomKind]      // empty = fits every room
    public let tag: Clutter?          // the clutter this routine deals with
    public let goals: [Goal]          // empty = fits every goal
    public let minutes: Int
    public let energy: Energy         // energy needed at least
    public let visible: Bool          // quick, visible win (visitors)
    public let deep: Bool             // thorough work (cleaning, moving)
    public let steps: [String]
}

/// Offline planner: no network, no AI. It turns the kind of room, the goal,
/// time and energy – plus whatever is known about the room's clutter – into a
/// small plan from built-in and learned routines. It never looks at photos.
public enum LocalPlanner {
    public static func normalize(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Reads kinds of clutter out of free text, e.g. "Teller auf dem Schreibtisch".
    public static func inferTags(from texts: [String]) -> Set<Clutter> {
        let joined = texts.joined(separator: " ").lowercased()
        return Set(Clutter.allCases.filter { clutter in clutter.keywords.contains { joined.contains($0) } })
    }

    public struct Outcome {
        public let analysis: RoomAnalysis
        public let tasks: [HouseholdTask]
    }

    /// - Parameters:
    ///   - observed: clutter the user ticked by hand
    ///   - previous: the last AI analysis of this room, if any (its tags and texts are reused)
    public static func plan(roomID: UUID, roomName: String, goal: Goal, minutes: Int, energy: Energy,
                            observed: Set<Clutter>, learned: [LearnedRoutine], previous: RoomAnalysis?,
                            now: Date = Date()) -> Outcome {
        let kind = RoomKind.infer(roomName)
        var tags = observed
        if let previous {
            tags.formUnion((previous.tags ?? []).compactMap(Clutter.init(rawValue:)))
            tags.formUnion(inferTags(from: previous.problemZones + [previous.summary]))
        }

        struct Candidate { let title: String; let minutes: Int; let energy: Energy; let steps: [String]; let score: Int }
        var candidates: [Candidate] = []
        for rule in rules {
            guard rule.kinds.isEmpty || rule.kinds.contains(kind),
                  rule.goals.isEmpty || rule.goals.contains(goal),
                  rule.energy.rawValue <= energy.rawValue else { continue }
            var score = 10
            if let tag = rule.tag, tags.contains(tag) { score += 60 }
            if !rule.kinds.isEmpty { score += 8 }
            switch goal {
            case .visitors: if rule.visible { score += 20 }; if rule.minutes <= 6 { score += 5 }
            case .cleaning: if rule.deep { score += 20 }
            case .moving: if rule.goals.contains(.moving) { score += 20 }
            case .order: if rule.tag == nil { score += 5 }
            }
            candidates.append(Candidate(title: rule.title, minutes: rule.minutes, energy: rule.energy, steps: rule.steps, score: score))
        }
        let known = Set(rules.map { normalize($0.title) })
        for routine in learned where routine.kind == kind && routine.goal == goal
            && routine.energy.rawValue <= energy.rawValue && !known.contains(normalize(routine.title)) {
            candidates.append(Candidate(title: routine.title, minutes: routine.minutes, energy: routine.energy,
                                        steps: routine.steps.map { step in step.hint.map { "\(step.text) → \($0)" } ?? step.text },
                                        score: 30 + min(routine.seen, 5) * 4))   // AI-proven for this kind of room: ahead of generic routines
        }
        candidates.sort { ($0.score, -$0.minutes, $1.title) > ($1.score, -$1.minutes, $0.title) }

        var remaining = max(minutes, 1)
        var chosen: [Candidate] = []
        for candidate in candidates where chosen.count < 6 && candidate.minutes <= remaining {
            chosen.append(candidate)
            remaining -= candidate.minutes
        }
        if chosen.isEmpty, let shortest = candidates.min(by: { $0.minutes < $1.minutes }) { chosen = [shortest] }

        let tasks = chosen.map { candidate -> HouseholdTask in
            let steps = candidate.steps.map { line -> ActionStep in
                let parts = line.components(separatedBy: " → ")
                return ActionStep(text: parts[0], hint: parts.count > 1 ? parts[1] : nil)
            }
            return HouseholdTask(roomID: roomID, title: candidate.title, goal: goal, energy: candidate.energy,
                                 estimatedMinutes: candidate.minutes, steps: steps, createdAt: now, source: .local)
        }

        var summary = "Plan aus eingebauten Routinen für „\(roomName)“ – deine Fotos wurden dabei nicht ausgewertet."
        if let previous {
            summary += " Berücksichtigt, was die KI am \(previous.createdAt.formatted(date: .abbreviated, time: .omitted)) gesehen hat."
        }
        let ordered = Clutter.allCases.filter { tags.contains($0) }
        let analysis = RoomAnalysis(roomID: roomID, createdAt: now, goal: goal, photoIDs: [], summary: summary,
                                    startHint: tasks.first.map { "Fang mit „\($0.title)“ an." } ?? "",
                                    detectedPlaces: [], problemZones: ordered.map(\.label), tags: ordered.map(\.rawValue))
        return Outcome(analysis: analysis, tasks: tasks)
    }

    // MARK: Built-in routines

    private static func r(_ id: String, _ title: String, _ kinds: [RoomKind] = [], tag: Clutter? = nil, goals: [Goal] = [],
                          min: Int, energy: Energy = .low, visible: Bool = false, deep: Bool = false,
                          _ steps: [String]) -> CleanRule {
        CleanRule(id: id, title: title, kinds: kinds, tag: tag, goals: goals, minutes: min, energy: energy,
                  visible: visible, deep: deep, steps: steps)
    }

    public static let rules: [CleanRule] = [
        // Küche
        r("k-dishes", "Geschirr einsammeln", tag: .dishes, min: 5, visible: true, [
            "Sammle alle Teller, Tassen und Gläser ein → Spüle", "Kratz grobe Reste in den Müll",
            "Stell das Geschirr in die Spülmaschine oder spül es kurz ab", "Wisch die frei gewordene Fläche ab"]),
        r("k-dishwasher", "Spülmaschine ausräumen", [.kitchen], tag: .dishes, min: 8, [
            "Nimm das saubere Geschirr heraus", "Stell Besteck in die Schublade → Besteckschublade",
            "Räum Teller und Tassen an ihren Platz → Küchenschrank", "Lass die Maschine offen, damit sie wieder frei ist"]),
        r("k-counter", "Arbeitsplatte freiräumen", [.kitchen], tag: .surfaces, min: 8, visible: true, [
            "Nimm alles von der Arbeitsplatte, was dort nicht hingehört", "Sortiere es: Küche, andere Räume, Müll",
            "Bring die Dinge an ihren Platz oder in einen Korb", "Wisch die Platte feucht ab"]),
        r("k-fridge", "Kühlschrank durchsehen", [.kitchen], tag: .fridge, goals: [.order, .cleaning, .moving], min: 15, energy: .normal, deep: true, [
            "Nimm abgelaufene Lebensmittel heraus → Müll", "Stell Ähnliches zusammen (Milchprodukte, Reste, Getränke)",
            "Wisch die frei gewordenen Fächer aus", "Stell alles geordnet zurück"]),
        r("k-trash", "Küchenmüll rausbringen", [.kitchen], tag: .trash, min: 4, visible: true, [
            "Binde den Müllbeutel zu", "Bring ihn zur Mülltonne → Mülltonne", "Zieh einen neuen Beutel auf"]),
        r("k-sink", "Spüle sauber machen", [.kitchen], tag: .dishes, goals: [.visitors, .cleaning], min: 6, visible: true, deep: true, [
            "Räum die Spüle komplett leer", "Spül sie mit Spülmittel aus", "Trockne den Wasserhahn ab, dann glänzt er"]),
        r("k-cupboard", "Einen Küchenschrank sortieren", [.kitchen], goals: [.order, .moving], min: 15, energy: .normal, deep: true, [
            "Such dir einen Schrank aus und nimm alles heraus", "Sortiere aus: Doppeltes, Kaputtes, Nie Benutztes → Prüfstapel",
            "Wisch den Schrank innen aus", "Räum Gleiches zusammen zurück, das Häufigste nach vorn"]),
        r("k-stove", "Herd und Backofen abwischen", [.kitchen], goals: [.cleaning, .visitors], min: 12, energy: .normal, deep: true, [
            "Nimm Roste und Abdeckungen ab", "Weiche die Herdplatten mit Reiniger ein", "Wisch alles ab, dann die Roste",
            "Setz alles wieder zusammen"]),
        r("k-floor", "Küchenboden fegen", [.kitchen], tag: .floor, min: 6, visible: true, [
            "Schieb Stühle und Mülleimer kurz zur Seite", "Fege den Boden", "Wisch bei Flecken feucht nach"]),
        // Wohnzimmer
        r("l-sofa", "Sofa aufräumen", [.living], tag: .surfaces, min: 5, visible: true, [
            "Leg Kissen und Decken ordentlich hin", "Sammle Fremdes vom Sofa ein (Tassen, Kleidung, Fernbedienung)",
            "Saug oder klopf Krümel von den Polstern"]),
        r("l-table", "Couchtisch freiräumen", [.living], tag: .surfaces, min: 5, visible: true, [
            "Nimm Geschirr und Müll vom Tisch → Küche", "Leg Fernbedienung und Zeitschriften ordentlich hin", "Wisch den Tisch ab"]),
        r("l-toys", "Spielzeug einsammeln", [.living, .kids], tag: .toys, min: 8, [
            "Sammle das Spielzeug in einen großen Korb", "Sortiere grob: Bausteine, Figuren, Bücher → Spielzeugkisten",
            "Stell den Korb an seinen festen Platz"]),
        r("l-books", "Bücher und Zeitschriften einsortieren", [.living, .bedroom, .office, .kids], tag: .books, min: 8, [
            "Sammle alle herumliegenden Bücher und Zeitschriften", "Lege Zeitschriften auf einen Stapel, alte in den Papiermüll",
            "Stell die Bücher zurück → Bücherregal"]),
        r("l-plants", "Pflanzen gießen und abwischen", [.living, .office], goals: [.visitors, .cleaning], min: 6, visible: true, [
            "Gieße die Pflanzen, die es brauchen", "Entferne trockene Blätter", "Wisch die Untersetzer ab"]),
        // Schlafzimmer
        r("b-bed", "Bett machen", [.bedroom, .kids], tag: .bed, goals: [.visitors, .order, .cleaning], min: 3, visible: true, [
            "Zieh das Laken glatt", "Schüttel Decke und Kissen auf", "Leg alles ordentlich hin"]),
        r("b-clothes", "Kleidung vom Stuhl und Boden holen", [.bedroom, .kids, .living], tag: .clothes, min: 7, visible: true, [
            "Teile die Kleidung in zwei Haufen: sauber und getragen", "Häng Saubere auf oder leg sie zusammen → Kleiderschrank",
            "Wirf Getragene in den Wäschekorb → Wäschekorb"]),
        r("b-nightstand", "Nachttisch freiräumen", [.bedroom], tag: .surfaces, min: 5, [
            "Nimm Gläser und Geschirr mit → Küche", "Sortiere Bücher und Kabel", "Wisch die Fläche ab"]),
        r("b-wardrobe", "Kleiderschrank aussortieren", [.bedroom], goals: [.moving, .order], min: 25, energy: .high, deep: true, [
            "Nimm alles aus einem Fach", "Sortiere in: behalten, abgeben, prüfen → Abgabe-Tasche",
            "Leg oder häng das Behaltene zurück", "Stell die Abgabe-Tasche an die Tür"]),
        r("b-bedding", "Bettwäsche wechseln", [.bedroom], goals: [.cleaning, .visitors], min: 12, energy: .normal, deep: true, [
            "Zieh das Bett ab → Wäschekorb", "Beziehe Matratzenschoner und Laken frisch", "Beziehe Decke und Kissen neu",
            "Starte die Maschine mit der benutzten Bettwäsche"]),
        // Wäsche (überall)
        r("w-laundry", "Wäsche waschen starten", tag: .laundry, min: 10, energy: .normal, [
            "Trag die Wäsche zur Waschmaschine → Waschmaschine", "Trenne Helles und Dunkles", "Starte eine Maschine",
            "Stell dir einen Wecker für das Aufhängen"]),
        r("w-fold", "Saubere Wäsche zusammenlegen", [.bedroom, .living, .kids, .other], tag: .laundry, min: 12, energy: .normal, [
            "Nimm den Wäschestapel auf Bett oder Tisch", "Leg zusammen, Gleiches auf Gleiches",
            "Bring jeden Stapel an seinen Platz → Kleiderschrank"]),
        // Bad
        r("ba-sink", "Waschbecken freiräumen", [.bathroom], tag: .cosmetics, min: 6, visible: true, [
            "Stell Zahnbürsten, Seife und Creme in eine Reihe", "Bring Unnötiges in den Schrank → Badschrank",
            "Wisch Becken und Armatur ab"]),
        r("ba-towels", "Handtücher wechseln", [.bathroom], tag: .towels, min: 4, visible: true, [
            "Nimm benutzte Handtücher ab → Wäschekorb", "Häng frische auf"]),
        r("ba-mirror", "Spiegel und Armatur polieren", [.bathroom], goals: [.visitors, .cleaning], min: 5, visible: true, [
            "Sprüh Glasreiniger auf den Spiegel", "Wisch ihn trocken", "Poliere die Armatur mit einem Tuch"]),
        r("ba-toilet", "WC reinigen", [.bathroom], goals: [.visitors, .cleaning], min: 8, energy: .normal, visible: true, [
            "Gib Reiniger unter den Rand", "Bürste das Becken", "Wisch Brille und Deckel ab", "Spül nach"]),
        r("ba-shower", "Dusche reinigen", [.bathroom], goals: [.cleaning], min: 15, energy: .normal, deep: true, [
            "Sprüh Reiniger an Wände und Armaturen", "Lass ihn kurz einwirken", "Schrubb Fugen und Ablauf",
            "Spül alles ab und zieh die Scheibe ab"]),
        r("ba-cabinet", "Badschrank ausmisten", [.bathroom], goals: [.order, .moving], min: 12, energy: .normal, deep: true, [
            "Nimm alles aus einem Fach", "Wirf Abgelaufenes und Leeres weg → Müll", "Sortiere nach Gesicht, Körper, Medizin",
            "Räum es geordnet zurück"]),
        r("ba-floor", "Badboden wischen", [.bathroom], tag: .floor, min: 6, [
            "Heb Teppiche und Körbe hoch", "Wisch den Boden feucht auf", "Leg alles zurück, wenn es trocken ist"]),
        r("ba-trash", "Badmüll leeren", [.bathroom], tag: .trash, min: 3, visible: true, [
            "Leere den Mülleimer → Mülltonne", "Wisch den Eimer kurz aus"]),
        // Flur
        r("h-shoes", "Schuhe ordnen", [.hallway, .living], tag: .shoes, min: 6, visible: true, [
            "Stell Schuhe paarweise ins Regal → Schuhregal", "Bring Schuhe aus anderen Räumen hierher",
            "Stell Saisonschuhe nach hinten oder in eine Kiste"]),
        r("h-coats", "Jacken und Taschen aufhängen", [.hallway], tag: .shoes, min: 5, visible: true, [
            "Häng Jacken an die Haken → Garderobe", "Stell Taschen an einen festen Platz",
            "Nimm alles mit, was nicht in den Flur gehört"]),
        r("h-keys", "Platz für Schlüssel und Post", [.hallway], tag: .papers, goals: [.order], min: 5, [
            "Such eine Schale oder einen Haken → Eingangsbereich", "Leg Schlüssel und Post immer dorthin",
            "Wirf alte Werbung aus dem Flur weg"]),
        r("h-floor", "Flur saugen und wischen", [.hallway], tag: .floor, min: 8, visible: true, [
            "Schieb Schuhe und Matte zur Seite", "Saug den Flur", "Wisch grobe Flecken weg"]),
        // Arbeitszimmer
        r("o-desk", "Schreibtisch freiräumen", [.office], tag: .surfaces, min: 10, energy: .normal, visible: true, [
            "Nimm alles vom Schreibtisch und leg es auf den Boden oder ein Tablett", "Wisch die Fläche ab",
            "Stell nur zurück, was du täglich brauchst", "Sortiere den Rest weg → Regal oder Schublade"]),
        r("o-drawer", "Eine Schublade ausmisten", [.office], goals: [.order, .moving], min: 12, energy: .normal, deep: true, [
            "Kipp die Schublade auf den Tisch aus", "Sortiere: behalten, wegwerfen, woanders hin",
            "Räum das Behaltene in Fächern zurück"]),
        r("o-papers", "Ablage leeren", [.office], tag: .papers, min: 15, energy: .normal, [
            "Nimm den Papierstapel und schau jedes Blatt einmal an", "Wirf Altes weg → Papiermüll",
            "Lege Wichtiges ab → Ordner", "Leg Offenes in einen Korb 'Erledigen'"]),
        r("o-screen", "Bildschirm und Tastatur reinigen", [.office], goals: [.cleaning, .visitors], min: 5, [
            "Schalte alles aus", "Wisch den Bildschirm mit einem trockenen Tuch ab", "Klopf Krümel aus der Tastatur"]),
        // Kinderzimmer
        r("ki-toys", "Spielzeug in Kisten sortieren", [.kids], tag: .toys, min: 10, energy: .normal, [
            "Sammle alles auf einen Haufen", "Sortiere in Kisten: Bauen, Figuren, Bücher", "Stell die Kisten an ihren Platz",
            "Leg Kaputtes in einen Prüfkorb"]),
        r("ki-outgrown", "Zu kleine Kleidung aussortieren", [.kids], goals: [.order, .moving], min: 15, energy: .normal, deep: true, [
            "Nimm ein Fach Kleidung heraus", "Leg Zu-Kleines in eine Tasche → Abgabe", "Räum Passendes zurück"]),
        // Keller / Abstellraum
        r("s-box", "Eine Kiste sortieren", [.storage], goals: [.order, .moving], min: 20, energy: .high, deep: true, [
            "Hol eine Kiste heraus und leere sie auf den Boden", "Sortiere: behalten, abgeben, Müll",
            "Beschrifte die Kiste mit dem Inhalt", "Stell sie zurück oder pack sie für den Umzug"]),
        r("s-label", "Kisten beschriften", [.storage], goals: [.moving, .order], min: 10, [
            "Nimm einen dicken Stift und Klebeband", "Schreib Inhalt und Raum auf jede Kiste, an die Seite",
            "Stell die Beschriftung nach vorn"]),
        r("s-floor", "Platz am Boden schaffen", [.storage], tag: .floor, min: 10, energy: .normal, [
            "Stell lose Dinge an die Wand", "Stapel Kisten nach Größe", "Lass einen Weg zur Tür frei"]),
        r("s-bulky", "Sperriges aussortieren", [.storage], goals: [.moving, .order], min: 20, energy: .high, deep: true, [
            "Such Dinge, die du seit einem Jahr nicht gebraucht hast", "Mach drei Haufen: behalten, abgeben, Sperrmüll",
            "Notiere, was abgeholt werden muss"]),
        // Umzug (überall)
        r("mv-donate", "Abgabe-Kiste starten", goals: [.moving, .order], min: 10, [
            "Stell einen Karton bereit und schreib 'Abgeben' darauf", "Wirf alles hinein, was du ein Jahr nicht gebraucht hast",
            "Stell den Karton an die Tür"]),
        r("mv-box", "Einen Bereich einpacken", goals: [.moving], min: 20, energy: .high, deep: true, [
            "Wähle ein Regal oder einen Schrank", "Pack Gleiches zusammen in einen Karton", "Polstere Zerbrechliches mit Tüchern",
            "Beschrifte den Karton mit Raum und Inhalt"]),
        r("mv-first", "Erste-Nacht-Kiste packen", goals: [.moving], min: 15, energy: .normal, [
            "Stell einen Karton bereit: 'Erste Nacht'", "Leg Zahnbürste, Ladegeräte, Bettzeug und Wasserkocher hinein",
            "Stell ihn gut sichtbar an die Tür"]),
        r("mv-docs", "Wichtige Unterlagen zusammenlegen", tag: .papers, goals: [.moving], min: 15, energy: .normal, [
            "Sammle Pässe, Verträge und Rechnungen", "Leg sie in eine feste Mappe → Dokumentenmappe",
            "Nimm die Mappe beim Umzug selbst mit"]),
        // Besuch (überall)
        r("vi-surfaces", "Sichtbare Flächen freiräumen", tag: .surfaces, goals: [.visitors], min: 10, energy: .normal, visible: true, [
            "Geh durch den Raum und nimm alles von Tischen und Ablagen", "Bring es an seinen Platz oder in einen Korb",
            "Wisch die Flächen kurz ab"]),
        r("vi-basket", "Alles Herumliegende in einen Korb", goals: [.visitors], min: 5, visible: true, [
            "Nimm einen Korb oder eine Kiste", "Wirf alles hinein, was herumliegt", "Stell ihn in einen anderen Raum, sortiere später"]),
        r("vi-air", "Lüften und Frische schaffen", goals: [.visitors], min: 3, visible: true, [
            "Reiß die Fenster fünf Minuten auf", "Leere den Mülleimer → Mülltonne", "Stell Blumen oder eine Kerze hin"]),
        r("vi-trash", "Müll einsammeln", tag: .trash, goals: [.visitors, .order], min: 5, visible: true, [
            "Nimm einen Müllbeutel", "Sammle Verpackungen, Papier und Leergut ein", "Bring ihn nach draußen → Mülltonne"]),
        // Putzen (überall)
        r("cl-windows", "Fenster putzen", goals: [.cleaning], min: 20, energy: .high, deep: true, [
            "Wisch den Rahmen und die Fensterbank ab", "Sprüh Glasreiniger auf die Scheibe",
            "Zieh die Scheibe von oben nach unten ab", "Poliere Schlieren mit einem Tuch"]),
        r("cl-dust", "Staub wischen von oben nach unten", tag: .dust, goals: [.cleaning, .visitors, .order], min: 12, energy: .normal, deep: true, [
            "Nimm kleine Dinge von den Flächen", "Wisch von oben nach unten: Regale, Tische, Fensterbank",
            "Stell zurück, was du behalten willst"]),
        r("cl-floor", "Boden saugen und wischen", tag: .floor, goals: [.cleaning, .visitors], min: 15, energy: .normal, visible: true, deep: true, [
            "Heb lose Dinge vom Boden auf", "Saug erst den Rand, dann die Mitte", "Wisch den Boden feucht nach"]),
        r("cl-doors", "Türen und Griffe abwischen", goals: [.cleaning], min: 8, deep: true, [
            "Wisch Türklinken und Lichtschalter ab", "Wisch die Türblätter ab, wo Fingerabdrücke sind"]),
        r("cl-curtains", "Vorhänge waschen", [.living, .bedroom, .kids], goals: [.cleaning], min: 15, energy: .normal, deep: true, [
            "Nimm die Vorhänge ab", "Lies das Pflegeetikett", "Wasch sie und häng sie feucht wieder auf"]),
        // Ordnung (überall)
        r("or-hotspot", "Eine Brennpunkt-Stelle ordnen", goals: [.order], min: 10, energy: .normal, [
            "Such die Stelle, an der sich am meisten ansammelt", "Räum sie komplett leer und wisch sie ab",
            "Gib jedem Ding einen festen Platz", "Stell einen kleinen Korb für 'kommt später weg' dazu"]),
        r("or-five", "Fünf Dinge zurückbringen", goals: [.order, .visitors], min: 5, [
            "Such fünf Dinge, die im falschen Raum liegen", "Bring jedes an seinen Platz → richtiger Raum"]),
        r("or-floor", "Boden freiräumen", tag: .floor, goals: [.order, .visitors], min: 8, visible: true, [
            "Heb alles vom Boden auf", "Sortiere in: weg, woanders hin, hierher", "Bring alles an seinen Platz"]),
        r("or-pets", "Haustierzeug ordnen", tag: .pets, min: 6, [
            "Sammle Näpfe, Spielzeug und Decken ein", "Wisch den Futterplatz ab", "Stell alles an seinen Platz → Tierecke"]),
        r("or-cables", "Kabel und Ladegeräte bündeln", tag: .cables, min: 10, energy: .normal, [
            "Sammle alle Ladegeräte und Kabel", "Sortiere: funktioniert, unbekannt, kaputt",
            "Wickle jedes Kabel auf und binde es mit einem Band", "Leg sie in eine beschriftete Kiste → Kabelkiste"]),
        r("or-bottles", "Flaschen und Pfand sammeln", tag: .bottles, min: 6, [
            "Sammle leere Flaschen und Dosen ein", "Stell sie in eine Kiste oder Tasche → Pfandkiste",
            "Stell die Kiste an die Tür, damit du sie mitnimmst"]),
        r("or-papers", "Post und Papiere sortieren", tag: .papers, min: 10, energy: .normal, [
            "Sammle alle losen Papiere und Briefe", "Wirf Werbung und Verpackungen weg → Papiermüll",
            "Sortiere den Rest: erledigen, ablegen, wichtig", "Leg 'Erledigen' sichtbar an einen festen Platz → Ablagekorb"]),
        r("or-drawer", "Eine Schublade sortieren", goals: [.order, .moving], min: 12, energy: .normal, [
            "Such dir eine Schublade aus und kipp sie aus", "Sortiere: behalten, anderswo hin, weg",
            "Räum das Behaltene in Fächern zurück"]),
        r("or-timer", "Zehn Minuten Ordnung", goals: [.order], min: 10, [
            "Stell einen Timer auf zehn Minuten", "Räum, was dir als Erstes ins Auge fällt", "Hör auf, wenn der Timer klingelt"])
    ]
}
