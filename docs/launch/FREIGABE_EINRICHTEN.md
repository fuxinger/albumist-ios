# Freigabe vor dem Hochladen einrichten (einmalig, etwa 10 Minuten)

Ab jetzt lädt GitHub einen Build erst zu TestFlight hoch, wenn **du** ihn freigibst (deine
Entscheidung vom 18.11.2026). Dafür kommt der Apple-Schlüssel in einen geschützten Bereich von
GitHub, eine „Umgebung“. Nur der Upload-Schritt kommt an ihn heran, und erst nach deinem Klick.

**Bis du das eingerichtet hast, lädt TestFlight nichts hoch.** Ein Lauf hält dann gleich im
ersten Schritt („Upload approval“) an und verweist auf diese Seite. Auch der tägliche Build
startet erst danach.

Am besten am Windows-PC im Browser (wegen der Datei in Schritt 4). Der Rest geht auch auf dem
iPhone im Browser. Die Knöpfe bei GitHub sind englisch; sie stehen unten **fett**.

## Was du brauchst

Die vier Werte, die du schon einmal bei GitHub eingetragen hast (`docs/TESTFLIGHT.md`,
Abschnitt 3):

- **Schlüssel-ID** und **Issuer-ID**: App Store Connect > Benutzer und Zugriff > Integrationen >
  App Store Connect API > Team-Schlüssel (die Issuer-ID steht über der Tabelle),
- die Datei **`AuthKey_….p8`**,
- die **Team-ID**: https://developer.apple.com/account > Mitgliedschaft.

GitHub zeigt gespeicherte Secrets nie wieder an. Findest du die `.p8`-Datei nicht mehr: in App
Store Connect einen neuen Team-Schlüssel erzeugen (Name `GitHub`, Zugriff **Admin**), die Datei
laden und den alten Schlüssel widerrufen.

## Schritt 1: Umgebung anlegen

1. https://github.com/fuxinger/sortly-ios/settings/environments öffnen.
2. **New environment**, Name genau so: `testflight-upload`
3. **Configure environment**.

## Schritt 2: Dich als Prüfer eintragen

1. Unter „Deployment protection rules“ **Required reviewers** ankreuzen.
2. Im Suchfeld deinen GitHub-Namen eingeben (`fuxinger`) und antippen.
3. **Prevent self-review** *nicht* ankreuzen. Sonst kannst du Läufe, die du selbst startest,
   nicht freigeben.
4. **Save protection rules**.

## Schritt 3: Nur der Zweig `main`

1. Unter „Deployment branches and tags“ statt „No restriction“ **Selected branches and tags**
   wählen.
2. **Add deployment branch or tag rule**, Name `main`, **Add rule**.

## Schritt 4: Die vier Secrets in die Umgebung

Weiter unten auf derselben Seite, „Environment secrets“: viermal **Add environment secret**.

| Name | Inhalt |
|---|---|
| `ASC_KEY_ID` | Schlüssel-ID |
| `ASC_ISSUER_ID` | Issuer-ID |
| `ASC_KEY_P8` | ganzer Inhalt der `.p8`-Datei (mit dem Editor öffnen, alles kopieren, auch die Zeilen BEGIN und END) |
| `APPLE_TEAM_ID` | Team-ID |

Die Namen genau so schreiben, Groß- und Kleinschreibung zählt.

## Schritt 5: Die alten Secrets löschen

Erst jetzt, nach Schritt 4:

1. https://github.com/fuxinger/sortly-ios/settings/secrets/actions öffnen.
2. Unter **Repository secrets** diese vier löschen (Papierkorb, dann bestätigen):
   `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`.
3. Alle anderen bleiben, zum Beispiel `APPETIZE_TOKEN`.

Erst damit ist der Schlüssel geschützt: Solange er noch als Repository-Secret dort steht, kann
ihn jeder Workflow lesen. **Kontrolle:** Auf dieser Seite stehen die vier Namen danach nur noch
unter **Environment secrets** (bei `testflight-upload`), nicht mehr unter **Repository secrets**.

## Schritt 6 (freiwillig, etwa 3 Minuten): Schlüssel nur für Feedback

Die tägliche Abfrage von Feedback und Abstürzen (Workflow „TestFlight feedback“) bekommt den
Upload-Schlüssel nicht mehr. Ohne eigenen Schlüssel pausiert sie; ihr Lauf meldet dann nur
„Skipped“. Feedback und Abstürze siehst du weiter direkt in App Store Connect > Albumist >
TestFlight.

Wenn du die tägliche Zählung behalten willst:

1. App Store Connect > Benutzer und Zugriff > Integrationen > App Store Connect API >
   Team-Schlüssel > **+**. Name `GitHub Feedback`, Zugriff **Developer** (nicht Admin).
   Schlüssel laden, Schlüssel-ID notieren.
2. https://github.com/fuxinger/sortly-ios/settings/secrets/actions > **New repository secret**,
   dreimal:

| Name | Inhalt |
|---|---|
| `ASC_FEEDBACK_KEY_ID` | Schlüssel-ID des neuen Schlüssels |
| `ASC_FEEDBACK_ISSUER_ID` | Issuer-ID (dieselbe wie oben) |
| `ASC_FEEDBACK_KEY_P8` | Inhalt der neuen `.p8`-Datei |

Hier nie den Admin-Schlüssel eintragen: dann läge er wieder ungeschützt im Repository.

## So sieht die Freigabe aus

Wenn ein Build hochgeladen werden will:

1. GitHub meldet dir meist, dass ein Lauf auf deine Prüfung wartet (E-Mail oder GitHub-App).
   Sicher findest du ihn so: **Actions** > **TestFlight** > der Lauf mit der gelben Uhr
   („Waiting“).
2. Oben im Lauf steht, dass `testflight-upload` auf eine Prüfung wartet, daneben der Knopf
   **Review deployments**.
3. Antippen, Häkchen bei `testflight-upload` setzen, dann **Approve and deploy**.
   Willst du diesen Build nicht: **Reject**.
4. Danach dauert es etwa 15 bis 20 Minuten bis zum Hochladen und meist noch 5 bis 30 Minuten, bis
   Apple den Build verarbeitet hat und er in der TestFlight-App erscheint.

Gut zu wissen:

- **Welches Tor?** Heißt der Lauf „TestFlight daily build (small gate, only for the owner)“, ist
  es der tägliche Build mit kleinem Tor: nur für dich, nicht an Tester weitergeben. Auch die
  letzte Zeile von „Was testen“ sagt das dann. Heißt er nur „TestFlight“, hatte er das große Tor
  (für Tester und App Store). Was die beiden Tore prüfen: `docs/TESTFLIGHT.md`, „Zwei Tore“.
- **Bitte am selben Tag entscheiden** (freigeben oder ablehnen). Solange ein Lauf wartet, startet
  kein anderer TestFlight-Lauf, auch kein täglicher Build. Nach 30 Tagen bricht GitHub ihn selbst
  ab.
- Der tägliche Build wartet morgens ab etwa 5:30 Uhr (im Sommer 6:30 Uhr) auf dich, aber nur an
  Tagen, an denen sich die App geändert hat.
- **Die Freigabe gibst nur du.** Kein Agent gibt sie für dich.
- **Nur solange das Repository öffentlich ist:** Den Prüfer für eine Umgebung bietet GitHub ohne
  Enterprise-Abo nur für öffentliche Repositorys an. Bevor du das Repository auf privat stellst,
  bitte zuerst einen Agenten fragen: dann braucht die Freigabe einen anderen Weg.
- Aus Versehen abgelehnt? Im Lauf **Re-run failed jobs**: GitHub fragt dich noch einmal, die Tests
  laufen nicht neu.

## Prüfen, ob alles stimmt

Entweder auf den nächsten täglichen Build warten, oder: **Actions** > **TestFlight** > **Run
workflow**, Zweig `main`, im Feld „Gate“ `small` wählen (das geht am schnellsten). Der erste Job
„Upload approval“ wird grün und nennt dich als Prüfer. Rund 45 Minuten später wartet der Lauf auf
deine Freigabe.

Steht im ersten Job stattdessen „No upload: the approval is not set up“, fehlt Schritt 1 oder 2.
Bricht der Upload nach deiner Freigabe gleich mit „App Store Connect secrets“ ab, fehlt in
Schritt 4 ein Name oder er ist anders geschrieben: ergänzen, dann im Lauf **Re-run failed jobs**.
