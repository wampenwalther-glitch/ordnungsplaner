# Ordnungsplaner – erster nativer Prototyp

SwiftUI-App für iPhone/iPad ab iOS 17, mit unabhängigem Foundation-Datenkern. Keine externen Swift-Paketabhängigkeiten. Claude lieferte die optionale RoomPlan-Komponente; Codex prüfte und korrigierte sie und implementierte den lokalen Kern und die Oberfläche.

**Prüfstatus:** Die zwölf Foundation-XCTest-Fälle, XcodeGen und der unsignierte iOS-Simulator-Build sind auf GitHubs macOS-Runner bestanden. [Erfolgreicher Build des Quellstands d32f1c0](https://github.com/wampenwalther-glitch/ordnungsplaner/actions/runs/39046163359). Ein Simulator-Starttest mit Screenshot und die Erstellung einer unsignierten IPA sind im nächsten Workflow ergänzt. Echte Kamera-/LiDAR-Gerätetests und Signierung stehen weiterhin aus. Aktueller belegter Stand: STATUS.md.

## Enthalten

- Räume anlegen, Lagerorte verschachteln, Kisten mit eindeutiger Kennung führen.
- Standort einer Kiste innerhalb desselben Raums ausdrücklich bestätigen; Kreisverweise werden beim Schreiben verhindert.
- Aufgaben selbst eingeben, in Handgriffe zerlegen, Zeit, Energie, Modus und optionalen gemeinsamen Zielort festlegen.
- Bis zu drei vorhandene Aufgaben nach Ziel, Zeit und Energie auswählen; keine erfundene KI-Analyse.
- Ein Handgriff nach dem anderen; erwartete Schritt-ID schützt vor doppelter Bestätigung.
- Erledigung und Session-Zustand gemeinsam atomar in einer lokalen JSON-Datei speichern, danach erst den UI-Zustand aktualisieren.
- Pause/Resume und Neustart erhalten den nächsten Schritt. Letzte Erledigung kann auch nach Neustart zurückgenommen werden, solange keine andere Datenänderung den Rücknahmestand verworfen hat.
- Fotopunkte mit Standbeschreibung, Kameraaufnahme oder ausgewähltem Foto; Normalisierung der Bildausrichtung und Verkleinerung.
- Datierten Vergleich des ersten und neuesten Fotos am selben Punkt anzeigen.
- Optionale RoomPlan-/LiDAR-Erfassung mit Geräteprüfung. Scan-Ergebnis erst nach Bestätigung und erfolgreicher Speicherung übernehmen. Ohne LiDAR sind Fotos der primäre Weg.
- Vollständige JSON-Sicherung inklusive Bilder und Scans; Wiederherstellung mit Vorschau und zusätzlicher lokaler Vorab-Sicherung.
- Bei beschädigter Datei oder unbekannter Datenversion bleibt der vorhandene Stand unverändert. Keine automatische leere Neuinitialisierung.

## Noch offen

KI-Backend und Fotoanalyse, transparente Live-Kameraüberlagerung, genaue Wiedererkennung der Fotoposition, Routinen/Benachrichtigungen, Kisteninhalt/Gegenstandsinventar, freies Ändern/Löschen, Umzug zwischen Räumen oder Wohnungen, Synchronisation zwischen Geräten, Veröffentlichung und Mehrbenutzerfreigabe. Zeit-/Energiefilter verwenden derzeit manuell erfasste ganze Aufgaben, keinen KI-Plan. Zielmodus verändert daher die Auswahl vorhandener Aufgaben, nicht automatisch deren Handgriffe.

## Auf einem Mac starten

Voraussetzungen: ein zur macOS-Version passendes Xcode mit iOS-17-oder-neuer-SDK und XcodeGen. Der Homebrew-Befehl installiert nur den Projektgenerator:

```sh
brew install xcodegen
cd /Pfad/zum/Ordnungsplaner
swift test
xcodegen generate
open Ordnungsplaner.xcodeproj
```

In Xcode das Scheme `Ordnungsplaner` und einen iPhone-Simulator wählen und starten. Für ein echtes Gerät zusätzlich unter Signing ein eigenes Team und gegebenenfalls eine eigene Bundle-ID wählen. Es sind keine Zertifikate, Team-IDs oder Signierschlüssel hinterlegt.

Gesamtprüfung ohne Signierung:

```sh
bash scripts/check-macos.sh
```

GitHub Actions läuft unter `.github/workflows/ios.yml`. Nach erfolgreichem erweiterten Workflow stehen unter Artifacts ein Simulator-Screenshot und `Ordnungsplaner-unsigniert.ipa` bereit. Die IPA ist **nicht signiert** und kann nicht durch einfaches Antippen installiert werden. Sie benötigt vor der Geräteinstallation einen eingerichteten Signierungsweg, beispielsweise ein geeignetes Sideload-Werkzeug oder Xcode. Zertifikate, Apple-Zugang und Geräteeinrichtung sind nicht Teil dieses Repositorys.

## Erster Ablauf auf dem Gerät

1. Unter Wohnung einen Raum anlegen.
2. Darin „Regal“ und darunter eine Kiste, etwa A07 „Kabel“, anlegen.
3. Unter Aufgaben eine Aufgabe mit drei Handgriffen anlegen, je Zeile ein Handgriff.
4. Aufgabe starten und unter Heute den ersten Handgriff bestätigen.
5. App vollständig beenden und erneut öffnen: der zweite Handgriff muss als Nächstes erscheinen.
6. Letzte Erledigung rückgängig machen und erneut bestätigen. Pause wählen, wieder starten und fortsetzen.
7. Im Raum einen Fotopunkt anlegen und zwei Aufnahmen hinzufügen; den datierten Vergleich prüfen.
8. Auf einem Gerät mit LiDAR zusätzlich Scan öffnen, abbrechen, neu scannen und ausdrücklich übernehmen. Auf dem iPhone 11 Pro muss der Fotoablauf erhalten bleiben.
9. Sicherung exportieren und anschließend eine Wiederherstellung prüfen. Nur selbst erzeugte Testdaten benutzen.

## Datenspeicherung und Grenzen

Speicherort im iOS-App-Container: `Application Support/Ordnungsplaner/household.json`. Die Datei enthält Schema-Version 1, Entitäten, Bilder als Base64, Session, Erledigungsereignisse und den letzten Rücknahmestand. Schreiben erfolgt synchron und atomar, damit keine UI-Erledigung vor ihrem Speichervorgang veröffentlicht wird. Große Bildarchive können die UI blockieren; die spätere Skalierung braucht getrennte Bilddateien und eine serialisierte Persistenzschicht. Für diesen ersten Stand werden Bilder auf maximal 1600 Pixel lange Kante und 2 MB pro Foto begrenzt. Angezeigte Fotodaten sind das Datum der Erfassung in dieser App; das ursprüngliche EXIF-Aufnahmedatum importierter Bilder wird noch nicht übernommen.

Vor Wiederherstellung entsteht unter `backups/` eine lokale Kopie. JSON-Exporte enthalten private Wohnungsdaten. Es gibt keine automatische Cloud-Synchronisation und keine Foto-Uploads. Kameraerlaubnis steht in der durch XcodeGen erzeugten Info.plist. LiDAR ist keine Pflicht-Hardwareanforderung.

Fehler beim Laden werden sichtbar angezeigt; es gibt absichtlich keinen automatischen Reset-Knopf. Für eine beschädigte Datei ist noch keine komfortable Reparatur-/Importoberfläche im Startfehlerbildschirm implementiert. Originaldatei sichern, bevor eine manuelle Wiederherstellung erfolgt.

## Kerntests

`Tests/OrderCoreTests/RepositoryTests.swift` deckt unter anderem Neustart, Pause/Resume, Undo nach Neustart, fehlgeschlagene Schreibvorgänge, Doppel-Tap, letzte Erledigung, Lagerort-Zyklen, doppelte Kistenkennungen, Auswahl nach Budget/Energie/Modus, ungültige Datenversionen und Foto-/Scan-Export ab. Alle zwölf XCTest-Fälle wurden im oben verlinkten macOS-Workflow erfolgreich ausgeführt. Reale Kamera-/LiDAR-Prüfungen werden dadurch nicht ersetzt.

## Zusammenarbeit

Vor Änderungen AGENTS.md und STATUS.md lesen. Keine zweite RoomPlan-Implementierung und keine parallelen Änderungen an denselben Dateien. Raumscan-Geometrie und bestätigte freie Lagerplätze bleiben getrennte Daten. Keine echten Fotos oder Nutzerdaten in Git/Testfixtures.
