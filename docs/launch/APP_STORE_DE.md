# App Store – Deutsch (Produktseite)

Stand 26.11.2026: Lektorat und App-Store-Prüfung (Sprache, Apples Grenzen und Schreibweisen,
jede Aussage am Code gegengeprüft), danach unabhängige Zweitprüfung eingearbeitet. Ersetzt die
Fassung vom 21.11.
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
- **Datenschutz überall gleich und genau:** „Albumist lädt keine Fotos hoch“ und „die Analyse
  läuft auf deinem iPhone“, aber nie „alles bleibt auf dem iPhone“ oder „kein Foto verlässt dein
  iPhone“. Ab Werk gehen für Ortsnamen Koordinaten an Apples Kartendienst (abschaltbar), mit der
  Karte auch Anfragen für Kartenbilder, und mit iCloud-Fotos liegen Fotos ohnehin in iCloud.
  Redaktionen legen Produktseite, Pressetexte und Datenschutzerklärung nebeneinander.
- Keine Fachwörter. Knopfnamen genau wie in der App, in „…“.
- Albumist spricht als **ich** (eine Person, kein Team), wie Webseite, Pressemails und
  Featuring-Bewerbung. Die Leser werden geduzt, wie in der App.
- Schreibweisen wie Apple: iPhone, iPad, Mac, iCloud-Fotos, Fotos-App, Sperrbildschirm,
  Dunkelmodus, „Größerer Text“, „Bewegung reduzieren“, Apple Intelligence, Apple Account.
  Keine Mehrzahl von Produktnamen („iPhone-Modelle“, nicht „iPhones“) und „iPhone“ nie in
  Versalien (darum keine Zwischentitel mit „IPHONE“).
- „Tippen auf“ für Knöpfe („tippe auf „Alben jetzt anlegen““), „eingeben“ für Suchtext.
- „Anlegen“ für Alben (wie der Knopf), nicht „machen“ oder „erstellen“; „rückgängig machen“ wie
  der Knopf.
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

- Startwoche: `Nur in der Startwoche günstiger: beliebig viele Alben, einmal zahlen, kein Abo. Albumist findet deine Reisen und legt echte Alben in deiner Fotos-App an.` (153)
- Danach: `Jahre voller Fotos, endlich in Ordnung: Albumist findet deine Reisen und legt echte Alben in deiner Fotos-App an. Erst ansehen, dann anlegen, jederzeit rückgängig.` (163)

> Der Werbetext der Startwoche sagt, *was* günstiger ist: Der Download ist ohnehin kostenlos,
> günstiger ist die Vollversion. Am letzten Tag des Startpreises gegen „Danach“ tauschen.

**Schlüsselwörter (max. 100 Byte, ohne Leerzeichen, nichts aus Name und Untertitel):**
```
urlaub,urlaubsfotos,fotoalbum,reisen,album,ordnen,aufräumen,bilder,weltkarte,länder,screenshots
```
(95 Zeichen, 97 Byte; Apple zählt Byte, Umlaute zählen doppelt.) Deutsche Suche trennt
zusammengesetzte Wörter nicht und erkennt Ein- und Mehrzahl nicht sicher, darum „urlaubsfotos“,
„fotoalbum“, „reisen“ und „album“ eigens. Bewusst nicht drin: Wörter aus Name und Untertitel,
„app“, Namen anderer Apps, „speicher“ oder „löschen“ (locken Leute, die Speicher frei räumen
wollen; das macht Albumist nicht).

**Beschreibung** (max. 4.000; diese Fassung 2.736 Zeichen mit Karte, 2.596 ohne):

```
Tausende Fotos und kein einziges Album? Albumist findet deine Reisen und legt sie als echte Alben in deiner Fotos-App an. Du siehst alles vorher, und Albumist lädt keine Fotos hoch.

REISEN WERDEN ALBEN
Albumist erkennt Urlaube und Ausflüge von selbst, auch solche, die Jahre zurückliegen, und trennt sie vom Alltag zu Hause. Jede Reise bekommt ein eigenes Album mit Ort und Zeit im Namen, etwa „Gardasee, August 2026“. Die Alben erscheinen in Apples Fotos-App, mit iCloud-Fotos auch auf Mac und iPad.

ERST ANSEHEN, DANN ANLEGEN
Albumist zeigt dir vorher jedes Album mit seinen Fotos. Nimm Fotos heraus, ändere Namen, teile Reisen auf oder lege sie zusammen. Erst wenn du auf „Alben jetzt anlegen“ tippst, ändert sich etwas.

ALLES LÄSST SICH RÜCKGÄNGIG MACHEN
Eine Liste zeigt genau, was angelegt wurde, und mit „Rückgängig machen“ ist alles wieder wie vorher. Deine Fotos löscht und verändert Albumist nie. Hast du schon passende Alben, ergänzt Albumist sie, statt sie doppelt anzulegen.

[KARTE] DEINE WELT
Ein Globus mit allen Orten, an denen du fotografiert hast. Spiel eine Reise noch einmal ab, Station für Station, mit deinen besten Fotos, und teile deine Welt als Bild.
[OHNE KARTE] DEIN REISE-ATLAS
Eine Weltkarte mit allen Ländern, in denen du fotografiert hast, mit Flagge und Fotozahl für jedes Land. Als Bild zum Teilen.

AUS SUCHTREFFERN WERDEN ALBEN
Gib „Hunde Italien 2023“ ein, und Albumist zeigt dir die passenden Fotos. Auf iPhone-Modellen mit Apple Intelligence versteht die Suche auch Beschreibungen in eigenen Worten wie „Grillen bei Oma letzten Sommer“. Aus den Treffern legst du auf Wunsch gleich ein Album an.

MEHR ALS REISEN
Albumist legt auch Alben an für:
• Länder, auf Wunsch auch Städte
• Orte, an denen du oft bist, mit Namen, die du selbst vergibst
• Screenshots nach Inhalt: Bestellungen, Tickets, Rezepte
• Dokumente wie Rechnungen und Kassenbons
• Themen wie Hunde, Strand oder Essen
• Monate und Jahre, wenn du magst

PRIVAT VON ANFANG AN
• Die ganze Analyse läuft auf deinem iPhone
• Kein Konto, kein Tracking, keine Werbung
• Für Ortsnamen schickt iOS nur Koordinaten an Apples Kartendienst, nie Fotos; abschaltbar
[KARTE] • Kartenbilder kommen von Apple, nur für den Ausschnitt, den du gerade ansiehst; ebenfalls abschaltbar

LÄUFT IM HINTERGRUND WEITER
Große Mediatheken brauchen Zeit. Du kannst Albumist dabei verlassen: Solange iOS es erlaubt, analysiert die App weiter und zeigt den Fortschritt auf dem Sperrbildschirm. Neue Fotos sortierst du später mit einem Fingertipp oder per Siri ein.

EINMAL ZAHLEN, KEIN ABO
Die ersten 10 Alben sind kostenlos. Danach schaltest du Albumist mit einem einmaligen Kauf frei und legst so viele Alben an, wie du möchtest.

Albumist unterstützt VoiceOver, „Größerer Text“, den Dunkelmodus und „Bewegung reduzieren“.

Albumist entwickle ich allein. Fragen oder Ideen? Schreib mir über die Support-Seite. Ich lese jede Nachricht.
```

Was sich gegenüber dem 21.11. geändert hat (Lektorat):
- „Erst wenn du „Alben jetzt anlegen“ tippst“ hieß wörtlich „den Text eintippen“. Richtig:
  „auf „…“ tippst“.
- „teile oder verbinde Reisen“ las sich als „Reisen weiterschicken“. Jetzt „teile Reisen auf
  oder lege sie zusammen“ (die App sagt „zusammenlegen“).
- Überschrift „SUCHEN, WIE DU SPRICHST“ passte nicht zum Beispiel „Hunde Italien 2023“. Jetzt
  beides: Stichwörter für alle, eigene Worte mit Apple Intelligence (`SmartAssistant.searchKeywords`,
  Beispiel aus `SearchView.swift`). Die Featuring-Bewerbung sagt dasselbe.
- „sortiert es weiter“ (im Hintergrund) klang, als lege die App Alben ohne Zustimmung an. Im
  Hintergrund wird nur analysiert, darum „analysiert die App weiter“.
- „mit einem Tipp“ (= Hinweis) → „mit einem Fingertipp“, wie Apple.
- „Wir lesen jede Nachricht“ → „Ich lese jede Nachricht“: eine Stimme mit Webseite und Presse.
- Satzzeichen in Aufzählungen einheitlich (keine Punkte am Ende).

Nach der unabhängigen Zweitprüfung (26.11.):
- **Datenschutz genau wie in der Datenschutzerklärung:** „kein Foto verlässt dein iPhone“ →
  „Albumist lädt keine Fotos hoch“; „schickt iOS nur den Aufnahmeort an Apple“ → „nur Koordinaten
  an Apples Kartendienst, nie Fotos“.
- „PRIVAT AUF DEINEM IPHONE“ → „PRIVAT VON ANFANG AN“ (wie die Webseite; Apple erlaubt „iPhone“
  nicht in Versalien). „Auf iPhones“ → „Auf iPhone-Modellen“.
- „FOTOS SCHNELL FINDEN“ → „AUS SUCHTREFFERN WERDEN ALBEN“: Suchen kann die Fotos-App selbst; was
  sie ergänzt, ist das Album aus den Treffern. „ganze Sätze“ → „Beschreibungen in eigenen Worten“
  (das Beispiel ist kein Satz).
- Bedienungshilfen standen in der Datenschutz-Liste; jetzt eigene Zeile mit Apples Namen
  („Größerer Text“ statt „große Schrift“).
- Werbetext der Startwoche sagt, was günstiger ist. In-App-Kauf „Beliebig viele Alben“ statt
  „Unbegrenzte Alben“ (aus dem Englischen übersetzt).
- Kleinigkeiten: „analysiert die App weiter“ (vorher zwei „es“ mit verschiedenem Bezug), „Neue
  Fotos sortierst du … ein“ (den Fingertipp macht der Mensch), „statt sie doppelt anzulegen“,
  Einleitung „Albumist legt auch Alben an für:“, „ALLES LÄSST SICH RÜCKGÄNGIG MACHEN“ wie der
  Knopf, „Flagge und Fotozahl für jedes Land“, „Albumist entwickle ich allein“ als Bezug für das
  „ich“ am Schluss.

Prüfvermerke (vor dem Einreichen abhaken):
- [ ] Erster Absatz (sichtbar vor „mehr“) mit dem eingereichten Build gegenlesen.
- [ ] „Sprachsteuerung“ erst in die Zeile „Albumist unterstützt …“, wenn der Test aus
      `BARRIEREFREIHEIT_ANGABEN.md` bestanden ist.
- [ ] Familienfreigabe ist heute **aus** (`App/StoreKit/Albumist.storekit`: `"familyShareable":
      false`). Wird sie eingeschaltet (in App Store Connect danach nicht mehr ausschaltbar), unter
      EINMAL ZAHLEN ergänzen: „Mit der Familienfreigabe für alle in deiner Familie.“
- [ ] „Hunde Italien 2023“ und „Grillen bei Oma letzten Sommer“ sind die Beispiele der App
      selbst (`SearchView.swift`), „Als Album anlegen“ der Knopf bei den Treffern. Vor dem
      Einreichen mit der Demo-Mediathek ausprobieren, die eigenen Worte auf einem iPhone mit
      Apple Intelligence.
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
- Beschreibung (max. 45): `Beliebig viele Alben. Einmalkauf, kein Abo.` (43)

> Korrektur 26.11.: Die Grenzen sind 30 und 45 Zeichen (App Store Connect Hilfe, In-App Purchase
> information), nicht 35 und 55. Die alte Beschreibung (50 Zeichen) hätte App Store Connect
> abgelehnt.

**Copyright:** `2026 [Name von Fuchs oder Firma]` (ohne ©, Apple setzt es selbst).
