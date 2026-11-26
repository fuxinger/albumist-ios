# Featuring-Bewerbung (App Store Connect → Nominierungen)

Stand 26.11.2026: Lektorat (natives Englisch, eine Erzählperspektive, Apples Schreibweisen),
jede Aussage am Code gegengeprüft, danach unabhängige Zweitprüfung (US-Lektorat) eingearbeitet.
Ersetzt die Fassung vom 21.11., den Entwurf vom 14.11. und den
Entwurf in `/mnt/project-files/sortly-launch/Featuring-Bewerbung-Entwurf.md`.

## Was Apple sagt (gelesen 21.11., nachgeprüft 26.11.2026)

- Wo: App Store Connect → Albumist → **Featuring** → **Nominations** → „+“. Rollen: Kontoinhaber,
  Admin, App Manager, Marketing. Eine Nominierung lässt sich als Entwurf speichern.
- Typen: **App Launch**, App Enhancements, New Content. Typ ist nach dem Absenden nicht änderbar.
- Wann: Die Seite „Getting featured“ nennt **mindestens zwei Wochen** Vorlauf, die Hilfeseite zur
  Nominierung empfiehlt mindestens drei; für mehr Chancen **bis zu drei Monate**. Für eine
  „Story“ (Artikel im Heute-Tab) braucht die Redaktion etwa 8 Wochen. Das Datum lässt sich später
  anpassen, also **früh einreichen und Datum nachziehen**.
- Die Redaktion liest jede Woche. Wichtigster Satz aus Apples Gespräch mit Entwicklern: **„We don't
  feature games that we haven't played.“** Darum gehört der öffentliche TestFlight-Link hinein;
  Apple erlaubt ihn ausdrücklich unter „Supplemental Materials“ (bis 5 Links).
- Worauf Apple achtet (Seite „Getting featured“, ausdrücklich „no checklist“): Bedienung,
  Gestaltung, Innovation („solve a unique problem“), Einzigartigkeit („fresh approach to a familiar
  category“), Barrierefreiheit, Sprachen und die Produktseite (Bilder, Video, Texte, Bewertungen).
- „Helpful Details“ ist laut Apple der Platz für Barrierefreiheit, Inklusion, Priorität und
  „unique aspects of your app or team“: hier gehört der persönliche Satz hin.
- Apple nennt für keines der Felder eine Zeichengrenze. Der Text unten bleibt trotzdem unter
  60 / 1.000 / 500 Zeichen: Redakteure lesen viele Bewerbungen, kurz wirkt professioneller.

## Haltung

Albumist ist eine **Ergänzung zur Fotos-App**: Es füllt Apples Fotos-App mit echten Alben. Keine
Liste von Apple-Techniken (bewegt keine Redaktion), sondern was Menschen davon haben. Das ist genau
die Art App, die Apples Redaktion gern zeigt (macht ein Apple-Erlebnis besser, nutzt Apple-Technik,
schützt die Privatsphäre). Kein Wort von Konkurrenz zu Apple Fotos.

Sprache: US-Englisch, durchgehend in der dritten Person über die Nutzer („people“), wie ein
Redaktionstext; keine unbelegten Mengenangaben („most people“ → „many iPhone libraries“).

## Felder

**Nomination Name** (≤ 60)
```
Albumist: every trip becomes a real album in Photos
```
(51)

**Type:** App Launch

**Publish Date:** Starttag (sobald fest; bis dahin realistisches Datum, später anpassen)

**Description** (≤ 1.000)
```
Many iPhone libraries hold thousands of photos and hardly any albums. Albumist sorts that out without uploading a single photo: it recognizes trips, even ones from a decade ago, and turns each one into a real album in the Photos app, where iCloud Photos syncs it to Mac and iPad. Countries, frequent places, screenshots, and documents can get albums too.

Trust comes first. Before anything changes, people see each album with its photos and can remove photos or rename trips. Everything can be undone, existing albums are added to rather than duplicated, and people’s photos are never edited or deleted.

“Your World” puts every place from a library on a globe and replays any trip stop by stop with its best shots. [MAP]

Albumist feels like part of iOS: Siri sorts new photos, Spotlight finds countries, on-device Apple Intelligence understands searches like “barbecue at Grandma’s last summer,” and progress appears on the Lock Screen. No account, no tracking, no ads, no subscription.
```
(983 Zeichen mit dem Kartenabsatz, ohne die Marke „[MAP]“; ohne Karte den dritten Absatz
streichen: 871.)

Warum so formuliert (Zweitprüfung 26.11.): „without uploading a single photo“ statt „without a
single photo leaving the device“, weil ab Werk Koordinaten für Ortsnamen an Apple gehen und
iCloud-Fotos Fotos ohnehin in iCloud hält; „Upload“ stimmt immer. „can follow“ las sich wie
„kommt in einem späteren Update“, darum „can get albums too“. „favorite places“ → „frequent
places“ (so heißt die Funktion). „the Photos app“ statt „Apple Photos“: So schreibt Apples
Redaktion selbst. Kein „someone … their“ mehr, das zwischen Einzahl und Mehrzahl sprang.

Belege im Code: Reisen und Ausflüge (`TripSettings`), echte Alben in Fotos, Vorschau vor jeder
Änderung, Rückgängig, Abgleich mit vorhandenen Alben (`AlbumMatcher`), Siri-Kurzbefehl
„Sort new photos with Albumist“ (`AppShortcuts.xcstrings`), Spotlight für Länder und Vorschläge
(`AppEntities.swift`, `IndexedEntity`), Suche in natürlicher Sprache über Apple Intelligence auf
dem Gerät (`SmartAssistant.searchKeywords`), Fortschritt auf dem Sperrbildschirm
(`BGContinuedProcessingTask`, `ContinuedAnalysis.swift`).

**Relevant Countries or Regions:** alle (vorausgefüllt lassen)
**Localizations:** German, English
**Platforms:** iOS (iPhone)
**In-App Events:** zum Start keins; für Januar siehe unten.

**Supplemental Materials** (≤ 5 Links), in dieser Reihenfolge:
1. Öffentlicher TestFlight-Link (Kauf ist dort kostenlos; die Redaktion kann alles ausprobieren).
   Ist TestFlight noch nicht öffentlich, das Video an erste Stelle.
2. Vorschauvideo, 30 Sekunden (siehe `SCREENSHOTS_VIDEO_PLAN.md`), als nicht gelisteter Link
3. Webseite mit Datenschutz und Hilfe
4. Pressemappe (`PRESS_KIT.md`, Stand nach Design und Karte)
5. frei lassen oder: Ordner mit Bildschirmfotos und dem Teilen-Bild „Deine Welt“

**Helpful Details** (≤ 500)
```
[PERSONAL SENTENCE] Photos are never uploaded, and all analysis runs on the iPhone. Before any TestFlight build goes out, it must pass two automated checks: a stress test with a simulated 10,000-photo library, and Apple’s accessibility audit at the largest text size, in Dark Mode, and with Reduce Motion.
```
(Ohne den persönlichen Satz 285 Zeichen; Platz für gut 210 Zeichen Geschichte.)

Belege: Härtetest mit 10.000 Fotos vor jedem Zusammenführen in main, der TestFlight-Upload
übernimmt das grüne Ergebnis nur bei nachweislich gleichem App-Stand (Projektregel, Entscheidung
Fuchs 20.11.). Barrierefreiheits-Prüfung: `App/AlbumistUITests/AccessibilityUITests.swift`
(`performAccessibilityAudit`, größte Schrift, „Bewegung reduzieren“ an), Kontrast hell und dunkel.

## Der persönliche Satz: drei Vorschläge (Fuchs wählt)

Nur aus dem, was wir wissen; **Fuchs prüft, ob jede Zahl stimmt** (die 14.000 stammt aus dem
Gerätetest vom 15.11.: 14.356 Fotos). Nichts davon wird ohne die Wahl von Fuchs eingesetzt.

- **A – die Mediathek:** „I built Albumist for my own library: 14,000 photos, years of trips, and not a single album.“ (91)
  *DE: Ich habe Albumist für meine eigene Mediathek entwickelt: 14.000 Fotos, Jahre voller Reisen und kein einziges Album.*
- **B – die Herkunft:** „I’m an independent developer from Zwiesel in the Bavarian Forest. Albumist started with my own 14,000 unsorted photos.“ (118)
  *DE: Ich komme aus Zwiesel im Bayerischen Wald und entwickle unabhängig. Albumist begann mit meinen eigenen 14.000 unsortierten Fotos.*
- **C – der Grund:** „I didn’t want yet another app for looking at my photos. I wanted my trips as real albums in Photos, so I built Albumist.“ (120)
  *DE: Ich wollte keine weitere App, nur um Fotos anzusehen. Ich wollte meine Reisen als echte Alben in Fotos, also habe ich Albumist entwickelt.*

Empfehlung: **B + C zusammen** (239 Zeichen). Dann den Satz „Photos are never uploaded, and all
analysis runs on the iPhone.“ streichen: Er steht schon in der Beschreibung. Ergebnis 461
Zeichen. (Mit ihm wären es 525, über den selbst gesetzten 500.)

Bei A oder B steht „14,000 photos“ neben dem Härtetest mit 10.000. Das ist kein Widerspruch
(der Härtetest ist eine künstliche Mediathek, die 14.000 sind echte Fotos), kann aber eine
Rückfrage auslösen. Dann im Härtetest-Satz „a simulated 10,000-photo library“ durch „a large
simulated photo library“ ersetzen (gleiche Länge).

## Weitere Nominierungen (Plan)

| Wann | Typ | Thema |
|---|---|---|
| Sofort, wenn TestFlight öffentlich und Startdatum grob fest | App Launch | dieser Text |
| Ab dem ersten Jahreswechsel nach dem Start (Events brauchen eine App, die schon live ist) | In-App Event „Ordnung fürs neue Jahr“ (Badge: Special Event) + Nominierung New Content | Das alte Jahr in Alben, Rückblick mit „Deine Welt“ |
| Vor den Sommerferien (Mai) | App Enhancements | erstes großes Update (z. B. Widget, Neue-Reise-Mitteilung) |

## Vor dem Absenden prüfen

- [ ] Jede Aussage stimmt im eingereichten Build (Karte, „Reise abspielen“, Sperrbildschirm,
      Spotlight, Suche in eigenen Worten, Voice Control nach dem Test aus
      `BARRIEREFREIHEIT_ANGABEN.md`).
- [ ] Öffentlicher TestFlight-Link funktioniert ohne Einladung.
- [ ] Produktseite fertig (Bilder, Video), denn die Redaktion schaut sie an.
- [ ] Barrierefreiheits-Angaben als Entwurf gespeichert.
- [ ] Typ und Datum noch einmal ansehen; Typ ist danach fest.

Quellen: developer.apple.com/app-store/getting-featured, App Store Connect Hilfe „Nominate your app
for featuring“, „Meet with Apple“ Sitzung 249 (gelesen 21.11.2026, Grenzen und Vorlauf nachgeprüft
26.11.2026).
