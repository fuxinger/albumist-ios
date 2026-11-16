# Albumist auf dem eigenen iPhone: TestFlight einrichten

Mit TestFlight läuft Albumist als echte App auf dem iPhone, mit der echten Mediathek und ohne
Zeitlimit. Jede neue Version kommt danach von selbst: GitHub baut sie, signiert sie und lädt sie
zu TestFlight hoch (`.github/workflows/testflight.yml`). Alles hier geht vom Windows-PC im
Browser oder vom iPhone aus; ein Mac ist nicht nötig.

## 1. Apple Developer Program beitreten (einmalig, 99 € im Jahr)

- Am einfachsten auf dem iPhone mit der App **Apple Developer** (App Store): Konto > Jetzt
  registrieren. Alternativ im Browser: https://developer.apple.com/programs/enroll/
- Als **Einzelperson** anmelden. Dann steht dein Name im App Store als Anbieter. Für einen
  Firmennamen braucht Apple eine D-U-N-S-Nummer, das dauert länger.
- Apple prüft deinen Ausweis. Die Freischaltung dauert meist ein bis zwei Tage.

## 2. Bundle-ID und App anlegen

1. https://developer.apple.com/account/resources/identifiers/list öffnen, **+** > App IDs > App.
   - Beschreibung: `Albumist`
   - Bundle ID: **Explicit**, `app.albumist.ios`
   - Keine besonderen Funktionen ankreuzen. Speichern.
2. https://appstoreconnect.apple.com > Apps > **+** > Neue App.
   - Plattform iOS, Name `Albumist`, Primärsprache Deutsch,
     Bundle-ID `app.albumist.ios`, SKU `albumist-ios`, Zugriff: Vollzugriff.

## 3. Schlüssel für GitHub erzeugen

1. App Store Connect > Benutzer und Zugriff > **Integrationen** > App Store Connect API >
   Team-Schlüssel > **+**.
2. Name `GitHub`, Zugriff **Admin** (nur damit kann GitHub das Verteilungszertifikat in der
   Cloud verwenden).
3. **Schlüssel laden** (`AuthKey_XXXXXXXXXX.p8`). Das geht nur ein einziges Mal; Datei gut
   aufheben.
4. Notieren: **Schlüssel-ID** (in der Tabelle) und **Issuer-ID** (über der Tabelle).
5. Team-ID: https://developer.apple.com/account > Mitgliedschaft > **Team-ID** (10 Zeichen).

## 4. Vier Secrets in GitHub eintragen

https://github.com/fuxinger/sortly-ios/settings/secrets/actions > **New repository secret**:

| Name | Inhalt |
|---|---|
| `ASC_KEY_ID` | Schlüssel-ID |
| `ASC_ISSUER_ID` | Issuer-ID |
| `ASC_KEY_P8` | Inhalt der .p8-Datei (mit Editor öffnen, alles kopieren, auch die Zeilen BEGIN und END) |
| `APPLE_TEAM_ID` | Team-ID |

Danach baut GitHub bei jeder neuen Version automatisch einen TestFlight-Build.

## 5. Auf dem iPhone installieren

1. App Store Connect > Albumist > **TestFlight** > Interne Tests > Gruppe anlegen (zum Beispiel
   „Ich“) und dich selbst hinzufügen.
2. App **TestFlight** aus dem App Store laden und mit derselben Apple-ID anmelden.
3. Albumist erscheint dort, sobald Apple den ersten Build verarbeitet hat (meist 5 bis
   30 Minuten nach dem Hochladen).

Käufe in TestFlight kosten nichts (Testumgebung von Apple). Damit „Freischalten“ funktioniert,
braucht es in App Store Connect einen In-App-Kauf vom Typ „Nicht verbrauchbar“ mit der
Produkt-ID `app.albumist.ios.unlock`.

## Abstürze und Feedback abholen

Was Tester in TestFlight schicken (Feedback mit Screenshot und Kommentar, Absturzberichte mit
Absturzprotokoll), fragt GitHub jeden Morgen um 06:00 UTC von selbst ab
(`.github/workflows/asc-feedback.yml`, Skript `.github/scripts/asc_feedback.py`). Von Hand:
Actions > **TestFlight feedback** > Run workflow.

- **counts** (täglich und Standard): die Zusammenfassung des Laufs zeigt nur, wie viele
  Feedbacks und Abstürze jeder Build hat, und das Datum des neuesten. Kommentare, Gerätedaten,
  Screenshots und Absturzprotokolle werden dabei gar nicht erst abgefragt, nichts wird
  gespeichert oder hochgeladen. Die Inhalte selbst stehen in App Store Connect > Albumist >
  TestFlight > Feedback (Screenshots und Abstürze).
- **full** (Kommentare, Screenshots, vollständige Absturzprotokolle mit den obersten Zeilen in
  `report.md`, alles im Artefakt **testflight-feedback**, 7 Tage) geht nur, solange das Repository
  **privat** ist. Auch dann zeigt die Zusammenfassung des Laufs nur die Anzahlen und „Details im
  Artefakt“, denn Zusammenfassungen bleiben etwa 90 Tage stehen. Das Skript fragt GitHub selbst danach; bei einem
  öffentlichen Repository bricht es mit „Mode full is refused“ ab, bevor irgendetwas abgeholt wird.
  Grund: die Zusammenfassung eines öffentlichen Repositorys kann jeder lesen, das Artefakt jeder
  mit GitHub-Konto laden, und Screenshots einer Foto-App können eigene Fotos der Tester zeigen.
- **Bevor das Repository wieder öffentlich wird:** alle Läufe von „TestFlight feedback“, die mit
  full liefen, löschen (Actions > TestFlight feedback > Lauf öffnen > „…“ > Delete workflow run).
  Damit verschwinden ihre Protokolle und Artefakte.
- E-Mail-Adressen und Namen der Tester holt das Skript nie, auch nicht bei full. Texte der Tester
  erscheinen nur als Text (kein HTML, keine Links, keine Erwähnungen) und nie im Protokoll des Laufs.
- Gleicher Schlüssel wie der Upload (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`). Er braucht die
  Rolle **Admin**, **App Manager** oder **Developer**; mit einer anderen Rolle meldet der Lauf
  „HTTP 403“ und nennt die fehlende Rolle. Die Rolle eines Schlüssels lässt sich nicht ändern:
  App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API >
  Team-Schlüssel, neuen Schlüssel mit passender Rolle erzeugen, alten widerrufen und die
  Secrets `ASC_KEY_ID` und `ASC_KEY_P8` ersetzen. Geprüft 16.11.: der vorhandene Schlüssel darf
  beides lesen (Lauf 43969243298).
- Der tägliche Lauf und „Run workflow“ gehen erst, wenn die Datei in `main` ist (GitHub plant
  und startet Workflows nur von dort). In einem öffentlichen Repository schaltet GitHub den
  Zeitplan nach 60 Tagen ohne Aktivität ab; dann Actions > TestFlight feedback > „Enable workflow“.
- Noch nicht mit echten Daten erprobt (bisher gab es kein Feedback und keinen Absturz): das Abholen
  der Absturzprotokolle (`crashLog`) und das Laden der Screenshots. Beides ist nur mit
  nachgebauten Antworten getestet und läuft ohnehin nur bei full.

## Gut zu wissen

- Interne Tester (bis 100 Personen aus dem eigenen Team) brauchen keine Prüfung durch Apple.
  Externe Tester per Link brauchen eine kurze Beta-Prüfung beim ersten Build.
- Ein TestFlight-Build läuft 90 Tage.
- Die Bundle-ID `app.albumist.ios` lässt sich nach dem ersten Hochladen nicht mehr ändern.
- Ablauf in GitHub: sobald CI für den Commit grün ist, baut ein Mac schon das Archiv; signiert
  und hochgeladen wird erst, wenn auch der UI-Lauf genau dieses Commits grün ist, und nur ein
  Archiv genau dieses Commits. Ohne UI-Lauf auf diesem Commit gibt es keinen Upload (und kein
  Release): der UI-Lauf startet nur für Pull Requests, auf deren letztem Commit.
- Von selbst lädt nur ein Push auf `claude/sortly-app` hoch. Ein Merge in `main` startet keinen
  Build (16.11.: das Zusammenführen der Webseite startete sonst einen Build mit altem App-Stand).
  `main` wird von Hand freigegeben: Actions > **UI flow** > Run workflow für `main`, wenn grün:
  Actions > **TestFlight** > Run workflow für `main`; die Prüfung wartet nach grünem CI
  15 Minuten auf einen UI-Lauf und meldet sonst „no UI flow run“.
- Ändert ein Push seit dem letzten hochgeladenen Build (Git-Tag `build-<Nummer>`) nur die
  Webseite (`website/`) oder Dokumente (`docs/`, `*.md`), startet kein Build
  (`.github/scripts/app_changed.py`). Das Archiv wird am Ende des Laufs gelöscht. Schlägt nur das Hochladen fehl,
  den Lauf mit **Re-run all jobs** neu starten (baut das Archiv neu); „Re-run failed jobs“ findet das
  Archiv nicht mehr und schlägt absichtlich fehl.
- Welcher Commit in einem Build steckt: die App trägt ihn in ihrer Info.plist (`AlbumistCommit`,
  daneben die Build-Nummer `CFBundleVersion` und das Xcode `DTXcodeBuild`). Vor dem Hochladen prüft
  der Lauf alle drei und dass jede Datei der App Byte für Byte die archivierte ist (Liste aller
  Dateien mit SHA-256, verglichen vor dem Signieren, weil das Signieren die App-Datei ändert). Gebaut wird mit dem festgelegten Xcode aus
  `.github/toolchain.json`, nie mit einer Beta. Nach dem Hochladen trägt der Commit das Git-Tag
  `build-<Nummer>` (`git show build-41` zeigt den Code von Build 41).
