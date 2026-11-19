# Changelog

## 0.1.0 (in Entwicklung)
### Hinzugefügt
- Neue Fortschrittsanzeige der Analyse (Entwurf v3 mit den 5 Punkten vom 15.11.): ein Balken in
  6 Abschnitten nach Zeitanteil, „Fertig gegen 23:40“ für die ganze Analyse, gleitender Balken,
  „Schon fertig: 51 Reisen, 38 Orte · Ansehen“, Fertig-Moment mit Häkchen, Details-Blatt,
  Wartezustände ohne das Wort „Pause“, Sperrbildschirm „2.431 von 5.683 Fotos · fertig gegen 23:40“
  und Mitteilung „Analyse fertig“ mit dem Knopf „Vorschläge prüfen“.
- Kernlogik: Reisen, häufige Orte, Orte (Offline-Karte + gedrosselter Geocoder), Chronologie,
  Medientypen, Screenshots, Themen, Dokumente, Messenger-Hinweise, Regeln, Suche, Status.
- Abgleich mit vorhandenen Alben und Erkennung ähnlicher Alben.
- Änderungspläne mit Vorschau, sicherer Ausführung, Wiederanlauf und Rückgängig.
- SQLite-Store mit Migrationen v1–v2.
- Fortsetzbare Analyse-Pipeline mit Probelauf und nächtlicher Verfeinerung.
- iOS-App: Einführung, Übersicht, Vorschläge, Umsetzen, Mediathek, Alben, Suche,
  Einstellungen, Verlauf; Einmalkauf; Kurzbefehl; Datenschutz-Manifest.
- Teilbarer „Reise-Atlas“ im Apple-Stil: Weltkarte der besuchten Länder, Kennzahlen,
  Teilen-Bild mit Vorschau und optionalem Foto vom Lieblingsziel.
- Foto-Geschichte mit Apple Intelligence (Reisen, Jahre, ganze Mediathek), in der App-Sprache.
- Englische Übersetzung (App, Info.plist, Kurzbefehle).
- Optional mit Apple Intelligence: Suche in ganzen Sätzen, Namensvorschläge für Reisen.
- CI: Tests auf Linux und macOS, App-Build im Simulator, Simulator-ZIP und automatischer Upload zu Appetize (mit Secret `APPETIZE_TOKEN`).
- Atlas: Land antippen zeigt seine Fotos, nach Jahren, mit den meistfotografierten Orten und
  dem passenden Albumvorschlag.
- „Album passt nicht“: ein vorgeschlagenes vorhandenes Album lässt sich ausschließen; unter
  „Anpassen“ ist jedes bearbeitbare Album wählbar.
- Siri, Kurzbefehle und Spotlight: „Fotos aus Italien in Albumist“, „Offene Vorschläge“,
  Vorschlag öffnen; Spotlight findet Länder und offene Vorschläge.
- iOS-26-Glasknöpfe (`glassProminent`/`glass`), Vibration beim Fertigwerden und bei Fehlern.
- Logiktest des ganzen Entscheidungs-Ablaufs (übernehmen, umsetzen, rückgängig, löschen,
  ablehnen, 40 zufällige Abläufe mit Invarianten).
- Anleitung und Skript für eine unabhängige Code-Prüfung (`docs/review/`, `tools/make_review_zip.sh`).
- Sicherung der Entscheidungen (I12): Regeln, Ausnahmen, Einstellungen, eigene Namen, die Alben
  von Albumist und der Verlauf liegen zusätzlich als kleine Datei im Geräte-Backup. Nach einem
  Neuaufbau der Datenbank oder auf einem neuen iPhone kommen sie zurück; Alben und Verlauf nur,
  wenn die Sicherung zur Mediathek passt. Hinweiskarte in der Übersicht, Stand unter „Verlauf“.
  „Neu aufbauen“ nach einem Startfehler startet die Analyse jetzt sofort.
- Änderungsbeleg (I01): jede Zeile im Verlauf und das Ergebnis nach dem Umsetzen öffnen eine
  Seite mit dem, was Albumist wirklich geändert hat (nur nachgeprüfte Schritte), jedem Album,
  „0 Originale gelöscht, bearbeitet, kopiert“, nicht Erledigtem und dem Rückgängigmachen.
  Als Text teilbar. Englisch „Verschoben“ heißt jetzt „Moved“ (war „Postponed“).
- Geführte Reparatur (I16): ein unterbrochenes Umsetzen bietet „Fortsetzen“, „Rückgängig machen“
  und „So lassen“; Fehler stehen im Änderungsbeleg in Klartext, mit „Fehlendes erneut versuchen“
  (legt nur an, was fehlt; der Plan sagt das auch). Was du nach einer Unterbrechung so gelassen
  hast, zählt im Beleg nicht als Fehler. „Diagnose teilen“ in den Einstellungen und im Beleg:
  Zustände, Zahlen und Fehlercodes, keine Fotos, Namen oder Orte.
- Reise-Werkstatt (I07): Im Reise-Vorschlag „Reise teilen oder zusammenlegen“. Teilen an einem Tag
  mit Vorschau der zwei Reisen, Zusammenlegen mit der Reise davor oder danach (bis 14 Tage
  Abstand). Albumist hält sich daran bei jeder späteren Analyse. „Aufheben“ an der Reise nimmt
  eine Änderung zurück, „Reisen wieder automatisch erkennen“ in den Einstellungen alle. Nur solange das Reise-Album noch nicht angelegt ist.
### Geändert
- 18.11. (Entscheidungen Fuchs 1 und 2, Fable P1-05/P1-06): Eine Bedeutung für „sortiert“.
  Ignorierte Fotos zählen im Ring nicht mehr mit (weder sortiert noch offen); der Ring erreicht
  100 %, sobald alles nicht Ignorierte sortiert ist, und „Ignorieren“ vergrößert nie die Zahl
  hinter „von“. Die Übersicht nennt sie unter „Außerdem nicht mitgezählt: … 10 ignorierte Fotos“. Die
  Liste „Sortiert“ in der Mediathek zeigt genau die Zahl des Rings, „Nicht sortiert“ den Rest
  seiner Gesamtzahl (eine Funktion für beide: `OrganizationStatusResolver.ringPart`). Fotos, die
  der Ring nicht zählt (kein Hauptbereich, etwa zu Hause, oder außerhalb von „Nur 2026“), stehen
  nur noch unter „Alle“; ihr Status in den Foto-Infos heißt „Nicht mitgezählt“ (bei einem
  anderen Jahr mit dem Grund „Albumist zählt gerade nur Fotos aus 2026.“). Der Ring zeigt „100 %“
  erst, wenn alles sortiert ist (vorher rundete 199 von 200 auf 100 %); nach dem Wechsel des
  Jahres zählt er sofort neu; die Suche „nicht sortiert“ findet genau die Liste „Nicht sortiert“.
- Bau-Strecke (Entscheidungen 5 und 10 vom 18.11.): TestFlight lädt nur noch nach der Freigabe von
  Fuchs hoch. Der Upload-Job läuft in der GitHub-Umgebung `testflight-upload`, nur dort liegen die
  Apple-Schlüssel; der erste Job hält den Lauf an, solange die Umgebung keinen Prüfer verlangt
  oder nicht nur der Zweig `main` sie nutzen darf (Anleitung `docs/launch/FREIGABE_EINRICHTEN.md`). Neu: ein täglicher Build mit kleinem Tor
  (`daily-build.yml`: CI, die UI-Gruppen „ganzer Ablauf“ und „Kontrast“ und der Härtetest, der vor
  jedem Upload läuft; rund 70 Minuten, nur an Tagen mit geänderter App); das große Tor mit allen
  UI-Gruppen und Härtetest bleibt für Tester und App Store. „Was testen“ nennt das kleine Tor; der
  Feedback-Abruf hat einen eigenen Schlüssel.
- 19.11. (Entscheidung Fuchs per Karte): TestFlight lädt ohne Klick hoch, nur von `main` und nur
  mit allen Toren grün; der erste Job „Upload setup“ prüft die Umgebung `testflight-upload`
  (nur Zweig `main`), ein privates Repository nur mit der Planvariable, ein Re-Run nach einem
  Upload lädt nie ein zweites Mal hoch. Vor dem Upload wird der Release-Build selbst kurz
  UI-getestet (Rauchtest), höchstens fünf Macs je Lauf.
- „Gleicher Name gewinnt“ (Fable P1-02): Gibt es genau ein bearbeitbares Album mit dem Namen eines
  Vorschlags, ergänzt Albumist dieses Album, auch unter den Inhaltsschwellen. Ein Album, das den
  ganzen Vorschlag schon enthält, gewinnt vor dem Namen; Fotos ohne Ort zählen für jedes andere
  Album weiter, der Ring sinkt dadurch nie (Abgleich Version 6).
- Diagnosebericht: Akkuverbrauch der Analyse „etwa höchstens N % pro 1.000 Fotos“ und Zahlen aus
  MetricKit (Hänger, Akku), ohne Fotos, Namen oder Orte.
### Korrigiert
- 19.11.: Im Tab „Alben“ steht jedes Album nur noch einmal: „Deine Alben“ lässt die Alben weg,
  die schon unter „Von Albumist angelegt oder ergänzt“ stehen (P3-16 = G3-02).
- 19.11.: Die Foto-Großansicht baut nur noch die Seiten um das gezeigte Foto (50 davor und
  danach) statt aller geladenen Fotos und schiebt sie beim Blättern nach (P4-11).
- 19.11.: Fotos mit einem Datum in der Zukunft bleiben nicht mehr für immer unsortiert (P1-03);
  ein als unlesbar aufgegebenes Foto wird eine Woche später noch einmal versucht (P1-08); Fotos,
  deren Land sich nicht finden lässt, gelten nicht mehr für immer als offen (P1-09); die
  Umkreis-Suche findet jedes Foto im Kreis (G1-01); eine Reise über die Datumsgrenze bleibt ein
  Halt. Reisen bearbeiten: kann das Neuberechnen nicht starten, werden die Knöpfe wieder frei;
  nach einem Fehler folgt genau ein weiterer Versuch.
- CI 19.11.: Die Ubuntu-Paketquelle war eine Viertelstunde nicht erreichbar, die Linux-Kerntests
  auf `main` liefen nie. Pakete kommen jetzt über `apt_install.sh` (20 s Grenze, Wiederholung,
  zweite Paketquelle, jede Wiederholung gezählt).
- UI-Tests: jede Gruppe wartet vor ihrem ersten Test (und vor einer Wiederholung) bis zu 5 Min.,
  bis der Simulator nach seinem Start wieder schnell antwortet (`SIM_SETTLE`);
  vorher verlor XCTest dabei die App beim ersten Start (UI-Lauf 44437759848, test05).
- Prüfung 18.11. (Zuhause): Albumist erkennt das Zuhause jetzt an den Fotos des ganzen Tages,
  nicht nur an den ersten 15. Wer morgens regelmäßig woanders fotografiert (etwa bei der Arbeit),
  bekommt den Alltag zu Hause nicht mehr als Reise vorgeschlagen; ebenso beim Ort eines
  Urlaubsziels, an das du öfter fährst.
- Prüfung 18.11. (häufige Orte): Zwei häufige Orte dicht beieinander (etwa Haus und Garten
  gegenüber) hatten eine gemeinsame Kennung, ein Name oder „Nicht jetzt“ galt für beide. Jetzt
  hat jeder Ort seine eigene und behält sie über seine Fotos, auch wenn Fotos dazukommen oder
  wegfallen. Name, „Nicht jetzt“ und Album bleiben bei dem der beiden Orte, den Albumist bisher
  gezeigt hat; der andere erscheint als neuer Vorschlag und braucht wieder einen Namen.
  Ein Album, das Albumist für einen Vorschlag angelegt hat, wird nur noch mit dessen Fotos
  ergänzt; ein angenommenes „ergänzen“ in das Album eines früheren Orts ist nach der Analyse
  einmal wieder offen („Vorschläge neu geprüft“); wählst du dasselbe Album wieder, bleibt es. Ein leeres Album nach einem abgebrochenen Plan füllt
  der nächste Plan, statt ein zweites gleichen Namens anzulegen.
- iPhone-Test Build 36: Ein Ort, an dem du öfter bist, heißt jetzt nach seiner Stadt (etwa
  „Dorfen“), nicht mehr nach dem Bundesland („Bayern“).
- iPhone-Test Build 36: Derselbe Ort kam zweimal, als Ort, an dem du öfter bist („Bayern“), und
  als häufiger Ort („Häufiger Ort in Zwiesel“). Jetzt einmal, als Ort, an dem du öfter bist.
  Hast du dem häufigen Ort in der App einen Namen gegeben, ihn zum Erstellen ausgewählt oder
  hat er schon sein Album, bleibt er; ebenso ein Ort, an dem du öfter bist, den du ausgewählt
  hast oder der sein Album hat. Sagst du zu einem der beiden „Nicht jetzt“, bleibt der andere.
  Ein kleiner Lieblingsort in einer großen Urlaubsgegend bleibt ein eigener Vorschlag. Bleibt
  der häufige Ort, sind Fotos, die nur der Ort hatte, an dem du öfter bist, in keinem dieser
  beiden Vorschläge; ohne anderen Vorschlag (etwa das Album ihrer Stadt) bleiben sie „Nicht
  sortiert“. Ein in der App benannter häufiger Ort zählt
  nicht zu den höchstens fünf unbenannten und bleibt auch neben einem fast gleichen Ort mit
  Album.
- Prüfer B 18.11. (UI-Tests): Ein roter UI-Test bleibt rot, wenn nur Kommentare oder Einrückung
  seiner Testdatei geändert werden (G5-04). Ein Bildschirm, dessen Barrierefreiheits-Prüfung
  zweimal nicht fertig wird, lässt den Test scheitern statt nur zu warnen (G5-06). Der Härtetest
  scheitert, wenn die Analyse nicht vorankommt oder Pause und Fortsetzen nie versucht wurden
  (G5-07). Der Kauf-Test scheitert, wenn die Freischalt-Karte fehlt, obwohl der Plan mehr Alben
  braucht als frei sind (G5-09).
- Gerätetest 18.11. (Build 36): Während der Analyse stand „Apple antwortet gleich“ 20–30 s lang
  mit stehender Zahl. Apple war nicht langsam, Albumist bremste sich selbst (höchstens 40
  Ortsabfragen pro Minute, im Lauf aber 60 erlaubt; nach einer Ablehnung bis zu 30 s Warten).
  Kein Lauf außer der nächtlichen Verfeinerung wartet jetzt auf Apple (auch nicht im
  Hintergrund): Er fragt nur so oft, wie es ohne Warten geht (Abfragen eines Laufs kurz davor
  zählen mit), und hört an der Grenze oder bei der ersten Ablehnung sofort auf; dann fragt ein
  Lauf in der App eine Stunde lang nicht wieder. Die übrigen Ortsnamen kommen mit einem späteren
  Lauf oder der nächtlichen Verfeinerung. Wird die App während der Verfeinerung geöffnet, zeigt
  die Karte sie jetzt als eigenen Lauf (Schritt, Zahl, Balken; vorher stand dort ohne ein Wort
  der Stand des letzten Laufs), und wartet sie auf Apple, sagt sie warum, mit Countdown:
  „Ortsnamen: Apple erlaubt nur einige Abfragen pro Minute · weiter in 25 s“, über einer Minute
  „weiter in 2 Minuten“. Nach einer Wartezeit nimmt eine Abfrage ihren Platz in Albumists Grenze
  neu, statt sich nur einzutragen.
- Entscheidungen Fuchs 18.11. (Punkte 3, 8 und 14 der Rückgabe): Der erste Bildschirm sagt
  „Kein Foto wird hochgeladen“ statt „Nichts wird hochgeladen“; die Zugriffs-Seite sagt in einem
  Satz, dass iOS für Ortsnamen einzelne Aufnahmeorte (nur Koordinaten und die Sprache der
  Ortsnamen) an Apples Kartendienst schickt und dass man das in den Einstellungen ausschalten
  kann. Der Schalter „Orte online
  genauer bestimmen“ bleibt ab Werk an; Einstellungen, Datenschutz-Seite, Website und
  Store-Texte sagen dasselbe. Umstrittene Gebiete (Krim, Westsahara, Kaschmir, Nordzypern,
  Kosovo, Taiwan, Golanhöhen, Abchasien) bekommen kein Land mehr: Das Gebiet heißt mit seinem
  eigenen Namen („Krim“), sein Vorschlag ist „Unsicher“ mit der Begründung „Umstrittenes
  Gebiet …“; Städte darin behalten ihren Namen. Das gilt auch auf dem Wasser davor (Krim mit
  der Straße von Kertsch, Taiwans Inseln mit Penghu, Matsu und Pratas) und an der Grenze, wo
  Apples Antwort die Seite bestimmt: nennt Apple dort das Gebiet oder eine Region darin, bleibt
  der Ort „Unsicher“. Nennt Apple an der Grenze das Nachbarland, gilt dieses (siehe
  `KNOWN_LIMITATIONS.md`). Die Golanhöhen enden im Westen an der Linie von 1949 (Gonen, Kfar
  Szold und Kibbutz Dan bleiben in Israel); im Osten und auf dem Hermon reichen sie bis an die
  Linie von 1974, so weit die Karte dort Israel zeichnet (vorher hieß etwa Alonei HaBashan
  „Israel“). Auch Lieyu (Klein-Kinmen), Dadan, Erdan, Wuqiu und Dongding, die die Karte nicht zeichnet,
  und die Gewässer im Norden Zyperns sind „Unsicher“ (vorher entschied Apples Antwort: „China“
  bzw. „Republik Zypern“). Die Atlas-Karte und das Teilen-Bild füllen ein umstrittenes Gebiet
  nie mit einem besuchten Land (die Krim nicht mit Russland, Nordzypern nicht mit Zypern,
  Kaschmir nicht mit Indien oder Pakistan); es bleibt Landfarbe, ausgeschnitten statt übermalt
  (kein Rand in der Farbe des Landes), und ein Tippen darauf öffnet kein Land mehr (vorher
  öffnete die Krim „Russland“). Ein Tippen neben ein kleines besuchtes Land misst jetzt bis
  zu seiner Küste oder Grenze, nicht bis zu der eines umstrittenen Gebiets darin (vorher öffnete etwa ein Tippen auf Paris „Russland“, wenn nur
  Russland besucht war). Auch ein Streifen zwischen Sewastopol und der übrigen Krim, Ränder vor Jewpatorija und bei Perekop blieben in der Farbe Russlands, weil die Karte Russland und die Regionen der Krim jedes für sich vereinfachte; Länder mit umstrittenen Regionen und diese Regionen behalten jetzt jeden Punkt. Der Text der Fotozugriffs-Frage
  sagt „Kein Foto wird hochgeladen“ wie alle anderen Texte. Eine Stadt aus Apples Antwort gilt nur, wenn das
  gefragte Foto auf derselben Seite der Linie liegt wie das Foto, um das es geht. Im Reise-Atlas
  zählt ein Gebiet nicht als Land, seine Reisen und Orte zählen aber und tragen den
  Gebietsnamen; „Ausland“ in der Suche und das erkannte Zuhause kennen die Gebiete. Orte, die
  vor dem Update bestimmt wurden, behalten ihr altes Land, bis „Analyse neu aufbauen“ sie neu
  bestimmt. Die Store-Texte versprechen „Länder, auf Wunsch auch
  Städte“ statt Städte-Alben ab Werk (Standard bleibt: nur Länder).
- Gratis-Alben nach Rückgängig (Prüfung 18.11.): Gibt ein Rückgängig Alben aus der alten
  Gesamtzahl (Versionen vor der Zählung je Plan) zurück, merkt sich Albumist das jetzt je Plan.
  Gingen die beiden Kopien der Zählung (Einstellungen, Schlüsselbund) auseinander, weil die App
  zwischen den beiden Schreibvorgängen endete, nahm das Zusammenführen beim nächsten Start die
  Rückgabe wieder weg (die Alben zählten dauerhaft weiter). Rückgaben summieren sich nie über
  die erlaubte Zahl hinaus, und ältere Versionen lesen weiter, was noch zählt. „Rückgängig
  gemacht“ erscheint erst, wenn die Zählung geschrieben ist (vorher erst nach der langsamen
  Abfrage bei Fotos). Gesperrte UI-Läufe starten mit einer festen Zahl, die kein Rückgängig
  eines früheren Laufs mehr erhöht (auch nicht nach einem Neustart mitten im Abschluss).
- Gerätetest 18.11. (dunkler Modus): Bei einem Ort, den nur du benennen kannst („Häufiger Ort in
  Zwiesel“), sah man nicht, wo der Name hingehört. Das Feld mit dem Ortsnamen als grauem
  Platzhalter wirkte wie ein Titel, sein Rand verschwand im Dunkeln, und der Knopf sagte nur
  ausgegraut „Erst einen Namen eingeben“. Jetzt bleibt der Ort der Titel; darunter steht „Name
  für das Album“ als Formularzeile wie in den Einstellungen von iOS, mit Beispielen („z. B. Bei
  Oma, Garten, Ferienhaus“) und dem Hinweis „Albumist benennt persönliche Orte nie selbst.“ Der
  Knopf „Namen eingeben“ öffnet die Tastatur im Feld, mit Namen wird er zu „Album anlegen“. Die
  Eingabetaste schließt nur die Tastatur; angelegt wird nur über den Knopf. Der getippte Name
  steht auch unter „Anpassen“ bei „Titel“ (dort war „Dahoam“ verschwunden), eine Änderung dort
  steht danach wieder im Feld, und er bleibt, wenn man zwischendurch alle Fotos ansieht.
  Gespeichert wird er erst, wenn du ein Album wählst oder anlegst. UI-Test test7.
- iPhone-Test Build 36: Vorschaufotos, Titelbilder, Farbschein, Sortier-Show, „Gerade angesehen“
  und das Atlas-Bild zeigen keine sensiblen Dokumente mehr (Bankkarte, Kontoauszug, Ausweis,
  Arztbrief; „Häufiger Ort in Zwiesel“ zeigte eine Karte mit lesbarer Nummer), wenn die Analyse
  sie erkannt hat (Grenzen: `docs/KNOWN_LIMITATIONS.md`). Im Zweifel ausgeblendet: auch eine
  Karte ohne lesbare Nummer und jedes Bild, das die Bildanalyse für ein Dokument hielt und sein
  Text nicht erklärt. Noch nicht angesehene Fotos kommen nach den angesehenen. Bildschirmfotos
  und Dokumente füllen nur Plätze, für die es zu wenige gewöhnliche Fotos gibt; sonst zeigt die
  Vorschau weniger Kacheln, „+N“ zählt weiter alle Fotos, und nichts wird aus Vorschlägen oder
  Alben genommen. Vierte Prüfung: der Vorschlag „Rezepte“ zeigt seine Rezept-Screenshots wieder
  („Rezept“ machte sie zu medizinischen Papieren); Bildschirmaufnahmen bleiben bewusst
  ausgeblendet; Kartenwörter auch mit schmalen und ideografischen Leerzeichen, neben
  chinesischen und japanischen Satzzeichen und in Vollbreite („ＶＩＳＡ“).
- Reise-Werkstatt während einer Pause (Entscheidung 18.11.2026, „Analyse läuft dann weiter“):
  Wer die Analyse pausiert hatte und dann eine Reise teilte, zusammenlegte, eine Änderung
  aufhob oder in den Einstellungen „Reisen wieder automatisch erkennen“ wählte, dessen Änderung
  wurde gespeichert, aber nicht angewendet: die Werkstatt drehte ohne Ende, die alten Reisen
  blieben, ohne Hinweis. Jetzt startet die Analyse, die die Änderung anwendet, sofort wie nach
  einem Tippen, und die Pause endet. Was von selbst startet (Start der App, Wiederholungen,
  Änderungen in Fotos oder an Einstellungen), wartet weiter auf „Fortsetzen“. Die Bestätigungen
  sagen das vorher („Die pausierte Analyse läuft dann weiter.“). Setzt die Änderung eine lange
  Analyse fort, wartet die Werkstatt nicht mehr darauf: „Gespeichert. Albumist wendet die Änderung
  an, sobald die Analyse fertig ist.“, und das Blatt lässt sich schließen.
- Reise-Werkstatt: Das Blatt lässt sich auch schließen, während es auf den Lauf einer Änderung
  wartet; die Änderung ist dann schon gespeichert. Begann zwischen dem Speichern und dem Start ein
  anderer Lauf, folgt ihm ein weiterer, der die Änderung sicher anwendet. Während einer Pause sagen
  auch „Reise teilen“ und „Deine Änderungen“, dass die pausierte Analyse dann weiterläuft.
- Reise-Werkstatt: „Gleich wieder möglich“ steht nur noch bei einer kurzen Prüfung, nicht bei einer
  mit eigener Arbeit (Labels nach „Themen“, viele neue Fotos) oder der nächtlichen Verfeinerung.
  VoiceOver sagt an jedem grauen Knopf, warum er wartet.
- Reise-Werkstatt (UI-Lauf 44375768011): Direkt nach dem Teilen war „Mit der Reise danach
  zusammenlegen“ gesperrt, solange Albumist die Reisen neu rechnete, sah aber tippbar aus und sagte
  nichts. Jetzt sind „Zusammenlegen“, „Aufheben“, „Reise teilen“ und in den Einstellungen „Reisen
  wieder automatisch erkennen“ in dieser Zeit grau, und darunter steht mit kleinem Ladekreis,
  warum: „Albumist rechnet die Reisen gerade neu. Gleich wieder möglich.“ (während der ersten
  Analyse „Albumist analysiert gerade deine Fotos. Danach wieder möglich.“, beim Anlegen „Albumist
  legt gerade Alben an. Danach wieder möglich.“). Danach werden sie von selbst wieder aktiv.
- Testplan widersprach sich (Prüfung 18.11., G6-06): er verbot TestFlight mit offenen Fällen und
  führte selbst 77. Jetzt gilt der Abschnitt „Tore“ (Entscheidungen 10 und 12): der tägliche Build
  für Fuchs (noch nicht gebaut) braucht die schnellen Tests und einen kurzen Bedienungsdurchgang,
  Builds für Tester und den App Store dazu alle UI-Gruppen, den kleinen Härtetest und keinen Fall
  mit ⛔. Jeder offene Fall ist am Code geprüft: 36 jetzt mit ihrem Test belegt, 2 nur am iPhone
  prüfbar, 1 sperrt (G1: das Zuhause wird zur Reise, ein fester Ort heißt „Bayern“), 39 offen mit
  Grund, warum sie nicht sperren. Neu: „Am iPhone prüfen“ für Fuchs und die Lücken in den Tests
  selbst (G5).
- CI: der frische Simulator in `ci.yml` wartet wie die UI-Gruppen, bis er schnell antwortet
  (`ui_tests.py settle`), statt auf eine Last unter 3,5, die die Macs nie erreichen (wartete
  jedes Mal die vollen 5 Min.).
- UI-Gerätetests: vor einem Neustart beendet in CI der Mac die laufende App (`simctl terminate`),
  nicht XCTest, dessen Beenden bei einer ruhenden App scheiterte (UI-Lauf 44446270757, test07).
- Fable-Analyse und Prüfungen 18.11.: Albumist schreibt die ID eines neuen Albums jetzt innerhalb
  derselben Änderung ins Protokoll, Rückgängig nach einem Abbruch nennt, was in Fotos bleibt;
  ein Protokoll, das Fotos hinterherhinkt, legt nichts doppelt an; „Fehlendes erneut versuchen“
  wartet auf Alben, die noch ankommen können; Zählen und Erkennen der Beispielfotos innerhalb
  der Lösch-Änderung. Suche: Grenzen auf beiden Seiten, „seit/vor/nach/bis“ als Zeiträume,
  „oder“ zwischen Grenzen. Orte behalten ihre ID beim Sprachwechsel und beim Neuaufbau;
  Jahreszeiten der Südhalbkugel; Schwärzen von IBAN, Karten und Ausweisen in mehr Schreibweisen;
  ein ganzer Tag zu Hause trennt eine Reise. Release-Tor: ein Grün nach Wiederholung zählt nie.
- Prüfungen 18.11. (G2-03, Nebenbefund): Ein englischer Arztbrief galt nicht als medizinisch
  („Diagnosis“ enthält „Diagnose“ nicht), sein Text und Betreff wurden gespeichert und waren
  suchbar. Jetzt erkennt Albumist auch englische Arztbriefe, Entlassberichte, Krankmeldungen,
  Laborberichte und ICD-Codes, auf Deutsch zusätzlich Entlassbrief, Anamnese, Medikation und
  Krankschreibung, „fit note“ und „sick leave“; Wortgruppen auch über zwei Zeilen, getrennte
  Wörter („Diag-⏎nosis“) und „doctors note“ ohne Apostroph. Schlüsselwörter zählen nur am
  Wortanfang: Hotelbestätigungen mit „Rezeption“, „Libanon“, „bicycle“ oder „please be patient“
  gelten nicht mehr als sensibel. Schon gespeicherte Texte solcher Briefe werden einmal entfernt
  (Masken-Version 5), ohne die Fotos neu zu lesen, auch wenn das Lesen von Text inzwischen aus
  ist; gelöschter Text wird in der Datenbankdatei überschrieben.
- Prüfungen 18.11. (G5-02/G6-02): Der TestFlight-Ablauf hatte noch den Notfall-Schalter
  „force“, der einen Build ohne jeden Test hochlud, obwohl Fuchs ihn am 17.11. gestrichen hatte.
  Er ist entfernt, samt `--forced` in `earlier_attempts.py` und `testflight_notes.py`; kein
  Workflow kann Tests, Härtetest oder UI-Tor mehr überspringen, und ein Test wacht darüber.
- Prüfung 18.11. (Suche): Einen Ort, dem du selbst einen Namen gegeben hast („Mein Kleingarten“),
  fand die Suche erst, wenn sein Album angelegt war. Jetzt findet sie ihn gleich unter diesem
  Namen und bietet ihn beim Tippen an, nach dem Umbenennen nur unter dem neuen, ohne Namen nicht
  mehr; mit dem Album danach bleibt es ein Treffer mit denselben Fotos. Groß- und
  Kleinschreibung, Umlaute (auch „ae“) und „ß“ spielen keine Rolle. Das gilt auch für einen Ort,
  an dem du öfter bist, wenn du ihn unter „Anpassen“ umbenennst. Der Name bleibt auf dem iPhone.
- Suche: Wer den Anfang eines Namens aus mehreren Wörtern tippte („Mein Klein“, „Tage am Me“),
  bekam ihn hinter die schon getippten Wörter ergänzt („Mein Mein Kleingarten“), und ein ganz
  getippter Name wurde noch einmal angeboten. Jetzt ersetzt der Vorschlag die getippten Wörter;
  das gilt für Orte, Städte, Alben und Themen.
- Erster iPhone-Test (15.11.): Analyse endet nicht mehr bei Wärme, Stromsparmodus oder
  wenn iOS die Hintergrundzeit beendet, sondern wird langsamer, wartet oder geht beim Öffnen
  weiter; jeder lange Lauf fragt nach Hintergrundzeit (Sperrbildschirm); Fortschritt zählt
  über alle Fotos und springt nicht zurück; das Probejahr bleibt gespeichert und begrenzt
  die Analyse; Analyse-Karte nennt die analysierten Fotos; höchstens 5 unbenannte häufige
  Orte, mit Stadt; eigenes Titelbild je Vorschlag; gleichnamige Länder zusammengeführt;
  Fotos im Vollbild; strengere Flugbuchungs-Erkennung; „Fotos-App öffnen“ mit Wegbeschreibung;
  neue Alben ohne Ordner „Albumist“.
- Übersicht sagte „Neue Fotos werden beim nächsten Start erkannt“, obwohl Albumist Änderungen in
  Fotos schon während der Nutzung bemerkt. Jetzt: „Neue Fotos erkennt Albumist von selbst.“
- Textknöpfe „So lassen“, „Alle … Alben anzeigen“, „Auswählen und später anlegen“ und
  „Als Album anlegen“ (Suche) haben jetzt die volle Tippfläche von 44 Punkt (Barrierefreiheitsprüfung im Simulator).
- Gegenprüfung 14.11.2026 (43 Befunde, `docs/review/AUDIT_2026-11-14.md`): Ausführungsjournal
  mit echten Änderungen, sicherer Wiederanlauf und Rückgängig, geschützte Löschungen, eine
  Ausführung zur Zeit, Abschluss in einer Transaktion, Reisen behalten ihre Identität, alte
  Orte und Texte nach Änderungen verworfen, iCloud-Fotos später erneut gelesen, WLAN je Foto
  geprüft, schnellerer Abgleich und Ortsgruppen, Mediathek und Suche ohne Obergrenze,
  Lasttest mit 100 000 Fotos.
- Zweite Gegenprüfung 15.11.2026 (22 Befunde, `docs/review/AUDIT2_2026-11-15.md`): unklare
  Ausgänge nach einer Unterbrechung werden nie geraten (kein Nachholen, kein Beanspruchen von
  Nutzerfotos), vom Nutzer gelöschte Alben auch beim Fortsetzen nicht neu angelegt, leere eigene
  Alben bleiben in der Verwaltung, Planung nur mit frisch gelesenem Albenstand, halbes
  Rückgängig lässt sich abschließen, Teilungen in der Reise-Werkstatt verbindlich, Sicherung mit
  offenem Abschluss und Folgenummer, Reset wartet auf das Ende der Analyse, Einwilligungen wirken
  vor jedem Netzaufruf, Karten- und Kontonummern über Zeilenumbrüche maskiert (auch Altbestand),
  Gratis-Alben bei Rückgängig sicher zurück, Beleg mit damaligen Namen und ehrlich bei
  ausgelassenen Fotos, Speichern großer Pläne 160 s → 1,7 s.
- Übersicht: Bei unterbrochenem Umsetzen stand „0 von … sortiert“ ohne Erklärung neben „39 von
  61 Schritten erledigt“. Darunter steht jetzt, dass es zählt, sobald du entschieden hast.
- Reise-Erkennung: Wer zu Hause wenig fotografiert, bekam nur eine Reise; das Zuhause
  braucht jetzt Fotos über mindestens drei Wochen verteilt.
- Umgesetzte Vorschläge kamen als „mehrere passende Alben“ zurück, wenn zwei Alben dieselben
  Fotos hatten, oder wenn zwei Vorschläge in ein Album gingen. Beides bleibt jetzt erledigt.
- Die Wahl unter „Anpassen“ wurde beim Übernehmen durch die Empfehlung ersetzt.
- Deutsche Einzahl („1 Reise“ statt „1 Reisen“) über Pluralformen im Katalog.
- Bereichsfarben haben im Dunkelmodus hellere Varianten (Kontrast).
- Kleine Vorschaubilder von Screenshots und Dokumenten wirkten abgeschnitten; Hochformat-Raster.
- Datumswerte verlieren beim Speichern keine Millisekunden mehr.
- Bilderkennungs-Begriffe an die tatsächliche Vision-Liste angepasst.
- Namenskonflikt `Observation` mit Apples Observation-Framework behoben.
- Feinschliff nach Erstnutzer-Durchgang: Ein rückgängig gemachter Änderungsbeleg sagt das
  jetzt oben statt erst am Ende; in der Reise-Werkstatt steht „Beginn der Reise“ unter dem
  Datum (der Tag brach sonst um); die Blätter „Reise anpassen“ und „Fotos hinzufügen“
  schließen mit dem runden X, der Titel steht wieder mittig.
- Fotos-Grenzen: Eine Änderung, die Albumist aufgab, bevor sie überhaupt an Fotos ging (alle
  Threads mit der Analyse beschäftigt), lief später trotzdem noch und galt als hängend; die
  nächste Änderung wurde abgelehnt, mit dem Rat zum Neustart. Jetzt läuft sie nie, die Meldung
  sagt „Albumist war gerade ausgelastet und hat diese Änderung nicht an Fotos geschickt – sie
  ist nicht passiert“, und „Fortsetzen“ geht sofort. „Fotos antwortet gerade nicht“ erscheint
  nicht mehr, nur weil Albumist selbst ausgelastet ist (wohl aber, solange ein Aufruf hinter
  einem hängenden wartet); endet die Analyse an einem Lesen, das so nie begann, sagt die Karte
  „Albumist war gerade ausgelastet“ und es geht jede Minute von selbst weiter. Ein Löschen
  von Alben, das Fotos ausgeführt hat, bleibt auch dann aufgezeichnet (und Rückgängig kann es
  zurückbringen), wenn das Nachlesen danach keine Antwort bekommt. Bekommt die Prüfung vor
  einer Änderung keine Antwort (etwa ob das Album noch da ist), gilt der Schritt als nicht
  begonnen, und „Fortsetzen“ fügt die Fotos normal hinzu.
### Migrationen
- v2: Spalte `asset_places.precision_m`.
- v3: `text_plain` mit Zeilen-ID, damit der Volltextindex automatisch folgt.
- v4: Planjournal Schritt für Schritt: Tabellen `plan_steps` und `plan_media`.
