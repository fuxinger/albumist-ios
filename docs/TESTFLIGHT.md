# Albumist auf dem eigenen iPhone: TestFlight einrichten

Mit TestFlight läuft Albumist als echte App auf dem iPhone, mit der echten Mediathek und ohne
Zeitlimit. Eine neue Version testet, baut, signiert und lädt GitHub zu TestFlight hoch, sobald
jemand den Lauf startet (Actions > **TestFlight** > Run workflow auf `main`,
`.github/workflows/testflight.yml`) oder morgens der tägliche Build startet, und nur, wenn jedes
Tor des Laufs grün ist; seit 19.11.2026 ohne deinen Klick (Abschnitt „Hochladen ohne Klick“ und
`docs/launch/FREIGABE_EINRICHTEN.md`).
Alles hier geht vom Windows-PC im Browser oder vom iPhone aus; ein Mac ist nicht nötig.

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

## 4. Vier Secrets in GitHub eintragen (in der Umgebung `testflight-upload`)

Seit 18.11.2026 liegen sie nicht mehr als Repository-Secrets, sondern als Secrets der
GitHub-Umgebung `testflight-upload`, die nur der Zweig `main` benutzen darf. Anlegen, die Regel
`main` setzen und die Secrets dort speichern: `docs/launch/FREIGABE_EINRICHTEN.md`.

| Name | Inhalt |
|---|---|
| `ASC_KEY_ID` | Schlüssel-ID |
| `ASC_ISSUER_ID` | Issuer-ID |
| `ASC_KEY_P8` | Inhalt der .p8-Datei (mit Editor öffnen, alles kopieren, auch die Zeilen BEGIN und END) |
| `APPLE_TEAM_ID` | Team-ID |

Danach baut GitHub einen TestFlight-Build, sobald jemand Actions > **TestFlight** > Run workflow
auf `main` startet oder der tägliche Build startet, und lädt ihn hoch, wenn alles grün ist.

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
- Eigener Schlüssel, nicht der des Uploads (seit 18.11.2026): den Upload-Schlüssel bekommt nur
  der Upload-Job. Der Feedback-Schlüssel hat die Rolle **Developer** und
  liegt als Repository-Secrets `ASC_FEEDBACK_KEY_ID`, `ASC_FEEDBACK_ISSUER_ID` und
  `ASC_FEEDBACK_KEY_P8` (`docs/launch/FREIGABE_EINRICHTEN.md`, „Freiwillig“). Ohne sie
  meldet der Lauf nur „Skipped“. Mit einer Rolle ohne Lesezugriff meldet er „HTTP 403“ und nennt
  die fehlende Rolle (Admin, App Manager oder Developer geht). Die Rolle eines Schlüssels lässt
  sich nicht ändern: neuen Schlüssel mit passender Rolle erzeugen, alten widerrufen, die drei
  Secrets ersetzen. Geprüft 16.11. (damals noch mit dem Upload-Schlüssel): Feedback und Abstürze
  lassen sich lesen (Lauf 43969243298); mit einem Developer-Schlüssel noch nicht erprobt.
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
  auf `main` (oder `gh workflow run testflight.yml --ref main`). Der Lauf prüft genau diesen Commit
  selbst: erst CI (Regeln, Kern-Tests, iOS-Tests auf einem Mac), dann nebeneinander die UI-Tests
  (kleines Tor: nur zwei Gruppen, Abschnitt „Zwei Tore“), den kleinen Härtetest und den
  Release-Kurztest (unten), bei beiden Toren. Nur wenn alles grün ist (seit 19.11.2026 ohne Klick, `docs/launch/FREIGABE_EINRICHTEN.md`),
  baut ein Mac das Archiv, prüft es, signiert es beim Export, lädt es hoch und setzt „Was testen“;
  danach bekommt der Commit das Git-Tag `build-<Nummer>`. Zwei bis zweieinhalb Stunden bis zum
  Upload-Job, wenn alle UI-Gruppen laufen (die UI-Tests allein 75–100 Minuten); laufen nur einzelne
  Gruppen oder keine (Abschnitt „UI-Tests: nur betroffene Gruppen“), bestimmt der Härtetest (rund 45
  Minuten) die Dauer, ebenso beim kleinen Tor: rund 70 Minuten bis zum Upload-Job. Dann
  15–20 Minuten bis zum Hochladen, „Was testen“ setzt derselbe Job meist wenige Minuten danach
  (höchstens 20). Kein Teil wartet auf andere Läufe. Ein zweiter TestFlight-Lauf wartet, bis der
  erste ganz fertig ist. Wiederholungen nach einem
  Simulator-Ausfall und Tests, die erst in der Wiederholung grün wurden, zählt der Job „Repeats and
  flaky tests“ für UI-Tests, Härtetest und Release-Kurztest zusammen.
- Release-Kurztest (Prüfbefund P5-03, 19.11.2026): alle UI-Tests laufen auf einem Debug-Build mit
  Test-Schaltern; die Release-Fassung, die hochgeladen wird, startete vorher kein Test. Der Job
  „Release build smoke test (UI)“ baut die UI-Tests mit `-configuration Release` und lässt einen
  Test laufen (`App/SortlyUITests/ReleaseSmokeUITests.swift`): Einführung, Beispiel-Mediathek und
  Analyse, empfohlene Vorschläge, ein Plan in den Gratis-Alben, in Fotos angelegt, ohne
  Test-Schalter wie bei einem neuen Nutzer. Bei beiden Toren, neben UI-Tests und Härtetest (rund
  25–35 Minuten, kürzer als der Härtetest), und er muss grün sein, sonst wird nicht hochgeladen; ein
  übersprungener Test zählt als Fehler. Nie mehr als fünf Macs zugleich: im TestFlight-Lauf laufen
  höchstens drei UI-Gruppen gleichzeitig, die längste (Gerätebedingungen) zuerst; die zwei kurzen
  warten auf einen Mac und sind trotzdem vor ihr fertig, der Lauf dauert also nicht länger.
  Ein roter Release-Kurztest gilt wie ein roter Härtetest nur für seinen Lauf: „Re-run failed
  jobs“ macht ihn nicht grün, ein neuer Lauf auf derselben App startet ihn aber neu (anders als
  eine UI-Gruppe, deren Rot das UI-Tor für diese App und diesen Testcode behält). Der tägliche
  Build startet keinen neuen Lauf auf einem Commit, der schon in einem TestFlight-Lauf war (oder
  nur Doku dazu bringt); von Hand erst die Ursache beheben. **Ungeprüft bis zum ersten Lauf auf einem Mac.**
- Kein Push und kein Merge in `main` startet einen Build (16.11.: das Zusammenführen der
  Webseite startete sonst einen Build mit altem App-Stand). Von selbst startet nur der tägliche
  Build mit kleinem Tor (`daily-build.yml`, Abschnitt „Zwei Tore“); er lädt seit 19.11.2026 ohne
  Klick hoch, wenn alles grün ist, als internen Build nur für dich. Läufe auf anderen Zweigen als `main` tun nichts (der erste Job läuft nur
  auf `main`, die Umgebung lässt nur `main` zu). Der alte Release-Zweig `claude/sortly-app` lädt
  nichts mehr hoch (Beschluss Fuchs 18.11., Zweig bleibt bestehen): seit 1358f7f lässt sich seine
  `testflight.yml` nur von Hand starten und bricht sofort ab, ohne Secrets, ohne Mac, ohne
  Push-Auslöser.
- Ist ein Test rot: den Fehler beheben und einen **neuen** Lauf starten (wackelnde Tests werden
  gezählt und behoben, nie versteckt). Ein roter Test wird nie per Wiederholung grün: der
  Upload-Job eines späteren Versuchs liest alle Schritte der früheren Versuche und lädt nicht
  hoch, wenn einer in einem Test, einer Regel, einem Bau oder beim Archiv scheiterte
  (`.github/scripts/earlier_attempts.py`). **Re-run failed jobs** hilft nur, wenn die Technik
  versagt hat: Runner oder Container nicht gestartet, Simulator nicht hochgefahren, gebaute Tests,
  Checkout oder XcodeGen (festgelegte Version 2.46.0 aus `.github/toolchain.json`, mit Prüfsumme, Schritt „Install XcodeGen“) nicht angekommen, Hochladen zu
  App Store Connect abgebrochen. Maßgeblich ist der Schritt, nicht die Ursache: geht der Runner
  mitten in einem Testschritt verloren (etwa „Run UI tests“), wird der Lauf dort abgebrochen
  oder hakt „Select pinned Xcode“ oder „Generate Xcode project“, braucht es ebenfalls einen
  neuen Lauf. Erlaubte Ausfälle stehen als Warnung in der Zusammenfassung des Upload-Jobs und in
  der Nachricht des Tags („attempt 2; earlier attempts: …“). Kann der Upload-Job die früheren
  Versuche nicht lesen (GitHub-API antwortet nicht), lädt er ebenfalls nicht hoch; dann nur ihn
  wiederholen. Die gebauten UI-Tests bleiben für **Re-run failed jobs** 3 Tage liegen; danach
  einen neuen Lauf starten. Hat ein Lauf schon hochgeladen (es gibt den Tag `build-<Nummer>` des
  Laufs), hält jede Wiederholung im ersten Job und am Anfang des Upload-Jobs an („Not uploaded by
  this run yet“): dieselbe Build-Nummer nähme App Store Connect nicht noch einmal; ein neuer Build
  braucht einen neuen Lauf. Dasselbe gilt über Läufe hinweg: war eine UI-Gruppe für genau diese
  App und genau ihren Testcode einmal rot, zählt ein späteres Grün derselben Kombination nicht,
  auch nicht aus einem anderen Lauf. Erst eine Änderung am Test oder an der App (die Korrektur)
  macht sie wieder hochladbar.
- Kein Notfall-Weg ohne Tests: den Schalter **force** (lud ohne jeden Test hoch) hat Fuchs am
  17.11.2026 gestrichen; er ist seit 18.11. auch aus `testflight.yml` und den Skripten entfernt
  (Prüfbefund G5-02/G6-02). Auch ein eiliger Build wartet auf CI, UI-Tests, Härtetest und das
  UI-Tor. Ein Test in `.github/scripts/tests/test_workflows.py` schlägt fehl, sobald ein
  Workflow wieder eine Eingabe oder ein Skript einen Schalter zum Überspringen bekommt. Die
  einzige Wahl ist das Tor (groß oder klein, beide von Fuchs beschlossen, Abschnitt „Zwei Tore“).
- Welcher Build an Tester gehen darf (Entscheidungen 10 und 12, 18.11.2026): `docs/TEST_PLAN.md`,
  Abschnitt „Tore“. Dieser Lauf setzt die Tests des großen Tors durch; Fälle mit ⛔ im Testplan
  prüft vor jeder Weitergabe an Tester der Koordinator. Offene Fälle ohne ⛔ halten keinen Build auf.
- Härtetest (Regel Fuchs, 17.11.2026, und Entscheidung 4): vor jedem TestFlight-Build, mit beiden
  Toren, der kleine Durchgang mit 10.000 Fotos und 15 Minuten Messung (rund 45 Minuten); auch vor
  dem täglichen Build mit kleinem Tor, denn er lädt auch hoch. Er
  läuft im TestFlight-Lauf neben den UI-Tests und muss grün sein, sonst wird nicht hochgeladen;
  grün heißt, test12 ist durchgelaufen (ein übersprungener test12 zählt als Fehler). Von Hand:
  Actions > **UI stress** > Run workflow, Vorgaben unverändert lassen (oder `gh workflow run
  ui-stress.yml --ref <Zweig>`). Der volle Durchgang mit 50.000 Fotos läuft nur wöchentlich nachts
  (Sonntag 00:40 UTC, erst wenn der Workflow in `main` ist; in einer eigenen Gruppe, die
  Mac-Warteschlange ersetzt ihn nie) und vor dem Start im App Store. Der letzte volle Durchgang,
  Lauf 44116350940 (17.11.), ist **fehlgeschlagen**: zu Beginn von Schritt 4 stand die
  Fortschrittszeile 13,7 s still (Grenze 10 s). Die Korrektur (9ff0dfc) ist in diesem Stand; ein
  neuer voller Durchgang damit steht aus.
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

## UI-Tests: nur betroffene Gruppen (Regel Fuchs, 17.11.2026)

Die UI-Tests laufen in fünf Gruppen (`.github/ui-groups.json`): Gerätezustände, voller Ablauf
mit Video, übrige Abläufe mit Kauf und Suche, Barrierefreiheit, Kontrast. Seit 18.11. läuft
eine Gruppe nur noch, wenn es für sie kein grünes Ergebnis für genau diese App und genau ihren
Testcode gibt.

- **Fingerabdruck der App**: eine Prüfsumme über alle Dateien, aus denen die App gebaut wird.
  Gezählt wird alles außer UI-Tests (`App/SortlyUITests`), Unit-Tests (`App/SortlyTests`,
  `Tests`), `docs/`, Markdown-Dateien im obersten Ordner (`README.md` usw.; eine `.md` in
  `App/` zählt mit), `.github/` (außer `.github/toolchain.json` mit dem festgelegten Xcode und
  XcodeGen, das zählt mit), `scripts/`, `tools/` und `design/`. Also zählen unter anderem
  `App/Sortly/**`, `Sources/**`, `Package.swift`, `App/project.yml` mit den Build-Einstellungen,
  Ressourcen und die StoreKit-Datei. Eine neue, unbekannte Datei zählt zur App: im Zweifel
  läuft eine Gruppe einmal zu viel, nie einmal zu wenig. Gleicher Fingerabdruck heißt:
  Byte für Byte dieselben Dateien.
- **Fingerabdruck einer Gruppe**: ihre Testdateien, alle Hilfsdateien, die diese benutzen (zum
  Beispiel `UITestOnboarding.swift`), ihre Zeile in `.github/ui-groups.json` und alles, über
  das jede Gruppe läuft: die beiden UI-Workflows (`ui.yml`, `ui-stress.yml`) und jede Datei
  unter `.github/`, die sie nennen, und jedes Skript, das ein solches Skript nennt oder
  importiert (`ui_tests.py`, `pick_simulator.py`, `toolchain.py`, `ui_evidence.py`, ...; ohne
  die Unit-Tests in `tests/` und ohne `ui-groups.json`, dort zählt nur die Zeile der Gruppe).
  Eine Änderung daran lässt alle Gruppen laufen; eine Änderung an einem Workflow oder Skript,
  das kein UI-Job ausführt (`testflight.yml`, `ci.yml`, `ci_gate.py`, ...), lässt jedes grüne
  Ergebnis stehen (Prüfer 5, P5-08 c). Im Zweifel zählt jede Datei unter `.github/`: wenn ein
  UI-Workflow fehlt oder `ui_tests.py` nicht erreicht, ein Skript nicht lesbar ist oder ein
  Name sich nicht auflösen lässt (ein Skript- oder Pfadname aus einer Variablen, ein Pfad, den
  es nicht gibt), und wenn ein Skript Code startet, den der Leser nicht sieht: ein zur Laufzeit
  gebauter Shell-Befehl (`shell=True`, `os.system`, `bash -c`, `python -c`), `exec`, `eval`,
  `compile`, oder ein Ordner unter `.github/`, den es auflistet (`glob`, `listdir`, `walk`).
  Datendateien zählen mit jeder Endung.
  Swift-Dateien der UI-Tests zählen mit ihrem Code, nicht Byte für Byte: Kommentare,
  Einrückung und Leerzeilen zählen nicht, Zeichenketten und Regex-Literale schon (Zeichen für
  Zeichen). Ein geänderter Kommentar ist also keine Änderung des Tests: ein rotes Ergebnis
  bleibt rot (Prüfer B, G5-04). Kann das Skript eine Datei nicht sicher lesen (etwa `a/b` statt
  `a / b`, das könnte ein Regex-Literal sein), zählt sie Byte für Byte; ein Unit-Test verlangt,
  dass alle Swift-Dateien der UI-Tests sicher lesbar sind.
  Welche Datei welche benutzt, liest `.github/scripts/ui_groups.py` bei jedem Lauf aus den
  Swift-Dateien (auch Klassen, deren Kopf über mehrere Zeilen geht, und Code in `\(…)` von
  Zeichenketten); keine Liste von Testnamen ist fest eingetragen. Im Zweifel streng: eine
  Swift-Datei der UI-Tests, die keiner Gruppe zugeordnet werden kann, zählt für alle Gruppen;
  eine Gruppe, die keinen Test auswählt, ist ein Fehler (der Plan bricht ab), ebenso ein
  Gruppenname, der nicht in einen Job-Namen passt. Übersicht von Hand:
  `python3 .github/scripts/ui_groups.py map`.
- Daraus folgt: **nur Testcode geändert** → nur die Gruppen, deren Dateien sich geändert haben;
  **gemeinsame Hilfsdatei geändert** → jede Gruppe, die sie benutzt; **irgendetwas an der App
  geändert** → alle Gruppen. Welche Gruppen eine Änderung wieder laufen lässt:
  `python3 .github/scripts/ui_groups.py affected --base <alter Commit>`.
- Jeder Gruppen-Job trägt beide Fingerabdrücke im Namen, zum Beispiel
  „UI device conditions [device app 1a2b3c4d5e6f tests 9f8e7d6c5b4a]“. Daran finden spätere
  Läufe das Ergebnis wieder (`.github/scripts/ui_evidence.py`). Gezählt wird ein grünes
  Ergebnis nur, wenn Git für den getesteten Commit dieselben Fingerabdrücke ausrechnet, und
  nur aus diesem Repository (nie aus einem Fork). Ein Pull-Request-Lauf testet GitHubs
  Merge-Commit; er steht deshalb im Namen des Laufs („[merge <sha>] …“).
- **Lückenlos gelesen**: Plan und Gate lesen jeden Lauf von `ui.yml` und `testflight.yml` der
  letzten 90 Tage (so lange hält GitHub Läufe; keiner vor dem 18.11.2026, als die Job-Namen
  die Fingerabdrücke bekamen). Bewusst nicht ab einem Commit-Datum: ein Rot auf einem Commit,
  der später umgeschrieben (rebase, amend) oder dessen Zweig gelöscht wurde, bleibt so im
  Blick. Ein Zeitraum mit mehr als 1000 Läufen (so viele liefert die API je Abfrage) wird
  geteilt. Die Jobs eines Laufs werden gelesen, wenn sein Commit diese App haben kann: Git
  kennt den Commit und er hat diese App, oder Git kennt ihn nicht (dann zählt sein Rot, sein
  Grün nicht). Läufe dieser App, die für keine Gruppe den jetzigen Testcode haben, liest der
  Aufruf zuletzt und nur, solange Anfragen übrig sind (sie braucht nur die Liste „Rot mit
  älterem Testcode“). Jeder Aufruf darf höchstens 300 API-Anfragen machen (das Token eines
  Laufs hat 1000 je Stunde für das ganze Repository; jeder UI-Lauf ruft zweimal auf, die Zahl
  steht als `UI_API_CALLS` im Log). Reicht das nicht oder antwortet die API nicht, laufen im
  Plan alle Gruppen und das Gate ist rot. **Grenze:** das passiert erst bei mehr als rund 200
  Läufen in 90 Tagen, deren Commit diese App und den jetzigen Testcode einer Gruppe hat (oder
  die Git nicht kennt), zusätzlich zur Laufliste (100 Läufe je Anfrage). Dann sperrt das Gate
  jeden Upload dieses Stands, bis sich die App ändert oder `MAX_CALLS` in
  `ui_evidence.py` erhöht wird. Ein Zwischenspeicher der ausgewerteten Läufe (als Artefakt)
  würde das aufheben; er ist noch nicht gebaut. Ein dauerhaftes Verzeichnis der roten Ergebnisse außerhalb
  von GitHubs Laufliste gibt es nicht (es bräuchte ein Schreib-Token in den Testläufen;
  Artefakte laufen ab wie die Läufe).
- **Beispiel** (die Nacht zum 18.11.): Commit 4bb7fdd änderte nur eine Wartezeit in
  `SortlyFlowUITests.swift`. Bisher liefen danach alle fünf Gruppen (über 80 Minuten). Jetzt
  laufen „voller Ablauf“ und „übrige Abläufe“ (beide haben Tests in dieser Datei);
  Gerätezustände, Barrierefreiheit und Kontrast übernimmt der Lauf aus dem letzten grünen Lauf
  mit derselben App und demselben Testcode. Die Zusammenfassung des Jobs „UI plan“ zeigt für
  jede Gruppe, woher ihr Grün kommt oder warum sie läuft.
- **Rot bleibt rot** (wie bei „Re-run failed jobs“): Ist eine Gruppe für dieselbe App und
  denselben Testcode irgendwann rot gewesen, zählt kein späteres Grün dieser Kombination, egal
  aus welchem Lauf und in welchem Modus (schnell oder voll). Rot heißt: „Run UI tests“ hatte
  begonnen, ist nicht grün geworden, und das Log zeigt ein Testergebnis, nämlich die Zeile
  `UI_RESULT <Gruppe> fail` von `ui_tests.py` (ältere Logs: ein gescheiterter Testfall) oder
  das Zeitlimit des Jobs. Damit ein Hänger nicht als „kein Ergebnis“ endet, stoppt
  `ui_tests.py` einen Durchgang, der 12 Minuten vor dem Zeitlimit des Jobs (150 Minuten) noch
  läuft. Läuft dabei gerade ein Test, ist das rot (`UI_HANG`, ein Befund, keine Wiederholung);
  läuft keiner (zwischen zwei Tests, vor dem ersten), war nur die Zeit um (`UI_DEADLINE`,
  kein Ergebnis). Eine Wiederholung nach einem Simulatorfehler beginnt nur, wenn noch
  mindestens 30 Minuten bis zu dieser Frist bleiben (und nach dem Zurücksetzen noch 10);
  sonst hat die Gruppe kein Ergebnis. Gescheiterte Testfälle und `: error: -[`-Zeilen
  erscheinen schon während des Durchgangs im Log (`UI_LIVE`), sodass auch ein Abbruch danach
  rot bleibt. Ein Job, der nach seinem vollen Zeitlimit nicht grün endete, ist ebenfalls rot. Ein Log, das sich nicht lesen lässt, zählt
  als Rot; GitHub löscht Logs spätestens mit dem Lauf (Antwort 410), und ein solches Rot
  bleibt dann bestehen, bis sich App oder Test ändern. Ein
  wackelnder Test wird so gezählt und behoben, nie durch Wiederholen versteckt. Die Gruppe darf
  zur Beobachtung noch einmal laufen; ihr Grün steht dann als „red before for this key“ in der
  Tabelle und zählt für TestFlight nicht. Ein Test, der einen Schritt in sich selbst noch
  einmal versucht und das mit `UI_FLAKY_RETRY <Test> <Grund>` meldet (Gerätetest test07), wird
  wie ein erst in der Wiederholung grüner Test als wackelnd gezählt und gezeigt
  (`flaky-*.json`, FLAKY-Zeile, Zusammenfassung, Warnung im Gate bei übernommenen Ergebnissen),
  blockiert aber nicht: gezählt und behoben, nicht gesperrt. Scheitert er trotz seines eigenen
  zweiten Versuchs, ist er ohnehin rot. Kein Ergebnis (weder Rot noch Grün): „Run UI tests“
  hat nie begonnen (Simulator nicht gestartet, Lauf vorher abgebrochen, gebaute Tests fehlen:
  Schritt „Built tests present“); ein Abbruch oder verlorener Runner mitten in den Tests, ohne
  dass im Log etwas gescheitert ist (**laufende Testläufe nie abbrechen**, Regel des
  Besitzers); oder jeder Durchgang scheiterte allein am Simulator oder an XCTest, auch die
  Wiederholung (`ui_tests.py` endet mit 75 und `UI_RESULT <Gruppe> infra`, der Job scheitert
  im eigenen Schritt „No test result (simulator or XCTest failed in every pass)“). Dazu zählt
  seit 18.11.2026 ein Absturz von XCTests Dienst `testmanagerd` („Critical process testmanagerd
  crashed“, „Lost connection to the application“; Lauf 44202318875, Versuch 2, Gruppe
  flow-other): die betroffenen Tests laufen einmal neu wie nach einem Simulatorfehler, gezählt
  und sichtbar als wackelnd (auch „app lost + daemon crash in <Test>“, wenn die App im selben
  Test ohne Absturzbericht verloren ging); rot wird es, wenn dabei ein Test aus Gründen der App
  scheitert oder `testmanagerd` im selben Test noch einmal abstürzt (dann wohl von der App
  ausgelöst, etwa durch einen riesigen Bedienungshilfen-Baum). **Meine Entscheidung vom 18.11.2026, vom
  Besitzer zu bestätigen:** einen Test, der schon begonnen hatte, nach dem Verlust von
  `testmanagerd` oder CoreSimulator noch einmal laufen zu lassen, geht über die Regel „Ausfall
  der Technik vor dem ersten Test = kein Ergebnis“ hinaus. Wurde ein Rot
  nur durch eine gemeinsame Datei (Hilfsdatei, Skript, Workflow) zu einem neuen Schlüssel,
  ohne dass sich eine eigene Testdatei der Gruppe änderte, warnen Plan und Gate („UI red
  cleared by a shared change“): prüfen, ob das wirklich die Korrektur war.
- **Längere Wartezeiten in Tests brauchen einen gemessenen Grund** (Regel 17.11.): wer ein
  `timeout` oder eine Wartezeit verlängert, nennt im Commit die Messung (Lauf und gemessene
  Sekunden), so wie 4bb7fdd („say how long it took“). Eine reine Verlängerung ohne Messung ist
  keine Korrektur.
- **Eine Zeitgrenze wird nur mit Eintrag gelockert** (Regel 19.11., Prüfer 5, P5-13: Build 36
  kam aus 4bb7fdd, das nur eine Wartezeit von 5 auf 20 s verlängerte; die langsame App war damit
  leiser): wer in einem Test (`App/SortlyUITests`, `App/SortlyTests`, `Tests`) ein `timeout:`,
  ein `limit:` von `timed(...)`, eine Obergrenze `< .seconds(…)` oder ein `.timeLimit` erhöht,
  oder in einem Workflow ein `timeout-minutes`, legt im selben Pull Request oder Push eine Zeile
  in `docs/IMPROVEMENTS.md` an, die „Zeitgrenze gelockert“ sagt und die Datei nennt: warum, die
  Messung (Lauf, Sekunden), der alte Wert und was die Grenze wieder enger macht. Sie steht als
  offener Punkt (🔜), bis die Ursache behoben ist. CI prüft das im Job „App rules and strings“
  (`.github/scripts/time_limit_rule.py`, Schritt „Time limits only loosened with an entry“) und
  zählt die Einträge (`TIME_LIMIT_ENTRIES`, davon offen). Eine neue oder kürzere Grenze braucht
  nichts. Nicht gesehen werden eine ganz gelöschte Grenze und eine aus Variablen berechnete.
- **TestFlight**: der Lauf ruft die UI-Tests mit „auto“ auf (kleines Tor: nur `flow-full` und
  `contrast`, Abschnitt „Zwei Tore“). Vor dem Hochladen prüft der Job
  **UI gate** auf Linux, dass jede Gruppe des Tors für genau diese App und ihren Testcode grün
  ist (aus diesem Lauf oder einem früheren) und keine dafür rot war. Seine Zusammenfassung nennt jede
  übernommene Gruppe mit Lauf und Commit und listet deren wackelnde Tests (Test erst in der
  Wiederholung grün); das Tag `build-<Nummer>` nennt sie ebenfalls („UI groups: device reused
  from run …“). Antwortet die GitHub-API nicht, lädt der Lauf nicht hoch; dann nur diesen Job
  wiederholen.
- **Urteil jedes UI-Laufs**: der letzte Job **UI verdict (full)** bzw. **UI verdict (quick)**
  macht dieselbe Prüfung wie das Gate von TestFlight, auch wenn keine Gruppe laufen musste.
  Das Freigabe-Gate (`ci_gate.py`, Workflow „Release“) verlangt einen grünen Job
  „UI verdict (full)“.
- **Schnellmodus** (`quick`): Pull Requests laufen schnell. Die Tests bekommen
  `SORTLY_UI_QUICK=1` (im Workflow als `TEST_RUNNER_SORTLY_UI_QUICK`), und
  `DeviceConditionUITests.test11_LargeLibrary` (große Mediathek, rund 25 Minuten) überspringt
  sich. Im Schnellmodus hat jede Gruppe einen anderen Test-Fingerabdruck (sicherheitshalber
  alle, nicht nur die, deren Dateien den Schalter sichtbar lesen), und ihr Job heißt
  „… (quick)“. Ein schnelles Grün zählt nie als volles: TestFlight und die Freigabe verlangen
  volle Ergebnisse. Ein schneller Lauf darf dagegen ein volles Grün übernehmen. Ein Rot sperrt
  in beiden Modi. Für die Freigabe eines Commits, der nur schnelle Läufe hat: „UI flow“ von
  Hand ohne `quick` starten; dann laufen alle Gruppen ohne volles Grün für diesen Stand.
- Von Hand: Actions > **UI flow** > Run workflow, Feld **groups**: `auto` (Vorgabe), `all`
  (alle Gruppen) oder Gruppennamen (`device flow-full flow-other accessibility contrast`), und
  **quick** (aus = voller Lauf). In **TestFlight** gibt es dafür **ui_groups** (`auto` oder
  `all`); TestFlight läuft immer voll.

## Messung der Mac-Läufe (18.11.2026)

Gemessen aus den Job-Protokollen der Läufe zu Commit 4bb7fdd (Pull Request 1): UI-Lauf
44202318875, CI-Lauf 44202319006, CodeQL-Lauf 44202319351. Zeiten in Minuten.

| Job | Start bis Xcode bereit | Gebaute Tests laden und entpacken | Warten auf den Simulator | Tests (davon reine Testzeit) | Ganzer Job |
|---|---|---|---|---|---|
| UI-Bau (bauen und hochladen) | 0,1 | – | – | Bau 1,4 | 1,7 |
| Gerätezustände | 0,2 | 4,0 | 2,4 | 59,6 (58,2; test11 allein 25,9) | 66,7 |
| voller Ablauf mit Video | 0,2 | 0,1 | 5,1 | 12,2 (10,0) | 18,1 |
| übrige Abläufe (rot) | 0,3 | 0,7 | 4,3 | 55,8 (53,5) | 61,8 |
| Barrierefreiheit (rot) | 0,2 | 0,0 | 4,9 | 24,1 (22,1) | 30,2 |
| Kontrast | 0,2 | 1,7 | 2,3 | 13,1 (11,8) | 17,9 |
| CI: Kern-Tests Linux | 0,6 (Container) | – | – | 3,9 (Bau 2,2, Lasttest 1,7) | 4,7 |
| CI: iOS (macOS) | 0,3 | – | – | Kern 3,8, App bauen und testen 9,8, UI-Tests bauen 0,6, Texte 0,9 | 15,6 |
| CodeQL Swift (macOS, rot) | 1,1 | – | – | Bau 24,4, dann Abbruch | 26,2 |

- Der UI-Lauf dauerte 72,8 Minuten: Kern-Tests Linux 4,3, UI-Bau 1,7, dann die längste Gruppe
  (Gerätezustände) 66,7. Gebaut wird schon nur einmal (UI-Bau), die Gruppen laden das Ergebnis.
- Bauen ist billig (UI-Bau 1,4 Minuten). Ein Bau-Cache auf dem Mac lohnt sich darum nicht;
  es gibt weiter keinen (Regel: nur, wenn er nachweislich keinen alten Stand ausliefern kann).
- Jede Gruppe wartet 2,3–5,1 Minuten auf den Simulator, obwohl er schon ab der ersten
  Sekunde im Hintergrund startet; dazu 1,3–2,3 Minuten im Testschritt vor dem ersten Test (App
  und Test-Runner installieren). Wo die Simulator-Minuten bleiben (Start, Fotozugriff,
  Einstellungen), zeigen ab jetzt die Zeilen `UI_BOOT_TIMING` im Schritt „Wait for the
  simulator“. Ein vorgewärmter Simulator geht auf GitHubs Macs nicht: jeder Job bekommt eine
  frische Maschine.
- Laden und Entpacken der gebauten Tests dauerte bei zwei Gruppen 1,7 und 4,0 Minuten statt
  Sekunden, weil der Simulator gleichzeitig startet und die Platte belegt. Nicht geändert.
- Barrierefreiheit startete 14 Minuten später als die anderen Gruppen: alle fünf Macs waren
  belegt (CIs iOS-Job, drei Gruppen und 26 Minuten lang die CodeQL-Swift-Analyse, die am Ende
  scheiterte). Kontrast wartet ohnehin, bis eine Gruppe fertig ist (höchstens vier zugleich).

Umgesetzt (18.11.):

| Änderung | Ersparnis |
|---|---|
| Nur betroffene UI-Gruppen (oben) | Teständerung nur in `AccessibilityUITests.swift`: rund 37 statt 73 Minuten; Änderung nur in `SortlyFlowUITests.swift`: zwei statt fünf Gruppen, rund 115 Mac-Minuten weniger (die Dauer bestimmt dann „übrige Abläufe“, rund 62 Minuten) |
| TestFlight ohne Änderung an App und Tests seit dem letzten grünen UI-Lauf | UI-Tests rund 2 statt 75–100 Minuten; der Lauf dauert dann etwa CI 20 + Härtetest 45 + Hochladen 15 Minuten |
| TestFlight: die Kern-Tests unter Linux laufen nicht zweimal (CI hat sie für denselben Commit gerade bestanden) | rund 5 Minuten bis zum UI-Bau |
| CodeQL Swift nicht mehr bei jedem Pull Request, sondern nachts, und nur das Kernpaket | 26 Mac-Minuten je Push; im gemessenen Lauf hätte Barrierefreiheit 14 Minuten früher begonnen |

Vorschläge, noch nicht umgesetzt (Entscheidung nötig, nach dem Kürzen der UI-Tests neu messen):

1. Gruppen neu verteilen: Gerätezustände (58 Minuten Testzeit, test11 allein 26) und übrige
   Abläufe (54) bestimmen die Dauer, voller Ablauf (10) und Kontrast (12) sind kurz. Zum
   Beispiel test11 in die Gruppe „voller Ablauf“ und test05/07/08 zu den Gerätezuständen: die
   längste Gruppe hätte dann etwa 45 statt 58 Minuten Testzeit.
2. Im TestFlight-Lauf die UI-Tests schon nach den Linux-Teilen von CI starten statt nach dem
   iOS-Job (rund 16 Minuten früher). Kostet Mac-Minuten, wenn der iOS-Job dann rot wird, und
   weicht von „erst schnell, dann teuer“ ab.

## Code-Scanning (CodeQL)

- Python und Workflows: bei jedem Pull Request, auf Linux.
- Swift: nachts um 01:30 UTC und von Hand, nur das Kernpaket (`Sources/**`). Die App selbst
  lässt sich zurzeit nicht analysieren: unter dem CodeQL-Werkzeug kann der Compiler Xcodes
  Makro-Helfer nicht starten („swift-plugin-server … Bad CPU type in executable“, Lauf
  44202319351), und die App braucht Makros (`@Observable`, `@State`). Das Kernpaket braucht
  keine. **Der Swift-Code der App (`App/Sortly`) wird von CodeQL also zurzeit nicht geprüft.**
  Die Kern-Analyse meldet unter der eigenen Kategorie `/language:swift-core`; Warnungen aus
  früheren App-Analysen (Kategorie `/language:swift`) werden von ihr weder bestätigt noch
  geschlossen (Schritt 1 unten).
- Die ReDoS-Warnung in `test_summary.py` ist behoben (keine verschachtelten Wiederholungen mehr).
- Die Warnung „cache poisoning“ in `nightly.yml` ist behoben (18.11.): Der nächtliche Lauf
  testet den Stand, auf dem er läuft (nachts main, von Hand der gewählte Branch), statt einen
  anderen Branch auszuchecken. Ein Test prüft, dass kein geplanter Workflow einen anderen Ref
  auscheckt, und dass kein Workflow einen Actions-Cache liest.

## Schritte für den Besitzer (18.11.2026)

1. Nach dem Zusammenführen: Security > Code scanning. Die ReDoS-Warnung schließt sich beim
   nächsten Scan von selbst, ebenso „Cache poisoning“ in `nightly.yml` (Ursache entfernt).
   Alte Swift-Warnungen in `App/…` aus der früheren Kategorie `/language:swift`: Security >
   Code scanning > **Tool status** > CodeQL > die Konfiguration `/language:swift` > **Delete
   configuration** (ihre Warnungen schließen sich dann). Oder jede einzeln > **Dismiss alert**
   > „Won't fix“, Begründung: „App/Sortly wird zurzeit nicht analysiert (Makros unter
   CodeQL, docs/TESTFLIGHT.md); Befund von Hand geprüft.“ Vorher kurz lesen: ein echter
   Befund dort ist weiter ein Befund, nur prüft ihn niemand mehr automatisch.
2. Falls in den Branch-Regeln (Settings > Branches oder Rules) „Analyze (swift)“ als
   Pflicht-Check eingetragen ist: entfernen, denn er läuft bei Pull Requests nicht mehr.
3. Settings > Code security > Code scanning: „Default setup“ muss aus bleiben (die Datei
   `codeql.yml` ist das „Advanced setup“; beide zugleich gehen nicht).
4. Beim ersten Lauf nach dem Zusammenführen laufen alle UI-Gruppen einmal (ältere Läufe tragen
   noch keine Fingerabdrücke). Erst danach werden Ergebnisse übernommen.

## Hochladen ohne Klick (Entscheidung Fuchs 19.11.2026; ersetzt Nr. 5 vom 18.11.)

Ein Build geht von selbst zu TestFlight, nur von `main` und nur, wenn jedes Tor seines Laufs grün
ist: CI mit seinem Tor, UI-Tests und UI-Tor, Härtetest, Release-Kurztest und die früheren Versuche
des Laufs (`earlier_attempts.py`: ein roter Test wird nie durch Wiederholen grün). Keine Eingabe
überspringt eines davon. Der Upload-Job von `testflight.yml` läuft in der GitHub-Umgebung
`testflight-upload`, die nur der Zweig `main` benutzen darf. Die vier Secrets (`ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`) liegen nur dort: GitHub gibt sie allein diesem Job.
Kein anderer Job eines Workflows nennt sie (Test in `.github/scripts/tests/test_workflows.py`); die
Jobs davor brauchen sie nicht.

- **Einrichten** (einmalig, etwa 5 Minuten): `docs/launch/FREIGABE_EINRICHTEN.md`. Bis dahin
  hält jeder TestFlight-Lauf im ersten Job „Upload setup“ an (vor jeder Mac-Minute), und der
  tägliche Build startet nicht.
- **Warum der erste Job das prüft** (`.github/scripts/upload_approval.py`): nennt ein Job eine
  Umgebung, die es noch nicht gibt, legt GitHub sie ohne jede Regel an, und der Job liefe von
  jedem Zweig aus. Der erste Job lässt den Lauf darum nur weiter, wenn die Umgebung besteht und
  nur der Zweig `main` sie nutzen darf (genau eine Regel `main`; fehlt sie, oder steht dort
  „Protected branches“, ein Muster, ein zweiter Zweig oder eine Tag-Regel, hält der Lauf an). Diese
  Regel ist jetzt der einzige Zaun: wer auf `main` schreiben darf, kann hochladen; den Schutz von
  `main` stellst du in den Einstellungen ein (P5-09). Verlangt dort nichts einen Pull Request für
  `main` (weder ein Ruleset noch der klassische Zweigschutz), steht im ersten Job die Warnung
  „main ist nicht geschützt: wer auf main pushen kann, kann hochladen“ (nur eine Warnung, der
  Lauf geht weiter); kann der Lauf den klassischen Zweigschutz nicht lesen (er braucht dafür
  Admin-Rechte), sagt die Warnung das. Ist noch ein Prüfer eingetragen, steht eine
  Warnung im Lauf, und der Upload wartet weiter auf deinen Klick. Ob die alten Repository-Secrets
  gelöscht sind, kann kein Job prüfen, ohne sie zu lesen: das ist Schritt 5 der Anleitung.
- Der Upload-Job prüft zuerst, dass alle vier Secrets da sind (nur ob, nie ihren Inhalt),
  liest die früheren Versuche des Laufs, archiviert, lädt hoch und setzt „Was testen“ (höchstens
  20 Minuten Warten, meist wenige).
- **Feedback-Abruf**: `asc-feedback.yml` hat einen eigenen Schlüssel mit Rolle Developer
  (Abschnitt „Abstürze und Feedback abholen“).
- **Privates Repository** (GitHub-Hilfe „Managing environments for deployment“, gelesen am
  19.11.2026): mit GitHub Free gibt es Umgebungen, ihre Secrets und ihre Zweig-Regeln nur in
  öffentlichen Repositorys; GitHub Pro, Team und Enterprise haben sie auch in privaten. Eine
  Regel, die die API in einem privaten Repository mit Free noch zeigt, setzt GitHub nicht durch,
  und der Lauf kann den Tarif nicht lesen. Darum hält der erste Job in einem privaten Repository
  immer an (mit Hinweis auf GitHub Free), außer die Repository-Variable `UPLOAD_PRIVATE_PLAN_OK`
  steht auf `true`; die setzt der Eigentümer erst, wenn sein Tarif Umgebungen in privaten
  Repositorys hat. Dann gelten dieselben Prüfungen wie im öffentlichen Repository.

## Zwei Tore: täglicher Build und Build für Tester (Entscheidung Fuchs 18.11.2026, Nr. 10)

| | Kleines Tor: täglicher Build, nur für dich | Großes Tor: Tester und App Store |
|---|---|---|
| Start | jeden Morgen um 03:30 UTC von selbst (`daily-build.yml`), wenn sich die App geändert hat; von Hand: TestFlight > Run workflow, **gate** `small` | von Hand: Actions > TestFlight > Run workflow, **gate** `big` (Vorgabe) |
| CI | Regeln, Kern-Tests Linux, iOS-Bau mit Kern- und App-Tests auf dem Mac | gleich |
| UI-Tests | nur die zwei kurzen Gruppen `flow-full` (ganzer Ablauf mit Video) und `contrast` (Kontrast), je Job rund 18 Minuten, nebeneinander | alle Gruppen (`auto`: jede ohne Grün für genau diese App und ihren Testcode) |
| UI-Tor | diese zwei Gruppen grün für genau diese App und ihren Testcode, keine davon je rot dafür | alle Gruppen, gleiche Regeln |
| Härtetest 10.000 Fotos | ja (vor jedem Upload: Regel 17.11., Entscheidung 4), neben den zwei Gruppen | ja |
| Release-Kurztest | ja (P5-03: die Release-Fassung einmal gestartet), daneben | ja |
| Bis zum Upload-Job | rund 70 Minuten (CI rund 20, dann bestimmt der Härtetest mit rund 45 die Dauer) | 2–2,5 Stunden (ohne UI-Gruppen rund 65–70 Minuten wie das kleine Tor) |
| Hochladen | von selbst, wenn alles grün ist (seit 19.11.2026; jeden Tag, an dem sich die App geändert hat) | von selbst, wenn alles grün ist (seit 19.11.2026) |
| Erkennbar an | Laufname „TestFlight daily build (small gate, only for the owner)“, Nachricht des Tags, letzte Zeile von „Was testen“ | Laufname „TestFlight“ |
| Für wen | nur dich (interne Tests); nicht an externe Tester geben | Tester und App Store |

- Beide Tore laufen in `testflight.yml` (Eingabe **gate**), damit Build-Nummern, Tags und „ein
  TestFlight-Lauf zur Zeit“ bleiben, wie sie sind. `daily-build.yml` (Linux, eine Minute, ohne
  Secrets) startet nur den Lauf; `.github/scripts/daily_build.py` entscheidet, ob.
- **Der tägliche Build startet nicht** (die Zusammenfassung von Actions > Daily build sagt,
  warum), wenn: die Umgebung `testflight-upload` noch nicht eingerichtet ist; ein TestFlight-Lauf
  läuft oder wartet; die App seit dem letzten hochgeladenen Build gleich ist (nur Doku, Tests
  oder Bau-Strecke geändert; derselbe Fingerabdruck der App wie bei den UI-Tests, verglichen mit
  den Tags `build-<Nummer>`); oder genau dieser Commit, oder ein früherer mit derselben App, nach
  dem nur Doku (`*.md`, `docs/`) dazukam, schon einmal in einem TestFlight-Lauf war (rot, abgelehnt
  oder abgebrochen): ein roter Test wird in einem neuen Commit behoben, der Code, Tests oder die
  Bau-Strecke ändert, nie durch Wiederholen grün, und einen abgelehnten Build bietet er nicht jeden
  Tag neu an, auch nicht, wenn danach nur Doku dazukommt. Von Hand geht es trotzdem.
- Der tägliche Build achtet nicht auf die Mac-Warteschlange (eigene Gruppen wie jeder
  TestFlight-Lauf); er braucht höchstens vier Macs zugleich (zwei UI-Gruppen, den Härtetest und den
  Release-Kurztest), um
  03:30 UTC sind die nächtlichen Läufe meist fertig.
- **Nicht in `nightly.yml`**: dessen Jobs sind seit 18.11. bewusst unverändert der Vergleichslauf
  für den StoreKit-Fall („no product“), und ein TestFlight-Build braucht die Laufnummern von
  `testflight.yml` (Build-Nummer) und dessen Gruppe `testflight`.
- **Kleines Tor = CI + `flow-full` + `contrast` + Härtetest + Release-Kurztest**, rund 70 Minuten
  bis zum Upload-Job. Den Härtetest verlangen deine Regel vom 17.11. und Entscheidung 4 vor jedem
  Upload, und auch der tägliche Build lädt hoch. Die Dauer bestimmt darum der Härtetest (rund 45
  Minuten nach CI), nicht die UI-Tests; die Fable-Analyse (P6-02) wünschte höchstens 20 Minuten.
