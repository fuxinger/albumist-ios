# Ideenliste und Verbesserungen

Lebende Liste. Nach jeder Runde (Expertenprüfung, Nutzertest, Testläufe, Gegenprüfung durch
andere KIs) kommen neue Punkte dazu. Status: ✅ erledigt · 🔜 als Nächstes · 💡 später/Update.
Aufwand: S klein, M mittel, L groß.

Quellen: **E1** Expertenrunde 14.11.2026 (Tempo, Oberfläche, Technik, Produkt) · **U** Nutzer
(Fuchs) · **T** Testläufe · **B** Bedienungstest 14.11.2026 (5 unabhängige Testpersonen: Gelegenheitsnutzerin, Vielreisender, Senior mit großer Schrift, Fotografin, Vater mit Kinderfotos) · **G** Gegenprüfung durch ChatGPT/Gemini 14.11.2026 (43 Befunde, alle bewertet in `docs/review/AUDIT_2026-11-14.md`; 16 Produktideen, unten eingeordnet) · **H** zweite Gegenprüfung durch ChatGPT 15.11.2026 (22 Befunde, alle bewertet in `docs/review/AUDIT2_2026-11-15.md`; 9 Produktideen, unten eingeordnet).

## Datensicherheit und Zuverlässigkeit

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Rückgängig löscht nie einen Ordner, in dem noch Alben liegen (Fotos würde sie mitlöschen). Ausführung und PhotoKit verweigern das Löschen nicht leerer Ordner. | S | E1 Technik |
| ✅ | Abgebrochenes Umsetzen (App beendet): Übersicht bietet beim nächsten Start „Fortsetzen“ oder „Rückgängig machen“; nichts wird doppelt angelegt. | M | E1 Technik |
| ✅ | Verlauf zeigt auch unterbrochene Pläne, mit „Fortsetzen“ und „Rückgängig“. | S | E1 Technik |
| ✅ | Umsetzen während einer laufenden Analyse: Albenliste vor dem Abgleich neu lesen, damit kein doppeltes Album entsteht. | M | E1 Technik |
| ✅ | „Ausgewählte Fotos“-Zugriff: vor dem Umsetzen klarer Hinweis „Voller Zugriff nötig“ mit Link zu Einstellungen statt Fehlermeldung. | S | E1 Technik |
| ✅ | Bereits rückgängig gemachte Pläne nicht nochmal rückgängig machen; Rückgängig-Läufe nicht als eigene Einträge zeigen. | S | E1 Technik |
| ✅ | Fehlender Elternordner (zweites Gerät hat ihn gelöscht): nie oben auf der Mediathek-Ebene anlegen, sondern abbrechen. | S | E1 Technik |
| ✅ | Fotos nur in iCloud: nicht als „erledigt“ markieren, später erneut versuchen. Fehlversuche werden gezählt und in späteren Läufen wiederholt; Text aus der kleinen Vorschau wird mit dem Original nachgelesen. | M | E1 Technik, G 5.1/2.4 |
| ✅ | Ausgeblendete Fotos in Alben mitzählen, damit Rückgängig nichts Fremdes löscht. | S | E1 Technik |
| ✅ | Beschädigte Datenbank: „Neu aufbauen“-Knopf statt Sackgasse. | S | E1 Technik |
| ✅ | StoreKit: nicht geprüfte Käufe sauber abschließen und Fehlermeldung zeigen; wartende Käufe (Familienfreigabe) erklären. | S | E1 Technik |

## Aus den Testläufen (T)

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| offen | Tausenderpunkt in den Ring-Zeilen („1.199 teilweise sortiert“): `format: .number` fand den Katalog-Schlüssel nicht (Englisch zeigte „57 Fotos von zu Hause“), daher zurück zu einfachen Zahlen. Richtig: eigene Schlüssel mit `%@` plus Plural über eine Zahl-Variable, oder `AttributedString` mit `inflect`. | S | T 16.11. |
| offen | Ortsnamen-Stunde: wenn Apple bei jeder Abfrage einen anderen Fehler meldet (nicht Netz, nicht Drosselung), startet die Stunde nie und jeder Lauf fragt wieder bis zu 60 Zellen. Vorschlag: Stunde auch starten, wenn mehr als eine Abfrage einer Runde fehlschlug. | S | Zweitprüfung 16.11. |
| ✅ | Code-Prüfung (CodeQL) Swift brach ab: unter dem Tracer meldete sandbox-exec „Bad CPU type in executable (86)“. Pakete werden jetzt vorher aufgelöst, die Manifest-Sandbox ist im geprüften Build aus. Ein Suchmuster in `test_summary.py` lief bei bestimmten Texten exponentiell lange; jetzt linear (gleiche Treffer, geprüft). | S | CodeQL 16.11. |
| ✅ | Barrierefreiheit auf kleinem iPhone (CI): zweimal am 16.11. brach der Simulator-Dienst ab („Connection interrupted“, „AX loaded notification“), ohne einen echten Fund, und hielt den TestFlight-Build auf. Ein solcher Durchlauf wird jetzt einmal auf frisch gestartetem Simulator wiederholt; Durchläufe mit echten Funden nie. | S | T 16.11. |
| ✅ | CI schneller, ohne einen Test wegzulassen: die UI-Tests laufen in drei parallelen Gruppen auf je eigenem Mac und Simulator (ganzer Ablauf mit Sortier-Show-Video · alle übrigen Abläufe, Kauf und Suche · Barrierefreiheit auf kleinem iPhone samt Kontrast-Durchgang), einmal gebaut statt in jedem Job. Vorher zwei Jobs mit 50–70 bzw. 42 Min.; jetzt bestimmt die langsamste Gruppe (~30 Min. Tests) die Dauer. Mit CI höchstens vier Mac-Jobs pro Push. | M | U 16.11. |
| ✅ | UI-Tests: meldet der Simulator-Dienst ausdrücklich einen Ausfall („Error returned in reply from CoreSimulatorService“, „AX loaded notification“, Test-Runner nicht gestartet) und zeigen weder Log noch Absturzbericht noch Ergebnis-Bundle etwas über die App, werden nur die nicht bestandenen Tests einmal wiederholt, auf einem gelöschten und neu eingerichteten Simulator (wie eine neue Gruppe), statt den ganzen Job neu zu starten. Fehlgeschlagene Tests, Fehlerzeilen, A11Y_FAIL, Abstürze, Zeitüberschreitungen und ein bloßer Neustart des Test-Runners (kann ein Hänger der App sein) werden nie wiederholt; ein Durchlauf ohne einen einzigen Test ist rot; Absturzberichte, Kontext vor dem Neustart und Ergebnis-Bundles landen im Log bzw. als Artefakt. Eine Fehlerzeile eines Tests, ein „Test Case … failed“ oder ein Absturz-Signal außer SIGTERM zählt auch dann als echter Fehler, wenn darin eine Simulator-Meldung zitiert wird; ein Ergebnis-Bundle ohne Liste „testNodes“ gilt als nicht lesbar (keine Wiederholung). Ein Skript für alle Gruppen (`.github/scripts/ui_tests.py`), Regeln mit Log-Ausschnitten echter Läufe auf Linux getestet. | M | T 16.11. |
| ✅ | TestFlight: das Release-Archiv wird gebaut, während die UI-Tests noch laufen (sobald der CI-Lauf dieses Commits grün ist, so bleiben es höchstens vier Mac-Jobs gleichzeitig); signiert und hochgeladen wird erst nach grünem Test-Tor, und nur ein Archiv genau dieses Commits mit der Build-Nummer dieses Laufs. Nach dem Tor ~3 statt ~8 Min. bis zum Upload. | S | U 16.11. |
| ✅ | Erst schnell, dann teuer auch im UI-Lauf und bei TestFlight: scheitern die Kern-Tests auf Linux, startet kein Mac-Job. | S | U 16.11. |
| ✅ | UI-Test 1 (ganzer Ablauf und Barrierefreiheit) läuft immer zuerst auf frischem Simulator und schlägt jetzt fehl, wenn Willkommen-Bildschirm oder „Beispiel-Mediathek anlegen“ fehlen oder er sein Ende nicht erreicht (vorher still übersprungen bzw. erst von Test 2 bemerkt, der jetzt auf einem anderen Simulator läuft). Test 3 (Durchklicken) muss auf „Übersicht“, „Mediathek“, „Alben“, „Suchen“ und in „Vorschläge“ mindestens einen Bildschirm erreichen; fehlt „Vorschläge prüfen“, schlägt er fehl. | S | Gegenprüfung CI 16.11. |
| ✅ | Git-Tag je TestFlight-Build: nach erfolgreichem Hochladen bekommt der Commit das Tag `build-<Nummer>` (eigener Job „tag“, als einziger mit Schreibrecht auf das Repository; ein vorhandenes Tag auf demselben Commit bleibt, auf einem anderen bricht der Job ab). | S | Fuchs 16.11. |
| ✅ | Einmal bauen, genau das ausliefern: das Release-Archiv trägt Commit und Build-Nummer in der Info.plist der App (`AlbumistCommit`, `CFBundleVersion`), `build-info.txt` dazu Xcode und SHA-256 der App-Datei; vor dem Signieren prüft der Upload alles gegen den geprüften Commit und den Lauf (`.github/scripts/archive_check.py`) und bricht sonst ab. Seit der Gegenprüfung 16.11. zählt die ganze App, nicht nur die App-Datei: eine sortierte Liste aller Dateien, Ordner und Links mit SHA-256 (`app-manifest.txt`, ihre Prüfsumme in `build-info.txt`; bei Abweichung nennt der Lauf die Dateien), dazu muss `DTXcodeBuild` in der Info.plist das festgelegte Xcode aus `.github/toolchain.json` sein. Ausgelassen wird nichts: verglichen wird vor dem Signieren, das jede Programmdatei, `_CodeSignature` und `embedded.mobileprovision` ändert. Der Archiv-Job behält kein Git-Token (`persist-credentials: false`). Bit-gleich mit dem getesteten Simulator-Build kann das Geräte-Release-Archiv nicht sein (anderes SDK, Release-Optimierung, Signatur); gleich sind Commit, Xcode und Build-Nummer, geprüft. | S | Fuchs 16.11. |
| ✅ | Kontrast-Durchgang (Barrierefreiheit Test 5) als vierte parallele UI-Gruppe auf eigenem kleinem iPhone: die Barrierefreiheits-Gruppe war mit ihm die längste (UI-Lauf 43906501407: 56,5 Min., davon 8 Min. Kontrast); ohne ihn ~48 Min., Kontrast ~18 Min. daneben. Höchstens fünf Mac-Jobs gleichzeitig (mit CI), am 16.11. so entschieden. | S | Koordination 16.11. |
| ✅ | Simulator-Wächter: verlässt der Simulator vor dem ersten Test den Zustand „Booted“ (zwei Prüfungen im Abstand von 20 s), beendet `ui_tests.py` den Durchlauf sofort, statt 4–5 Min. auf xcodebuild zu warten (UI-Lauf 43893790053: zwei Gruppen so verloren); das zählt als FLAKY_BOOT und wird wie jeder Simulator-Ausfall einmal auf einem gelöschten Simulator wiederholt. Ein Durchlauf, in dem ein Test begonnen hat, wird nie abgebrochen; dazu liest der Wächter das Log direkt vor dem Abbruch noch einmal, denn die Simulator-Abfrage dauert bis 30 s und ein Test kann in der Zeit starten (Gegenprüfung 16.11.: so wäre ein laufender Test abgebrochen worden). | S | Koordination 16.11., Gegenprüfung CI 16.11. |
| ✅ | Test-Gate ohne Ausnahme: TestFlight-Upload und Release brauchen immer einen grünen UI-Lauf auf genau diesem Commit. Vorher galt „kein UI-Lauf für den Commit“ als grün, so dass ein Push auf `main` (Merge-Commit, nie Kopf eines Pull Requests) ohne UI-Tests hochgeladen worden wäre. Jetzt wartet `ci_gate.py` nach grünem CI 15 Min. auf einen UI-Lauf und meldet sonst „no UI flow run“ mit dem Weg dazu (UI flow von Hand auf dem Commit starten). | S | Gegenprüfung CI 16.11., Entscheidung Fuchs |
| ✅ | Wackelige Tests sichtbar: jede Wiederholung nach einem Simulator-Ausfall, jeder Test, der erst in der Wiederholung bestand, und jeder fehlgeschlagene Boot-Versuch steht als `FLAKY…`-Zeile im Log und in der Job-Zusammenfassung und in `build/flaky-GRUPPE.json`; der neue Linux-Job „UI summary“ zählt sie über alle Gruppen (Zusammenfassung und Hinweis im Lauf). Ein echter Testfehler wird weiterhin nie wiederholt. | S | Fuchs 16.11. |
| ✅ | Werkzeuge festgenagelt: jeder Mac-Job nimmt genau das Xcode, die Simulator-Laufzeit und die Simulatoren aus `.github/toolchain.json` (jetzt Xcode 27.2 27B52, iOS 27.2 24B8117, iPhone 17e / iPhone 18 Pro / neu angelegtes iPhone SE) und bricht mit Meldung ab, wenn das Image sie nicht hat. Vorher „neuestes Xcode“: auf dem Image 20261112 ist `Xcode_27.3.app` eine Beta, und App Store Connect nimmt keine Beta-Builds. Wechsel nur bewusst, an einer Stelle. | S | Fuchs 16.11. |
| ✅ | UI-Gruppe „übrige Abläufe“ (UI-Lauf 43893790053): Test 2 legt dort als erster die Beispiel-Mediathek an; endete der Test-Runner direkt nach „Beispiel-Mediathek anlegen“, fanden Test 3 bis 7 die App nach dem Onboarding, aber ohne Beispiel-Mediathek, und liefen auf den paar Fotos des Simulators (10 Fehler, nur die Suche legte sie selbst an). Jeder spätere Test legt sie jetzt selbst an, wenn die App sie noch anbietet, wie es die Barrierefreiheits-Tests schon taten. | S | Gegenprüfung CI 16.11. |
| ✅ | UI-Test 3 (Durchklicken) erreichte auf „Alben“, „Suchen“ und in „Vorschläge“ nie einen Bildschirm: Listenzellen haben kein eigenes Label, also galt jede Zeile als „nicht sicher“. Jetzt zählt der erste Text der Zelle, wenn die Zelle wie eine Zeile aussieht (mehr als ein Text oder ein Bild; Abschnittsüberschriften und Fußtexte sind in iOS 27 eigene Zellen und wurden in UI-Lauf 43906501407 als „tote Zeilen“ gemeldet) (Zellen mit einer Aktion darin, etwa „Auswählen“ oder „gleichen Fotos“, bleiben aus und werden als UI_SWEEP_SKIP gemeldet); auf „Suchen“ muss ein Startpunkt Fotos finden und ein gefundenes Foto groß aufgehen; „Alben“ ohne Album meldet „Alben not checked (empty)“ und prüft, dass wirklich keine Albumzeile da ist. Die neuen Taps sind noch nicht auf einem Mac gelaufen: findet einer eine tote Zeile oder einen Absturz, ist das ein App-Befund. | S | Gegenprüfung CI 16.11. |
| ✅ | UI-Test 3 (Durchklicken) übergeht Listenzellen ohne eigenes Label mit weniger als zwei Texten und ohne Bild als Abschnitts-Kopf oder -Fuß (UI-Lauf 43906501407: „Länder und Orte“ wurde als tote Zeile gemeldet). Damit eine echte Zeile, die so übergangen wird, auffällt, stehen alle übergangenen Zeilen (`UI_SWEEP_SKIP`: Bildschirm › Text und Grund) jetzt in der Job-Zusammenfassung der Gruppe und in der Lauf-Zusammenfassung „UI summary“, mit Hinweis im Lauf. | S | Gegenprüfung CI 16.11. |
| offen | UI-Test 5 (unterbrochener Plan) endet ohne Fehler, wenn keine Unterbrechungs-Karte erscheint (Plan war schon fertig): dann ist „Nur Erledigtes behalten“ und „Fehlendes erneut versuchen“ nicht geprüft. Plan so groß oder langsam machen, dass die Unterbrechung sicher greift, und dann die Karte verlangen. | S | Gegenprüfung CI 16.11. |
| offen | UI-Test 7 (gesperrter Kauf) prüft die Freischalt-Karte nur, wenn der Plan mehr Alben hat als frei sind; mit nur einem Album geht er ohne sie weiter. Einen Plan mit mindestens zwei Alben erzwingen und die Karte verlangen. | S | Gegenprüfung CI 16.11. |
| ✅ | Barrierefreiheits-Test 1 auf kleinem iPhone hing beim Anlegen der Demo-Mediathek (nur Simulator): Zuschneiden, Zeichnen und JPEG-Kodieren liefen auf dem Haupt-Thread, die Abfragen der UI-Tests liefen bei größter Schrift ins Zeitlimit. Jetzt im Hintergrund, Reihenfolge des Zufallsgenerators unverändert (gleiche Mediathek). Die ausgelieferten Beispielfotos zeichneten schon im Hintergrund. | S | T 16.11. |
| ✅ | Karte „Noch zu wenige Fotos“: Der Knopf „Mit Beispielfotos ausprobieren“ war für Bedienungshilfen und UI-Tests nicht einzeln auffindbar, weil die Kennung der Karte auf alle Elemente darin überging. Karte ist jetzt ein eigener Container (Simulator-Lauf 43885771117). | S | T 16.11. |
| offen | CodeQL meldet „Cache Poisoning“ im Nachtlauf (prüft den neuesten Stand von `claude/sortly-app` im Zeitplan-Lauf aus). Praktisch kein Risiko: nur wir können auf den Zweig schreiben, und der Mac-Cache ist aus. Vor dem Start mit dem privaten Repo neu bewerten (Cache-Schritte entfernen oder Alarm begründet schließen). | S | CodeQL 16.11. |
| ✅ | „Ähnliche Alben“ schlug vor, Albumists eigene Alben zusammenzulegen (Land enthält seine Reisen). Eigene Alben und Teil-Alben (Rom in Italien) sind jetzt ausgenommen. | S | T 14.11. |
| ✅ | Sortier-Show: beim schnellen Blättern überlappten sich Alben, der Platzhalter schimmerte durch das Titelbild. | S | T 14.11. (Video) |
| ✅ | UI-Test: Tab-Leiste schrumpfte beim Scrollen und versteckte die Tabs; fehlende Schritte machen jetzt ein Bildschirmfoto. | S | T 14.11. |
| ✅ | Rückgängig fragte iOS für jedes Album einzeln „Albumist darf Album löschen?“ (37 Fragen bei 37 Alben). Alle Alben und Ordner gehen jetzt in einer Anfrage weg: eine Frage. Ordner nur, wenn alles darin mitgeht. | M | T 14.11. |
| ✅ | Menü bei größter Schrift schnitt „Nicht sortiert“ ab. Eigenes Menü-Etikett, das umbricht. | S | T 14.11. |
| ✅ | Land Italien zeigte „Mehrere passende Alben“ mit den eben angelegten Reisen Rom und Florenz und wollte Florenz-Fotos ins Rom-Album legen. Alben anderer Vorschläge und kleinere Alben mit anderem Namen werden bei Ländern nicht mehr ergänzt. | M | Fuchs 14.11. |
| ✅ | „Mehrere passende Alben“ hatte einen ausgegrauten Knopf „Bitte unter „Anpassen“ wählen“. Jetzt aktiver Knopf „Album auswählen“, die Erklärung nennt jedes Album und verspricht nichts, die Wahl wird angezeigt. | S | Fuchs 14.11. |
| ✅ | Mit nur einem freigegebenen Foto zeigte Albumist trotzdem viele Vorschläge (die Beispiel-Mediathek: iOS gibt selbst gespeicherte Fotos frei). Übersicht zeigt bei eingeschränktem Zugriff jetzt, wie viele Fotos Albumist sieht, mit „Auswahl ändern“ und „Alle Fotos erlauben“. | S | Fuchs 14.11. |
| ✅ | Erster iPhone-Test: Wurde das iPhone warm, endete die Analyse ganz und startete nicht wieder („bricht die Suche ab“). Läufe in der App werden jetzt nur langsamer (sehr warm) oder warten (zu heiß, Akku unter 10 %) und gehen von selbst weiter. Stromsparmodus hält sie nicht mehr an. | M | Fuchs 15.11. (iPhone) |
| ✅ | Sperrbildschirm-Fortschritt erschien „nur einmal und dann ein Fehler“: Albumist fragte iOS nur beim ersten Lauf nach Hintergrundzeit, und wenn iOS sie beendete, wurde die Analyse pausiert. Jetzt fragt jeder lange Lauf (und nach jeder Rückkehr in die App), das Ende der Hintergrundzeit pausiert nichts mehr, der Balken bewegt sich gleichmäßig. | M | Fuchs 15.11. (iPhone) |
| ✅ | Zahlen wurden kleiner und „Schritt 3“ kam wieder: Orte, Bildinhalte und Texte zählen über alle Fotos statt nur über den aktuellen Lauf; ein fortgesetzter Lauf zeigt „Macht da weiter, wo sie aufgehört hat“ statt bei Schritt 1 neu zu beginnen. Ein Prüflauf nach fertiger Analyse zeigt nur „Prüft auf neue Fotos“. | M | Fuchs 15.11. (iPhone) |
| ✅ | „Nur 2026“ beim Start galt nur für den ersten Lauf, danach kamen Vorschläge für alle Jahre. Das Jahr bleibt jetzt gespeichert, die Analyse schaut nur diese Fotos an (schneller), der Ring zählt nur sie. Auf der Übersicht steht „Probelauf: nur Fotos aus 2026“ mit „Alle Jahre“, in den Einstellungen „Albumist arbeitet mit“. | M | Fuchs 15.11. (iPhone) |
| ✅ | „Analyse aktuell“ neben „15 %“ wirkte wie abgebrochen. Die Karte sagt jetzt „Alle 14.332 Fotos analysiert“ (oder wie viele fehlen, und wie viele nicht lesbar waren) und nach „Neu prüfen“, was gefunden wurde. | S | Fuchs 15.11. (iPhone) |
| ✅ | 44 „Häufiger Ort N“ ohne Namen: Nur die 5 meistbesuchten ohne Namen werden vorgeschlagen, mit Stadt („Häufiger Ort in München“), Hinweis „Name fehlt“ statt „Neues Album“. Benannte Orte bleiben immer. | S | Fuchs 15.11. (iPhone) |
| ✅ | Viele Vorschläge hatten dasselbe Titelbild (kleinste Foto-ID). Jeder Vorschlag wählt jetzt stabil ein eigenes. | S | Fuchs 15.11. (iPhone) |
| ✅ | Zweimal „Deutschland“: Länder und Regionen gleichen Namens werden zu einem Vorschlag zusammengeführt (Fotos, deren Land ohne Ländercode kam). Städte gleichen Namens bleiben getrennt. Ursache beim echten iPhone noch nicht bestätigt. | S | Fuchs 15.11. (iPhone) |
| ✅ | Fotos im Vorschlag ließen sich nicht groß ansehen. Antippen öffnet sie jetzt im Vollbild, Wischen zum nächsten, Zoomen mit zwei Fingern oder Doppeltippen. | S | Fuchs 15.11. (iPhone) |
| ✅ | „Flugbuchungen“ falsch erkannt: Stichworte wurden als Wortteile gesucht („Flug“ in „Flugmodus“ und „Ausflug“, „gate“ in „Navigate“, „boarding“ in „Snowboarding“). Jetzt nur mit Flugnummer, Strecke wie „MUC → BCN“ oder „Bordkarte“ plus Flugwort, oder mehreren ganzen Flugwörtern. | S | Fuchs 15.11. (iPhone) |
| ✅ | „In Fotos ansehen“ führte nicht zu den Alben (iOS erlaubt Apps nicht, ein bestimmtes Album zu öffnen). Knopf heißt jetzt „Fotos-App öffnen“, darunter steht der Weg zu den Alben. | S | Fuchs 15.11. (iPhone) |
| ✅ | Ordner „Albumist“ über allen Alben: Neue Alben liegen jetzt ohne ihn direkt bei den eigenen Alben (Entscheidung Fuchs). Wer schon Alben im Ordner hat, behält ihn, bis er ihn in den Einstellungen leert. | S | Fuchs 15.11. |
| ✅ | Ring fiel von „811 von 5.683 sortiert“ auf 141 und 157: Seit dem Kuratieren der Vorschläge (Build 28) steht eine Reise für ein Land, das nur auf ihr vorkam, und der Status las nur die offenen Vorschläge. Eigene Reise-Alben zählen jetzt auch für das Land. Fotos von zu Hause und Fotos, für die kein Album vorgeschlagen wird, zählen nicht mit, und unter dem Ring steht, wie viele das sind. Fotos von einer Reise nach der letzten Analyse zählen bis zur nächsten als unsortiert. | M | Fuchs 15.11. (iPhone) |
| 💡 | **Produktfrage:** Fotos aus abgelehnten Vorschlägen („Nicht jetzt“) ohne eigenes passendes Album zählen im Ring weiter als unsortiert. Wer ablehnt, erreicht nie 100 %, und die Arbeit bleibt, obwohl entschieden ist. Vorschlag: Ablehnen ist eine Entscheidung. Diese Fotos verlassen den Ring wie Fotos von zu Hause und stehen in der Zeile darunter („… und 40 aus abgelehnten Vorschlägen“); „Abgelehnte Vorschläge wieder zeigen“ holt sie zurück. Dagegen spricht, dass Ablehnen den Ring dann voller macht. Alternative: weiter als Arbeit zählen, aber die Zeile unter dem Ring nennt sie mit dem Weg zurück. Entscheidung Fuchs. | S | Review 16.11. |
| 🔜 | Alben ganz ohne Ordner („Länder“, „Reisen“) als Schalter, falls gewünscht. | S | Fuchs 15.11. |
| 💡 | Bereits im Ordner „Albumist“ angelegte Alben auf Wunsch herausholen (Ordner auflösen). | M | Fuchs 15.11. |
| 💡 | Bedienungshilfen-Prüfung meldet zu wenig Kontrast bei den großen Glas-Knöpfen. Gemessen: Weiß auf Petrol 6:1, also bestanden; vermutlich misst die Prüfung den Glas-Effekt mit. Auf echtem Gerät nachprüfen. | S | T 14.11. |

## Aus dem Bedienungstest (B)

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | „Alle sicheren übernehmen“ war im „…“-Menü versteckt (4 von 5 fanden es nicht). Jetzt großer Knopf „N empfohlene übernehmen“ oben in der Liste, mit Erklärung darunter. | S | B |
| ✅ | Nach dem Übernehmen fehlte der Weg zum Umsetzen. Unten in der Liste steht jetzt „N übernommene Vorschläge umsetzen“. | S | B |
| ✅ | Liste sprang nach jedem Übernehmen um. Feste Reihenfolge: Reisen neueste zuerst, sonst nach Größe. | S | B |
| ✅ | „Sicher“, „Wahrscheinlich“ ohne Erklärung. Antippen zeigt jetzt einen Satz, was das heißt. | S | B |
| ✅ | „Für später vormerken“ unklar. Heißt jetzt „Übernehmen und später anlegen“. | S | B |
| ✅ | „Überspringen“ in der Show klang nach „Arbeit abbrechen“. Jetzt „Animation überspringen“ als Glas-Knopf. | S | B |
| ✅ | Großer Fotozähler blieb in der Show stehen (Fotos im Land und in der Reise zählen einmal). Groß zählt jetzt „Alben fertig“, darunter die Fotos. | S | B |
| ✅ | Zurück während des Umsetzens sah wie Abbrechen aus. Zurück-Knopf ist währenddessen weg. | S | B |
| ✅ | „Noch 10 Alben kostenlos“ unklar, ob vor oder nach diesem Plan. Jetzt „Kostenlos. Danach hast du noch N von 10 Gratis-Alben.“ | S | B |
| ✅ | Rückgängig auf dem Fertig-Bildschirm: Hinweis, dass es auch später geht und Fotos bleiben. | S | B |
| ✅ | Suchfeld im Tab „Suchen“ nicht sichtbar (alle 5). Feld ist jetzt beim Öffnen aktiv. | S | B |
| ✅ | „Voller Zugriff“ machte Angst ums Löschen. Zugriffsseite sagt jetzt: Albumist löscht und verändert nie ein Foto. | S | B |
| ✅ | „Erst ein Probelauf?“ verwirrte. Heißt jetzt „Womit soll Albumist anfangen?“. | S | B |
| ✅ | „0 Alben gefunden“ wirkte wie ein Fehler. Nur noch „N davon in deinen Alben“, wenn es welche gibt. | S | B |
| ✅ | Ring zeigte bei größter Schrift „6…“. Ring wächst mit der Schrift, Zahl bleibt lesbar. | S | B |
| ✅ | Zu viele Alben auf einmal: Land + Stadt + Reise ergab schnell 40 Alben. Entscheidung Fuchs 14.11.: standardmäßig nur Länder und Reisen, Städte per Schalter „Städte als eigene Alben“ in den Einstellungen. | S | B (3 von 5) |
| ✅ | „Umsetzen“ zeigte nur Zahlen (8 Ordner, 10 Alben), aber nicht, welche Alben entstehen. Die Vorschau listet jetzt jedes Album mit Titelbild, Ordner, Fotoanzahl und „Neu“ oder „Ergänzt“. | S | Fuchs 14.11. |
| ✅ | „Übernommen“ war unklar (ist schon etwas angelegt?). Jetzt durchgehend „auswählen“ und „N ausgewählte Alben anlegen“; Alben, die so bleiben, zählen nicht mehr mit. | S | Fuchs 14.11. |
| ✅ | Reisen wie „Rom · 10.05.–14.05.2024“ wirkten wie Stadt-Alben, weil alle Vorschläge gemischt standen. Die Gesamtliste hat jetzt Abschnitte je Bereich (Länder und Orte, Reisen …), Reisen neueste zuerst. | S | Fuchs 14.11. |
| ✅ | Heimliche Auswahl: „Dein Startpaket – N Alben anlegen“ und „Album anlegen“ wählten Vorschläge aus, die nach „Zurück“ ausgewählt blieben (Fuchs sah 34 ausgewählte, ohne etwas gewählt zu haben). Zurück ohne Anlegen stellt jetzt alles wieder her; „Auswahl aufheben“ in der Vorschau; UI-Test prüft beide Wege. | M | Fuchs 14.11. |
| ✅ | Übersicht zeigte vor dem ersten Schritt „13 von 246 sortiert“ (Screenshots ohne Ort zählten als sortiert). Fotos, für die kein Hauptbereich gilt, zählen jetzt weder als sortiert noch in der Gesamtzahl. | S | Erstnutzer-Durchgang 14.11. |
| ✅ | Vorhandene Alben fehlten im Tab „Alben“: (1) bei „Nur ausgewählte Fotos“ zeigt iOS einer App keine Alben, das steht jetzt dort mit „Alle Fotos erlauben“; (2) in Fotos neu angelegte Alben kamen erst nach „Neu prüfen“. Albumist bemerkt Änderungen in Fotos jetzt selbst und prüft beim Start nach. | M | Fuchs 14.11. |
| ✅ | Städte schon beim Einrichten wählbar: Schalter „Städte als eigene Alben“ unter „Länder und Orte“ (vorher nur in den Einstellungen). | S | Fuchs 14.11. |
| 🔜 | Zahlen passen nicht ganz zusammen: Übersicht „0 von 233 sortiert“ (nur Hauptbereiche), Fertig-Bildschirm „236 Fotos einsortiert“ (auch Screenshots und Dokumente). Erledigt: „0 ergänzt“ und andere Nullen fallen weg. Offen: Fertig-Bildschirm nach Bereichen aufteilen. | S | Erstnutzer-Durchgang 14.11. |
| ✅ | Startpaket-Karte nannte „Island, Rom und Kyoto …“, die Vorschau listete in anderer Reihenfolge (Lissabon, Kyoto …; Planer-Reihenfolge nach ID). Jetzt eine Reihenfolge überall (`inDisplayOrder`): Vorschlagsliste, Startpaket und Vorschau. | S | Erstnutzer-Durchgang 14.11. |
| 💡 | Bereich „Kinder und Familie“ (Gesichter). Mit Personen-Erkennung in Update 1.1. | L | B |
| 💡 | Fertig-Bildschirm mit Collage der neuen Alben statt nur Zahlen. | M | B |
| 💡 | Länderseite im Atlas mit kleiner Karte der Orte. | M | B |
| 💡 | Teilen-Karte im Atlas: standardmäßig mit Foto statt nur Karte. | S | B |
| 💡 | Namensfeld bei Orten ohne Namen deutlicher als Eingabefeld zeigen. | S | B |
| ✅ | Filter-Chips (Mediathek, Atlas-Jahre) liefen bei größter Schrift aus dem Bild. Bei den größten Schriftstufen jetzt ein Menü. | S | B |
| ✅ | Übernommen nur als kleines Häkchen. Zeilen sagen jetzt „Übernommen“ oder „Nicht jetzt“ in Worten. | S | B |
| 💡 | Atlas-Kacheln wachsen bei größter Schrift nicht ganz mit (Zahlen und Untertitel). | S | B |
| ✅ | Albumnamen in der Sortier-Show bei langen Reisen abgekürzt („Paris · 05.10.–07.10…“). Jetzt zwei Zeilen. | S | B |

## Tempo bei großen Mediatheken

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Ortsnamen beim ersten Durchgang begrenzt nachschlagen (60), Rest nachts; Pause wirkt sofort. Erste Vorschläge bis zu einer Stunde früher. | S | E1 Tempo |
| ✅ | Orte ohne Ergebnis (See, Meer, Wildnis) werden gemerkt und nicht jede Nacht erneut nachgeschlagen. | S | E1 Tempo |
| ✅ | „Nächste 50 Fotos“-Abfrage mit Lesezeichen statt Suche von vorn (17,7 s → 0,3 s bei 100.000 Fotos). | S | E1 Tempo |
| ✅ | Beim Umsetzen nur das betroffene Album prüfen, nicht jedes Mal die ganze Albenliste (große Pläne: Minuten statt Viertelstunden). | M | E1 Tempo/Technik |
| 💡 | Nach Analyse und Start nichts doppelt von der Platte lesen; Oberfläche sofort zeigen, Rest im Hintergrund. | M | E1 Tempo |
| 💡 | Nur geänderte Fotos neu einlesen (PhotoKit-Änderungsverlauf). | M–L | E1 Tempo |
| 💡 | Bildanalyse in Paketen, Vorschaubilder vorladen, in einer Datenbank-Transaktion schreiben. | M | E1 Tempo |
| 💡 | Analyse mit niedriger Priorität, bei warmem Gerät früher bremsen. | S | E1 Tempo |
| 💡 | Texterkennung bei Screenshots erst schnell, nur bei Bedarf genau. | M | E1 Tempo |
| 💡 | Suche im Hintergrund statt auf dem Haupt-Thread; Vorschaubilder vorladen. | S | E1 Tempo/Oberfläche |
| 💡 | Analyseergebnisse kompakter speichern (152 MB → unter 30 MB bei 100.000 Fotos). | M | E1 Tempo |
| 💡 | CI: Zwischenergebnisse der Mac-Builds speichern (jeder Lauf ein paar Minuten schneller). | S | U |

## Oberfläche und Bedienung

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| 💡 | Fortschrittsanzeige: „Gerade angesehen“ lädt die Vorschaubilder über den normalen Zwischenspeicher (`opportunistic`, 30 pt), nicht ausdrücklich `.fastFormat` (S9); am Gerät messen, ob es etwas kostet. | S | pro-progress |
| 💡 | Fortschrittsanzeige: Im Schritt Orte endet die Arbeit oft am Online-Budget lange vor „1.600 von 1.600“; die Fertig-Uhrzeit ist dort eher zu spät. Die Pipeline könnte die geplanten Abfragen mitteilen. | M | pro-progress |
| 💡 | Fortschrittsanzeige: Details-Blatt zeigt für kommende Schritte noch keine Mengen („1.040“ beim Text); die Werte kommen schon mit `AnalysisWorkload`. | S | pro-progress |
| ✅ | Vorschlag-Bildschirm kompakter, Knöpfe ohne Scrollen sichtbar. | S | U |
| ✅ | „Fotos fliegen in Alben“ beim Umsetzen. | M | U |
| ✅ | „Nicht jetzt“ ist umkehrbar: später doch anlegen geht; in den Einstellungen „Abgelehnte Vorschläge wieder zeigen“. | M | E1 Oberfläche |
| ✅ | Bibliothek und Atlas aktualisieren sich zuverlässig (Zwischenspeicher meldet Änderungen). | S | E1 Oberfläche |
| ✅ | Nach „Rückgängig“ eine passende Meldung statt „Fertig, 0 neue Alben“. | S | E1 Oberfläche |
| ✅ | Vorschau-Fotos über die ganze Zeitspanne verteilt, nach Datum; Antippen zeigt alle Fotos; einzelne Fotos aus dem Vorschlag entfernen. | M | E1 Oberfläche/Produkt |
| 💡 | Schönstes Foto als Titelbild (Bildqualität aus der Analyse nutzen). | S | E1 Produkt |
| ✅ | Ein Fortschrittsbalken über alle Schritte statt Neustart bei jeder Stufe („Schritt 4 von 7“), auch auf dem Sperrbildschirm. | S | E1 Oberfläche |
| ✅ | Zoom-Übergang vom Vorschaubild ins Foto. | S | E1 Oberfläche, U |
| 💡 | Kontextmenüs und Wischaktionen. | M | E1 Oberfläche |
| ✅ | Suche: Treffer antippbar (mit Zoom), für VoiceOver lesbar, „Als Album anlegen“. | S | E1 Oberfläche |
| 💡 | „Analyse aktuell“ nur anzeigen, wenn es stimmt; neue Fotos beim Öffnen erkennen. | M | E1 Oberfläche |
| ✅ | Einheitliche Wörter: überall „sortiert“ statt „organisiert“. „Umsetzen“ bleibt für das Anlegen eines ganzen Plans. | S | E1 Oberfläche |
| 💡 | iPad: Inhalte nicht über die ganze Breite ziehen, Liste und Detail nebeneinander. | M | E1 Oberfläche |
| 💡 | Erhöhter Kontrast: eigene Farbvarianten. | S | E1 Oberfläche |
| 💡 | Design-Prüfung 15.11., N7: Fußnote im Startschritt der Einführung kürzen. Zurückgestellt, weil sie zur neuen Fortschrittsanzeige auf `claude/pro-progress` passen muss. | S | Design-Prüfung |
| 💡 | Design-Prüfung 15.11., W4-Rest: „%lld Aufnahmen“ in der Scan-Show und „Fortsetzen“ in der Analysekarte; der Satz „Das unterbrochene Umsetzen zählt, sobald du oben entschieden hast.“ in der Statuskarte. Zurückgestellt, weil diese Bereiche auf `claude/pro-progress` neu gebaut werden. | S | Design-Prüfung |
| 💡 | Atlas: „Land/Länder“, „Stadt/Städte“, „Reise/Reisen“ und „Tag/Tage“ werden im Code gewählt statt über Mehrzahl im Katalog. Für Deutsch und Englisch richtig; für weitere Sprachen auf Katalog-Mehrzahl umstellen (Zahl und Wort sind getrennt gestaltet). | S | Design-Prüfung |
| 💡 | Teaser „Dein Reise-Atlas“ hat keine Überschrift-Eigenschaft, weil er ein Link ist; prüfen, ob VoiceOver-Nutzer ihn im Rotor vermissen. | S | Design-Prüfung |

## Produkt und App Store

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Name Albumist, neues Icon „Glass Stack“. | S | U |
| ✅ | Berechtigungstext und alle anderen Texte sagen „Gerät“ statt „iPhone“ (iPad). | S | E1 Produkt |
| ✅ | Builds und Tests mit Xcode 27 auf iOS 27 (aktuelles iOS). | S | U |
| ✅ | Erstes Ergebnis früh: Reisen, Länder und Orte erscheinen beim ersten Durchgang vor der Bildanalyse (statt nach Stunden). | M | E1 Produkt/Oberfläche |
| ✅ | Startpaket: „Dein Startpaket“ mit den besten Alben (Reisen und Orte zuerst), ein Knopf „10 Alben kostenlos anlegen“; bei großen Plänen „Die ersten N jetzt kostenlos anlegen“. | M | E1 Produkt |
| ✅ | Kauf-Knopf in den Einstellungen; Gratis-Zähler gibt nach Rückgängig zurück. | S | E1 Produkt |
| ✅ | Datenschutz-Seite in der App (offline lesbar). Für App Store Connect fehlt noch eine öffentliche Adresse. | S | E1 Produkt |
| ✅ | Namensvorschläge für Reisen in der eingestellten Sprache (bisher immer Deutsch). | S | E1 Produkt |
| ✅ | **„Dein Zuhause“** in den Einstellungen (Branch `claude/pro-home`): erkanntes Zuhause („München und Umgebung“, als erkannt markiert) mit „Stimmt“ und „Ändern“ (durchsuchbare Orte aus den eigenen Fotos, offline Regionen; „Kein Zuhause festlegen“; „Automatisch erkennen“), leerer Zustand „Noch kein Zuhause erkannt“, frühere Zuhause mit Zeitraum („Bis Dezember 2018: Hamburg“), andere Orte mit eigenem Namen („Eltern“, „Zweitwohnung“, „Arbeit“, frei), die keine Reisen sind (ersetzt die Liste „Hier bist du öfter“). Eine Funktion `HomeSettings.home(at:)` sagt für jedes Datum, wo Zuhause war; Reisen, Reisenamen, Länder- und Orte-Vorschläge und der Ring fragen nur sie. Eine Änderung macht nur die Vorschläge neu (`AnalysisPipeline.resuggest`, keine Bildanalyse, kein Album ändert sich), ausgewählte Vorschläge bleiben, wie sie gewählt wurden, die Übersicht sagt, was wegfiel und was neu ist. Gespeichert unter `user.home`, übersteht „Analyse neu aufbauen“ und liegt in der Sicherungskopie. Nach dem Review 16.11.: „Stimmt“ gilt ab der Bestätigung (ändert nichts an der Vergangenheit), ein Ort unter „Ändern“ für immer; die Änderung ist mit einer Vormerkung gespeichert, sodass auch ein Lauf, der zuerst drankommt, oder der nächste Start Auswahl und Hinweis richtig macht; die Orte des Zuhauses kommen aus den Fotos im Umkreis; „Ausland“ in der Suche folgt dem Zuhause des Aufnahmetags; unlesbare Werte halten keine Analyse auf. Nach dem Re-Review 16.11.: ein Ort unter „Ändern“ gilt ab „Seit wann wohnst du dort?“ (vorgeschlagen aus den Fotos), nie für alle Zeit; die Orte des Zuhauses werden linear bestimmt (50.000 Fotos, drei Zuhause: 0,03 s statt 3 s); während einer Änderung sagen Pläne, Neuaufbau und Analyse-Anfragen „Gerade nicht möglich“ oder warten. Nach Runde 3: der vorgeschlagene Beginn zählt nur Tage mit Fotos und endet an 28 Fototagen, von denen mindestens vier von fünf woanders sind (Besuche alle zwei, drei Wochen vor einem Umzug und seltene Fotos zu Hause verschieben ihn nicht mehr); eine Änderung bleibt vorgemerkt, auch wenn Vorschläge beim Speichern fertig werden; „Ja“ und „Nein“ unter „Bist du hier öfter?“ sagen, warum sie warten. Nach Runde 4: der Aufenthalt endet an 28 Fototagen mit mehr als der Hälfte woanders (auch wöchentliche Wochenendbesuche vor einem Umzug ziehen das Datum nicht mehr zurück; eine Woche im Ausland jeden Monat beendet ihn nicht; ein langer Urlaub legt das Datum dahinter, ohne eine Reise zu ändern), der Tag selbst ist der mit dem größten Vorsprung der Tage dort, sodass eine kurze Reise kurz nach dem Umzug ihn nicht verschiebt; auch „Keine Reise, hier bin ich öfter“ sagt, warum es wartet. | M | U |
| 💡 | **Produktfrage: eigene Orte ohne Album?** Ein Ort aus „Andere Orte“ („Arbeit“) bekommt wie jede Antwort „Ja, hier bin ich öfter“ ein Album „Häufige Orte“. Abschalten pro Art an einer Stelle: `RecurringPlaces.getsAnAlbum` (Entscheidung des Eigentümers offen). | S | U |
| 💡 | „Album aktuell halten“: neue Fotos nachts automatisch in bestätigte Alben. Hauptthema für Update 1.1. | M | E1 Produkt |
| ✅ | Entscheidungen ins Backup, damit sie einen Gerätewechsel überstehen (siehe I12). | S–M | E1 Produkt |
| 💡 | Atlas-Widget und In-App-Event „Dein Reisejahr“ im Dezember/Januar. | M | E1 Produkt |
| 💡 | Siri-Antwort mit Knöpfen „Anlegen / Nicht jetzt“ statt App öffnen. | M | E1 Produkt |
| 💡 | Familienfreigabe für den Kauf, Small Business Program (15 % statt 30 %). | S | E1 Produkt |
| 💡 | „Alle Fotos dieses Albums verbessern“: Apples automatische Verbesserung (Core Image) für viele Fotos auf einmal, mit Vorher/Nachher, in Fotos jederzeit umkehrbar. Erst nach dem Start (Update 1.2), weil es das Versprechen „Fotos bleiben unverändert“ aufweicht; Apples KI-Bereinigen ist für Apps nicht verfügbar. | M | U |
| 💡 | Produktseite: Bildschirmfoto 1 beantwortet „Warum nicht einfach Fotos?“ (echte Alben überall); keine Zahl zeigen, die nicht stimmt. | S | E1 Produkt |

## Aus der Gegenprüfung (G): Produktideen

Einordnung der 16 Vorschläge. Leitlinie bleibt: wenige verlässliche Abläufe statt langer
Funktionsliste; nichts, was Fotos löscht oder ohne Bestätigung ändert.

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | **I01 Änderungsbeleg:** pro Plan eine Seite „Das hat Albumist geändert“ mit nachgeprüften Zahlen aus dem Ausführungsjournal, jedem Album (neu, ergänzt, übernommen, entfernt, +/− Fotos), „Deine Originale“ (0 gelöscht, 0 bearbeitet, 0 Kopien), nicht Erledigtem und dem Rückgängigmachen; als Text teilbar. Erreichbar über Einstellungen › Verlauf und nach dem Umsetzen. | M | G I01 |
| ✅ | **I12 Sicherung der Entscheidungen:** Ausnahmen, Regeln, Einstellungen, eigene Namen, verwaltete Alben und Verlauf liegen zusätzlich in einer kleinen Datei im Geräte-Backup; Wiederherstellen nach Neuaufbau der Datenbank oder auf einem neuen Gerät, Alben und Verlauf nur bei passender Mediathek. Schließt die Restlücke von Befund 3.2. | M | G I12 |
| 💡 | **I12b Sicherung auf neuem iPhone mit iCloud-Fotos:** Album- und Foto-Kennungen zusätzlich als iCloud-Kennung (`PHCloudIdentifier`) sichern und beim Wiederherstellen umrechnen, damit auch Alben, Verlauf und Ausnahmen auf einem neuen Gerät zurückkommen. | M | I12 |
| ✅ | **I16 Geführte Reparatur:** unterbrochene Pläne: „Fortsetzen / Rückgängig machen / So lassen“ (So lassen behält das Erledigte als normalen Verlaufseintrag); Pläne mit Fehlern: Gründe in Klartext im Änderungsbeleg und „Fehlendes erneut versuchen“ (nur was fehlt, über die normale Vorschau, nichts doppelt, gelöschte Alben respektiert, Gratis-Alben nicht doppelt gezählt); „Diagnose teilen“ mit Zuständen, Zahlen und Fehlercodes, ohne Fotos, Namen oder Orte. | M | G I16 |
| 💡 | **I04 Lebende Alben:** neue Fotos einer Reise oder eines Themas als kleine Ergänzung vorschlagen statt neu zu sortieren. Passt zum Wochenhinweis für 1.1. | L | G I04 |
| ✅ | **I07 Reise-Werkstatt:** Reisen teilen (Tag wählen, Vorschau der zwei Teile) und mit der Nachbarreise zusammenlegen, im Reise-Vorschlag unter „Reise teilen oder zusammenlegen“; jede Änderung an der Reise wieder aufheben, alle zurücksetzen in den Einstellungen. Gespeichert als Zeitpunkte (`TripCorrections`), gilt für jede spätere Analyse und liegt in der Sicherung (I12). Noch offen: Fotos einzeln aus einer Reise nehmen, Reisen mit schon angelegtem Album umbauen. | L | G I07 |
| 💡 | **I02 Sortier-Kompass:** beim Start zwei, drei Fragen („wenige große Alben“ oder „viele genaue“), die Bereiche und Schwellen setzen. Erweitert die Bereichsauswahl. | M | G I02 |
| 💡 | **I06 Album-Gesundheitscheck:** „Ähnliche Alben“ ausbauen: leere Alben, fast gleiche Alben, Alben ohne Titelbild, nur lesend mit Vorschlag. | M | G I06 |
| 💡 | **I09 Ähnliche Fotos:** „Mehr wie dieses“ über die schon berechneten Bild-Merkmale (Feature Print), nur lesend. | L | G I09 |
| 💡 | **I08 Gespeicherte Suchen:** eine Suche als Sammlung merken, ohne echtes Album. | M | G I08 |
| 💡 | **I11 Atlas 2.0:** Jahresrückblick der Reisen im Atlas, direkt mit Album-Vorschlag. | M | G I11 |
| 💡 | **I13 Analyse-Assistent:** vor der ersten Analyse ehrlich sagen, wie lange es dauert und was iCloud braucht; Teile davon gibt es schon (erste Ergebnisse früh, Pause bei Wärme je Foto). | M | G I13 |
| 💡 | **I03 Lernschleife:** aus abgelehnten und angepassten Vorschlägen Regeln vorschlagen, sichtbar und abschaltbar. | L | G I03 |
| 💡 | **I05 Regelstudio:** Regeln (gibt es im Kern) mit einfacher Oberfläche und Vorschau „würde 120 Fotos betreffen“. | M | G I05 |
| 💡 | **I10 Beleg-Assistent:** Felder aus Rechnungen (Händler, Betrag, Datum) prüfbar anzeigen und suchen. | L | G I10 |
| 💡 | **I14 Personen und Haustiere:** nur bestätigte Gruppen, Opt-in; schon für 1.1 geplant. | XL | G I14 |
| 💡 | **I15 Widget und Kurzbefehle:** Widget „offene Vorschläge“, Kurzbefehl „neue Fotos sortieren“; Widget ist für 1.1 geplant. | M | G I15 |

## Aus der zweiten Gegenprüfung (H): Produktideen

Einordnung der 9 Vorschläge aus `PRODUKT_ROADMAP_AUDIT2.md`. Vier davon decken sich mit
G-Ideen und stehen dort. Leitplanken der Prüfung, die wir teilen: nichts löschen, keine
Cloud-KI, keine unbestätigte Änderung, „unbekannt ist nicht erfolgreich“.

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | **H1 Unklare Änderungen sichtbar machen (Konflikt-Inbox):** Ein Schritt mit unklarem Ausgang nach einer Unterbrechung steht im Änderungsbeleg mit Grund in Klartext; nichts wird von selbst wiederholt, „Fehlendes erneut versuchen“ zeigt erst eine Vorschau. Noch offen (💡): eine Sammelstelle für unklare Schritte aus mehreren Plänen. | M | H |
| ✅ | **H2 Änderungsbeleg als Kette:** Teil-Rückgängig wird erkannt („teilweise rückgängig gemacht“) und mit „Rest rückgängig machen“ abgeschlossen; Namen und Ordner der Alben zum Zeitpunkt der Ausführung; nur bestätigte Änderungen zählen. | M | H, I01 |
| 💡 | **H3 Wiederherstellen mit Vorschau:** vor dem Zurückholen einer Sicherung zeigen, was zurückkommt (Entscheidungen, Alben, Verlauf, offene Abschlüsse) und warum etwas fehlt (andere Mediathek). Heute gibt es dazu einen Hinweis danach. | M | H, I12 |
| ✅ | **H4 Verbindliche Teilung in der Reise-Werkstatt:** Teile mit einem Foto bleiben, Fotos ohne GPS an der Grenze landen in genau einem Teil; Vorschau und Analyse rechnen gleich. | S | H, I07 |
| 💡 | **H5 Datenschutz-Übersicht:** auf einer Seite zeigen, was Albumist lokal gespeichert hat (Texte, Orte), ob gerade etwas aus dem Netz geladen wird, und alles mit einem Schalter löschen. Die Einwilligungen selbst wirken schon vor jedem einzelnen Netzaufruf. | M | H |
| 💡 | **H6 Persönliche Regelvorschläge („Meine Ordnung“):** siehe I03 Lernschleife und I05 Regelstudio. | L | H |
| 💡 | **H7 Lebende Alben als freiwillige Inbox:** siehe I04. | L | H |
| 💡 | **H8 Reise-Atlas mit Jahreskarten:** siehe I11; Export ohne GPS-Daten, nur bestätigte Reisen. | M | H |
| 💡 | **H9 Ähnliche Fotos auf dem Gerät:** siehe I09; erst nach Messung auf einem Gerät mit 100.000 Fotos. | L | H |

## Wow-Ideen

| Status | Punkt | Aufwand | Quelle |
|---|---|---|---|
| ✅ | Fotos fliegen in Alben. | M | U |
| ✅ | Erster Scan als Show: Mosaik aus eigenen Fotos mit wanderndem Licht, gefundene Reisen springen als Karten auf. Nur während der ersten Analyse (Fuchs, 16.11.; Schalter `ScanShowRule.onFirstAnalysis`). | M | U |
| ✅ | Farben aus den Fotos: jeder Vorschlag und jedes Land im Atlas mit eigenem weichen Farbverlauf aus dem Titelbild. | S | U |
| ✅ | Zoom-Übergang ins Foto (Mediathek und Atlas-Länder). | S | U |
| 🔜 | „Seit wann wohnst du dort?“ genauer vorschlagen: eine Reise kurz nach dem Umzug oder ein Urlaub von 15 und mehr Fototagen legt den Vorschlag später als den Umzug (harmlos, die Reisen bleiben wie automatisch; nur wer sehr selten zu Hause fotografiert, behält nach „Festlegen“ eine kleine Reise am neuen Ort). Idee aus der Prüfung Runde 5: Tage woanders einfach zählen und den Aufenthalt nur an einer Strecke enden lassen, die meist an einem anderen Ort war. | S | U |
| ✅ | Jeder Ladekreis sagt VoiceOver, worauf er wartet („Foto wird geladen“, „Suche läuft“, „Kauf läuft“ …), oder ist ausgeblendet, wenn ein Text daneben es sagt. Gefunden: Apples Barrierefreiheits-Prüfung meldete im Fotobetrachter ein Element ohne Beschreibung, wenn das Foto langsam lud (Lauf 43906501407). 14 Stellen geprüft, 13 ergänzt; die neue Regel `spinner_rule.py` im CI verhindert neue. | S | U |
| ✅ | TestFlight startet nicht mehr bei einem Merge in `main` (nur Push auf `claude/sortly-app` oder von Hand) und nie, wenn sich seit dem letzten hochgeladenen Build nur Webseite oder Dokumente geändert haben (`app_changed.py`, Vergleich mit dem Tag `build-<Nummer>`). Anlass 16.11.: das Zusammenführen der Webseite startete einen Build mit altem App-Stand (abgebrochen, nichts hochgeladen). | S | U |
| 🔜 läuft ab Merge in `main` | TestFlight-Feedback und Absturzberichte werden jeden Morgen von selbst abgefragt (Workflow „TestFlight feedback“, 06:00 UTC, auch von Hand). Solange das Repository öffentlich ist, nur Anzahlen je Build (keine Kommentare, Screenshots oder Absturzprotokolle in Zusammenfassung oder Artefakt); den vollständigen Bericht mit Screenshots und Protokollen (Artefakt 7 Tage) erlaubt das Skript nur bei privatem Repository, und auch dann steht in der Zusammenfassung nur die Tabelle. Gleicher Schlüssel wie der Upload; Rolle Admin, App Manager oder Developer nötig (vorhandener Schlüssel geprüft: darf es). Nie E-Mail-Adressen oder Namen der Tester. `asc_feedback.py` mit Tests. | S | U |
| 💡 | 3D-Globus im Atlas. | L | U |
| 💡 | Zeitreise-Regler durch die Jahre. | M | U |
| 💡 | Reise als Postkarte teilen (umdrehbar). | M | U |
| 💡 | Album-Stapel mit Tiefe beim Neigen. | S | U |
| 💡 | Widget „Heute vor 3 Jahren“. | M | U |
