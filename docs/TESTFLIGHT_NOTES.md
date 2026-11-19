# TestFlight: „Was testen“

Jeder TestFlight-Build bekommt den Text zwischen den beiden Markierungen unten als „Was testen“
für die Tester (App Store Connect, deutsche Beta-Beschreibung des Builds). Das erledigt
`.github/workflows/testflight.yml` nach dem Hochladen, sobald Apple den Build kennt; die
Buildnummer und der Commit werden automatisch angehängt.

- Kurz halten, in Du-Form, Deutsch. Höchstens etwa 3900 Zeichen (Apple erlaubt 4000).
- Markdown wird zu einfachem Text: Überschriften werden zu Zeilen, `-` zu `•`.
- Text vor dem nächsten Build anpassen, der etwas Neues zum Testen hat. Der alte Text wandert
  darunter nach „Frühere Builds“.
- Ein Push startet keinen Build (außer auf `claude/sortly-app`, solange dort die alte
  `testflight.yml` liegt); TestFlight-Läufe startet man von Hand (`docs/TESTFLIGHT.md`).
- Ein Notfall-Build ohne Tests („force“) bekommt automatisch eine Warnung davor
  („FORCED – untested“).

<!-- testflight:start -->
Danke fürs Testen! Dieser Build bringt vor allem Stabilität. Bitte achte besonders auf:

- Ausblenden: Fotos, die du ausblendest oder wieder einblendest, verschwinden bzw. erscheinen sofort. Die Zahlen ziehen kurz danach nach.
- Mediathek-Tab: öffnet schneller, auch bei einer großen Mediathek.
- Fotos hängt: Antwortet Fotos einmal nicht (z. B. während iCloud lädt), friert weder die Analyse noch das Umsetzen eines Plans ein. Albumist sagt, worauf es wartet, und macht danach weiter.
- Rückgängig nach einem abgebrochenen Plan: Albumist entfernt nur, was sicher von Albumist ist, und sagt dir genau, falls etwas in Fotos bleibt. Deine Fotos bleiben unverändert.
- Suche mit Zeiträumen: Probiere „seit 2024“, „vor 2022“ und „vor 2022 oder nach 2024“.
- Themen und Dokumente später einschalten: Fotos, die schon analysiert waren, bekommen ihre Themen danach im Hintergrund.
- Sprache der Albumnamen ändern: Orte bekommen neue Namen, Vorschläge, die du abgelehnt hast, kommen nicht zurück.
- Reisen: Ein ganzer Tag zu Hause zwischen zwei Reisetagen trennt die Reise in zwei.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.
<!-- testflight:end -->

## Frühere Builds

- Bis 18.11.2026: Rückgängig fragt nach dem Löschen; Analyse läuft bei Wärme weiter; Probejahr bleibt; Fotos groß ansehen.
- Build 27 (15.11.2026): erster Text, Inhalt wie oben.
