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
### Korrigiert
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
  zu seiner Küste oder Grenze (vorher öffnete etwa ein Tippen auf Paris „Russland“, wenn nur
  Russland besucht war). Der Text der Fotozugriffs-Frage
  sagt „Kein Foto wird hochgeladen“ wie alle anderen Texte. Eine Stadt aus Apples Antwort gilt nur, wenn das
  gefragte Foto auf derselben Seite der Linie liegt wie das Foto, um das es geht. Im Reise-Atlas
  zählt ein Gebiet nicht als Land, seine Reisen und Orte zählen aber und tragen den
  Gebietsnamen; „Ausland“ in der Suche und das erkannte Zuhause kennen die Gebiete. Orte, die
  vor dem Update bestimmt wurden, behalten ihr altes Land, bis „Analyse neu aufbauen“ sie neu
  bestimmt. Die Store-Texte versprechen „Länder, auf Wunsch auch
  Städte“ statt Städte-Alben ab Werk (Standard bleibt: nur Länder).
- Fable-Analyse und Prüfungen 18.11.: Albumist schreibt die ID eines neuen Albums jetzt innerhalb
  derselben Änderung ins Protokoll, Rückgängig nach einem Abbruch nennt, was in Fotos bleibt;
  ein Protokoll, das Fotos hinterherhinkt, legt nichts doppelt an; „Fehlendes erneut versuchen“
  wartet auf Alben, die noch ankommen können; Zählen und Erkennen der Beispielfotos innerhalb
  der Lösch-Änderung. Suche: Grenzen auf beiden Seiten, „seit/vor/nach/bis“ als Zeiträume,
  „oder“ zwischen Grenzen. Orte behalten ihre ID beim Sprachwechsel und beim Neuaufbau;
  Jahreszeiten der Südhalbkugel; Schwärzen von IBAN, Karten und Ausweisen in mehr Schreibweisen;
  ein ganzer Tag zu Hause trennt eine Reise. Release-Tor: ein Grün nach Wiederholung zählt nie.
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
### Migrationen
- v2: Spalte `asset_places.precision_m`.
- v3: `text_plain` mit Zeilen-ID, damit der Volltextindex automatisch folgt.
- v4: Planjournal Schritt für Schritt: Tabellen `plan_steps` und `plan_media`.
