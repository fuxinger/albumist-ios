# Albumist auf dem eigenen iPhone: TestFlight einrichten

Mit TestFlight läuft Albumist als echte App auf dem iPhone, mit der echten Mediathek und ohne
Zeitlimit. Eine neue Version testet, baut, signiert und lädt GitHub zu TestFlight hoch, sobald
jemand den Lauf startet: Actions > **TestFlight** > Run workflow auf `main`
(`.github/workflows/testflight.yml`). Alles hier geht vom Windows-PC im Browser oder vom iPhone
aus; ein Mac ist nicht nötig.

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

Danach baut GitHub einen TestFlight-Build, sobald jemand Actions > **TestFlight** > Run workflow
auf `main` startet.

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
- Ablauf in GitHub (ein Lauf, Profi-Analyse, 17.11.2026): Actions > **TestFlight** > Run workflow
  auf `main` (oder `gh workflow run testflight.yml --ref main`). Der Lauf prüft genau diesen
  Commit selbst: erst CI (Regeln, Kern-Tests, iOS-Tests auf einem Mac), dann nebeneinander die
  UI-Tests und den kleinen Härtetest. Nur wenn alles grün ist, baut ein Mac das Archiv, prüft
  es, signiert es beim Export und lädt es hoch; danach bekommt der Commit das Git-Tag
  `build-<Nummer>`, und „Was testen“ wird gesetzt. Zwei bis zweieinhalb Stunden bis zum
  Hochladen (die UI-Tests allein 75–100 Minuten), danach bis zu 50 Minuten, bis „Was testen“
  steht. Kein Teil wartet auf andere Läufe. Ein zweiter TestFlight-Lauf wartet, bis der erste
  ganz fertig ist, „Was testen“ eingeschlossen. Wiederholungen nach einem Simulator-Ausfall und
  Tests, die erst in der Wiederholung grün wurden, zählt der Job „Repeats and flaky tests“ für
  UI-Tests und Härtetest zusammen.
- Nichts startet von selbst, kein Push und kein Merge in `main` (16.11.: das Zusammenführen der
  Webseite startete sonst einen Build mit altem App-Stand). Das gilt für jeden Zweig mit der
  neuen `testflight.yml`. `claude/sortly-app` hat noch die alte Fassung mit Push-Auslöser: dort
  startet jeder Push einen Lauf, der nach grünem CI hochlädt, bis der Zweig die neue Datei
  bekommt oder stillgelegt ist (Profi-Analyse Top 1). Mit der neuen Datei geht der Lauf auch
  dort nur von Hand.
- Ist ein Test rot: den Fehler beheben und einen **neuen** Lauf starten (wackelnde Tests werden
  gezählt und behoben, nie versteckt). Ein roter Test wird nie per Wiederholung grün: der
  Upload-Job eines späteren Versuchs liest alle Schritte der früheren Versuche und lädt nicht
  hoch, wenn einer in einem Test, einer Regel, einem Bau oder beim Archiv scheiterte
  (`.github/scripts/earlier_attempts.py`). **Re-run failed jobs** hilft nur, wenn die Technik
  versagt hat: Runner oder Container nicht gestartet, Simulator nicht hochgefahren, gebaute Tests
  oder Checkout nicht angekommen, Hochladen zu App Store Connect abgebrochen. Solche Ausfälle
  stehen als Warnung in der Zusammenfassung des Upload-Jobs und in der Nachricht des Tags
  („attempt 2; earlier attempts: …“). Kann der Upload-Job die früheren Versuche nicht lesen
  (GitHub-API antwortet nicht), lädt er ebenfalls nicht hoch; dann nur ihn wiederholen. Die
  gebauten UI-Tests bleiben für **Re-run failed jobs** 3 Tage liegen; danach einen neuen Lauf
  starten.
- Notfall: **force** lädt ohne Tests hoch. So ein Build ist überall als „FORCED – untested“
  markiert: in der Zusammenfassung des Upload-Jobs, in der Nachricht des Tags `build-<Nummer>`
  und als erste Zeile von „Was testen“.
- Härtetest (Regel Fuchs, 17.11.2026): vor jedem TestFlight-Build der kleine Durchgang mit
  10.000 Fotos und 15 Minuten Messung (rund 45 Minuten). Er läuft im TestFlight-Lauf neben den
  UI-Tests und muss grün sein, sonst wird nicht hochgeladen; grün heißt, test12 ist
  durchgelaufen (ein übersprungener test12 zählt als Fehler). Von Hand: Actions > **UI stress** >
  Run workflow, Vorgaben unverändert lassen (oder `gh workflow run ui-stress.yml --ref <Zweig>`).
  Der volle Durchgang mit 50.000 Fotos läuft nur wöchentlich nachts (Sonntag 00:40 UTC, erst wenn
  der Workflow in `main` ist; in einer eigenen Gruppe, die Mac-Warteschlange ersetzt ihn nie) und
  vor dem Start im App Store. Der letzte volle Durchgang, Lauf 44116350940 (17.11.), ist
  **fehlgeschlagen**: zu Beginn von Schritt 4 stand die Fortschrittszeile 13,7 s still (Grenze
  10 s). Die Korrektur liegt auf `claude/ui-fix` (9ff0dfc); ein neuer voller Durchgang damit
  steht aus.
- Mac-Warteschlange (Profi-Analyse, 17.11.2026): UI-Läufe und Härtetests aller Zweige laufen
  nacheinander, nie zwei zugleich. Es wartet höchstens einer; startet ein weiterer, ersetzt er den
  wartenden, der dann als „abgebrochen“ erscheint und später neu gestartet werden muss. Ein
  TestFlight-Lauf steht nicht in dieser Schlange: seine UI-Tests und sein Härtetest gehören nur zu
  ihm, nichts hält sie auf oder ersetzt sie. Darum TestFlight starten, wenn die Schlange leer ist.
  Ebenfalls außerhalb: der wöchentliche volle Härtetest und Pull Requests aus Forks (je eine
  eigene Gruppe). **Beim ersten TestFlight-Lauf prüfen**, dass UI-Tests und Härtetest nicht auf
  `mac-queue` warten (ihre Gruppen heißen `testflight-ui-<Lauf-ID>` und
  `testflight-stress-<Lauf-ID>`); in echt gelaufen ist das noch nicht.
- Eine GitHub-Version (Workflow **Release**) braucht weiter einen grünen CI-Lauf und einen grünen
  Lauf **UI flow** genau dieses Commits; die Tests im TestFlight-Lauf zählen dafür nicht
  (`.github/scripts/ci_gate.py`).
- Welcher Commit in einem Build steckt: die App trägt ihn in ihrer Info.plist (`AlbumistCommit`,
  daneben die Build-Nummer `CFBundleVersion` und das Xcode `DTXcodeBuild`). Vor dem Hochladen prüft
  der Lauf alle drei. Archiv und Export laufen im selben Job auf demselben Mac, dazwischen wird
  nichts weitergereicht. Gebaut wird mit dem festgelegten Xcode aus
  `.github/toolchain.json`, nie mit einer Beta. Nach dem Hochladen trägt der Commit das Git-Tag
  `build-<Nummer>` (`git show build-41` zeigt den Code von Build 41 und in der Nachricht des
  Tags, ob die Tests liefen).

## Freigabe vor dem Hochladen (geplant, Schritte für den Besitzer)

Noch nicht eingerichtet, und `testflight.yml` nutzt es noch nicht. Ziel: den Schlüssel für App
Store Connect bekommt nur ein Lauf auf `main` (bis zur Stilllegung auch `claude/sortly-app`), und
erst, wenn du ihn freigegeben hast.

1. https://github.com/fuxinger/sortly-ios/settings/environments > **New environment**, Name
   `testflight`.
2. **Required reviewers**: dich selbst eintragen. „Prevent self-review“ aus lassen, sonst kannst
   du deine eigenen Läufe nicht freigeben.
3. **Deployment branches and tags** > Selected branches and tags: `main` und `claude/sortly-app`.
4. **Environment secrets**: die vier Secrets aus Abschnitt 4 dort noch einmal anlegen
   (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`).
5. Einem Agenten sagen, dass die Umgebung steht. Er trägt `environment: testflight` bei den Jobs
   von `testflight.yml` ein, die den Schlüssel lesen. Danach fragt GitHub bei jedem Lauf um
   Freigabe, einmal je solchem Job (mindestens vor dem Hochladen und vor „Was testen“).
6. Erst dann die vier Repository-Secrets löschen. Vorher bedenken: der tägliche Feedback-Abruf
   (`asc-feedback.yml`) liest mit denselben drei ASC-Secrets und würde mit der Freigabe-Pflicht
   jeden Morgen auf dich warten. Für ihn einen eigenen Schlüssel mit Rolle **Developer** als
   Repository-Secrets anlegen (oder eine zweite Umgebung ohne Prüfer).
