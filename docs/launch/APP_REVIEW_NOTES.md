# Notiz für App Review / Notes for App Review

Stand 26.11.2026 (Englisch lektoriert, Knopfnamen mit der App abgeglichen, unabhängige
Zweitprüfung eingearbeitet). In App Store Connect unter „App Review Information → Notes“ **nur den
englischen Block** einfügen (mit Karte etwa 3.700 Zeichen, ohne etwa 3.500). Das Feld ist reiner
Text: Darum steht der Block ohne Fettdruck, ohne Code-Schrift und ohne Zeilenumbrüche mitten im
Satz; mit der Kopieren-Taste des Blocks kopieren. Der deutsche Teil ist die Übersetzung zum
Mitlesen. Kein Konto, kein Login, kein Server, darum bleiben „Sign-in required“ und die
Demo-Zugangsdaten leer. Knopfnamen stehen in „…“, Satzzeichen außerhalb, damit niemand denkt, der
Punkt gehöre zum Knopf.

Plugin-Prüfung 15.11.2026, K6: Prüfgeräte haben oft nur wenige Fotos ohne Ort, dann gibt es nichts
vorzuschlagen. Seit 16.11. erklärt die Übersicht das und bietet Beispielfotos an.

## Vor dem Einreichen (sonst droht Ablehnung)

- [ ] **Karten-Prototyp entfernen.** Die Prototyp-Seite der Karte erscheint, wenn
      `AppTransaction.environment == .sandbox` ist (TestFlight). Apples Prüfung läuft ebenfalls in
      der Sandbox, der Prüfer würde also eine unfertige Seite sehen (Ablehnung nach 2.1/2.2).
      `MapPrototypeGate`/`MapPrototypeView` in `App/Albumist/Map/Prototype` müssen vor der ersten
      Einreichung raus (steht auch im Kartenstrang).
- [ ] In-App-Kauf `app.albumist.ios.unlock` angelegt, mit Prüf-Screenshot, **an Version 1.0
      angehängt** (`LAUNCH_CHECKLIST.md`).
- [ ] Bildschirmaufnahme nach dem Drehbuch unten gemacht, `[LINK-VIDEO]` im Block ersetzt.
- [ ] Absatz „[MAP] Map“: nur mit Karte im Build; dann „[MAP] “ löschen und „[label from the
      build]“ durch den Namen der Einstellung ersetzen. Ohne Karte den ganzen Absatz streichen.
- [ ] Texte unten mit dem eingereichten Build abgleichen (Knopfnamen, Karte, Einstellungen).
      „Full Version“ (großes V) ist der Abschnittsname ab dem Design-Paket; im Build davor
      heißt er „Full version“.
- [ ] Kontaktdaten für Rückfragen (Name, Telefon, E-Mail) im Feld „Contact Information“.

## English (paste this block)

```text
Albumist finds the trips, places, and other themes in the user’s own photo library and, after showing a preview, creates real albums for them in the Photos app. Everything can be undone. All analysis happens on the device; there is no account and no developer server.

See everything in about one minute:
1. Launch the app, tap “Let’s Go”, keep the preselected areas, and tap “Continue”. When iOS asks for photo access, choose “Allow Full Access” (albums can only be created with full access). On “Try a test run first?”, keep “The whole library” and tap “Start Analysis”.
2. If the device has only a few photos, or none with location data, there is nothing to suggest yet. The overview then says so (“Not Enough Photos Yet” or “No Photos Yet”) and offers “Try It with Sample Photos”. Before adding anything, the app explains that the sample photos are actually added to the Photos library (it can only create albums from photos that are there). The app generates them itself: 78 pictures of everyday life at home and of four trips (Rome, the Dolomites, Lisbon, and Copenhagen), each with a date and a location.
3. After a few seconds of analysis, the overview shows suggestions. Tap “Review N Suggestions” or the starter set “Create N Albums for Free”, look at the preview (nothing changes until you confirm), and tap “Create Albums Now”. The albums appear in Photos under Collections › Albums.
4. “Undo” on the result card reverts everything. Settings › “History and Undo” lists exactly what was done.
5. Settings › “Remove Sample Photos” deletes all of the app’s sample photos, including ones that were edited or added to other albums, plus the albums made only from them. The app finds these photos by their stored identifiers; iOS asks for confirmation before deleting, and the photos then stay in Recently Deleted for 30 days. All other photos and albums are never touched. Removing requires full photo access and isn’t possible while the app is applying changes; the app explains this if needed.

Purchase: The first 10 albums are free. A one-time, non-consumable in-app purchase (“Unlock Albumist”) removes the limit; it is submitted together with this version. “Restore Purchase” and “Redeem Code” are in Settings › “Full Version”.

Privacy: Photos are never uploaded, and all analysis happens on the device. If “Refine places online” is on (the default), coordinates and the language for place names are sent to Apple’s geocoder (CLGeocoder) to name places; nothing is sent to the developer. Original photos are never modified. After the user confirms, the app creates albums and adds photos to matching existing albums; “Undo” removes the albums it created and the photos it added. The only photos it ever deletes are its own sample photos, after the user taps “Remove Sample Photos” and confirms in the iOS dialog (they stay in Recently Deleted for 30 days).

Background work and notifications: A long first analysis runs as a continued processing task (BGContinuedProcessingTask), so it can keep going after the user leaves the app; the system shows its progress on the Lock Screen and can stop it at any time. A local “Analysis complete” notification is sent only if the user has allowed notifications for the app. Nothing runs on a server.

[MAP] Map (“Your World”): The globe and trip replay use the photos’ own locations. Map images are loaded from Apple’s map service, only for the visible area; Settings › “[label from the build]” turns this off.

Siri and Shortcuts: “Sort new photos with Albumist” starts an analysis of new photos; Spotlight lists countries and pending suggestions.

Video: A 60-second screen recording of the flow with a real photo library: [LINK-VIDEO]
```

## Deutsch (zum Mitlesen, nicht einfügen)

Albumist findet Reisen, Orte und andere Themen in der eigenen Fotomediathek und legt dafür nach
einer Vorschau echte Alben in der Fotos-App an. Alles lässt sich rückgängig machen. Die Analyse
läuft auf dem Gerät; es gibt kein Konto und keinen Server des Entwicklers.

**Alles in etwa einer Minute sehen**
1. App starten, auf „Los geht’s“ tippen, die vorausgewählten Bereiche unverändert lassen und auf
   „Weiter“ tippen. Wenn iOS nach dem Fotozugriff fragt, „Vollen Zugriff erlauben“ wählen (Alben
   lassen sich nur mit vollem Zugriff anlegen). Im Schritt „Erst ein Probelauf?“ die Auswahl „Die
   ganze Mediathek“ beibehalten und auf „Analyse starten“ tippen.
2. Hat das Gerät nur wenige Fotos oder keine mit Ortsangabe, gibt es noch nichts vorzuschlagen.
   Die Übersicht sagt das („Noch zu wenige Fotos“ / „Noch keine Fotos“) und bietet **„Mit
   Beispielfotos ausprobieren“** an. Vorher erklärt die App, dass die Beispielfotos wirklich in
   der Fotomediathek angelegt werden (nur dort kann sie Alben daraus anlegen). Die Bilder erzeugt
   die App selbst: 78 Bilder aus dem Alltag zu Hause und von vier Reisen (Rom, Dolomiten,
   Lissabon, Kopenhagen), jedes mit Datum und Ort.
3. Nach wenigen Sekunden Analyse zeigt die Übersicht Vorschläge. Auf „Vorschläge prüfen“ oder
   das Startpaket „… Alben kostenlos anlegen“ tippen, die Vorschau ansehen (vor dem Bestätigen
   ändert sich nichts) und auf „Alben jetzt anlegen“ tippen. Die Alben stehen in Fotos unter
   Sammlungen › Alben.
4. „Rückgängig machen“ auf der Ergebniskarte nimmt alles zurück; Einstellungen › „Verlauf und
   Rückgängig“ zeigt genau, was passiert ist.
5. Einstellungen › „Beispielfotos wieder entfernen“ löscht alle Beispielfotos der App, auch
   bearbeitete oder in andere Alben gelegte, sowie die Alben, die nur aus ihnen bestehen. Die App
   erkennt die Fotos an den gespeicherten Kennungen; iOS fragt vor dem Löschen nach, danach liegen
   sie 30 Tage unter „Zuletzt gelöscht“. Alle anderen Fotos und Alben bleiben unberührt. Das
   Entfernen braucht vollen Fotozugriff und geht nicht, während die App gerade Änderungen
   ausführt; sie weist dann darauf hin.

**Kauf:** Die ersten 10 Alben sind kostenlos. Ein einmaliger Kauf („Albumist freischalten“,
Nicht-Verbrauchsartikel) hebt die Grenze auf; er wird mit dieser Version eingereicht. „Kauf
wiederherstellen“ und „Code einlösen“ unter Einstellungen › Vollversion.

**Datenschutz:** Fotos werden nie hochgeladen, die Analyse läuft auf dem Gerät. Ist „Orte online
genauer bestimmen“ an (ab Werk), gehen Koordinaten und die Sprache der Ortsnamen an Apples
Kartendienst (CLGeocoder), um Orte zu benennen; an mich geht nichts. Originalfotos werden nie
verändert. Nach der Bestätigung legt die App Alben an und ergänzt vorhandene passende Alben;
„Rückgängig machen“ entfernt die angelegten Alben und die hinzugefügten Fotos wieder. Fotos löscht
sie nur, wenn es ihre eigenen Beispielfotos sind: nach „Beispielfotos wieder entfernen“ und der
Bestätigung im iOS-Dialog (sie liegen dann 30 Tage unter „Zuletzt gelöscht“).

**Hintergrund und Mitteilungen:** Eine lange erste Analyse läuft als fortgesetzte Aufgabe
(BGContinuedProcessingTask) und kann deshalb nach dem Verlassen der App weiterlaufen; iOS zeigt
dabei den Fortschritt auf dem Sperrbildschirm und kann die Aufgabe jederzeit beenden. Die
Mitteilung „Analyse fertig“ kommt nur, wenn Mitteilungen für die App erlaubt sind.

**[KARTE] Karte („Deine Welt“):** Globus und „Reise abspielen“ nutzen die Aufnahmeorte der Fotos.
Kartenbilder kommen von Apples Kartendienst, nur für den sichtbaren Ausschnitt; abschaltbar unter
Einstellungen › „[Name aus dem Build]“.

**Siri und Kurzbefehle:** „Neue Fotos sortieren mit Albumist“ startet die Analyse neuer Fotos;
Spotlight findet Länder und offene Vorschläge.

**Video:** 60 Sekunden Ablauf mit echter Mediathek: [LINK-VIDEO]

Was die Zweitprüfung (26.11.) hier korrigiert hat: Die Notiz sagte, die App lege „nur eigene
Alben“ an; tatsächlich ergänzt sie auch vorhandene passende Alben, und „Rückgängig machen“ nimmt
die hinzugefügten Fotos wieder heraus (wie Produktseite und Presse sagen). „Allow access to all
photos“ → der echte Knopf von iOS „Allow Full Access“. „Review devices usually have …“ unterstellte
den Prüfern, was auf ihren Geräten ist. „the change receipt“ gibt es in der App nicht; der Ort
heißt Einstellungen › „History and Undo“. Schritt 5 entwirrt.

Nach dem Abgleich mit der Wortlaut-Prüfung im Code (26.11.): Kartenbilder kommen jetzt von
„Apple’s map service“ / „Apples Kartendienst“, ohne den Namen von Apples Karten-Framework
(`PromiseWordingTests` lässt ihn hier nicht zu, weil die Ortsnamen über `CLGeocoder` kommen).
„Full version“ → „Full Version“ wie in der App ab dem Design-Paket.

## Drehbuch für die Bildschirmaufnahme (ca. 60 Sekunden, echte Mediathek)

Aufnahme mit der iOS-Bildschirmaufnahme (Kontrollzentrum), Hochformat, ohne Ton oder mit kurzem
Sprechertext. Ein iPhone mit echter Mediathek (einige Hundert Fotos mit Reisen). Vorher: Albumist
löschen und neu installieren, Nicht-Stören an, keine privaten Fotos im Bild, die man nicht zeigen will
(am besten eine Mediathek mit Reise- und Landschaftsfotos).

| Zeit | Bild | Was zu sehen sein muss |
|---|---|---|
| 0–8 s | Start, „Los geht’s“, Bereiche, „Weiter“ | Das Versprechen: Fotos werden nicht hochgeladen |
| 8–15 s | Zugriff „Vollen Zugriff erlauben“, Probelauf, „Analyse starten“ | Der iOS-Dialog für vollen Zugriff |
| 15–30 s | Übersicht während der Analyse | Fortschritt, die eigenen Fotos im Mosaik |
| 30–40 s | „Vorschläge prüfen“, eine Reise öffnen, Fotos wischen | Echte Reisen mit Ort und Datum |
| 40–50 s | Startpaket oder Auswahl, Vorschau, „Alben jetzt anlegen“ | Vorschau vor jeder Änderung, Fotos fliegen in Alben |
| 50–55 s | „Fotos-App öffnen“, Sammlungen › Alben | Die neuen Alben in Fotos |
| 55–60 s | Zurück, „Rückgängig machen“ | Alles lässt sich zurücknehmen |

Mit Karte: nach 50 s zusätzlich 10 s „Deine Welt“ (Globus drehen, eine Reise abspielen); das
Video darf dann 70 s lang sein, die Prüfnotiz hat keine Grenze.

Danach: Video in App Store Connect bei der Prüfnotiz anhängen (oder als nicht gelisteten Link
eintragen) und `[LINK-VIDEO]` im englischen Block ersetzen.
