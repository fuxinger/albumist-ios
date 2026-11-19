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
Danke fürs Testen! Dieser Build bringt viele Korrekturen aus deinen Tests. Bitte achte besonders auf:

- Orte, an denen du öfter bist: heißen jetzt nach der Stadt (nicht „Bayern“), und derselbe Ort kommt nur einmal. Dein Zuhause erkennt Albumist an den Fotos des ganzen Tages.
- Ortsnamen: Während du die App offen hast, wartet die Analyse nicht mehr auf Apple. Was dann noch fehlt, holt Albumist später nach; die Karte zeigt das als eigene Verfeinerung.
- Ring „Sortiert“: Ignorierte Fotos zählen nicht mehr mit, der Ring kann 100 % erreichen. Die Liste „Sortiert“ in der Mediathek zeigt dieselbe Zahl.
- Vorschaubilder: Bankkarten, Ausweise und andere sensible Dokumente erscheinen nie mehr als Vorschau oder Titelbild.
- Namensfeld: Einen Ort selbst benennen geht jetzt wie in den Einstellungen von iOS; „Anpassen“ zeigt den Namen, den du getippt hast.
- Pause: Änderst du während einer Pause eine Reise (teilen, zusammenlegen, „Aufheben“), läuft die Analyse weiter und wendet die Änderung an.
- Suche: Orte, die du selbst benannt hast, findest du über ihren Namen, auch bevor es ihr Album gibt.
- Umstrittene Gebiete (etwa Krim, Taiwan, Kosovo): Albumist ordnet sie keinem Land zu und sagt „nicht sicher“.
- Gleicher Name: Hast du schon ein Album mit genau dem Namen eines Vorschlags, ergänzt Albumist dieses Album, statt ein zweites anzulegen.
- Fotos mit falschem Datum in der Zukunft und Fotos, die einmal nicht lesbar waren, bleiben nicht mehr für immer unsortiert; Albumist versucht sie später noch einmal.
- Umkreis-Suche: Findet jetzt jedes Foto im Kreis.
- Reisen bearbeiten: Nach einem Fehler beim Neuberechnen werden die Knöpfe wieder frei.
- Diagnosebericht: zeigt jetzt, wie viel Akku die Analyse ungefähr pro 1.000 Fotos braucht.

Wenn etwas nicht stimmt: Einstellungen > „Diagnose teilen“ und den Bericht mit einer kurzen Beschreibung schicken. Der Bericht enthält keine Fotos, Namen oder Orte.
<!-- testflight:end -->

## Frühere Builds

- Build nach PR #7 (19.11.2026): Ausblenden sofort sichtbar, Mediathek-Tab schneller, Fotos hängt nie fest, Rückgängig nach Abbruch, Suche mit Zeiträumen, Themen später einschalten, Sprache der Albumnamen, Tag zu Hause trennt eine Reise.
- Bis 18.11.2026: Rückgängig fragt nach dem Löschen; Analyse läuft bei Wärme weiter; Probejahr bleibt; Fotos groß ansehen.
- Build 27 (15.11.2026): erster Text, Inhalt wie oben.
