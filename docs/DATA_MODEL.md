# Datenmodell

SQLite, Version über `PRAGMA user_version`, Migrationen in `Sources/SortlyStore/Migrations.swift`.

## Tabellen
| Tabelle | Schlüssel | Inhalt |
|---|---|---|
| `assets` | `id` (PhotoKit localIdentifier) | Metadaten, Fingerabdruck, `analysis_version`, `labels_version` (v5) |
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
| `settings` | `key` | Einstellungen, Entscheidungen, Vorschlags-Schnappschuss |

## Beziehungen und Indizes
`collection_members`, `asset_places`, `analysis_results`, `text_plain` hängen per
`ON DELETE CASCADE` an `assets` bzw. `collections`. Indizes: Aufnahmedatum, Analyseversion,
Koordinaten, Eltern-Ordner, Mitgliedschaft nach Foto, Ergebnis-Art, Plan-Status, Quelle
verwalteter Alben.

## Identitäten
Fotos und Alben werden über PhotoKit-`localIdentifier` angesprochen. Vorschläge haben
stabile `SortlyID`s, abgeleitet aus Bereich und Inhalt (Reise-ID, Ortsschlüssel, Kategorie),
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
Migrationen laufen nur vorwärts, jede in einer Transaktion.
