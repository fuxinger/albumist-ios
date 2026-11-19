# Upload zu TestFlight einrichten (einmalig, etwa 5 Minuten)

Seit deiner Entscheidung vom 19.11.2026 lädt GitHub einen Build **ohne Klick** zu TestFlight
hoch: nur vom Zweig `main` und nur, wenn jedes Tor des Laufs grün ist (CI, UI-Tests und UI-Tor,
Härtetest, Release-Kurztest, frühere Versuche des Laufs). Das ersetzt den Klick aus der
Entscheidung vom 18.11. Der Apple-Schlüssel liegt in einem geschützten Bereich von GitHub, der
„Umgebung“ `testflight-upload`. Nur der Upload-Schritt kommt an ihn heran, und nur von `main`.
Diese Regel ist jetzt der einzige Zaun; darum prüft der erste Job jedes Laufs sie genau.

**Bis das eingerichtet ist, lädt TestFlight nichts hoch.** Ein Lauf hält dann gleich im ersten
Job („Upload setup“) an und verweist auf diese Seite. Auch der tägliche Build startet erst danach.

**Privates Repository:** Das Repository ist öffentlich; würde es privat, hält jeder Lauf im ersten
Job an, bis du (erst mit GitHub Pro, Team oder Enterprise) die Repository-Variable
`UPLOAD_PRIVATE_PLAN_OK` auf `true` setzt.

Die Knöpfe bei GitHub sind englisch; sie stehen unten **fett**.

## Die Schritte

1. https://github.com/fuxinger/sortly-ios/settings/environments öffnen. Gibt es
   `testflight-upload` noch nicht: **New environment**, Name genau so, **Configure environment**.
   Sonst `testflight-upload` antippen.
2. Unter „Deployment protection rules“ den Haken bei **Required reviewers** entfernen, dann
   **Save protection rules**. (Bleibt er, wartet jeder Upload weiter auf deinen Klick.)
3. Unter „Deployment branches and tags“ **Selected branches and tags** wählen. Es muss genau eine
   Regel geben: `main` (sonst **Add deployment branch or tag rule**, Name `main`, **Add rule**;
   jede andere Regel löschen).
4. Weiter unten, „Environment secrets“: diese vier müssen dort stehen (sonst **Add environment
   secret**; Namen genau so):

   | Name | Inhalt |
   |---|---|
   | `ASC_KEY_ID` | Schlüssel-ID (App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API > Team-Schlüssel) |
   | `ASC_ISSUER_ID` | Issuer-ID (steht dort über der Tabelle) |
   | `ASC_KEY_P8` | ganzer Inhalt der Datei `AuthKey_….p8`, mit den Zeilen BEGIN und END |
   | `APPLE_TEAM_ID` | Team-ID (https://developer.apple.com/account > Mitgliedschaft) |

5. https://github.com/fuxinger/sortly-ios/settings/secrets/actions öffnen und unter **Repository
   secrets** dieselben vier Namen löschen, falls sie dort noch stehen. Alle anderen bleiben
   (zum Beispiel `APPETIZE_TOKEN`). Solange einer dort steht, kann ihn jeder Workflow lesen.
6. Prüfen: **Actions** > **TestFlight** > **Run workflow**, Zweig `main`, „Gate“ `small`. Der
   erste Job „Upload setup“ wird grün. Rund 70 Minuten später lädt der Lauf hoch, wenn alles grün
   ist.

Ist die `.p8`-Datei weg: in App Store Connect einen neuen Team-Schlüssel erzeugen (Name `GitHub`,
Zugriff **Admin**), die Datei laden, den alten widerrufen. GitHub zeigt gespeicherte Secrets nie
wieder an.

## Wenn etwas nicht klappt

- „No upload: the upload environment is not set up“ im ersten Job: Schritt 1 oder 3 fehlt, oder
  die Zweig-Regel ist nicht genau `main`. Nennt die Meldung GitHub Free, ist das Repository
  privat: siehe oben.
- Der Upload bricht gleich mit „App Store Connect secrets“ ab: in Schritt 4 fehlt ein Name oder
  er ist anders geschrieben. Ergänzen, dann im Lauf **Re-run failed jobs**.
- Der Upload wartet auf einen Klick („Review deployments“): Schritt 2 fehlt.

## Gut zu wissen

- **Welches Tor?** Heißt der Lauf „TestFlight daily build (small gate, only for the owner)“, ist
  es der tägliche Build mit kleinem Tor: ein interner Build nur für dich, nicht an Tester
  weitergeben (auch die letzte Zeile von „Was testen“ sagt das). Er lädt jetzt an jedem Tag hoch,
  an dem sich die App geändert hat und alles grün ist. Heißt der Lauf nur „TestFlight“, hatte er
  das große Tor (für Tester und App Store). Was die Tore prüfen: `docs/TESTFLIGHT.md`, „Zwei Tore“.
- Solange ein TestFlight-Lauf läuft oder wartet, startet kein anderer, auch kein täglicher Build.
- Nach dem Hochladen dauert es meist 5 bis 30 Minuten, bis Apple den Build verarbeitet hat und er
  in der TestFlight-App erscheint.

## Freiwillig: Schlüssel nur für Feedback (etwa 3 Minuten)

Die tägliche Abfrage von Feedback und Abstürzen (Workflow „TestFlight feedback“) bekommt den
Upload-Schlüssel nicht. Ohne eigenen Schlüssel pausiert sie („Skipped“); Feedback siehst du weiter
in App Store Connect > Albumist > TestFlight. Für die tägliche Zählung: in App Store Connect einen
Team-Schlüssel `GitHub Feedback` mit Zugriff **Developer** (nicht Admin) anlegen und bei
https://github.com/fuxinger/sortly-ios/settings/secrets/actions als **Repository secrets**
`ASC_FEEDBACK_KEY_ID`, `ASC_FEEDBACK_ISSUER_ID` und `ASC_FEEDBACK_KEY_P8` eintragen. Hier nie den
Admin-Schlüssel eintragen.
