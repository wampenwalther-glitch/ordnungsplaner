# Entwicklungsstand

Stand: 17. Oktober 2026 · nativer Quellstand 0.1.0

## AKTUELL (Claude, 17.10.2026 abends): KI-Ablauf geliefert, Commit c115889 – CI grün (Lauf 39072829860: swift test inkl. 3 neuer Tests, Simulator-Build, Start, unsignierte IPA)

Auf Franz' Wunsch nach dem ersten Gerätetest umgebaut. **Auf dem Gerät noch nicht geprüft, echter KI-Aufruf noch nie ausgeführt** (kein Schlüssel hinterlegt, Antwortformat nur nach Doku).

- Reiter jetzt: Aufräumen · Wohnung · Aufgaben · Finden · Einstellungen. „Aufräumen starten“ (`ios/StartFlow.swift`): Räume wählen (auch alle), Ziel, Zeit, Energie als große Kacheln → KI-Plan als Vorschau → „Los geht's“ speichert Analyse + Aufgaben + Runde atomar (`applyPlan`). Handgriffe schreibt die KI, nicht der Nutzer; „Eigene Aufgabe“ bleibt als Nebenweg unter Aufgaben.
- Raum (`ios/RoomsViews.swift`): Fotos über automatischen Fotopunkt „Raumfotos“ (Kamera mit „Noch eins?“, Mediathek-Mehrfachauswahl, Löschen), „Was die KI sieht“ (Zusammenfassung, Startpunkt, Baustellen, erkannte Lagerorte → Übernahme nur per Tipp). LiDAR-Karte nur wenn `RoomCaptureSession.isSupported`. Feste Fotopunkte/Vergleich sind aus der Oberfläche entfernt (`PhotoPointView` bleibt im Code).
- KI (`ios/AIService.swift`): OpenAI Responses API, Bilder als data-URL (1024 px), strict JSON-Schema (deutsche Feldnamen), Standardmodell `gpt-5-mini` (in Einstellungen → KI änderbar; Modellname unbestätigt!). Schlüssel nur im Schlüsselbund, nie in JSON/Export/Bundle. Plan wird auf Zeitbudget gekürzt. KI legt nie Lagerorte, Inhalte oder Entsorgung fest.
- Einstellungen (`ios/SettingsView.swift`): Hell/Dunkel/System, KI-Schlüssel + Verbindungstest, Sicherung.
- Kern: `RoomAnalysis`, `ActionStep.hint`, `HouseholdTask.source`, `removeTask`, `adoptDetectedPlaces`; Schema-Version bleibt 1 (additiv, alte Dateien laden).
- Offen/Risiken: echter KI-Lauf, Modellname, Kostenhinweis geprüft?, Fotos werden bei „Plan erstellen“ an OpenAI gesendet (Hinweis steht in der Oberfläche), Mehrräume teilen das Zeitbudget gleichmäßig, keine 3D-Rekonstruktion aus Fotos (Plan nutzt Fotos direkt), Tests der Oberfläche fehlen.
- Codex darf wieder ändern. Bitte `Sources/`-Tests und Doku abgleichen; README/„Erster Ablauf“ ist überholt.

## STAND 18.10.2026 nachts (Claude): auf Franz' iPhone abgenommen – Aufräumen-Assistent, Raumfotos, ChatGPT-Anmeldung, Abhaken, Timer

Franz hat getestet: KI-Plan über ChatGPT-Abo läuft, Abhaken und Timer funktionieren („richtig gut“). Neu seit dem KI-Ablauf: Handgriffe in der Aufgabe antippen = abhaken, beliebige Reihenfolge (`setStepDone`); Rundenuhr mit Countdown, Pause, +5 Min., Tempo-Hinweis, einstellbare Mitteilungen (`ios/TimerAlerts.swift`, Einstellungen → Timer und Hinweise). Letzter grüner Stand: Commit d23d4c0, CI-Lauf 39082841806. Ton im gesperrten Zustand: Franz hat es geprüft, Fokus/Stumm-Einstellungen können es beeinflussen.

### Bitten an Codex (Claude liefert nichts davon doppelt)
1. README.md und die Abschnitte „Enthalten/Erster Ablauf“ auf den heutigen Stand bringen (alt: Fotopunkte, Heute/Mehr, manuelle Aufgaben).
2. Aufräumen: nicht mehr erreichbaren Code prüfen (`PhotoPointView`, `NewPhotoPointForm`, Foto-Vergleich) – entfernen oder wieder einbinden, Entscheidung mit Franz.
3. Tests: Kern ist abgedeckt (XCTest, Lauf grün). Fehlend: UI-/Snapshot-Tests, `AIRoomPlan.records` (Kürzung aufs Zeitbudget), SSE-Parser und Fehlertext-Zuordnung in `AIService` (aktuell nur über CI gebaut, nie gegen Beispiel-Antworten geprüft), Timer-Planung in `TimerAlerts`.
4. Datenschutz/Robustheit: Fotos liegen als Base64 in einer JSON (siehe README „Datenspeicherung“) – getrennte Bilddateien, bevor es groß wird; EXIF-Aufnahmedatum; Sicherung enthält Fotos.
5. iPad-Layout, Dynamic Type/VoiceOver-Durchgang, Dunkelmodus-Sichtprüfung.
6. Offene Produktidee von Franz (nicht begonnen): Erinnerungen/Routinen, Kisteninhalt, Umzug zwischen Wohnungen, Verbindung zum Einkaufsplaner. Vor dem Bauen mit Franz abstimmen.
Regeln unverändert: kleine Commits `[codex]`, CI grün vor Merge, keine echten Fotos/Schlüssel in Git. Claude arbeitet gerade nicht an Dateien – Codex darf frei ändern.

## UPDATE 18.10.2026 (Claude): „Mit ChatGPT verbinden“ statt API-Guthaben – CI grün (Lauf 39075372619), am Gerät NICHT geprüft

Franz' API-Schlüssel lief auf „Limit/Guthaben“. Nach offizieller Prüfung (Details, Quellen, offene Punkte: `docs/OPENAI_ANBINDUNG.md`) nutzt die KI jetzt per „Sign in with ChatGPT“ sein ChatGPT-Abo (Plus/Pro). Neu: `ios/ChatGPTAuth.swift`; umgebaut: `ios/AIService.swift`, `ios/SettingsView.swift`, `StartFlow.swift` (Hinweis). API-Schlüssel bleibt als ausgeklappter Rückfall. **Ungeprüft/Risiko:** Registrierung eines iPhone-Clients über `dynamic_agent_client` (Doku nennt nur Loopback-Clients), Loopback-Empfang im Auth-Fenster, `json_schema` über diese Route (Rückfall eingebaut), Modellliste/Bild-Eingabe.

## Ziel und Nutzerkorrekturen

Native iPhone-/iPad-App für foto- und ortsgestütztes Aufräumen. RoomPlan/LiDAR ist optional enthalten, nicht auf unbestimmte Zeit verschoben. Ohne LiDAR funktioniert die Raum-/Fotopunkt-Erfassung. iPhone 11 Pro ist das vorhandene Testgerät, keine Produktbegrenzung. Codex und Claude arbeiten gemeinsam, mit getrennten Aufgaben.

## Tatsächlich implementierter Quellstand

- Foundation-Paket `OrderCore`: Räume, verschachtelte Lagerorte/Kisten, eindeutige Kistenkennung, Aufgaben und geordnete Handgriffe, Sitzungen, Ereignisse, Fotos und Raumscan-Daten.
- Atomare versionierte JSON-Persistenz: erst validieren und schreiben, danach In-Memory-/UI-Zustand übernehmen. Fehler verändern den bestätigten Zustand nicht.
- Bestätigte Erledigung mit erwarteter Schritt-ID gegen Doppel-Taps, Pause/Resume, Fortsetzung nach erneutem Laden, letzte Erledigung rückgängig machen. Jede andere Datenänderung verwirft den alten Rücknahmestand.
- Lagerort-Zyklusprüfung bei jedem Schreiben, keine Raumwechsel durch ungültige Elternbeziehungen. Kistenverschiebung aktuell nur innerhalb desselben Raums.
- SwiftUI-Oberfläche: Heute, Wohnung, Aufgaben, Finden, Mehr. Auswahl bis zu drei bereits erfasster Aufgaben nach Ziel, Zeit und Energie; keine KI-Auswertung vorgetäuscht.
- Fotopunkte, normale Kamera und PhotosPicker-Import, Ausrichtungsnormalisierung und Verkleinerung, datierter Vergleich erstes/neuestes Foto. Datum ist die Erfassung in der App, kein rekonstruierter EXIF-Aufnahmezeitpunkt.
- Optionale RoomPlan-Komponente: Geräteprüfung, Kameraberechtigung, Stop/Ergebnis/Bestätigung, vollständige CapturedRoom-Kodierung und persistenter Scan-Datensatz. Kein Ableiten bestätigter leerer Lagerorte aus einem Scan.
- Save-Callback für Raumscan ist jetzt `throws`; Sheet schließt erst nach erfolgreichem Save. Speicherfehler werden im Scan-Dialog angezeigt.
- Nach zusätzlichem Claude-Review: NSCoding-Anforderungen des RoomCaptureViewDelegate ergänzt, aktiven Scan gegen versehentliches Wisch-Schließen geschützt. Bei Save-Fehler bleibt das Ergebnis zur erneuten Übernahme erhalten.
- JSON-Export/Restore mit Validierung und zusätzlicher Sicherung vor Ersatz. Bei beschädigtem Startzustand oder unbekannter Schema-Version wird nicht automatisch überschrieben.
- XcodeGen-Projektspezifikation mit iOS 17+, iPhone/iPad, Kameranutzungstext; macOS-Prüfskript und vorbereiteter GitHub-Actions-Workflow.

**Dies ist ein implementierter, aber noch nicht mit dem nativen Compiler gebauter Quellstand. Keine installierbare IPA und keine Geräteabnahme.**

## Dateien und Zuständigkeit

- Codex implementierte `Sources/OrderCore/`, `Tests/OrderCoreTests/`, `ios/AppModel.swift`, `ios/PlannerViews.swift`, `ios/Forms.swift`, `ios/PhotosAndData.swift`, `project.yml`, `.github/workflows/ios.yml`, `scripts/check-macos.sh` und README.
- Claude lieferte den ersten Entwurf `ios/RoomScan.swift` und `CLAUDE-REVIEW.md`; Codex korrigierte und integrierte ihn. Der Schreibauftrag ist abgeschlossen. Kein weiterer Claude-Lauf und kein aktueller paralleler Schreibauftrag.
- Vor nächsten Änderungen den Git-Stand prüfen und einen konkreten Bereich reservieren. Einkaufsplaner-Dateien gehören dem dortigen Chat.

## Nachgewiesene Zusammenarbeit

Claude Code Session `329bbda1-81ba-417a-a4af-2334a41e87d5`: 7 Turns, Exit 0, Ergebnis geliefert. Codex prüfte danach gegen offizielle Apple-Dokumentation und korrigierte Session-Start vor Existenz der View, Ergebnisverarbeitung (`shouldPresent`), vollständige CapturedRoom-Kodierung, View-Lebenszyklus bei Verarbeitung, Berechtigungen und Abbruch-/Callback-Schutz. Der historische Claude-Bericht ist ausdrücklich als überholt kommentiert.

Zusätzlicher kurzer read-only Konzeptreview aus dem koordinierten Einkaufsplaner-Chat: atomare Status-/Speicheroperation, Undo von Anfang an, Zyklusprüfung, Schema-Version sowie reale Fotoausrichtung beachten. Diese Hinweise flossen in den Kern ein; Aussagen aus dem Konzeptreview sind keine ausgeführten nativen Tests.

Franz' separat gestarteter Claude lieferte außerdem `CLAUDE-ROOMSCAN-PRUEFUNG.md` read-only. Codex hat insbesondere den NSCoding-Befund gegen Apples aktuelle Protokolldokumentation bestätigt und umgesetzt. Throwing-Save und Info.plist waren im laufenden Codex-Stand bereits umgesetzt; der Review bezog sich an diesen Stellen auf einen früheren Zwischenstand. Hinweis auf große JSON-/Bildarchive bleibt als dokumentierte Skalierungsgrenze offen. Keine fremden Codeänderungen überschrieben.

## Ausgeführte Prüfungen

- Alle neun Swift-Dateien einschließlich Package und XCTest-Datei mit tree-sitter-swift syntaktisch geparst: keine Syntaxfehler.
- `project.yml` und `.github/workflows/ios.yml` als YAML geparst: gültig.
- Quelltextreview für Speichern-vor-Publish, erwartete Schritt-ID, Undo, Referenz-/Zyklusprüfung und Fehlerpfade.
- Übergaben auf UTF-8, geschlossene Markdown-Codeblöcke und versehentlich eingebettete OpenAI-Schlüssel geprüft.

## Nicht ausgeführte Prüfungen / Grenzen

- Kein Swift-Compiler, keine Typprüfung, kein `swift test`, kein XcodeGen-Generierungslauf, kein xcodebuild, kein Simulator und kein Kameratest auf Hardware. Windows hat auch keine eingerichtete WSL-/Docker-Swift-Umgebung. Syntaxprüfung ersetzt diese Prüfungen nicht.
- Zwölf echte XCTest-Fälle sind angelegt, aber nicht ausgeführt: Neustart/Undo, Schreibfehler, Doppel-Tap, Pause/Resume, letzte Erledigung, Lagerort-Zyklus, Kistenkennung, Planfilter, Session-Konflikt, Datenversion/Korruption, Foto-/Scan-Restore sowie echter Dateisystem-Neustart.
- GitHub-Anbindung lieferte aktuell keine sichtbaren Repositories. Workflow ist nur vorbereitet. Nutzer wurde nach Ziel-Repository gefragt; noch kein Push und kein GitHub-Build.
- Kamera-/Scan-Interruptions, Berechtigungswechsel nach Rückkehr aus Einstellungen, EXIF-/Hoch-/Querformat und LiDAR-Ergebnisse auf echter Hardware noch prüfen.
- Bilder liegen für diesen kleinen Prototyp als Base64 in derselben JSON-Datei. Große Archive können die Oberfläche blockieren; spätere Skalierung braucht getrennte Bilddateien/serialisierte Speicherung.
- Kein KI-Backend oder API-Key, keine KI-Fotoanalyse, keine Live-Referenzüberlagerung, keine Routinen/Benachrichtigungen, kein Inhaltsinventar, kein Gerätesync, keine Veröffentlichung. Zielmodi filtern manuell erfasste Aufgaben; sie erzeugen noch keine anderen Handlungspläne.
- Komfortable Änderung/Löschung, Raumwechsel einer Kiste sowie Reparatur/Import direkt vom Startfehlerbildschirm fehlen noch.

## Start und tatsächlicher nächster Schritt

Auf einem geeigneten Mac mit Xcode und XcodeGen im Projektordner:

```sh
swift test --parallel
xcodegen generate
open Ordnungsplaner.xcodeproj
```

Oder komplette unsignierte Prüfung: `bash scripts/check-macos.sh`.

**Genau nächster Schritt:** Ziel-Repository erhalten, diesen Projektordner als Repository-Wurzel hochladen und den vorbereiteten macOS-Workflow ausführen; alternativ direkt auf dem vorhandenen Mac dieselben Befehle ausführen. Etwaige Compiler-/Typfehler zuerst beheben. Erst nach grünem Build den vertikalen Ablauf auf dem iPhone abnehmen: Raum/Lagerort/Kiste und drei Handgriffe anlegen → ersten bestätigen → Prozess beenden → exakt beim zweiten fortsetzen → Undo prüfen. Foto und LiDAR separat testen. Danach Live-Fotoüberlagerung/Routinen oder KI-Dienst in einem eigenen Abschnitt implementieren.

## Übergaben

`../CLAUDE-Ordnungsplaner.md` enthält vollständiges aktualisiertes Pflichtenheft, Status und Scan-Code; `../CLAUDE-Einkaufsplaner.md` bleibt die Übergabe des getrennten Projekts. Die Dokumente sind Momentaufnahmen; aktueller Code und dieser STATUS sind für die Fortsetzung maßgeblich. `README.md` enthält Funktionsgrenzen und Startanleitung. Keine echten Fotos oder Schlüssel als Testdaten übernehmen.
