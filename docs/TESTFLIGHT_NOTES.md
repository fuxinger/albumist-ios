# TestFlight: „Was testen“

Jeder TestFlight-Build bekommt den Text zwischen den beiden Markierungen unten als „Was testen“
für die Tester (App Store Connect, deutsche Beta-Beschreibung des Builds). Das erledigt
`.github/workflows/testflight.yml` nach dem Hochladen, sobald Apple den Build kennt; die
Buildnummer und der Commit werden automatisch angehängt.

- Kurz halten, in Du-Form, Deutsch. Höchstens etwa 3900 Zeichen (Apple erlaubt 4000).
- Markdown wird zu einfachem Text: Überschriften werden zu Zeilen, `-` zu `•`.
- Text vor dem nächsten Build anpassen, der etwas Neues zum Testen hat. Der alte Text wandert
  darunter nach „Frühere Builds“.
- Ein Push startet keinen Build. TestFlight-Läufe startet man von Hand auf `main`, dazu kommt
  morgens der tägliche Build mit kleinem Tor (`docs/TESTFLIGHT.md`). Hochgeladen wird seit
  19.11. ohne Klick, nur von `main` und nur mit allen Toren grün. Der alte Zweig
  `claude/sortly-app` lädt seit 18.11. nichts mehr hoch.
- Jeder Build hat seine Tests bestanden; einen Notfall-Build ohne Tests gibt es nicht mehr
  (Beschluss 17.11.).

<!-- testflight:start -->
Danke fürs Testen! Dieser Build bringt Korrekturen aus der großen Prüfung. Bitte achte besonders auf:

- Tab „Alben“: Jedes Album steht nur noch einmal. Alben von Albumist stehen nicht zusätzlich unter „Deine Alben“.
- Fotos groß ansehen: Öffnest du ein Foto in einer sehr großen Mediathek, geht es schneller auf. Wische bitte einmal weit vor und zurück: Springt das Bild, oder hakt es?
- Größte Schrift (Einstellungen > Bedienungshilfen): Reise-Atlas, Suche und „Ordner für neue Alben“ sind jetzt ganz lesbar, nichts liegt mehr übereinander.
- Monatsalben nach Ortszeit: Fotos zählen jetzt zu dem Tag und Monat, den die Uhr am Aufnahmeort zeigte, wie in Apple Fotos. Ein Silvesterfoto aus New York landet also im Dezember, nicht im Januar.
- Suche: Beim Tippen steht neben einem Vorschlag wie „Italien“ kein „nicht erkannt“ mehr.
- Englisch: Viele Texte und Knöpfe sind korrigiert (zum Beispiel „Certain“ statt „Safe“). Wer das iPhone auf Englisch hat: Klingt etwas falsch?

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.
<!-- testflight:end -->

## Frühere Builds

- Build 38 (19.11.2026, erster Upload ohne Klick): Orte nach der Stadt, Ortsnamen ohne Warten, Ring „Sortiert“ bis 100 %, keine Dokumente als Vorschau, Namensfeld wie in iOS, Pause und Reisen, umstrittene Gebiete, Gleicher Name, Fotos mit Zukunftsdatum, Umkreis-Suche, Akku im Diagnosebericht.
- Build nach PR #7 (19.11.2026): Ausblenden sofort sichtbar, Mediathek-Tab schneller, Fotos hängt nie fest, Rückgängig nach Abbruch, Suche mit Zeiträumen, Themen später einschalten, Sprache der Albumnamen, Tag zu Hause trennt eine Reise.
- Bis 18.11.2026: Rückgängig fragt nach dem Löschen; Analyse läuft bei Wärme weiter; Probejahr bleibt; Fotos groß ansehen.
- Build 27 (15.11.2026): erster Text, Inhalt wie oben.
