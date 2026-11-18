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
  Hochladen, wenn alle UI-Gruppen laufen (die UI-Tests allein 75–100 Minuten); laufen nur
  einzelne Gruppen oder keine (Abschnitt „UI-Tests: nur betroffene Gruppen“), bestimmt der
  Härtetest (rund 45 Minuten) die Dauer. Danach bis zu 50 Minuten, bis „Was testen“
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
  versagt hat: Runner oder Container nicht gestartet, Simulator nicht hochgefahren, gebaute Tests,
  Checkout oder XcodeGen (festgelegte Version 2.46.0 aus `.github/toolchain.json`, mit Prüfsumme, Schritt „Install XcodeGen“) nicht angekommen, Hochladen zu
  App Store Connect abgebrochen. Maßgeblich ist der Schritt, nicht die Ursache: geht der Runner
  mitten in einem Testschritt verloren (etwa „Run UI tests“), wird der Lauf dort abgebrochen
  oder hakt „Select pinned Xcode“ oder „Generate Xcode project“, braucht es ebenfalls einen
  neuen Lauf. Erlaubte Ausfälle stehen als Warnung in der Zusammenfassung des Upload-Jobs und in
  der Nachricht des Tags („attempt 2; earlier attempts: …“). Kann der Upload-Job die früheren
  Versuche nicht lesen (GitHub-API antwortet nicht), lädt er ebenfalls nicht hoch; dann nur ihn
  wiederholen. Die gebauten UI-Tests bleiben für **Re-run failed jobs** 3 Tage liegen; danach
  einen neuen Lauf starten. Dasselbe gilt über Läufe hinweg: war eine UI-Gruppe für genau diese
  App und genau ihren Testcode einmal rot, zählt ein späteres Grün derselben Kombination nicht,
  auch nicht aus einem anderen Lauf. Erst eine Änderung am Test oder an der App (die Korrektur)
  macht sie wieder hochladbar.
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
  das jede Gruppe läuft: die Skripte `ui_tests.py`, `pick_simulator.py`, `toolchain.py` und die
  Workflows `ui.yml` und `testflight.yml` (eine Änderung daran lässt also alle Gruppen laufen).
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
  Ergebnis nur, wenn Git für den Commit dieses Laufs dieselben Fingerabdrücke ausrechnet, und
  nur aus diesem Repository (nie aus einem Fork).
- **Lückenlos gelesen**: Plan und Gate lesen jeden Lauf von `ui.yml` und `testflight.yml` seit
  dem ersten Commit mit diesem App-Fingerabdruck (Seite für Seite, ohne Obergrenze vor dem
  Filter). Geht das nicht vollständig (mehr als 1000 Läufe eines Workflows in diesem Zeitraum,
  oder der Zeitraum ist älter als 85 Tage und GitHub hat ältere Läufe womöglich gelöscht),
  laufen im Plan alle Gruppen und das Gate ist rot: ein altes Rot darf nicht aus dem Blick
  fallen. Ein dauerhaftes Verzeichnis der roten Ergebnisse außerhalb von GitHubs Laufliste
  gibt es nicht (es bräuchte ein Schreib-Token in den Testläufen; Artefakte laufen ab wie die
  Läufe).
- **Beispiel** (die Nacht zum 18.11.): Commit 4bb7fdd änderte nur eine Wartezeit in
  `SortlyFlowUITests.swift`. Bisher liefen danach alle fünf Gruppen (über 80 Minuten). Jetzt
  laufen „voller Ablauf“ und „übrige Abläufe“ (beide haben Tests in dieser Datei);
  Gerätezustände, Barrierefreiheit und Kontrast übernimmt der Lauf aus dem letzten grünen Lauf
  mit derselben App und demselben Testcode. Die Zusammenfassung des Jobs „UI plan“ zeigt für
  jede Gruppe, woher ihr Grün kommt oder warum sie läuft.
- **Rot bleibt rot** (wie bei „Re-run failed jobs“): Ist eine Gruppe für dieselbe App und
  denselben Testcode irgendwann rot gewesen (der Schritt „Run UI tests“ hatte begonnen und ist
  nicht grün geworden: ein Test gescheitert, Zeitlimit, Lauf abgebrochen, Runner verloren),
  zählt kein späteres Grün dieser Kombination, egal aus welchem Lauf. Ein
  wackelnder Test wird so gezählt und behoben, nie durch Wiederholen versteckt. Die Gruppe darf
  zur Beobachtung noch einmal laufen; ihr Grün steht dann als „red before for this key“ in der
  Tabelle und zählt für TestFlight nicht. Kein Ergebnis (weder Rot noch Grün) ist nur, was
  keinen Test gestartet hat: „Run UI tests“ hat nie begonnen (Simulator nicht gestartet,
  Lauf vorher abgebrochen, gebaute Tests fehlen: Schritt „Built tests present“), oder der
  Simulator ging in jedem Durchgang vor dem ersten Test verloren (`ui_tests.py` endet mit 75,
  der Job scheitert im eigenen Schritt „Simulator lost before the first test“). Wurde ein Rot
  nur durch eine gemeinsame Datei (Hilfsdatei, Skript, Workflow) zu einem neuen Schlüssel,
  ohne dass sich eine eigene Testdatei der Gruppe änderte, warnen Plan und Gate („UI red
  cleared by a shared change“): prüfen, ob das wirklich die Korrektur war.
- **Längere Wartezeiten in Tests brauchen einen gemessenen Grund** (Regel 17.11.): wer ein
  `timeout` oder eine Wartezeit verlängert, nennt im Commit die Messung (Lauf und gemessene
  Sekunden), so wie 4bb7fdd („say how long it took“). Eine reine Verlängerung ohne Messung ist
  keine Korrektur.
- **TestFlight**: der Lauf ruft die UI-Tests mit „auto“ auf. Vor dem Hochladen prüft der Job
  **UI gate** auf Linux, dass jede Gruppe für genau diese App und ihren Testcode grün ist (aus
  diesem Lauf oder einem früheren) und keine dafür rot war. Seine Zusammenfassung nennt jede
  übernommene Gruppe mit Lauf und Commit und listet deren wackelnde Tests (Test erst in der
  Wiederholung grün); das Tag `build-<Nummer>` nennt sie ebenfalls („UI groups: device reused
  from run …“). Antwortet die GitHub-API nicht, lädt der Lauf nicht hoch; dann nur diesen Job
  wiederholen.
- **Urteil jedes UI-Laufs**: der letzte Job **UI verdict (full)** bzw. **UI verdict (quick)**
  macht dieselbe Prüfung wie das Gate von TestFlight, auch wenn keine Gruppe laufen musste.
  Das Freigabe-Gate (`ci_gate.py`, Workflow „Release“) verlangt einen grünen Job
  „UI verdict (full)“.
- **Schnellmodus** (`quick`): Pull Requests laufen schnell. Die Tests bekommen
  `SORTLY_UI_QUICK=1` (im Workflow als `TEST_RUNNER_SORTLY_UI_QUICK`), und der lange
  Gerätetest (test11, große Mediathek) überspringt sich. Eine Gruppe, deren Dateien diesen
  Schalter lesen, hat im Schnellmodus einen anderen Test-Fingerabdruck, und ihr Job heißt
  „… (quick)“. Ein schnelles Grün zählt nie als volles: TestFlight und die Freigabe verlangen
  volle Ergebnisse. Ein schneller Lauf darf dagegen ein volles Grün übernehmen. Für die
  Freigabe eines Commits, der nur schnelle Läufe hat: „UI flow“ von Hand ohne `quick` starten;
  dann laufen nur die Gruppen, deren schneller und voller Testcode sich unterscheiden.
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
- Die Warnung „cache poisoning“ in `nightly.yml` ist begründet und abgesichert: kein Workflow
  liest einen Actions-Cache (ein Test prüft das), der nächtlich getestete Stand kommt nur aus
  diesem Repository, und er bekommt kein Token.

## Schritte für den Besitzer (18.11.2026)

1. Nach dem Zusammenführen: Security > Code scanning. Die ReDoS-Warnung schließt sich beim
   nächsten Scan von selbst. Bleibt „Cache poisoning“ in `nightly.yml` offen: die Warnung öffnen
   > **Dismiss alert** > „Won't fix“, Begründung: „Kein Workflow liest einen Actions-Cache
   (test_workflows.py), Ref nur aus diesem Repository, persist-credentials: false.“
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
