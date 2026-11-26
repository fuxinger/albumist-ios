# App Store – Deutsch (Produktseite)

Stand 26.11.2026: Lektorat und App-Store-Prüfung (Sprache, Apples Grenzen und Schreibweisen,
jede Aussage am Code gegengeprüft). Ersetzt die Fassung vom 21.11.
Zeilen mit **[KARTE]** erst übernehmen, wenn die Karte „Deine Welt“ im eingereichten Build ist;
bis dahin gilt die Zeile **[OHNE KARTE]**. Alle Zeichenzahlen mit Python nachgezählt.

## Leitgedanke (nur intern)

Albumist **ergänzt die Fotos-App**: Alles, was es macht, landet als echtes Album in Apples
Fotos-App, auf dem iPhone und mit iCloud-Fotos auch auf Mac und iPad. Nie „besser als Apple
Fotos“. Vier Wörter tragen den Unterschied: **echte Alben · privat · vorher ansehen ·
rückgängig.** Dazu: einmal zahlen, kein Abo.

Ohne Namen zu nennen (Apple verbietet Namen anderer Apps) heben wir uns ab von:
- Apples Sammlung „Reisen“: zeigt Reisen nur an. → „echte Alben in deiner Fotos-App“
- Themen-Apps im Abo (34,99 €/Jahr) → „Einmal zahlen. Kein Abo.“
- Regel-Apps, in denen man alles selbst einstellt → „findet deine Reisen von selbst“

Regeln für jeden Satz:
- Nichts Absolutes, das die App nicht hält. Im Fließtext kein „jede Reise“ (Reisen brauchen Ort
  und mindestens 10 Fotos, `TripSettings.minPhotos`); in Untertitel und Bildzeilen ist es als
  Versprechen erlaubt.
- „Deine Fotos“ statt „nie ein Foto“ (die App löscht auf Wunsch ihre eigenen Beispielfotos).
- Keine Fachwörter. Knopfnamen genau wie in der App, in „…“.
- Albumist spricht als **ich** (ein Entwickler), wie Webseite, Pressemails und
  Featuring-Bewerbung. Die Leser werden geduzt, wie in der App.
- Schreibweisen wie Apple: iPhone, iPad, Mac, iCloud-Fotos, Fotos-App, Sperrbildschirm,
  Dunkelmodus, „Bewegung reduzieren“, Apple Intelligence, Apple Account.
- „Tippen auf“ für Knöpfe („tippe auf „Alben jetzt anlegen““), „eingeben“ für Suchtext.
- „Teilen“ bedeutet in der App „an andere schicken“ (Share). Für das Zerlegen einer Reise darum
  „aufteilen“ schreiben, sonst liest man „Reise teilen“ als „Reise weiterschicken“.

## Felder

**Name (max. 30):** `Albumist – Fotos sortieren` (26)

> Name, Untertitel und Schlüsselwörter sind die einzigen Felder, die Apples Suche liest. Eine
> neue App wird über „Fotos sortieren“ gefunden, nicht über „Albumist“. Flighty macht es genauso
> („Flighty – Live Flight Tracker“). Unter dem Icon steht weiter nur „Albumist“.

**Untertitel (max. 30):** `Echte Alben für jede Reise` (26)

**Kategorie:** Foto & Video (Haupt), Reisen (zweite).

**Preis:** 6,99 € einmalig (Entscheidung Fuchs 25.11.2026); Startwoche 4,99 € (Entscheidung Fuchs
25.11.2026). Der Preis steht nur in App Store Connect, in keinem Text und keinem Bild.

**Werbetext (max. 170, ohne neue Prüfung änderbar). Ohne Preis**, weil derselbe Text auch in
Österreich und der Schweiz (Franken) erscheint und nach der Startwoche sonst falsch wäre:

- Startwoche: `Nur zum Start günstiger: einmal zahlen, kein Abo. Albumist findet deine Reisen und macht daraus echte Alben in deiner Fotos-App. Ganz privat auf deinem iPhone.` (159)
- Danach: `Jahre voller Fotos, endlich in Ordnung: Albumist findet deine Reisen und legt echte Alben in deiner Fotos-App an. Erst ansehen, dann anlegen, jederzeit rückgängig.` (163)

**Schlüsselwörter (max. 100 Byte, ohne Leerzeichen, nichts aus Name und Untertitel):**
```
urlaub,urlaubsfotos,fotoalbum,reisen,album,ordnen,aufräumen,bilder,weltkarte,länder,screenshots
```
(95 Zeichen, 97 Byte; Apple zählt Byte, Umlaute zählen doppelt.) Deutsche Suche trennt
zusammengesetzte Wörter nicht und erkennt Ein- und Mehrzahl nicht sicher, darum „urlaubsfotos“,
„fotoalbum“, „reisen“ und „album“ eigens. Bewusst nicht drin: Wörter aus Name und Untertitel,
„app“, Namen anderer Apps, „speicher“ oder „löschen“ (locken Leute, die Speicher frei räumen
wollen; das macht Albumist nicht).

**Beschreibung** (max. 4.000; diese Fassung 2.619 Zeichen mit Karte, 2.475 ohne):

```
Tausende Fotos und kein einziges Album? Albumist findet deine Reisen und legt sie als echte Alben in deiner Fotos-App an. Du siehst alles vorher, und kein Foto verlässt dein iPhone.

REISEN WERDEN ALBEN
Albumist erkennt Urlaube und Ausflüge von selbst, auch solche, die Jahre zurückliegen, und trennt sie vom Alltag zu Hause. Jede Reise bekommt ein eigenes Album mit Ort und Zeit im Namen, etwa „Gardasee, August 2026“. Die Alben erscheinen in Apples Fotos-App, mit iCloud-Fotos auch auf Mac und iPad.

ERST ANSEHEN, DANN ANLEGEN
Bevor sich etwas ändert, zeigt dir Albumist jedes Album mit seinen Fotos. Nimm Fotos heraus, ändere Namen, teile Reisen auf oder lege sie zusammen. Erst wenn du auf „Alben jetzt anlegen“ tippst, ändert sich etwas.

ALLES LÄSST SICH ZURÜCKNEHMEN
Eine Liste zeigt genau, was angelegt wurde, und mit „Rückgängig machen“ ist alles wieder wie vorher. Deine Fotos löscht und verändert Albumist nie. Hast du schon passende Alben, ergänzt Albumist sie, statt neue doppelt anzulegen.

[KARTE] DEINE WELT
Ein Globus mit allen Orten, an denen du fotografiert hast. Spiel eine Reise noch einmal ab, Station für Station, mit deinen besten Fotos, und teile deine Welt als Bild.
[OHNE KARTE] DEIN REISE-ATLAS
Eine Weltkarte mit allen Ländern, in denen du fotografiert hast, mit der Zahl der Fotos und Flaggen. Als Bild zum Teilen.

FOTOS SCHNELL FINDEN
Gib „Hunde Italien 2023“ ein, und Albumist zeigt dir die passenden Fotos. Auf iPhones mit Apple Intelligence versteht die Suche auch ganze Sätze wie „Grillen bei Oma letzten Sommer“. Aus den Treffern machst du auf Wunsch ein Album.

MEHR ALS REISEN
• Länder, auf Wunsch auch Städte
• Orte, an denen du oft bist, mit Namen, die du selbst vergibst
• Screenshots nach Inhalt: Bestellungen, Tickets, Rezepte
• Dokumente wie Rechnungen und Kassenbons
• Themen wie Hunde, Strand oder Essen
• Monate und Jahre, wenn du magst

PRIVAT AUF DEINEM IPHONE
• Die ganze Analyse läuft auf deinem iPhone
• Kein Konto, kein Tracking, keine Werbung
• Für Ortsnamen schickt iOS nur den Aufnahmeort an Apple, nie das Foto; abschaltbar
[KARTE] • Kartenbilder kommen von Apple, nur für den Ausschnitt, den du gerade ansiehst; ebenfalls abschaltbar
• Gemacht für VoiceOver, große Schrift, Dunkelmodus und „Bewegung reduzieren“

LÄUFT IM HINTERGRUND WEITER
Große Mediatheken brauchen Zeit. Du kannst Albumist dabei verlassen: Solange iOS es erlaubt, analysiert es weiter und zeigt den Fortschritt auf dem Sperrbildschirm. Neue Fotos nimmt Albumist später mit einem Fingertipp oder per Siri dazu.

EINMAL ZAHLEN, KEIN ABO
Die ersten 10 Alben sind kostenlos. Danach schaltest du Albumist mit einem einmaligen Kauf frei und legst so viele Alben an, wie du möchtest.

Fragen oder Ideen? Schreib mir über die Support-Seite. Ich lese jede Nachricht.
```

Was sich gegenüber dem 21.11. geändert hat (Lektorat):
- „Erst wenn du „Alben jetzt anlegen“ tippst“ hieß wörtlich „den Text eintippen“. Richtig:
  „auf „…“ tippst“.
- „teile oder verbinde Reisen“ las sich als „Reisen weiterschicken“. Jetzt „teile Reisen auf
  oder lege sie zusammen“ (die App sagt „zusammenlegen“).
- Überschrift „SUCHEN, WIE DU SPRICHST“ passte nicht zum Beispiel „Hunde Italien 2023“. Jetzt
  beides: Stichwörter für alle, ganze Sätze mit Apple Intelligence (`SmartAssistant.searchKeywords`,
  Beispiel aus `SearchView.swift`). Die Featuring-Bewerbung sagt dasselbe.
- „sortiert es weiter“ (im Hintergrund) klang, als lege die App Alben ohne Zustimmung an. Im
  Hintergrund wird nur analysiert, darum „analysiert es weiter“.
- „mit einem Tipp“ (= Hinweis) → „mit einem Fingertipp“, wie Apple.
- „Wir lesen jede Nachricht“ → „Ich lese jede Nachricht“: eine Stimme mit Webseite und Presse.
- Satzzeichen in Aufzählungen einheitlich (keine Punkte am Ende).

Prüfvermerke (vor dem Einreichen abhaken):
- [ ] Erster Absatz (sichtbar vor „mehr“) mit dem eingereichten Build gegenlesen.
- [ ] „Sprachsteuerung“ erst in die Zeile „Gemacht für …“, wenn der Test aus
      `BARRIEREFREIHEIT_ANGABEN.md` bestanden ist.
- [ ] Familienfreigabe ist heute **aus** (`App/StoreKit/Albumist.storekit`: `"familyShareable":
      false`). Wird sie eingeschaltet (in App Store Connect danach nicht mehr ausschaltbar), unter
      EINMAL ZAHLEN ergänzen: „Mit der Familienfreigabe für alle in deiner Familie.“
- [ ] „Hunde Italien 2023“ und „Grillen bei Oma letzten Sommer“ sind die Beispiele der App
      selbst (`SearchView.swift`), „Als Album anlegen“ der Knopf bei den Treffern. Vor dem
      Einreichen mit der Demo-Mediathek ausprobieren, den Satz auf einem iPhone mit Apple
      Intelligence.
- [ ] Datumsbeispiel = Vorlage ab Werk (`NamingTemplate.tripDefault`, `NamingTests.swift`,
      `defaultTripTemplate`).
- [ ] Siri: Kurzbefehl „Neue Fotos sortieren mit Albumist“ (`Shortcuts.swift`).
- [ ] [KARTE] „mit deinen besten Fotos“ und „teile deine Welt als Bild“ am fertigen Build prüfen.

**Neuerungen:** Für die erste Version gibt es dieses Feld in App Store Connect nicht („This
property isn’t available for the first version of the app“, App Store Connect Hilfe, Platform
version information). Vorlage für das erste Update, mit echten Änderungen füllen:
> Neu in dieser Version: [eine Neuerung, die man sieht]. Außerdem: [Verbesserung]. Danke für alle
> Nachrichten! Schreib mir gern weiter über die Support-Seite.

**In-App-Kauf** (`app.albumist.ios.unlock`, Nicht-Verbrauchsartikel):
- Anzeigename (max. 30): `Albumist freischalten` (21)
- Beschreibung (max. 45): `Unbegrenzte Alben. Einmal zahlen, kein Abo.` (43)

> Korrektur 26.11.: Die Grenzen sind 30 und 45 Zeichen (App Store Connect Hilfe, In-App Purchase
> information), nicht 35 und 55. Die alte Beschreibung (50 Zeichen) hätte App Store Connect
> abgelehnt.

**Copyright:** `2026 [Name von Fuchs oder Firma]` (ohne ©, Apple setzt es selbst).
