# Datenmodell

SQLite, Version über `PRAGMA user_version`, Migrationen in `Sources/AlbumistStore/Migrations.swift`.

## Tabellen
| Tabelle | Schlüssel | Inhalt |
|---|---|---|
| `assets` | `id` (PhotoKit localIdentifier) | Metadaten, Fingerabdruck, `analysis_version`, `labels_version` (v5), `out_of_view` (v6) |
| `collections` | `id` | Alben und Ordner: Titel, Art, Rechte, Eltern, Kinder |
| `collection_members` | (`collection_id`, `asset_id`) | Album-Mitgliedschaften |
| `place_cache` | `cell` (Rasterzelle) | aufgelöste Ortsnamen je Zelle |
| `asset_places` | `asset_id` | Ort je Foto, Quelle, `precision_m` (v2) |
| `analysis_results` | (`asset_id`, `kind`) | versionierte Analyseergebnisse (JSON) |
| `text_plain` / `text_fts` | `asset_id` | erkannter Text; FTS5 falls verfügbar |
| `analysis_progress` | `stage` | Fortschritt und Cursor je Etappe |
| `overrides` | `id` | Nutzerentscheidungen (ignorieren, ablehnen, entfernte Fotos) |
| `rules` | (`id`, `version`) | Regeln mit Versionsverlauf |
| `managed_albums` | `album_id` | von Albumist angelegte/ergänzte Alben |
| `plans` | `id` | Kopf der Änderungspläne: Status, Zeiten, Bezug auf rückgängig gemachten Plan (ab v4 ohne Schritte und Journal) |
| `plan_steps` | (`plan_id`, `idx`) | Schritte eines Plans mit Zustand (v4) |
| `plan_media` | (`plan_id`, `step_id`) | Ausführungsjournal je Schritt: wirklich geänderte Fotos (v4) |
| `plan_wanted` | `plan_id` | Fotos, die die Vorschläge eines Plans je Album wollen (`ChangePlan.wanted`, v7) |
| `settings` | `key` | Einstellungen, Entscheidungen, Vorschlags-Schnappschuss |

## Beziehungen und Indizes
`collection_members`, `asset_places`, `analysis_results`, `text_plain` hängen per
`ON DELETE CASCADE` an `assets` bzw. `collections`. Indizes: Aufnahmedatum, Analyseversion,
Koordinaten, Eltern-Ordner, Mitgliedschaft nach Foto, Ergebnis-Art, Plan-Status, Quelle
verwalteter Alben.

## Identitäten
Fotos und Alben werden über PhotoKit-`localIdentifier` angesprochen. Vorschläge haben
stabile `AlbumistID`s, abgeleitet aus Bereich und Inhalt (Reise-ID, Ortsschlüssel, Kategorie),
damit Entscheidungen neue Analyseläufe überleben. Planschritte haben deterministische
Idempotenzschlüssel (Plan-ID + Index + Inhalts-Hash).

## Migrationen
- v1: Grundschema.
- v2: `asset_places.precision_m` für den nächtlichen Verfeinerungslauf.
- v3: `text_plain` mit Zeilen-ID, der Volltextindex folgt automatisch.
- v4: `plan_steps` und `plan_media`. Gespeichert wird nur, was sich seit dem letzten Speichern
  geändert hat; gelesen wird der Plan wieder ganz. Ältere Pläne liegen noch als Ganzes in
  `plans` und werden beim nächsten Speichern aufgeteilt.
- v5: `assets.labels_version`: ob ein Foto Bildlabels hat (0: keine). Labels werden nur
  berechnet, solange „Themen“ oder „Dokumente“ an ist; wird einer der Bereiche später
  eingeschaltet, holt der nächste Lauf sie für genau diese Fotos nach (nur die Labels).
  Fotos älterer Versionen gelten nur dann als erledigt, wenn ihr gespeichertes Ergebnis
  mindestens ein Label hat; ob ein Foto ohne Labels mit eingeschalteter Erkennung angesehen
  wurde, ist nicht bekannt, es wird einmal nachklassifiziert. Kann ein Foto beim Nachholen
  nicht gelesen werden, zählt `analysis_results` (Art `labels`, `LabelAttempts`) die Versuche;
  sein Inhaltsergebnis bleibt unverändert.
- v6: `assets.out_of_view` (Prüfbefund P1-07): Bei „Ausgewählte Fotos“ werden Fotos außerhalb
  der Auswahl beiseitegelegt (1) statt gelöscht; ihre Analyse, ihr Ort und ihr Text bleiben.
  Alle Abfragen für Analyse, Zählung, Vorschläge und Suche lassen sie aus (`assetCount`,
  `allAssets`, `results`, `places`, `searchText` …); nur Änderungen an allen gespeicherten
  Ergebnissen (Sprache der Albumnamen, strengere Masken der Texte) nehmen sie mit
  (`includingOutOfView`). Wird ein Foto wieder gelesen, ist es wieder sichtbar (0); gelöscht
  wird es erst, wenn ein ganzes Lesen mit vollem Zugriff es nicht findet. Ein Lauf liest nur
  Änderungen, solange kein Foto beiseiteliegt. Fotos älterer Versionen sind sichtbar.
  Was für immer an Fotos hängt, behält die beiseitegelegten: Reise-Kennungen
  (`user.tripIdentities`), gewählte Vorschläge (`user.heldSuggestions`, gezeigt nur mit den
  freigegebenen Fotos) und häufige Orte, die die Auswahl nicht ergibt
  (`analysis.frequentPlacesOutOfView`, nur für ihre Kennung, nie gezeigt). Behält eine Reise
  oder ein Ort die Kennung mit nur einem Teil der Fotos, behält die Kennung auch die
  beiseitegelegten (Reise: in der Identität; Ort: als Eintrag mit derselben Kennung in
  `analysis.frequentPlacesOutOfView`).
- v7: `plan_wanted`: was die Vorschläge eines Plans je Album wollen (Prüfung P2-09), eine Zeile je
  Plan, geschrieben nur wenn es sich ändert. Im Plankopf wurde es mit jedem Schritt neu geschrieben
  (100.000 Fotos in 200 Alben: 165 s statt unter 20 s). Ältere Pläne behalten es im Kopf, bis sie
  wieder gespeichert werden.
Migrationen laufen nur vorwärts, jede in einer Transaktion.
