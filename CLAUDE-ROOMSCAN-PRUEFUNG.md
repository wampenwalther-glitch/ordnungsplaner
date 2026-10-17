# Prüfung RoomScan.swift vor der Integration (Claude, read-only)

Stand: 17.10.2026. Geprüft: `ios/RoomScan.swift` (Stand 16:59, Codex-korrigiert), dazu `Sources/OrderCore/Models.swift` und `Repository.swift`, soweit sie Scans speichern. **Keine Datei außer dieser geändert** – Codex arbeitet gerade in `Sources/` und besitzt die Integration. Kein Swift-Compiler, kein Simulator, kein Gerät: Alles unten ist Quelltextprüfung plus Abgleich mit Apples Doku.

## 1. Blocker: Kompilierfehler beim Delegate (belegt)

`RoomCaptureViewDelegate` erbt laut Apple-Doku von **`NSCoding`** (`protocol RoomCaptureViewDelegate : NSCoding`, developer.apple.com/documentation/roomplan/roomcaptureviewdelegate). `RoomScan.swift:365` deklariert `final class Coordinator: NSObject, RoomCaptureViewDelegate`, implementiert aber weder `init?(coder:)` noch `encode(with:)`. `NSObject` bringt beides nicht mit → „does not conform to protocol 'NSCoding'“. Ergänzung im Coordinator:

```swift
init?(coder: NSCoder) { nil }          // nie aus einem Archiv erzeugt
func encode(with coder: NSCoder) {}    // nichts zu archivieren
```

## 2. Datenvertrag: Speicherfehler zurückmelden (Vorschlag)

Heute ist `onSave: (RoomScanResult) -> Void`, und `RoomScanSheet` schließt direkt danach (`RoomScan.swift:36-39`). Scheitert das Speichern, ist der Scan weg, ohne dass der Nutzer es merkt. `HouseholdRepository.addScan` ist bereits synchron und `throws` (`Repository.swift:104`) und läuft laut Kommentar auf dem Main Actor. Darum reicht ein synchrones `throws`, kein `async`:

```swift
struct RoomScanSheet: View {
    let roomName: String
    let onSave: (RoomScanResult) throws -> Void   // throw = nicht gespeichert
}
// RoomScanSheet:
onSave: { result in try onSave(result); dismiss() }   // schließt nur bei Erfolg
// RoomPlanScanContainer: let onSave: (RoomScanResult) throws -> Void
// + @State private var saveError: String?
onConfirm: {
    guard !hasConfirmed else { return }
    hasConfirmed = true
    do { try onSave(result) }
    catch { hasConfirmed = false; saveError = error.localizedDescription }
}
```

`ReviewSummaryView` zeigt `saveError` an; das Ergebnis bleibt in `.review(result)` erhalten, „Übernehmen“ kann erneut gedrückt werden. Host: `try repository.addScan(RoomScanRecord(roomID: room.id, walls: r.walls, …, encodedRoom: r.encodedRoom))`.

## 3. Abnahmekriterien

| Kriterium | Ergebnis | Beleg |
| --- | --- | --- |
| Ohne LiDAR keine `RoomCaptureView` | erfüllt | `RoomCaptureView` nur in `RoomPlanScanContainer`, der nur bei `isSupported && authorized` entsteht (`:32-41`) |
| Fotoablauf ohne LiDAR erreichbar | über „Schließen“, der Host muss dann den Fotoweg anbieten | `:72-100` |
| Kameraerlaubnis | erfüllt; kleiner Schönheitsfehler: bei `.notDetermined` steht kurz der „In Einstellungen erlauben“-Text hinter dem Systemdialog. Besser für `.notDetermined` eine neutrale Ladeanzeige | `:43-62` |
| Start erst nach View, kein zweiter Scan beim Neuzeichnen | erfüllt (`hasStarted`, leeres `updateUIView`, neue `id` nur bei Wiederholen) | `:317-321`, `:341-354` |
| `shouldPresent` schaltet die Verarbeitung nicht ab | erfüllt (gibt `true` zurück, `false` nur bei Fehler/Abbruch) | `:382-389` |
| Echte Geometrie gespeichert | erfüllt (`JSONEncoder().encode(CapturedRoom)`) | `:233-247` |
| Nur nach bewusster Übernahme; Doppeltap/Abbruch/späte Callbacks | erfüllt (`hasConfirmed`, `isCancelled`, `didFinish`, 60-s-Zeitlimit). **Lücke:** Ein Wisch nach unten schließt das Sheet auch mitten im Scan oder in der Prüfung und verwirft den Scan. Vorschlag: `.interactiveDismissDisabled()` am `RoomPlanScanContainer`, „Abbrechen“ ist ja vorhanden | `:163-166`, `:204`, `:402-408` |
| Kein Möbeltyp wird bestätigter leerer Lagerort | erfüllt in der Komponente: Sie gibt nur Zählwerte und Daten zurück, legt keine Lagerorte an. Der Host darf `objects` nicht in Lagerorte umwandeln | `:7-13` |

## 4. Hinweis zur Speicherung (Codex' Kern, nicht geändert)

`transaction` kodiert bei **jeder** Aktion den ganzen `HouseholdState` als formatiertes JSON und schreibt die Datei neu (`Repository.swift:58-72`). Darin stehen auch `RoomPhoto.jpegData` und `RoomScanRecord.encodedRoom` (Base64). Nach ein paar Fotos und Scans wird jede bestätigte Kleinigkeit so zu einem Schreibvorgang über mehrere MB auf dem Main Actor. Vor der Fotointegration besser: Bild- und Scan-Daten als eigene Dateien (z. B. `scans/<id>.json`), im State nur Dateiname + Zählwerte, zuerst die Datei schreiben, danach die State-Transaktion.

## 5. Nicht ausgeführt (bitte nicht als bestanden führen)

- Swift-Build (Xcode/`xcodebuild`) und damit Punkt 1 tatsächlich am Compiler
- Simulator: Ohne-LiDAR-Weg (`isSupported == false`) und Erlaubnisdialog
- LiDAR-Gerät: Scan starten/beenden, `didPresent`-Zeitpunkt, Wiederholen, Abbruch während der Verarbeitung, Wisch-Geste
- Kodieren/Dekodieren eines echten `CapturedRoom` sowie Dateigröße
- Info.plist mit `NSCameraUsageDescription` (fehlt noch, sonst stürzt `requestAccess` ab)
- Speicherfehlerpfad mit einem werfenden Test-`StateStorage`

## 6. Nächstes Teilstück

Einverstanden mit dem in `STATUS.md` genannten Teilstück (Raum → Lagerort → Aufgabe → Handgriff → bestätigt → Neustart → Fortsetzung). Codex baut es bereits in `Sources/`. Claude fängt dort nichts parallel an. Die RoomScan-Integration kommt danach, mit den Punkten 1 und 2.

## 7. Nachtrag: echter macOS-Lauf auf GitHub Actions (Claude, 17.10.2026)

Repository `wampenwalther-glitch/ordnungsplaner` (zurzeit **öffentlich**, Franz entscheidet, ob es privat wird).
- Lauf #1 auf `ccb07a3`: `swift test` bestanden, XcodeGen bestanden, Simulator-Build fehlgeschlagen (xcodebuild Exit 65): https://github.com/wampenwalther-glitch/ordnungsplaner/actions/runs/39045619547
- Codex korrigierte das in `d32f1c0` (stabiler Objective-C-Name für den RoomPlan-Delegate). Lauf darauf: grün.
- Lauf auf `c3bd239`: alle Schritte grün, d. h. Kerntests, Simulator-Build, App-Start im iPhone-Simulator, unsigniertes iPhone-Paket, Artefakt „Ordnungsplaner-iPhone-Vorschau“ (ca. 0,9 MB): https://github.com/wampenwalther-glitch/ordnungsplaner/actions/runs/39046383137
- Damit sind Punkt 1 (NSCoding) und das Kompilieren der Scan-Komponente **am echten Compiler bestätigt**. Weiterhin offen: Simulator-Screenshot inhaltlich ansehen, Gerätetest per Sideloadly, LiDAR-Scan auf geeigneter Hardware.
- Hinweis: `STATUS.md` sagt in Zeile 48 noch „kein swift test … kein xcodebuild“. Das ist überholt; Codex bitte aktualisieren.
- **Gerät (17.10.2026, abends):** Franz hat `Ordnungsplaner-unsigniert.ipa` aus Lauf 39046383137 per Sideloadly (kostenlose Apple-ID, 7 Tage gültig) auf sein iPhone installiert. Laut Franz **installiert und startet** die App. Die Abläufe aus README „Erster Ablauf auf dem Gerät“ (Schritte 1–9) sind noch **nicht** geprüft. Ein LiDAR-Scan ist auf dem iPhone 11 Pro nicht möglich, hier zählt der Weg ohne LiDAR.
