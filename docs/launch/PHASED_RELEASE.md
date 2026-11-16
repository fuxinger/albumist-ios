# Phasenweise Veröffentlichung von Updates

Gilt ab dem ersten Update (1.0.1 oder 1.1): Version 1.0 hat noch niemanden, der automatisch aktualisiert.

- **Einschalten:** App Store Connect › Version › „Phasenweise Veröffentlichung für automatische Updates“. In 7 Tagen bekommen 1 %, 2 %, 5 %, 10 %, 20 %, 50 %, dann 100 % der Nutzer mit automatischen Updates die neue Version. Wer selbst im App Store aktualisiert oder Albumist neu lädt, bekommt sie sofort.
- **Täglich beobachten:** Abstürze und Hänger der neuen Version (Xcode › Organizer, App Store Connect › App-Analyse) im Vergleich zur Vorversion; Bewertungen und Rezensionen dieser Version; Support-Mails und geteilte Diagnosen („Diagnose teilen“), vor allem zu Anlegen und Rückgängig.
- **Pausieren** (insgesamt höchstens 30 Tage), sobald die Absturzrate über der Vorversion liegt oder auch nur ein Bericht falsche Alben, ein Rückgängig, das nicht alles zurücknimmt, oder verlorene Entscheidungen meldet. Die Pause hält nur die automatischen Updates an: Neue Downloads und manuelle Updates bekommen die Version weiter. Darum bei Fehlern an Alben sofort einen Fix einreichen (beschleunigte Prüfung beantragen); die neue Version beginnt wieder bei Tag 1.
- **Fortsetzen oder „Für alle Nutzer veröffentlichen“**, wenn zwei, drei Tage ruhig waren.
- **Bewertungsbitte** (`ReviewPromptPolicy`): kommt nur nach neuen Alben ohne Fehler, nie beim Start, höchstens einmal je Version und frühestens 120 Tage nach der letzten; iOS zeigt sie höchstens dreimal in 365 Tagen und in TestFlight nie. In den ersten Tagen fragt sie also nur den kleinen Teil, der das Update schon hat: Diese Bewertungen sind ein frühes Zeichen für die neue Version. Abstürze und Fehler bringen keine Bitte; wer dann bewertet, tut es von selbst. Deshalb die Rezensionen der Version mitlesen, nicht nur den Schnitt.
- **Bewertungsübersicht nicht zurücksetzen** (Option beim Veröffentlichen), außer ein Update behebt einen Fehler, der viele schlechte Bewertungen gebracht hat.
