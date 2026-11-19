# Albumist – Arbeitsstand

Diese Datei war die Übergabe-Notiz vom Projektstart (14.11.2026). Ihr Inhalt ist überholt
(Produkt-ID, Zahl der Tests, offene Punkte wie `BGContinuedProcessingTask`). Den aktuellen
Stand führen diese Dateien, sie werden laufend gepflegt:

| Frage | Datei |
|---|---|
| Was ist erledigt, was kommt als Nächstes, was später? | [`docs/IMPROVEMENTS.md`](docs/IMPROVEMENTS.md) |
| Phasen bis zum Start und danach | [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| Getroffene Entscheidungen | [`docs/DECISIONS.md`](docs/DECISIONS.md) |
| Bekannte Grenzen | [`docs/KNOWN_LIMITATIONS.md`](docs/KNOWN_LIMITATIONS.md) |
| Änderungen je Version | [`docs/CHANGELOG.md`](docs/CHANGELOG.md) |
| TestFlight und Einreichung | [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md), [`docs/launch/LAUNCH_CHECKLIST.md`](docs/launch/LAUNCH_CHECKLIST.md) |
| Aufbau und Dateien | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/CODEMAP.md`](docs/CODEMAP.md) |
| Datenschutz | [`docs/PRIVACY.md`](docs/PRIVACY.md) |

Was zuletzt passiert ist, zeigt `git log`.

## Rahmenbedingungen (weiter gültig)
- Kein Mac: iOS-Builds und Tests laufen über GitHub Actions. Xcode, Simulator-Laufzeit und
  Simulatoren stehen an einer Stelle: `.github/toolchain.json`.
- Mindestversion iOS 26; nur iPhone, nur Hochformat (Version 1).
- Linux-Toolchain im Container: `export PATH=/home/user/toolchain/swift-6.2.3-RELEASE-ubuntu24.04/usr/bin:$PATH`,
  Kern-Tests mit `swift build --build-tests && swift test --skip-build`.
