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
- Prüfung 18.11. (Zuhause): Albumist erkennt das Zuhause jetzt an den Fotos des ganzen Tages,
  nicht nur an den ersten 15. Wer morgens regelmäßig woanders fotografiert (etwa bei der Arbeit),
  bekommt den Alltag zu Hause nicht mehr als Reise vorgeschlagen; ebenso beim Ort eines
  Urlaubsziels, an das du öfter fährst.
- Prüfung 18.11. (häufige Orte): Zwei häufige Orte dicht beieinander (etwa Haus und Garten
  gegenüber) hatten eine gemeinsame Kennung, ein Name oder „Nicht jetzt“ galt für beide. Jetzt
  hat jeder Ort seine eigene und behält sie über seine Fotos, auch wenn Fotos dazukommen oder
  wegfallen. Name, „Nicht jetzt“ und Album bleiben bei dem der beiden Orte, den Albumist bisher
  gezeigt hat; der andere erscheint als neuer Vorschlag und braucht wieder einen Namen.
- iPhone-Test Build 36: Ein Ort, an dem du öfter bist, heißt jetzt nach seiner Stadt (etwa
  „Dorfen“), nicht mehr nach dem Bundesland („Bayern“).
- iPhone-Test Build 36: Derselbe Ort kam zweimal, als Ort, an dem du öfter bist („Bayern“), und
  als häufiger Ort („Häufiger Ort in Zwiesel“). Jetzt einmal, als Ort, an dem du öfter bist;
  hast du den häufigen Ort schon benannt oder hat er schon sein Album, bleibt dieser.
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
