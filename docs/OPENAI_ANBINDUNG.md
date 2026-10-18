# OpenAI-Anbindung: ChatGPT-Abo statt API-Guthaben (Claude, 18.10.2026)

## Offizielle Prüfung (Quellen: developers.openai.com/siwc, help.openai.com/en/articles/20001542)

- „Sign in with ChatGPT“ erlaubt Apps, mit Einwilligung des Nutzers das **ChatGPT-Plus/Pro-Kontingent** zu verwenden (Scope `chatgpt.tokens.use.direct`), ohne API-Schlüssel und ohne API-Guthaben.
- Laut Preview-Dokumentation vorgesehen für „open-source projects, **personal projects that run locally**, and selected private apps“. Kommerzielle/gehostete Apps: Interessentenformular. Der Ordnungsplaner ist ein privates Projekt von Franz → fällt unter „persönlich“.
- Ablauf: OAuth Authorization Code + PKCE (S256), Authorize `https://auth.openai.com/api/accounts/authorize`, Token `.../oauth/token`, Revoke `.../oauth/revoke`, `resource=https://api.openai.com/v1`. Erstregistrierung mit `client_id=dynamic_agent_client` (+ `agent_name_hint`, `ext_agent_host_id`); OpenAI liefert im Callback die eigene `client_id` (wird gespeichert und danach wiederverwendet). Redirect nur `http://127.0.0.1:<Port>/auth/callback`.
- Zugriffstoken 3600 s, Refresh-Token 30 Tage, rotiert bei jedem Refresh.
- Anfragen: `POST https://api.openai.com/v1/responses` mit `Authorization: Bearer <Zugriffstoken>`, **`store:false` und `stream:true`**; keine `system`-Rolle, kein `temperature`/`max_output_tokens`. Modelle: `GET /v1/models` (Feld `models`, `visibility == "list"`, `slug`). Bild-Eingabe „wenn das Modell sie annimmt“.
- Fehlercodes: `subscription_sharing_usage_limit_exceeded` (429), `..._user_not_eligible` (403), `..._usage_unavailable` (503), `..._unsupported_capability` (400), 401 → erneuern/erneut anmelden.
- Nutzer begrenzt den Verbrauch pro App unter ChatGPT → Einstellungen → Nutzung; Abmelden in der App trennt nicht automatisch, deshalb wird widerrufen.

## Nicht dokumentiert (daher im Code abgesichert, am Gerät zu prüfen)

- Ob ein **iPhone-App-Client** über `dynamic_agent_client` registriert werden darf. Die Doku nennt nur Loopback-Clients (CLI/Desktop). Gelöst mit lokalem Empfänger auf 127.0.0.1 in der App + `ASWebAuthenticationSession`.
- Ob `text.format = json_schema` (strukturierte Ausgabe) über diese Route erlaubt ist → Rückfall: bei `subscription_sharing_unsupported_capability` ohne Schema, mit JSON-Vorgabe im Prompt.
- `ext_agent_host_id` muss `urn:uuid:<UUIDv4>` (oder JWK-Thumbprint-URI / did:key) sein – erster Gerätetest scheiterte an einem eigenen Format, behoben.
- Welches Modell die Fotos am besten auswertet → Auswahl aus `GET /v1/models`, Standard = erstes gelistetes, wählbar in Einstellungen → KI.

## Umsetzung

`ios/ChatGPTAuth.swift` (Anmeldung, Loopback-Empfänger, Keychain, Erneuern, Widerruf), `ios/AIService.swift` (Streaming-Aufruf, Rückfälle, getrennte Fehlertexte), `ios/SettingsView.swift` („Mit ChatGPT verbinden“, Trennen, Modellwahl). Der eigene API-Schlüssel bleibt als **ausgeklappter Rückfall** erhalten (kostet extra, wird nur ohne ChatGPT-Verbindung benutzt). Keine Zugangsdaten im Code oder in Git; Tokens nur im iOS-Schlüsselbund (`...ThisDeviceOnly`).

Fehlertexte unterscheiden: nicht verbunden, Anmeldung abgelaufen/widerrufen, Tarif nicht berechtigt, Nutzungslimit, Netzwerk/Zeitüberschreitung, OpenAI gestört, API-Guthaben leer, Anfrage-Limit, Modell nicht verfügbar.
