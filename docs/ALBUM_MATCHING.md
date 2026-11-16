# Abgleich mit vorhandenen Alben

Quelle: `Sources/SortlyCore/Matching/AlbumMatcher.swift`, Tests: `Tests/SortlyCoreTests/MatchingTests.swift`.

## Verfahren
Für jeden Vorschlag P wird jedes vorhandene Album A über die **Inhalte** verglichen, nicht über
den Namen. Ein invertierter Index (Foto → Alben) macht das auch bei großen Mediatheken in
einem Durchgang möglich. Namen dienen nur als Gleichstand-Entscheider und zum Erkennen von
Namenskonflikten.

## Metriken
| Metrik | Formel | Bedeutung |
|---|---|---|
| Abdeckung | \|P∩A\| / \|P\| | Wie viel des Vorschlags ist schon im Album |
| Reinheit | \|P∩A\| / \|A\| | Wie viel des Albums gehört zum Vorschlag |
| Jaccard | \|P∩A\| / \|P∪A\| | Gesamtähnlichkeit |
| fehlend | \|P \ A\| | Fotos, die ergänzt würden |
| zusätzlich | \|A \ P\| | Fotos im Album, die bleiben, aber nicht dazugehören |

## Schwellen (Standard)
Kandidat ab Reinheit ≥ 0,5 und mindestens 3 gemeinsamen Fotos. Ein Album, das den Vorschlag
zwar enthält (Abdeckung ≥ 0,5), aber zum größten Teil aus anderen Fotos besteht (Reinheit
< 0,5, z. B. „iPhone-Export“ mit einer ganzen Reise, „Familie“ mit den Hundefotos, „Italien“
mit der Stadt Rom), ist **kein** Kandidat: Es wird nur unter „Anpassen“ angeboten.
**Vollständig**: Abdeckung ≥ 0,98 und Reinheit ≥ 0,9. **Ergänzbar**: Reinheit ≥ 0,8 und
Abdeckung ≥ 0,25; bei Sammlungen (alles außer Reisen und Zeiträumen) zusätzlich: Der
Albumname sagt, dass es diese Sammlung ist, oder das Album hat schon ≥ 80 % davon (siehe
„Sammlungen“). Sonst nur „Ähnliches Album gefunden“. **Größere Sammlung**: ≥ 20 % des Albums gehören zu Geschwister-Vorschlägen
derselben Familie (z. B. ein Album „Italien“ über mehrere Italienreisen). Liegen zwei Kandidaten
weniger als 0,15 Punkte auseinander, gilt „mehrere passende Alben“.

## Status
| Status | Empfohlene Aktion |
|---|---|
| Schon vollständig vorhanden | Album so lassen (zählt als sortiert) |
| Vorhandenes Album wird ergänzt | fehlende Fotos hinzufügen |
| Ähnliches Album gefunden (passt vermutlich) | **neues Album**; das vorhandene bleibt unverändert und wird unter „Anpassen“ angeboten; zählt nicht als sortiert, nicht im Startpaket |
| Mehrere passende Alben | Nutzer wählt unter „Anpassen“ |
| Gleicher Name, anderer Inhalt | neues Album, Konflikt wird angezeigt |
| Neues Album | anlegen im Ordner unter dem Hauptordner |
| Nicht eindeutig | Nutzer entscheidet |
| Album nicht bearbeitbar | (z. B. geteiltes Album) neues Album |

Grundsatz (Prüfung 16.11.2026): Albumist ändert ein Album des Nutzers nur, wenn der Abgleich
sicher ist („wird ergänzt“). „Passt vermutlich“ ändert nie etwas von selbst und zählt im Ring
nicht als sortiert. Unklar heißt nicht erledigt.

**Was als sortiert zählt** (Ring, „davon in deinen Alben“, Bereichsübersicht, alle über
`AlbumMatcher.sortingAlbums`): das Album bei „schon vollständig“ und „wird ergänzt“. Bei
„Mehrere passende Alben“ nur Alben, die zu ≥ 80 % aus dem Vorschlag bestehen (das beste und
die gleich guten). „Ähnliches Album gefunden“ und nicht bearbeitbare Alben zählen nie.

**„Dein Startpaket“ und „Empfohlene auswählen“** nehmen dieselben Vorschläge
(`ProposalDecision.isSafeToAcceptUnseen`): mindestens wahrscheinlich, nicht persönlich, kein
Name nötig, klare Aktion, kein „Ähnliches Album gefunden“.

**Albumists eigenes Album** für einen Vorschlag bleibt dessen Album, auch wenn der Vorschlag
stark wächst („2026“ im Januar angelegt): Es wird ergänzt, nie ein zweites angelegt.

**Gespeicherte Ergebnisse** tragen die Version der Regeln (`AlbumMatcher.version`). Sind sie
älter, gleicht die App beim Start einmal neu ab. Eine ausgewählte, noch nicht ausgeführte
Entscheidung, die ein Album ergänzen würde, das nach den neuen Regeln nicht mehr sicher passt
(z. B. „ergänzen“ aus dem Startpaket auf jetzt nur „Ähnliches Album gefunden“), ist danach
wieder offen. Die Übersicht sagt es: „N Vorschläge neu geprüft: bitte noch einmal ansehen“.
Ausgeführte und angefangene Pläne bleiben unberührt. Neue Ergebnisse mit Versionsstempel,
die wieder geöffneten Entscheidungen und die Zahl für die Übersicht werden in einem Schritt
gespeichert: Endet die App mittendrin, ist nichts gespeichert, und der nächste Start
wiederholt es.

## Konfliktstrategien
- Fotos, die der Nutzer selbst aus einem Album entfernt hat, werden nie wieder hinzugefügt.
- Vor der Ausführung werden Fingerabdrücke aller betroffenen Alben verglichen; hat sich ein
  Album seit der Vorschau geändert, wird der Plan blockiert und neu vorgeschlagen.
- Doppelte neue Titel im selben Ordner blockieren; ein fremdes Album mit gleichem Titel im
  Zielordner ist nur ein Hinweis.
- Zusammenführen ähnlicher Alben ergänzt das größte Album; die anderen bleiben bestehen.

## Sonderfälle
Smart-Alben (Favoriten, Screenshots …) werden nicht als Ziel verwendet. Geteilte und
synchronisierte Alben sind nur lesbar. Ausgeblendete Fotos zählen nur mit Zustimmung.

### Sammlungen: Name oder Menge (Zweitprüfung 16.11.2026)
Eine Sammlung (Land, Ort, Jahr, Monat, Kategorie, Medientyp …) ergänzt ein Album des Nutzers,
das nur einen Teil von ihr enthält, nur wenn
- der Albumname nichts sagt, was nicht auch im Namen des Vorschlags steht („Italien“ für
  Italien, „2019“ für 2019, „Winter 2025/2026“ für „Winter 2025/26“), oder er ein Wort mit
  ihm teilt, das kein Datum ist („Unsere Hunde“ für Hunde, „Urlaub in Italien“ für Italien),
- oder das Album schon ≥ 80 % der Sammlung enthält.
Sonst ist es nur „Ähnliches Album gefunden“: Das Jahr 2019 ergänzt nicht „Italien 2019“ mit
Fotos von zu Hause, die Kategorie Hunde nicht „Bello“ mit allen anderen Hunden, der Monat
Mai 2024 nicht „Italien, Mai 2024“. Monate, Jahreszeiten und Zahlen zählen als Datum.

### Teil-Alben bei Ländern und Orten
Ein kleineres Album mit anderem Namen ist bei einer Orts-Sammlung ein Teil, nicht das
Album: „Rom · 2024“ enthält nur Italien-Fotos, ist aber Rom. Albumist schlägt nie vor, es
mit Fotos aus ganz Italien zu ergänzen. Ergänzt wird nur ein Album, das ein Wort mit dem
Ort teilt („Urlaub in Italien“). Ein Album, das schon den ganzen Ort enthält, zählt weiter
als vollständig. Unter „Anpassen“ kann man ein Teil-Album trotzdem wählen.

**Eine Reise** (BEFUNDE #3): Liegen alle Fotos eines Albums in einer einzigen erkannten Reise
(auch einer, die zu klein für einen eigenen Vorschlag ist), und hat diese Reise weniger als
80 % der Fotos des Orts, ist das Album diese Reise, ein Teil – auch ohne Jahr im Namen
(„Urlaub in Italien“). Hat man das Land nur auf dieser Reise besucht, bleibt es sein Album.
**Ausnahme:** Ein Album, das nur nach dem Ort heißt („Italien“, nach der ersten Reise
angelegt), bleibt das Album des Orts wie ohne Reisen. Die Reise wird pro Album nur einmal je
Abgleich bestimmt.

**Jahr im Namen** (Prüfung 16.11.2026, A2/A9): Steht im Albumnamen ein Jahr, das nicht im
Namen des Vorschlags steht („Italien 2019“, „Italien '19“, „Urlaub2019“, Albumists eigenes
„Italien · Mai 2024“; „2025/26“ nennt 2025 und 2026), ist das
Album eine Reise bzw. ein Teil. Keine Sammlung (Land, Ort, Kategorie, Medientyp …) ergänzt es
mit Fotos anderer Jahre. Reisen und Zeiträume sind selbst begrenzt und davon nicht betroffen.

### Alben anderer Vorschläge
Ein Album, das Albumist für einen anderen Vorschlag angelegt oder ergänzt hat (laut den
Aufzeichnungen zu verwalteten Alben), wird nie mit fremden Fotos ergänzt und nicht
angeboten. Es zählt nur, wenn es schon genau diesen Vorschlag enthält (ein Land, das man
auf einer einzigen Reise besucht hat).

### Ein Album pro Lauf für einen Vorschlag (Prüfung 16.11.2026, A5/A10)
In einem Abgleich ändert Albumist ein Album des Nutzers für höchstens einen Vorschlag:
- **Gleicher Name gewinnt** (Entscheidung Fuchs 16.11.2026): Heißt das Album genau wie ein
  Vorschlag (ohne Groß-/Kleinschreibung und Akzente, z. B. „Italien“ für das Land Italien)
  und würde dieser Vorschlag es ergänzen, gehört es ihm – auch wenn eine Reise im selben Lauf
  es ergänzen will oder schon ganz darin steckt, und auch gegenüber zurückgestellten
  Vorschlägen. Das Land ergänzt dann „Italien“ (in der Vorschau unter „Ergänzt“, rückgängig
  zu machen); die Reise „Italien · Mai 2019“ bekommt ein eigenes Album und sieht „Italien“
  nur unter „Anpassen“. Alben mit Jahr („Italien 2019“) bleiben Teile und gehen weiter an
  die Reise. Ausnahmen: Albumist hat das Album schon für einen anderen Vorschlag angelegt
  oder ergänzt („Alben anderer Vorschläge“), oder ein Vorschlag mit genau diesem Namen ist
  schon vollständig darin.
- Sonst: Ein Album, das einen Vorschlag schon vollständig enthält („Album so lassen“, auch ohne dass
  man es antippt), gehört diesem Vorschlag. Kein anderer Vorschlag ergänzt es. Das gilt auch
  für Vorschläge, die man mit „Nicht jetzt“ zurückgestellt hat.
- Wollen mehrere Vorschläge dasselbe Album ergänzen, bekommt es der, dem es am ähnlichsten
  ist (Jaccard, dann Wert). Die anderen bekommen ein eigenes Album und sehen das vorhandene
  nur unter „Anpassen“.

### Mehrere passende Alben
Albumist ergänzt dann nichts von sich aus. Die Erklärung nennt jedes passende Album; der
Hauptknopf heißt „Album auswählen“ und öffnet die Auswahl.

## Dein Zuhause (16.11.2026)
Die Einstellungen in „Dein Zuhause“ ändern, **welche** Vorschläge entstehen (Reisen, Reisenamen,
Orte-Alben des Zuhauses), nicht wie ein Vorschlag mit vorhandenen Alben abgeglichen wird:
`AlbumMatcher` ist unverändert, `AlbumMatcher.version` bleibt. Nach einer Änderung macht
`AnalysisPipeline.resuggest` die Vorschläge neu und gleicht sie wie nach jeder Analyse ab.
Ein Vorschlag, den der Nutzer schon ausgewählt hat und den die Änderung verändern oder entfernen
würde, bleibt mit seinem Inhalt von damals (`HeldSuggestions`, Schlüssel `user.heldSuggestions`)
und wird gegen die Alben von jetzt abgeglichen; er geht erst, wenn er angelegt oder abgewählt ist.
Fotos, die nicht mehr in der Mediathek sind, fallen aus ihm heraus; bleibt keines, geht er.

Welcher Schritt die Vorschläge nach einer Änderung macht, ist gleich: die Änderung wird mit einer
Vormerkung (`analysis.pendingHomeChange`, die Vorschläge von vorher) in einer Transaktion
gespeichert. Wer zuerst Vorschläge macht – `resuggest`, ein Lauf, der den Lock vorher bekam, oder
der Lauf nach dem nächsten Start, wenn die App dazwischen beendet wurde –, hält die Auswahl, schreibt
den Hinweis für die Übersicht und löscht die Vormerkung in derselben Transaktion wie die neuen
Vorschläge. „Analyse neu aufbauen“ läuft über denselben Lock und löscht die Vormerkung mit.

Regeln, wann ein gewähltes Zuhause gilt:
- **„Stimmt“** auf dem erkannten Zuhause gilt ab dem Moment der Bestätigung
  (`HomeSettings.confirmedFrom`). Davor entscheidet weiter die Erkennung, in den Monaten eines
  Umzugs mit beiden Zuhause; „Stimmt“ ändert also nichts an der Vergangenheit und hält das Zuhause
  nur für spätere Fotos fest. Ohne Namen (noch kein Ort bekannt) wird „Stimmt“ nicht angeboten.
- **Ein Ort unter „Ändern“** gilt für jedes Datum, das kein früheres Zuhause abdeckt.
- **Frühere Zuhause** gelten bis zu ihrem Datum (Kette, siehe `HomeSettings.home(at:)`).
- Welche Länder, Regionen und Orte ein gewähltes Zuhause sind, kommt aus den Fotos im Umkreis
  (30 km) bei jedem Vorschlagslauf (`HomeContext`), der Name bei der Wahl ist nur Ersatz: ein Ort
  mit mindestens einem Viertel der Fotos dort, oder dessen Fotos überwiegend dort liegen (ein Land
  jenseits der nahen Grenze, solange seine Fotos Alltag sind).
