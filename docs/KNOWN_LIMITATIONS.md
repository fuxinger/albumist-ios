# Bekannte Einschränkungen

## iOS
- Fotos-Apps dürfen keine Smart-Alben, geteilten oder synchronisierten Alben verändern.
- Hintergrundarbeit ist nicht garantiert; iOS entscheidet über `BGContinuedProcessingTask`
  und `BGProcessingTask`, wie lange Albumist im Hintergrund rechnen darf. Endet die Zeit,
  hält iOS die App an, und die Analyse geht beim nächsten Öffnen an derselben Stelle weiter.
- Apps können die Fotos-App öffnen, aber nicht ein bestimmtes Album darin.
- Bei „Ausgewählte Fotos“ sieht Albumist nur diese Auswahl. Die Analyse der übrigen Fotos wird
  dabei gelöscht wie bei gelöschten Fotos (`removeAssets(notIn:)`, die Ergebnisse hängen mit
  `ON DELETE CASCADE` daran); zurück auf „Alle Fotos“ werden sie neu analysiert, bei 14.000
  Fotos Stunden (Prüfbefund P1-07, offen). Behebung: die nicht sichtbaren Fotos in der
  Datenbank als „zurzeit nicht sichtbar“ markieren statt sie zu löschen (neue Spalte, also eine
  Migration), sie aus allen Abfragen der Analyse, Zählung und Suche herausnehmen und erst
  löschen, wenn Albumist wieder alle Fotos sieht und das Foto dann fehlt. Das berührt die
  13 Abfragen auf die Tabelle `assets` in `SortlyStore` und die Anzeige der App bei eingeschränktem Zugriff und ist
  darum nicht im Kern allein zu machen.
- Ortsnamen über `CLGeocoder` sind von Apple begrenzt (Drosselung, gelegentliche Fehler);
  Länder und Regionen kommen immer aus der Offline-Karte.
- `CLGeocoder` ist in iOS 26 als veraltet markiert; der Nachfolger in MapKit ist geplant.
- Sprache der Albumnamen gewechselt (Prüfbefund P1-12): Länder und Regionen aller
  gespeicherten Orte werden beim nächsten Lauf aus der Offline-Karte neu benannt (der Wechsel
  startet einen Lauf). Städte und Ortsteile kommen von Apples Ortssuche und bleiben in der
  Sprache, in der sie bestimmt wurden; nach einem Neustart der App kommen neue Städte in der
  neuen Sprache, so dass „Rom“ und „Rome“ nebeneinander stehen können. Dafür bräuchte die App:
  die Ortssuche (`SystemGeocoder`) bei einem Sprachwechsel mit der neuen Sprache neu anlegen
  (heute nur beim Start, `AppModel`), den Zwischenspeicher der Ortssuche je Sprache führen und
  die gespeicherten Städte zum erneuten Nachfragen vormerken (Netz und Apples Drosselung, eine
  Entscheidung für Fuchs). Die Kennungen von Städten und Regionen hängen nicht an der Sprache
  (fester Regionsschlüssel je Mediathek, zweite Prüfung; seit der dritten Prüfung als
  Entscheidung gespeichert, `user.regionKeys`: er übersteht „Analyse neu aufbauen“ und kommt
  mit der Sicherheitskopie zurück). Die Tabelle zählt wie die Reise-Kennungen
  (`user.tripIdentities`) als Inhalt der Sicherheitskopie, auch wenn der Nutzer noch nichts
  entschieden hat. Offen: eine Region, die die
  Offline-Karte nicht kennt (Apple nennt sie anders als die Karte), behält ihren Namen als
  Schlüssel; bei ihr und bei Städten, die Apple nach einem Neustart in der anderen Sprache
  nennt („Rom“/„Rome“), entsteht nach einem Sprachwechsel eine neue Kennung.

## Reisen

- Fotos mit dem Ort des Zuhauses mitten in einer Reise (Prüfbefund P1-14, zweite Prüfung):
  ob der Nutzer wirklich zu Hause war oder ein Foto von dort geschickt bekam, zeigt das Foto
  nicht. Geht die Reise weit weg dort weiter, wo sie aufhörte, gilt ein Aufenthalt zu Hause
  nur, wenn die Fotos eine Nacht zu Hause zeigen (Fotos zu Hause an zwei Tagen oder an einem
  ganzen Tag zwischen zwei Reisetagen) oder er 36 Stunden dauern konnte. Offen bleiben seltene
  Fälle: wer abends nach Hause fliegt, nur am Abend dort fotografiert und am nächsten Morgen an
  denselben Ort zurückfliegt, bekommt eine Reise statt zwei; und ein geschicktes Foto von zu
  Hause an einem Reisetag ohne eigene Fotos (auch nur eines, dritte Prüfung) oder vor einem
  solchen Tag (nächstes Reisefoto 36 Stunden später) teilt die Reise. Die Reise-Werkstatt
  (Teilen/Zusammenführen) korrigiert beides.

## Häufige Orte

- Ein häufiger Ort behält seine Kennung (und damit Name, „Nicht jetzt“, Entscheidung und Album)
  über seine Fotos: jede Analyse vergleicht mit den Orten der vorigen (seit der zweiten Prüfung
  vom 18.11.2026). Offen bleibt:
  - Ändern sich die Fotos eines Orts zwischen zwei Analysen um mehr als die Hälfte (viele
    gelöscht, zwei Orte zusammengewachsen oder geteilt), gilt er als neuer Ort.
  - Fiel ein Ort aus einer Analyse heraus (unter fünf Tage, etwa nach dem Löschen von Fotos),
    kennt die nächste ihn nicht mehr: kommt er wieder, bekommt er die Kennung seiner Zelle,
    wenn sie frei ist (meist seine alte). Entsteht später ein neuer Ort in derselben Zelle
    (Mittelpunkt auf drei Stellen gerundet), bekommt dieser die Kennung, wenn sie frei ist, und
    damit Name und „Nicht jetzt“ des verschwundenen Orts; ein Album des alten Orts wird mit
    den neuen Fotos nicht ergänzt (es teilt keine Fotos mit ihm), ein schon angenommenes
    „ergänzen“ dorthin ist nach der Analyse wieder offen. Ist das Album des alten Orts leer
    (alle Fotos gelöscht), bleibt es das Album der Kennung und der neue Ort kommt hinein.
    Selten (ein neuer Ort im selben Feld von etwa 110 m × 75 m); der Name lässt sich ändern.
  - Ob ein „ergänzen“ vom Vorschlag kam oder über „Anderes Album wählen“, speichert Albumist
    nicht. Hat der Nutzer selbst das Album gewählt, das für die Kennung eingetragen ist und keine
    Fotos mit dem Vorschlag teilt, wird seine Wahl deshalb einmal wieder geöffnet (die Übersicht
    sagt „Vorschläge neu geprüft“); wählt er es erneut, bleibt es. Gemerkt wird das je Vorschlag
    und Album in `user.reopenedExtensions` (wie alle `user.`-Werte auch in der Sicherheitskopie).
  - Nach „Analyse neu aufbauen“ fehlen die vorigen Orte: Kennungen werden neu vergeben, ein Ort
    allein in seiner Zelle bekommt wieder die alte; von zwei Orten einer Zelle bekommt der in
    der App zuerst gezeigte die Zellkennung, der andere Zelle und erste Foto-ID, was nicht
    immer die Kennung von vorher ist (etwa wenn ältere Fotos nachgekommen sind).

- Derselbe Ort als Ort, an dem du öfter bist, und als häufiger Ort (gleich ab der Hälfte der
  Fotos des größeren): Bleibt der häufige Ort, weil er dir gehört (benannt, gewählt oder mit
  Album), fällt der Ort, an dem du öfter bist, weg. Fotos, die nur er hatte (bei Fuchs 87 von
  509 rund um Zwiesel), sind dann in keinem dieser beiden Vorschläge; ohne anderen Vorschlag
  (etwa das Ortsalbum ihrer Stadt) bleiben sie „Nicht sortiert“, und ihre Reisen kommen nicht
  zurück, weil du dort öfter bist. Mit Absicht so (Entscheidung vom
  18.11.2026), damit kein zweites Album für fast dieselben Fotos vorgeschlagen wird.

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
  (Prüfbefund P2-04, Masken-Version 3). Seit Version 4 (zweite Prüfung) auch mit Unterstrichen
  und mit Leerzeichen oder Unterstrich nach dem Ländercode („DE 89 3704 …“). Eine IBAN gilt
  ohne Prüfsumme nur in der gedruckten Form (Großbuchstaben, nur Leerzeichen); jede andere
  Schreibweise braucht eine gültige Prüfsumme, damit Bestell- und Rechnungsnummern wie
  „AB12-3456-7890-1234“ suchbar bleiben: eine IBAN mit Bindestrichen und einem Tippfehler
  bleibt dadurch lesbar. Die Prüfsumme gilt nur bei der IBAN-Länge des Ländercodes (dritte
  Prüfung); eine IBAN mit Trennzeichen aus einem Land, das in der Liste fehlt, bleibt lesbar,
  Bestellnummern, die vor der dritten Prüfung maskiert gespeichert wurden, bleiben maskiert
  (bis „Analyse neu aufbauen“). Kartennummern mit Schrägstrich nur in Vierergruppen
  („4111/1111/…“), damit Telefonnummern wie „04321/12345678“ bleiben; eine Amex-Nummer mit
  Schrägstrichen (4-6-5) bleibt lesbar. Andere Schreibweisen (Buchstaben zwischen den Gruppen,
  stark verlesene Ziffern) können lesbar bleiben.
- Nicht maskiert und nicht versprochen: Steuer-ID, Telefonnummern, E-Mail-Adressen, die Nummer
  der Gesundheitskarte. Der Text bleibt auf dem Gerät.

## Jahreszeiten
- Jahreszeiten sind noch nicht als Alben wählbar. Werden sie es, gilt: Frühling und Herbst
  heißen auf beiden Halbkugeln gleich („Herbst 2026“ für April in Sydney und Oktober in
  München) und wären zwei Alben gleichen Namens; wie sie unterschieden werden, ist offen
  (Prüfbefund P1-04 hat nur Winter und Sommer benannt).

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
- PhotoKit kennt kein bedingtes Löschen: Kommt ein Foto in ein Album von Albumist, solange die
  Frage von iOS zum Löschen offen ist, geht das Album trotzdem (das Foto selbst bleibt in der
  Mediathek). Albumist zählt im Änderungsblock selbst noch einmal nach, direkt bevor iOS fragt
  (Prüfer 2, P2-08): Ein Foto, das vorher hineinkam (auch in den bis zu 30 Sekunden, in denen
  Albumist wartet, bis es für die Frage auf dem Bildschirm ist), hält das Album und seine Ordner;
  dann nimmt Albumist nur seine eigenen Fotos heraus. Die Frage selbst darf bis zu 300 Sekunden
  offen sein.
- Ein beim Wiederanlauf nur über den Namen übernommenes leeres Album bleibt nach Rückgängig
  stehen (gewollt). Seit Prüfer 2, P2-01 (18.11.2026) selten: Die Kennung jedes neuen Albums
  und Ordners steht schon im Änderungsblock im Journal, bevor Fotos speichert; übernommen wird
  nur noch, wenn dieses Schreiben scheiterte (z. B. voller Speicher) oder bei Plänen älterer
  Versionen. Albumist sagt es dann nach dem Rückgängig („Etwas bleibt in Fotos“, mit Name und
  Ordner), und der Plan bleibt im Verlauf.
- Wird ein Hinzufügen in ein Album des Nutzers unterbrochen und ist der Ausgang unklar, nimmt
  Rückgängig ein dort doch angekommenes Foto nicht heraus (gewollt, zweite Gegenprüfung 1.1).
  Der Änderungsbeleg zeigt den Schritt als nicht bestätigt; nach dem Rückgängig (auch nach
  „Alles zurücknehmen“) sagt Albumist, wie viele Fotos in welchem Album bleiben, und der Plan
  bleibt im Verlauf statt zu verschwinden (P2-01).
- Zwei Pläne ergänzen dasselbe Album (Prüfer 2, P2-09): Ein Plan zeichnet nur auf, was er selbst
  hinzugefügt hat. Wird der ältere zurückgenommen, nimmt er seine Fotos aus dem Album, auch die,
  die der neuere Vorschlag ebenfalls dort haben wollte; der Beleg des neueren sagt weiter
  „erledigt“. Fotos des Nutzers sind nie betroffen. Nicht geändert, weil zwei Wege möglich sind
  und beide etwas versprechen, das der andere nicht hält: die Fotos beim Rückgängig des älteren
  lassen (dann nimmt „Rückgängig“ des älteren nicht alles zurück, und ein späteres Rückgängig des
  neueren kennt sie nicht als seine) oder es in der Rückfrage sagen. Offen für eine Entscheidung.
- Beispielfotos entfernen (Prüfer 2, P2-05): Gelöscht wird nur ein Foto, dessen Dateiname und
  Aufnahmedatum im Löschblock selbst noch zu einem Beispielfoto passen
  (`SampleLibrary.isSample`), egal was in der gespeicherten Liste steht; ein Album nur, solange
  es nichts anderes hält, ein Ordner nur, solange alles darin mitgeht. Hat der Nutzer Name oder
  Datum eines Beispielfotos in Fotos geändert, bleibt es: Albumist sagt, wie viele Fotos
  geblieben sind, und vergisst sie. Offen: Nach Löschen und Neuinstallieren von Albumist ist die
  Liste weg; die Beispielfotos bleiben dann als normale Fotos in der Mediathek, und „Entfernen“
  wird nicht mehr angeboten (die Prüfung könnte sie wiederfinden, das ist noch nicht gebaut).
- Das Journal schreibt mit `synchronous = FULL`, aber ohne `PRAGMA fullfsync` (Prüfer 2,
  P2-07): Nach einem Stromausfall kann auf Apple-Geräten der letzte Eintrag fehlen, obwohl Fotos
  die Änderung hat. Seit P2-01/P2-07 legt „Fortsetzen“ dann nichts doppelt an (die Kennung neuer
  Alben steht in einem eigenen Eintrag im Änderungsblock), und Fotos des ersten offenen Schritts,
  die schon im Album liegen, gelten in Albumists eigenem Album als seine, im Album des Nutzers
  als unklar (Rückgängig lässt sie und nennt sie). `fullfsync` ist nicht eingeschaltet: Es kostet
  bei jedem Journal-Eintrag eine volle Leerung des Gerätespeichers, und wie lange das auf einem
  iPhone bei Hunderten Schritten dauert, ist nicht gemessen. Offen für eine Messung auf dem Gerät.
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
