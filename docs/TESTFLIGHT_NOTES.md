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
Danke fürs Testen! Dieser Build bringt eine Testseite für die kommende Karte „Deine Welt“. Sie gibt es nur in TestFlight, nicht in der App-Store-Version. Bitte achte besonders auf:

- Kamera-Probe: Öffne die Testseite der Karte, dann „Reise abspielen“ und „Kamera-Probe“. Sieh dir zuerst den Flug an, dann tippe „Nochmal fliegen“, einmal im WLAN und einmal im Mobilfunk. Geh danach mit „Weiter“ durch die 16 Kamera-Blicke und mach Bildschirmfotos von den tiefen Blicken und von Rom.
- Werte: Tippe am Ende auf „Werte kopieren“ und schick den Text mit. Er enthält das Gerät und Messwerte, keine Fotos und keine Koordinaten.
- Ruckelt der Flug, bleiben Kartenteile leer oder wird das iPhone warm? Schreib kurz, was du gesehen hast.
- Foto-Ansicht: Öffne in „Nicht sortiert“ ein Foto. Oben steht jetzt „1 von …“ mit derselben Zahl wie in der Liste, nicht mehr 3.000. Wisch ein paar Fotos weiter: Reagiert es beim ersten Wischen?
- Zuhause: Deine Wohnung sollte nicht mehr als „Häufiger Ort in …“ vorgeschlagen werden. Unter Einstellungen › Dein Zuhause gibt es „Album fürs Zuhause vorschlagen“, falls du es doch willst.
- Alles andere sollte genau wie im letzten Build funktionieren.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.
<!-- testflight:end -->

## Frühere Builds

### Build 41 (21.11.2026)

Danke fürs Testen! Dieser Build macht die App bei großen Mediatheken ruhiger. Bitte achte besonders auf:

- Update ohne Verlust: Die Daten der App ziehen beim ersten Start in eine Datei mit dem neuen Namen um. Danach sollten deine Analyse, deine Vorschläge, deine Alben von Albumist und „Rückgängig“ genau wie vorher da sein. Fängt die App von vorn an zu analysieren oder fehlt etwas, melde das bitte sofort.
- Große Mediatheken: Übersicht, Atlas und „Dein Zuhause“ rechnen jetzt im Hintergrund. Scrollen und Tippen sollten auch während einer Analyse flüssig bleiben. Atlas und „Dein Zuhause“ zeigen dafür manchmal kurz, dass sie laden.
- Atlas teilen: „Teilen“ schickt die Karte so, wie sie beim Tippen aussah, auch wenn die Übersicht gerade neu lädt.
- „Seit wann wohnst du dort?“: Der gewählte Ort zeigt einen Kreisel, solange das Datum vorgeschlagen wird.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.

### Build 40 (20.11.2026)

Danke fürs Testen! Dieser Build bringt weitere Korrekturen aus der großen Prüfung. Bitte achte besonders auf:

- Monatsalben nach Ortszeit: Fotos zählen jetzt zu dem Tag und Monat, den die Uhr am Aufnahmeort zeigte, wie in Apple Fotos. Ein Silvesterfoto aus New York landet also im Dezember, nicht im Januar.
- Pause: Tippst du während der Analyse auf „Pause“, hält jetzt auch die Arbeit im Hintergrund an, nicht nur die Anzeige. Wird das iPhone dabei weniger warm?
- Übersicht: Nach einer Analyse und beim Start sollte die Übersicht schneller stehen und nicht mehr kurz hängen.
- Vorschau vor dem Anlegen: Der Titel sagt jetzt, was gerade passiert („Alben werden angelegt“, „Ergebnis“). Gibt es schon ein Album mit demselben Namen, sagt der Hinweis ehrlich, dass du danach zwei Alben mit diesem Namen hast.
- Suche: Während die Suche neu aufgebaut wird, findet sie gleich die neuen Treffer.
- Viele Apps offen: Wenn der Speicher knapp wird, gibt Albumist Platz frei und lädt das Nötige später neu. Bitte melde, wenn etwas leer bleibt.
- Analyse-Karte: Sie zeigt jetzt nur noch das Wichtigste. Schritt, Hintergrund und „Gerade angesehen“ findest du unter „Details“. Fehlt dir dort etwas?
- Vorschau: „Alben jetzt anlegen“ steht unten in einer Leiste und ist ohne Scrollen erreichbar.
- Vorschläge: Unten stehen zwei Knöpfe, alles Weitere oben rechts unter „…“.
- Übersicht: Die Zahlen zu „sortiert“ passen jetzt zur Analyse-Karte, und „0 von 0 sortiert“ kommt nicht mehr vor.
- Auswählen in Listen: Die Tab-Leiste blendet sich aus, die Aktionen stehen unten wie in Apple Fotos.
- Nur ausgewählte Fotos freigegeben: Die Analyse bleibt erhalten, wenn du die Auswahl änderst. Rückgängig und Anlegen fragen nach vollem Zugriff.
- Rückgängig und Entfernen sagen vorher, dass iOS gleich nach dem Löschen der Alben fragt.
- Weniger warten: Ein neuer Analyse-Lauf liest nur die Fotos neu, die sich geändert haben.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.

- Build nach PR #11 (19.11.2026): Alben-Tab ohne doppelte Alben, Fotoansicht schneller, größte Schrift ganz lesbar, Suche ohne „nicht erkannt“ neben einem Vorschlag, Englisch korrigiert.
- Build 38 (19.11.2026, erster Upload ohne Klick): Orte nach der Stadt, Ortsnamen ohne Warten, Ring „Sortiert“ bis 100 %, keine Dokumente als Vorschau, Namensfeld wie in iOS, Pause und Reisen, umstrittene Gebiete, Gleicher Name, Fotos mit Zukunftsdatum, Umkreis-Suche, Akku im Diagnosebericht.
- Build nach PR #7 (19.11.2026): Ausblenden sofort sichtbar, Mediathek-Tab schneller, Fotos hängt nie fest, Rückgängig nach Abbruch, Suche mit Zeiträumen, Themen später einschalten, Sprache der Albumnamen, Tag zu Hause trennt eine Reise.
- Bis 18.11.2026: Rückgängig fragt nach dem Löschen; Analyse läuft bei Wärme weiter; Probejahr bleibt; Fotos groß ansehen.
- Build 27 (15.11.2026): erster Text, Inhalt wie oben.
