# App-Icon „Glass Stack“

Gewählt am 14.11.2026. Drei Albumkarten übereinander, die vordere aus Milchglas mit Landschaft.

- `App/Albumist/Resources/AppIcon.icon`: das App-Icon der App, im Ebenen-Format von iOS 26
  (Icon Composer). iOS zeichnet daraus Glas, Schatten und die Looks hell, dunkel, klar und getönt.
  Gebaut aus den Ebenen hier (`.github/scripts/tests/test_app_icon.py` prüft, dass sie gleich bleiben):
  - `1-back-card.svg` bis `5-hills.svg` liegen unverändert in `Assets/`, von hinten nach vorn in vier
    Gruppen: hintere Karte, mittlere Karte, vordere Karte (Milchglas: Glas, durchscheinend, verwischt
    was dahinter liegt), Landschaft (Sonne und Hügel, flach auf der vorderen Karte).
  - `0-background.svg` ist keine Ebene, sondern die Füllung des Icons (derselbe Verlauf von oben
    nach unten): Hintergründe macht der Icon Composer selbst, nur so wird er im Dunkel- und
    Getönt-Look dunkel. Dunkel nimmt den Hintergrund von iOS; die Hügel werden dort hell (`#3CC3CC`
    wie in `icon-dark.svg`), sonst verschwinden sie auf dem dunkleren Glas. Getönt macht iOS allein.
  - Auf dem Mac lässt sich das Icon in Xcode oder im Icon Composer öffnen und weiter verfeinern.
- `icon-light.svg`, `icon-dark.svg`, `icon-tinted.svg`: die fertigen Icons (1024 px) als Bild, so
  wie sie am 14.11. gewählt wurden. Aus ihnen entstanden die PNGs des alten App-Icons (bis DS-20 im
  Asset-Katalog); jetzt sind sie die Vorlage, an der das neue Icon auf dem Mac gemessen wird.
- `make_icon.py <ausgabe> <ebenen>`: erzeugt alle SVGs neu. Gerendert wurde mit Chromium (Playwright).
  Ändert sich eine Ebene, kommt sie danach wieder nach `AppIcon.icon/Assets/`.
