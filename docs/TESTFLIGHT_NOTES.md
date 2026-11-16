# TestFlight: „Was testen“

Jeder TestFlight-Build bekommt den Text zwischen den beiden Markierungen unten als „Was testen“
für die Tester (App Store Connect, deutsche Beta-Beschreibung des Builds). Das erledigt
`.github/workflows/testflight.yml` nach dem Hochladen, sobald Apple den Build kennt; die
Buildnummer und der Commit werden automatisch angehängt.

- Kurz halten, in Du-Form, Deutsch. Höchstens etwa 3900 Zeichen (Apple erlaubt 4000).
- Markdown wird zu einfachem Text: Überschriften werden zu Zeilen, `-` zu `•`.
- Text vor dem nächsten Build anpassen, der etwas Neues zum Testen hat. Der alte Text wandert
  darunter nach „Frühere Builds“.
- Ein Commit, der nur diese Datei ändert, startet keinen Build (nur Dokumentation).

<!-- testflight:start -->
Danke fürs Testen! Bitte achte in diesem Build besonders auf:

- Rückgängig fragt jetzt nach dem Löschen: Wenn Albumist beim Rückgängigmachen ein Album löschen will, fragt iOS um Erlaubnis. Probiere einmal „Löschen“ und einmal „Nicht erlauben“. Albumist soll danach genau sagen, was erledigt ist und was nicht, und „Nicht erlauben“ nie als gelöscht zählen.
- Analyse läuft bei Wärme weiter: Wird das iPhone warm, ist der Stromsparmodus an oder beendet iOS die Hintergrundzeit, wird die Analyse langsamer oder wartet, hört aber nicht auf. Beim nächsten Öffnen geht sie weiter, und der Fortschritt springt nicht zurück. Am besten mit einer großen Mediathek, beim Laden und mit gesperrtem Bildschirm.
- Probejahr bleibt: Das gewählte Probejahr bleibt nach dem Beenden und Neustarten der App erhalten, und die Analyse bleibt auf dieses Jahr begrenzt.
- Fotos groß ansehen: Ein Foto in einem Vorschlag antippen öffnet es groß. Bitte ein paar Fotos öffnen und wieder schließen, auch mit großer Schrift.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.
<!-- testflight:end -->

## Frühere Builds

- Build 27 (15.11.2026): erster Text, Inhalt wie oben.
