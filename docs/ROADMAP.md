# Roadmap

| Phase | Inhalt | Status |
|---|---|---|
| 1 | Kernlogik: Reisen, Orte, Vorschläge, Abgleich, Plan, Ausführung, Rückgängig | fertig |
| 2 | Datenbank, Offline-Weltkarte, fortsetzbare Analyse | fertig |
| 3 | iOS-App: alle Bildschirme, PhotoKit, Vision, Hintergrundlauf | fertig (nur Simulator geprüft) |
| 4 | Freischaltung, Datenschutz-Manifest, Kurzbefehl, Bewertungsbitte | fertig |
| 4a | Siri, Kurzbefehle und Spotlight (Länder, Vorschläge), Glasknöpfe, Haptik | fertig |
| 5 | Englische Übersetzung, App-Store-Texte, Featuring-Check (`launch/FEATURING_AUDIT.md`) | fertig |
| 6 | Apple Intelligence (wenn verfügbar): Suche in Sätzen, Namensvorschläge, Foto-Geschichte | fertig (nur Simulator geprüft) |
| 6a | App-Icon im Icon-Composer-Format (Glas-Ebenen) | braucht einen Mac |
| 7 | TestFlight mit echten Nutzern | eingerichtet: CI baut, signiert und lädt hoch (`TESTFLIGHT.md`) |
| 8 | Update 1.1: Personen und Haustiere (Opt-in), Widget, Belege verstehen | geplant |
| 8a | Mitteilungen: „Analyse fertig“ und Fortschritt auf dem Sperrbildschirm (`BGContinuedProcessingTask`) | fertig |
| 8b | Live Activity, wöchentlicher Hinweis (Opt-in) | später (Entscheidung 2026-11-14) |
| 9 | Weitere Sprachen nach Downloads | geplant |

## Abhängigkeiten
Phase 7 braucht ein Apple-Developer-Konto, App-Store-Connect-Eintrag und Signatur-Zertifikat
(als GitHub-Secret für die automatische Auslieferung). Der App-Name ist Albumist („Sortly“ ist
im App Store vergeben).

## Prioritäten
Zuverlässigkeit vor Funktionsmenge: Erst müssen Analyse, Vorschläge und Rückgängig auf
echten Geräten stabil laufen, dann folgen neue Bereiche.
