# Ordnungsplaner

SwiftUI-App für iPhone und iPad (ab iOS 17), die beim Aufräumen sagt, **was als Nächstes zu tun ist**: Räume fotografieren, Ziel/Zeit/Energie wählen, einen Plan mit einzelnen Handgriffen bekommen und abhaken. Läuft lokal auf dem Gerät, die KI-Auswertung geht über das ChatGPT-Abo des Nutzers. Foundation-Datenkern (`OrderCore`) und Oberfläche (`ios/`) sind getrennt; keine externen Swift-Pakete.

Aktueller belegter Stand, offene Punkte und Übergaben: [STATUS.md](STATUS.md). Die OpenAI-Anbindung ist in [docs/OPENAI_ANBINDUNG.md](docs/OPENAI_ANBINDUNG.md) beschrieben.

## Was die App kann

- **Aufräumen starten:** Räume (einzeln oder alle), Ziel (Dauerhafte Ordnung, Besuch, Umzug, Grundreinigung), Zeit und Energie wählen → Plan als Vorschau → „Los geht's“.
- **Fotos pro Raum** (Kamera oder Mediathek, empfohlen vier). Die KI erkennt Möbel/Behälter und Arten von Unordnung, die Auswertung läuft im Hintergrund und wird gespeichert.
- **Lagerorte und Kisten:** aus der Auswertung übernehmen oder selbst anlegen; pro Lagerort in den Inhalt fotografieren und eine **Bestandsaufnahme** machen (nur erfassen oder mit Aufräumtipps), Einträge korrigieren, selbst ergänzen. „Finden“ durchsucht Lagerorte und Gegenstände.
- **Runde mit Timer:** ein Handgriff nach dem anderen, Pause, +5 Minuten, Tempo-Hinweis, einstellbare Mitteilungen (Hälfte, 10/5/2/1 Minuten, Ende). Handgriffe lassen sich in der Aufgabe auch in beliebiger Reihenfolge abhaken.
- **Nie ohne Plan:** ist die KI nicht verbunden, das Kontingent leer oder das Netz weg, plant die App selbst aus ca. 60 eingebauten Routinen (Raumtyp × Ziel × Energie × Zeit) und aus Routinen, die die KI früher vorgeschlagen hat. Der Plan trägt den Hinweis „Ohne KI geplant“.
- **Vorher/Nachher:** „Seit dem letzten Mal“ vergleicht die beiden letzten KI-Auswertungen eines Raums. Ausgewertete Fotos lassen sich löschen (das Wissen bleibt), optional automatisch.
- **Einstellungen:** Hell/Dunkel, KI-Zugang („Mit ChatGPT verbinden“, eigener API-Schlüssel nur als Rückfall), Timer-Hinweise, wöchentliche Erinnerung, Speicher, Sicherung/Wiederherstellung.
- **Optional LiDAR-Raumscan** (RoomPlan) auf Geräten, die ihn können; auf allen anderen läuft alles über Fotos.

## Grundregeln

- Beobachtung der KI, geplanter Zielort und bestätigter Fundort sind getrennte Dinge. Die KI schreibt auf, was sie sieht; sie bestimmt nie Entsorgung, freien Platz oder Bestand.
- Fotos und Wohnungsdaten bleiben auf dem Gerät. Nur beim Auswerten gehen die gewählten Fotos an OpenAI (über das ChatGPT-Konto des Nutzers).
- Keine Schlüssel im Code. ChatGPT-Anmeldung und optionaler API-Schlüssel liegen im iOS-Schlüsselbund. Keine echten Fotos oder Nutzerdaten in Git oder Tests.

## Aufbau

| Ort | Inhalt |
| --- | --- |
| `Sources/OrderCore/` | Modelle, atomares Speichern (Hauptdatei + eine Datei je Foto), Planer (`LocalPlanner`), Regeln, Lernspeicher |
| `Tests/OrderCoreTests/` | XCTest für Kern, Speicherung, Planer, Inventar |
| `ios/` | SwiftUI-Oberfläche, KI-Anbindung (`AIService`, `ChatGPTAuth`), Timer-Mitteilungen, RoomPlan-Komponente |
| `project.yml` | XcodeGen-Projekt (Bundle-ID, Info.plist, Asset-Katalog mit Icon und Akzentfarbe) |
| `.github/workflows/ios.yml` | macOS-Build: Tests, Simulator-Build und -Start, unsignierte IPA als Artefakt |

Daten auf dem Gerät: `Application Support/Ordnungsplaner/household.json` (Schema-Version 1, nur Metadaten) und `photos/<id>.jpg` (ein Foto je Datei). Die Sicherung (Export) ist eine einzelne JSON-Datei mit eingebetteten Fotos. Ältere Dateien mit eingebetteten Fotos werden beim nächsten Speichern automatisch umgezogen. Bei beschädigter Datei oder unbekannter Version wird nichts überschrieben.

## Bauen und prüfen

Auf einem Mac (Xcode, XcodeGen):

```sh
brew install xcodegen
swift test
xcodegen generate
open Ordnungsplaner.xcodeproj
```

Ohne Mac: Push auf GitHub startet den Workflow `Local core and iOS build`. Er läuft `swift test`, baut für den Simulator, startet die App dort und liefert unter „Artifacts“ `Ordnungsplaner-iPhone-Vorschau` (Screenshot und `Ordnungsplaner-unsigniert.ipa`).

## Auf das iPhone

Die unsignierte IPA lässt sich mit Sideloadly (kostenlose Apple-ID, 7 Tage gültig) installieren. Für dauerhafte Installation ist ein Apple-Entwicklerkonto nötig (TestFlight). Es sind keine Zertifikate, Team-IDs oder Schlüssel im Repository.

## Nicht geprüft / offen

Echter LiDAR-Scan auf Hardware, sehr große Foto-Mengen, Bildqualität der KI bei kleinen Gegenständen, Signierung und TestFlight, iPad-Feinschliff, Erinnerungen über die wöchentliche hinaus, Gerätesynchronisation und Mehrnutzer-Betrieb. Die Entwicklungsgeschichte steht im STATUS.
