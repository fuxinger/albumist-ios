# Notiz für App Review / Notes for App Review

In App Store Connect unter „App-Prüfung → Notizen“ einfügen (Englisch reicht für die Prüfung;
Deutsch für einen deutschsprachigen Prüfer). Kein Konto, kein Login, kein Server.
Plugin-Prüfung 15.11.2026, K6: Prüfgeräte haben oft nur wenige Fotos ohne Ort, dann gibt es nichts
vorzuschlagen. Seit 16.11. erklärt die Startseite „Vorschläge“ das und bietet Beispielfotos an.
Stand Design-Welle 1 (20.11.): Einführung ohne Bereiche und ohne Jahreswahl, Startseite mit Fotokarten,
„Anlegen“ auf einer Karte legt ein neues Album sofort an (mit „Widerrufen“), der Knopf der Vorschau heißt
„Jetzt anlegen“.

## English (paste this)

Albumist sorts the user's own photo library into albums for countries and trips. Everything runs on
the device; there is no account and no server.

**See everything in about one minute**
1. Start the app, tap "Let’s Go", then "Continue" and allow access to **all photos** (albums can only
   be created with full access). The analysis starts right away.
2. Review devices usually hold only a few photos without a location, so there is nothing to suggest.
   The start page ("Suggestions") then says so ("Not Enough Photos Yet" / "No Photos Yet") and offers
   **"Try It with Sample Photos"**. Before anything is added, the app explains that the sample photos
   are really added to the Photos library (only there can it make albums of them). They are drawn by
   the app itself: 78 pictures of everyday life at home and four trips (Rome, Dolomites, Lisbon,
   Copenhagen), each with a date and a place.
3. After a few seconds of analysis the start page shows suggestions as photo cards. Tap the starter set
   "Create … albums for free", look at the preview (nothing changes before you confirm) and tap
   "Create Now". The albums appear in Photos under Collections › Albums. "Create" on a single card
   makes that one new album at once and shows "Undo" right after; anything that changes an album of
   the user's own always shows the preview first.
4. "Undo" on the result card takes everything back. The change receipt lists exactly what was done.
5. Settings › "Remove Sample Photos" deletes the sample photos the app added (by their stored
   identifiers, with the system's own delete confirmation; they then stay in "Recently Deleted" for
   30 days) and the albums it made of nothing but them. A sample photo that was edited or put into
   an album of one's own is deleted too; the reviewer's own photos and albums are never touched.
   Removing needs full photo access and no plan in progress (the app says so otherwise).

**Purchase:** the first 10 albums are free. A one-time, non-consumable in-app purchase
("Unlock Albumist") removes the limit; it is submitted together with this version. Restore and offer
codes are in Settings › Full version.

**Privacy:** photos and analysis stay on the device. If "Refine places online" is
on (the default), coordinates and the language for the names are sent to Apple's geocoder
(`CLGeocoder`) to name places; nothing is sent to us. Original photos are
never modified; the app only creates, fills and (on undo) removes its own albums. The only photos it
ever deletes are its own sample photos, when the user taps "Remove sample photos" and confirms in the
iOS dialog (they stay 30 days in Recently Deleted).

**Video:** a 60-second recording of the flow with a real photo library: <link>

## Deutsch

Albumist ordnet die eigene Fotomediathek in Alben für Länder und Reisen. Alles läuft auf dem Gerät;
es gibt kein Konto und keinen Server.

**Alles in etwa einer Minute sehen**
1. App starten, „Los geht's“, dann „Weiter“ und Zugriff auf **alle Fotos** erlauben (Alben lassen sich
   nur mit vollem Zugriff anlegen). Die Analyse beginnt gleich.
2. Prüfgeräte haben meist nur wenige Fotos ohne Ort, dann gibt es nichts vorzuschlagen. Die Startseite
   „Vorschläge“ sagt das („Noch zu wenige Fotos“ / „Noch keine Fotos“) und bietet **„Mit Beispielfotos
   ausprobieren“** an. Vorher erklärt die App, dass die Beispielfotos wirklich in der Fotos-Mediathek
   angelegt werden (nur dort kann sie Alben daraus machen). Die Bilder zeichnet die App selbst:
   78 Bilder aus dem Alltag zu Hause und von vier Reisen (Rom, Dolomiten, Lissabon, Kopenhagen), jedes
   mit Datum und Ort.
3. Nach wenigen Sekunden Analyse zeigt die Startseite Vorschläge als Fotokarten. Das Startpaket
   „… Alben kostenlos anlegen“ antippen, die Vorschau ansehen (vor dem Bestätigen ändert sich nichts)
   und „Jetzt anlegen“. Die Alben stehen in Fotos unter Sammlungen › Alben. „Anlegen“ auf einer
   einzelnen Karte legt dieses eine neue Album sofort an und zeigt gleich danach „Widerrufen“; was ein
   eigenes Album des Nutzers ändert, zeigt immer zuerst die Vorschau.
4. „Rückgängig machen“ auf der Ergebniskarte nimmt alles zurück; der Änderungsbeleg zeigt genau, was
   passiert ist.
5. Einstellungen › „Beispielfotos wieder entfernen“ löscht die Beispielfotos, die die App angelegt
   hat (anhand der gespeicherten Kennungen, mit der Löschabfrage von iOS; danach liegen sie 30 Tage
   unter „Zuletzt gelöscht“), und die Alben, die sie nur aus ihnen gemacht hat. Auch ein bearbeitetes
   oder in ein eigenes Album gelegtes Beispielfoto wird gelöscht; eigene Fotos und Alben bleiben
   unberührt. Entfernen braucht vollen Fotozugriff und kein laufendes Anlegen (sonst sagt die App das).

**Kauf:** Die ersten 10 Alben sind kostenlos. Ein einmaliger Kauf („Albumist freischalten“,
Nicht-Verbrauchsartikel) hebt die Grenze auf; er wird mit dieser Version eingereicht. Wiederherstellen
und Code einlösen unter Einstellungen › Vollversion.

**Datenschutz:** Fotos und Analyse bleiben auf dem Gerät. Ist „Orte online genauer bestimmen“ an
(ab Werk), gehen Koordinaten und die Sprache der Ortsnamen an Apples Kartendienst (`CLGeocoder`),
um Orte zu benennen; an uns geht nichts. Originalfotos werden nie
verändert; die App legt nur eigene Alben an, füllt sie und entfernt sie beim Rückgängigmachen. Fotos löscht
sie nur, wenn es ihre eigenen Beispielfotos sind: nach „Beispielfotos wieder entfernen“ und der Bestätigung im
iOS-Dialog (sie liegen dann 30 Tage unter „Zuletzt gelöscht“).

**Video:** 60 Sekunden Ablauf mit echter Mediathek: <Link>

## Drehbuch für die Bildschirmaufnahme (ca. 60 Sekunden, echte Mediathek)

Aufnahme mit der iOS-Bildschirmaufnahme (Kontrollzentrum), Hochformat, ohne Ton oder mit kurzem
Sprechertext. Ein iPhone mit echter Mediathek (einige Hundert Fotos mit Reisen). Vorher: Albumist
löschen und neu installieren, Nicht-Stören an, keine privaten Fotos im Bild, die man nicht zeigen will
(am besten eine Mediathek mit Reise- und Landschaftsfotos).

| Zeit | Bild | Was zu sehen sein muss |
|---|---|---|
| 0–8 s | Start mit App-Symbol und Versprechen, „Los geht's“ | Das Versprechen: Fotos bleiben auf dem Gerät |
| 8–15 s | „Weiter“, Zugriff „Alle Fotos erlauben“, die Analyse beginnt | Der iOS-Dialog für vollen Zugriff |
| 15–30 s | Startseite während der Analyse | Fortschritt, die eigenen Fotos im Mosaik, die ersten Reisen |
| 30–40 s | Eine Reise-Karte öffnen, Fotos nach Tagen, Fotos wischen | Echte Reisen mit Ort und Datum |
| 40–50 s | Startpaket, Vorschau, „Jetzt anlegen“ | Vorschau vor dem Anlegen, Fotos fliegen in Alben |
| 50–55 s | „Fotos-App öffnen“, Sammlungen › Alben | Die neuen Alben in Fotos |
| 55–60 s | Zurück, „Rückgängig machen“ | Alles lässt sich rückgängig machen |

Danach: Video in App Store Connect bei der Prüfnotiz anhängen (oder als nicht gelisteten Link
eintragen) und den `<link>` oben ersetzen.
