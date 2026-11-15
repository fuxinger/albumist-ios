# Checkliste für den App-Store-Start

Was vor dem Verkaufsstart erledigt sein muss. Wird bei jeder Entscheidung ergänzt.

## Code und GitHub
- [ ] **Projekt auf privat stellen** (Entscheidung Fuchs, 15.11.2026: bis kurz vor dem Start
      öffentlich, weil die Mac-Läufe dann kostenlos sind). Danach seltener auf Macs testen
      (Nachtlauf und vor jeder TestFlight-Version), da Mac-Minuten bei privaten Projekten kosten.
- [ ] Dependabot-Warnungen und Sicherheits-Updates eingeschaltet (nur in den GitHub-Einstellungen möglich).
- [ ] Schutzregel für `main`: kein Löschen, kein Überschreiben, Änderungen nur über geprüfte Pull Requests.
- [ ] Zwei-Schritt-Anmeldung (2FA) für das GitHub-Konto.

## Qualität
- [ ] Testplan (`docs/TEST_PLAN.md`) ohne offene Fälle.
- [ ] Letzte TestFlight-Version auf einem echten iPhone durchgespielt: Analyse, Wärme, Hintergrund,
      Rückgängig, Kauf, große Schrift, VoiceOver.

## Marke und Recht
- [ ] Markenprüfung „Albumist“ (EUIPO, DPMA, USPTO) und Domain.
- [ ] Webseite mit Datenschutz, Support und Impressum online (PR 2, GitHub Pages).
