# Claude Review: RoomPlan-Integration (`ios/RoomScan.swift`)

## Nachträgliche Integrationsprüfung durch Codex

**Der folgende ursprüngliche Claude-Bericht ist historisch und beschreibt nicht mehr vollständig den aktuellen Code.** Codex hat nach Lieferung gegen die offizielle Apple-Dokumentation geprüft und den Entwurf korrigiert:

- Session-Start erfolgt jetzt in `makeUIView` nach Zuordnung der CaptureView; im ursprünglichen Coordinator-Init existierte die View noch nicht.
- `shouldPresent` liefert im Erfolgsfall `true`. Apple dokumentiert, dass `false` die Verarbeitung auslässt und dann kein `didPresent`-Ergebnis über diesen Pfad bereitsteht. Die Annahme in Punkt 4 des ursprünglichen Berichts war falsch.
- CapturedRoom ist Encodable und Decodable. `encodedRoom` enthält jetzt die vollständige Kodierung, nicht nur die Zusammenfassung. Punkt 8 war falsch.
- Die CaptureView bleibt während der Verarbeitung bestehen. Erst das fertige Ergebnis ersetzt die Ansicht. Alte/cancelled Callbacks werden unterdrückt, Wiederholung erhält eine neue View-Identität.
- Explizite Kameraberechtigung, Doppel-Save-Schutz und eine Verarbeitungstimeout-Anzeige ergänzt. Das unnötige Observable-Makro wurde entfernt.

Quellen: [shouldPresent](https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate/captureview(shouldpresent:error:)), [didPresent](https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate/captureview(didpresent:error:)), [CapturedRoom](https://developer.apple.com/documentation/roomplan/capturedroom).

**Aktualisierung nach Implementierung des lokalen Kerns:** Codex hat den Scan inzwischen in AppModel/RoomDetailView integriert. Der Save-Callback ist jetzt throwing und übernimmt einen RoomScanRecord über die atomare lokale Persistenz; erst nach erfolgreichem Speichern wird das Sheet geschlossen. Die XcodeGen-Konfiguration enthält NSCameraUsageDescription.

**Weiterhin nicht ausgeführt:** Swift-/Xcode-Build, echte Kamera- und LiDAR-Gerätetests. Ein Return aus den Einstellungen erfordert gegebenenfalls Schließen und erneutes Öffnen des Scan-Sheets; Scene-/Session-Interruptions müssen im Host getestet werden. Der folgende ursprüngliche Bericht bleibt historisch, nicht der aktuelle Funktionsstand.

---

## Ursprünglicher Claude-Bericht vor diesen Korrekturen

Stand: 17. Oktober 2026. Erstellt unter Windows ohne Xcode/Swift-Toolchain.
**Es wurde kein Build und kein Test ausgeführt.** Diese Datei beschreibt
Design-Entscheidungen, offene Risiken und die Geräte-/Xcode-Prüfungen, die vor
dem Merge auf einem Mac nötig sind.

## Zweck und Umfang

`RoomScanSheet` ist eine eigenständige, optionale Komponente:
- Auf Geräten ohne LiDAR (`RoomCaptureSession.isSupported == false`, z. B.
  iPhone 11 Pro) wird **keine** `RoomCaptureView` instanziiert, sondern ein
  reiner Hinweistext mit Verweis auf den Foto-Ablauf der Host-App angezeigt.
- Auf unterstützten Geräten läuft ein Scan → Stop → Verarbeitung → Review →
  „Übernehmen“/„Erneut scannen“-Zyklus. Die Host-App bekommt das Ergebnis
  ausschließlich über `onSave`, nachdem der Nutzer bewusst „Übernehmen“
  gedrückt hat.

## Wichtige Design-Entscheidungen

1. **`RoomCaptureSession.isSupported` wird einmal pro Sheet-Lebenszeit
   geprüft** (`let isRoomPlanSupported = ...` als Property, nicht neu
   berechnet bei jedem Render). Das verhindert, dass ein Zustandwechsel
   während der Sheet-Anzeige die UI unerwartet umschaltet.

2. **`updateUIView` ist bewusst leer.** Der Session-Start passiert exakt
   einmal in `Coordinator.init` → `startSessionIfNeeded()`, abgesichert durch
   `controller.hasStarted`. SwiftUI-Re-Renders (z. B. durch `@Observable`-
   Änderungen am `RoomCaptureController`) lösen dadurch nie einen erneuten
   `run(configuration:)`-Aufruf aus.

3. **Stop wird explizit vom Nutzer ausgelöst** über den Button „Scan
   beenden“, der `controller.stop()` → `captureView?.captureSession.stop()`
   aufruft. Das entspricht Apples Pattern: Stop führt zur Delegate-Methode
   `captureView(shouldPresent:error:)`.

4. **`captureView(shouldPresent:error:)` gibt `false` zurück**, um die
   eingebaute RoomPlan-Ergebnisansicht zu unterdrücken, da die Komponente
   eine eigene Review-UI (`ReviewSummaryView`) bereitstellt.
   **Unsicherheit / Risiko (siehe unten):** Ob RoomCaptureView bei `false`
   trotzdem intern verarbeitet und danach `captureView(didPresent:error:)`
   mit dem fertigen `CapturedRoom` aufruft, konnte hier nicht anhand
   aktueller Apple-Dokumentation verifiziert werden (kein Netzzugriff/Xcode-
   Doku verfügbar). Die Implementierung geht von diesem Verhalten aus, weil
   es dem bekannten Zweck der beiden Delegate-Methoden entspricht (eine
   steuert nur die *Darstellung*, die andere liefert das *Ergebnis*). Falls
   sich das als falsch herausstellt, muss `shouldPresent` ggf. `true`
   liefern und die eigene Review-UI stattdessen *nach* `didPresent`
   zusätzlich zur System-UI oder als Ersatz dafür mit anderem Timing
   gezeigt werden.

5. **Keine doppelten Saves/Callbacks:**
   - `Coordinator.didFinish` verhindert, dass `onFinish` mehr als einmal pro
     Scan-Durchlauf aufgerufen wird, falls das Delegate mehrfach triggert.
   - `hasConfirmed` (State in `RoomPlanScanContainer`) verhindert, dass ein
     schnelles Doppel-Tippen auf „Übernehmen“ `onSave` zweimal auslöst, noch
     bevor das Sheet durch `dismiss()` geschlossen ist.
   - „Erneut scannen“ erzeugt einen frischen `RoomCaptureController()` und
     damit einen neuen `Coordinator`/neue Session; alte Delegate-Instanzen
     können so keine veralteten Ergebnisse mehr nachliefern.

6. **Keine verlorenen Ergebnisse nach dem Stoppen:** Nach `stop()` zeigt die
   UI sofort „Scan wird verarbeitet…“ (`phase = .processing`), bis
   `onFinish` (via Delegate) eintrifft und `phase` auf `.review(...)` oder
   `.failed(...)` wechselt. Es gibt keinen Zustand, in dem das Ergebnis
   verworfen würde, ohne dass der Nutzer „Abbrechen“ gewählt hat.

7. **Abbrechen** (`Button("Abbrechen")`) ruft `controller.stop()` und direkt
   `onCancel()` (→ `dismiss()`) auf, ohne `onSave` aufzurufen. Es wird nichts
   übernommen.

8. **Kodierung:** `CapturedRoom` selbst ist nicht `Codable`. Es wird eine
   eigene, kleine `CapturedRoomSummary`-Struktur (Codable) aus den Zählwerten
   und Objektkategorien gebaut und per `JSONEncoder` zu `Data` kodiert; das
   ist die `encodedRoom` in `RoomScanResult`. Das ist bewusst **keine**
   vollständige Re-Serialisierung der RoomPlan-Geometrie (USD/USDZ-Export
   wäre der native Weg, aber außerhalb des hier geforderten Vertrags).
   **Risiko:** Falls die Host-App erwartet, dass `encodedRoom` die *gesamte*
   Geometrie für eine spätere 3D-Darstellung enthält, reicht dieses Format
   nicht aus. Laut Aufgabenstellung wird hier nur ein JSON-kodierbares
   Ergebnis mit den vier Zählwerten verlangt; falls mehr nötig ist, muss der
   Datenvertrag mit Codex abgestimmt und ggf. `CapturedRoom.export(to:)`
   (USDZ-Datei statt reinem JSON) genutzt werden.

9. **Fehlerbehandlung:** Encoding-Fehler und RoomPlan-Fehler (aus
   `didPresent(... error:)`) führen zu `phase = .failed(message)` mit
   „Erneut versuchen“-Button, keinem Absturz und keinem impliziten Save.

10. **Keine Netzkommunikation:** Die Datei importiert nur `SwiftUI`,
    `RoomPlan`, `UIKit`; es gibt keine URLSession/Network-Aufrufe.

## Offene, nicht getestete Risiken (vor Merge auf macOS prüfen)

- **API-Verhalten von `shouldPresent`/`didPresent`** wie unter Punkt 4
  beschrieben – die größte funktionale Unsicherheit. Muss an echten RoomPlan-
  Ergebnissen in Xcode verifiziert werden (Breakpoint/Log in beiden
  Delegate-Methoden, prüfen ob `didPresent` nach `shouldPresent -> false`
  überhaupt aufgerufen wird).
- **`RoomCaptureSession.Configuration()`** wird ohne weitere Parameter
  verwendet. Es wurde nicht geprüft, ob in iOS 17/18 zusätzliche
  Pflicht-Parameter oder sinnvolle Defaults (z. B. für
  `isCoachingEnabled`-ähnliche Optionen, falls existent) ergänzt werden
  sollten.
- **`@Observable`-Makro** auf `RoomCaptureController` kombiniert mit
  `weak var captureView: RoomCaptureView?` – nicht in Xcode kompiliert,
  daher nicht geprüft, ob `@Observable` mit `weak`-Properties und
  `UIKit`-Referenztypen hier Probleme macht (z. B. Observation-Tracking auf
  einer Property, die nie direkt in einer SwiftUI-`body` gelesen wird –
  sollte unkritisch sein, aber unverifiziert).
- **Speicherverwaltung der Session:** `dismantleUIView` ruft
  `uiView.captureSession.stop()` auf, um laufende Sessions beim Entfernen
  des UIViewRepresentable sauber zu beenden (z. B. bei App-Hintergrund,
  Sheet-Dismiss durch Schließen-Geste). Nicht getestet: Verhalten bei
  Interruption durch eingehenden Anruf oder Multitasking.
- **Thread/Actor-Kontext der Delegate-Callbacks:** Es wurde angenommen, dass
  `RoomCaptureViewDelegate`-Methoden auf dem Main Thread aufgerufen werden
  (üblich für UIKit-Delegates), ungetestet verifiziert. Falls nicht, müssten
  die `phase`-Zuweisungen in `buildResult`/`onFinish` explizit auf
  `MainActor` verschoben werden.
- **`CapturedRoom.Object.Category` → `String(describing:)`:** liefert z. B.
  `"storage"` oder ggf. Swift-Enum-Debug-Strings mit Assoziierten Werten
  (z. B. bei Kategorien mit Parametern). Nicht geprüft, ob das für alle
  Kategorien ein sauberer, erwartbarer String ist.
- **iPhone 11 Pro Fallback-Pfad:** Nur anhand der Dokumentationslogik
  (`isSupported == false` auf Geräten ohne LiDAR) implementiert, nicht auf
  echter Hardware verifiziert.
- **Lokalisierung:** Alle Texte sind hart auf Deutsch kodiert, passend zum
  Rest der App laut `STATUS.md`; falls die Host-App Lokalisierung über
  `String(localized:)`/`.strings`-Dateien erwartet, müsste das noch
  angepasst werden.

## Nötige Gerätetests (auf macOS/Xcode, vor Release)

1. iPhone/iPad **mit LiDAR** (z. B. iPhone 12 Pro oder neuer, iPad Pro):
   - Scan starten, durch den Raum bewegen, „Scan beenden“ drücken.
   - Prüfen: Wird `didPresent` mit plausiblem `CapturedRoom` aufgerufen,
     ohne dass RoomPlans eigene Ergebnis-UI aufblitzt?
   - Review-Zahlen (Wände/Türen/Fenster/Objekte) mit tatsächlichem Raum
     vergleichen.
   - „Erneut scannen“ mehrfach durchlaufen, prüfen auf Speicherlecks/Crashes
     bei wiederholtem Session-Neustart.
   - „Abbrechen“ während laufendem Scan und während „Verarbeitung“-Phase.
   - Schnelles Doppeltippen auf „Übernehmen“ beobachten (Instrumente/Logs),
     ob `onSave` nur einmal aufgerufen wird.
2. **iPhone 11 Pro (ohne LiDAR)**, wie in der Aufgabe gefordert:
   - Sheet öffnen, prüfen dass sofort der Fallback-Text erscheint und keine
     Kamera-/RoomCaptureView-Initialisierung versucht wird (keine Abstürze,
     keine Permission-Prompts für die 3D-Erfassung).
3. **Interruptions:** Eingehender Anruf/Backgrounding während eines
   laufenden Scans; App-Wechsel während „Verarbeitung“-Phase.
4. **Speicherverhalten:** Mehrere Scan-Durchläufe hintereinander (Retry-Loop)
   auf Memory-Wachstum/Leaks prüfen (Xcode Memory Graph/Instruments).
5. **Integration mit Host-App:** Verifizieren, dass `encodedRoom` korrekt in
   der von Codex gebauten Persistenzschicht ankommt und decodierbar ist
   (Format mit Codex abstimmen, siehe Punkt 8 oben).

## Nicht angefasste Bereiche

Es wurden ausschließlich `ios/RoomScan.swift` und diese Datei erstellt/
geändert. Keine anderen Projektdateien, keine Git-Operationen, kein Zugriff
auf Dateien außerhalb des erlaubten Bereichs.
