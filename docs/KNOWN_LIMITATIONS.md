# Bekannte Einschränkungen

## iOS
- Fotos-Apps dürfen keine Smart-Alben, geteilten oder synchronisierten Alben verändern.
- Hintergrundarbeit ist nicht garantiert; iOS entscheidet über `BGContinuedProcessingTask`
  und `BGProcessingTask`, wie lange Albumist im Hintergrund rechnen darf. Endet die Zeit,
  hält iOS die App an, und die Analyse geht beim nächsten Öffnen an derselben Stelle weiter.
- Apps können die Fotos-App öffnen, aber nicht ein bestimmtes Album darin.
- Bei „Ausgewählte Fotos“ sieht Albumist nur diese Auswahl.
- Ortsnamen über `CLGeocoder` sind von Apple begrenzt (Drosselung, gelegentliche Fehler);
  Länder und Regionen kommen immer aus der Offline-Karte.
- `CLGeocoder` ist in iOS 26 als veraltet markiert; der Nachfolger in MapKit ist geplant.

## Bilderkennung
- Begriffe statt Bedeutung, mögliche Fehlzuordnungen; deshalb Schwellen und Bestätigung.
- Analyse auf Vorschaubildern; kleine Motive werden eventuell nicht erkannt.
- Personen- und Haustiergruppen sind noch nicht umgesetzt (Bereich ausgeblendet).
- Bildlabels gibt es nur, solange „Themen“ oder „Dokumente“ an ist; später eingeschaltet,
  holt der nächste Lauf sie nach. Wer zwischen TestFlight-Builds mit und ohne diese Nachführung
  (Datenbank-Version 5) hin und her wechselt: ein älterer Build öffnet die neuere Datenbank,
  pflegt die Spalte `labels_version` aber nicht. Fotos, die unter dem älteren Build bearbeitet
  wurden, behalten dann ihre alte Markierung und bekommen nach dem Zurückwechseln keine neuen
  Labels; neue Fotos sind nicht betroffen (sie bekommen ihre Labels nachgeholt). Abhilfe:
  „Analyse neu aufbauen“.

## Gespeicherter Text (Bildschirmfotos, Dokumente)
- IBANs und Kartennummern werden maskiert, auch mit Punkten, Bindestrichen, Schrägstrichen,
  bis zu vier Leerzeichen oder über zwei Zeilen; Ausweise (auch die Rückseite mit der
  maschinenlesbaren Zeile) und medizinische Dokumente werden nicht als Text gespeichert
  (Prüfbefund P2-04, Masken-Version 3). Andere Schreibweisen (Buchstaben zwischen den Gruppen,
  stark verlesene Ziffern) können lesbar bleiben.
- Nicht maskiert und nicht versprochen: Steuer-ID, Telefonnummern, E-Mail-Adressen, die Nummer
  der Gesundheitskarte. Der Text bleibt auf dem Gerät.

## Messenger-Herkunft
iOS speichert keine verlässliche Quell-App. Albumist nutzt nur klare Hinweise (Messenger-
Screenshots, vorhandene Alben, optional Dateinamen-Muster) und markiert alles andere als
unbekannt.

## Nicht unterstützte Sammlungen
Smart-Alben, geteilte Alben, iCloud-Shared-Library-Besonderheiten, Alben aus anderen Apps
mit eingeschränkten Rechten: nur lesend.

## Offene technische Risiken
- **Nicht auf echten Geräten getestet.** Synthetisch geprüft: 100 000 Fotos (80 % nur in
  iCloud) in 54 s mit 563 MB Spitze auf dem Linux-Rechner der CI, ohne echte Bilderkennung.
  Laufzeit, Wärme und Akku auf iPhones sind ungemessen.
- PhotoKit kennt kein bedingtes Löschen: Zwischen dem letzten Lesen und dem Löschen eines
  leeren Albums kann noch ein Foto hineinkommen (Millisekunden). Albumist liest direkt davor.
- Ein beim Wiederanlauf übernommenes leeres Album bleibt nach Rückgängig stehen (gewollt).
- Wird ein Hinzufügen in ein Album des Nutzers unterbrochen und ist der Ausgang unklar, nimmt
  Rückgängig ein dort doch angekommenes Foto nicht heraus (gewollt, zweite Gegenprüfung 1.1).
  Der Änderungsbeleg zeigt den Schritt als nicht bestätigt.
- Nimmt der Nutzer während einer Unterbrechung alle Fotos aus einem Album, das der Plan gerade
  angelegt hat, und tippt danach „Rest anlegen“, legt Albumist sie wieder hinein: Das lässt sich
  nicht von einer Anfrage unterscheiden, die Fotos nie erreicht hat (gewollt, `DECISIONS.md`).
  Rückgängig nimmt genau diese Fotos wieder heraus.
- Benennt der Nutzer ein Album zwischen Ausführen und Abschluss um, zeigt der Beleg den Namen
  zum Zeitpunkt der Ausführung.
- Die Sicherung der Entscheidungen (I12) erkennt eine andere Mediathek an den Album-Kennungen.
  Mit iCloud-Fotos auf einem neuen iPhone können die Kennungen abweichen; dann kommen nur die
  Entscheidungen zurück, nicht Alben und Verlauf. Mit eingeschränktem Fotozugriff wartet die
  Prüfung, bis Albumist alle Fotos sehen darf. Auf echten Geräten (Backup und Wiederherstellen)
  ist das noch ungetestet.
- Reise-Werkstatt (I07): Teilen und Zusammenlegen geht nur, solange Albumist das Reise-Album
  noch nicht angelegt hat (sonst erst rückgängig machen). Tage richten sich nach der Zeitzone des
  Geräts, nicht nach der am Reiseort.
- Reiseart (Tagesausflug, Wochenende) richtet sich nach der Zielzeitzone nur, wenn die
  Online-Ortsbestimmung sie geliefert hat; sonst nach dem Gerätekalender.
- Eine Änderung nur der GPS-Genauigkeit eines Fotos wird nicht als Ortsänderung erkannt.
- Verhalten bei sehr großen Alben in einer PhotoKit-Transaktion (Schritte sind auf 500
  Fotos begrenzt).
- Die Apple-Intelligence-Funktionen sind im Cloud-Simulator nicht verfügbar und deshalb
  ungetestet; sie sind abgesichert (bei Fehler oder Nichtverfügbarkeit greift die normale Suche).
- StoreKit-Kauf ist erst mit App-Store-Connect-Eintrag testbar.
- Der sichtbare Name ist Albumist; Ordner, Module und Targets heißen noch „Sortly“ (nur intern).
