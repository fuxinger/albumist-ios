# Bekannte Einschränkungen

## iOS
- Fotos-Apps dürfen keine Smart-Alben, geteilten oder synchronisierten Alben verändern.
- Hintergrundarbeit ist nicht garantiert; iOS entscheidet über `BGContinuedProcessingTask`
  und `BGProcessingTask`, wie lange Albumist im Hintergrund rechnen darf. Endet die Zeit,
  hält iOS die App an, und die Analyse geht beim nächsten Öffnen an derselben Stelle weiter.
- Apps können die Fotos-App öffnen, aber nicht ein bestimmtes Album darin.
- Bei „Ausgewählte Fotos“ sieht Albumist nur diese Auswahl: Vorschläge, Reisen, Zuhause,
  Zählung und Suche entstehen nur aus diesen Fotos. Die übrigen Fotos werden beiseitegelegt,
  nicht gelöscht (Prüfbefund P1-07, behoben 20.11.): Zurück auf „Alle Fotos“ oder in einer
  anderen Auswahl kommen sie mit Analyse, Ort und Text zurück und werden nicht neu analysiert.
  Ob ein beiseitegelegtes Foto in Fotos gelöscht wurde, kann Albumist bei eingeschränktem
  Zugriff nicht wissen; es verschwindet aus der Datenbank erst, wenn Albumist wieder alle
  Fotos sieht. Der erste Lauf danach liest die Mediathek einmal ganz. Bis dahin bleiben auch
  die gespeicherten Orte und der (maskierte) erkannte Text der nicht freigegebenen Fotos in der
  Datenbank (`docs/PRIVACY.md`); „Analyse neu aufbauen“ löscht sie. Reisen, häufige Orte und
  gewählte Vorschläge behalten ihre Kennung und ihre beiseitegelegten Fotos, auch über mehrere
  Auswahlen hintereinander. Ein gewählter Vorschlag, den Albumist hält, wird dabei nicht
  losgelassen. Ausnahme: Wird „Dein Zuhause“ geändert, während nur ausgewählte Fotos freigegeben
  sind, und Albumist hält deshalb einen gewählten Vorschlag zum ersten Mal, hält es ihn mit den
  freigegebenen Fotos (die übrigen sind dem Vorschlag dann nicht bekannt); mit vollem Zugriff
  bleibt er so, bis der Nutzer ihn anlegt oder abwählt.
  Wird eine Sicherung wiederhergestellt, während nur ausgewählte Fotos freigegeben sind, kennt
  Albumist die beiseitegelegten Teile häufiger Orte nicht mehr (sie sind Analyse, nicht Teil der
  Sicherung): ein Ort, dessen Fotos gerade alle nicht freigegeben sind, bekommt mit vollem
  Zugriff eine neue Kennung, ein selbst gegebener Name geht dann verloren (zweite Prüfung von
  P1-07, selten).
- Ortsnamen über `CLGeocoder` sind von Apple begrenzt (Drosselung, gelegentliche Fehler);
  Länder und Regionen kommen immer aus der Offline-Karte. Ein Lauf in der App fragt höchstens
  40 Ortsnamen pro Minute und wartet nie darauf; was fehlt, kommt mit einem späteren Lauf
  (frühestens nach einer Stunde) oder der nächtlichen Verfeinerung.
- Albumists Zähler dieser Ortsabfragen (`RequestLog`, 40 pro Minute) liegt nur im Speicher:
  Wird die App beendet und innerhalb einer Minute wieder gestartet, kennt er die Abfragen davor
  nicht, und in dieser Minute können bis zu 80 an Apple gehen. Lehnt Apple dann ab, hört ein
  Lauf in der App sofort auf; die Verfeinerung wartet. Bewusst nicht gespeichert (Zweitprüfung
  des Fixes, 18.11.).
- Die Karte der nächtlichen Verfeinerung (bei geöffneter App) nennt keine Fertig-Uhrzeit, und
  ihr Titel ist der Name des Schritts, nicht „Verfeinerung“.
- `CLGeocoder` ist in iOS 26 als veraltet markiert; der Nachfolger in MapKit ist geplant.
- Umstrittene Gebiete (Entscheidung Fuchs 18.11., `DisputedAreas`): Krim, Westsahara, Kaschmir,
  Nordzypern, Kosovo, Taiwan, Golanhöhen und Abchasien heißen mit ihrem eigenen Namen statt eines
  Landes, ihr Vorschlag ist „Unsicher“. Die Umrisse von Westsahara, Golanhöhen und Aksai Chin
  und die Umrisse auf dem Wasser (um die Krim mit der Straße von Kertsch, um Taiwan, Penghu und
  die kleinen Inseln, Kästen um Matsu, Pratas, Lieyu, Dadan, Erdan, Wuqiu und Dongding, die Gewässer im
  Norden Zyperns) sind grob (einige Kilometer). Die winzigen, unbewohnten Inseln Fuxing und
  Shiyu westlich von Lieyu liegen womöglich außerhalb des Kastens (ihre Lage ist nicht sicher
  geprüft); dort entscheidet Apples Antwort. An der Grenze
  (bis etwa 1,5 km), wo die Karte nicht sicher ist und Apple das Nachbarland nennt (etwa
  Serbien am Kosovo, Republik Zypern an der Pufferzone), gilt das Nachbarland. Orte, die vor dem Update bestimmt wurden, behalten ihr altes Land, bis „Analyse
  neu aufbauen“ sie neu bestimmt. Eine automatische Nachprüfung gibt es bewusst nicht: Die
  Entscheidungen, Titel und Alben eines Ortsvorschlags hängen an seinem Schlüssel, und für Krim,
  Nordzypern, Westsahara und Kaschmir bleibt der alte Länderschlüssel („Russland“) für den Rest
  des Landes bestehen; eine Entscheidung zu „Russland“ ließe sich nicht sauber auf „Krim“
  übertragen. Im Reise-Atlas zählen diese Gebiete nicht als Land (ihre Reisen und Orte zählen
  mit dem Gebietsnamen), und die Atlas-Karte (auch im Teilen-Bild) füllt sie nie mit einem
  besuchten Land (`AtlasShapes`). Ein Tippen auf ein Gebiet öffnet nichts: Für ein Gebiet gibt es
  keine eigene Seite, und die Seite eines der Länder ergriffe Partei (`AtlasShapes.tappedCode`).
  Das Malen der Karte und das Tippen sind bisher nur auf Linux (Regel) und im Code geprüft, noch
  nicht auf einem Mac (`AtlasRenderingTests`). Die Suche findet sie über den Gebiets- oder Ortsnamen, nicht als
  Land. Nicht in der Liste: Südossetien, Transnistrien, Somaliland,
  Westjordanland und Ost-Jerusalem (dort gilt die Karte wie bisher). Noch nicht behandelt, offene
  Frage an Fuchs: das Shaksgam-Tal (von China verwaltet, von Indien als Teil Kaschmirs beansprucht;
  die Karte sagt sicher „China“), Arunachal Pradesh (von China beansprucht; die Karte sagt
  „Indien“) und die südlichen Kurilen (von Japan beansprucht; die Karte sagt „Russland“).
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

## Ortszeit (Tage, Monate, Jahre)

- Tage, Monate und Jahre eines Fotos sind die der Uhr am Aufnahmeort (Prüfbefund P1-15,
  Entscheidung 19.11.2026). Die Zeitzone nennt online der Ort selbst; offline kommt sie aus dem
  Land, in einem Land mit mehreren Zonen aus dem nächsten Bezugsort (IANA `zone.tab` und die Orte
  in `tools/country_time_zones_extra.txt`). Bis etwa 50 km an einer Zonengrenze kann das offline
  die Nachbarzone sein (Bullhead City in Arizona bekommt die Zeit von Laughlin am anderen Ufer).
  Wo die Uhren früher anders gingen (Indiana bis 2007, North Dakota bis 2010, Teile Russlands),
  kann ein älteres Foto nahe einer solchen Grenze offline eine Stunde daneben liegen. Kaschmir,
  die Golanhöhen und Abchasien haben offline keine Zone (dort gilt die Heimatzone).
- Fotos ohne Ort (auch mit einem Ort nur aus dem Bildinhalt) zählen außerhalb von Reisen in der
  Heimatzone, der Zeitzone des Zuhauses: des in „Dein Zuhause“ gewählten, sonst des gefundenen,
  auch bei einem Update unterwegs (zweite Prüfung von P1-15). Nur solange kein Zuhause bekannt
  ist, ist es die Zeitzone des iPhones bei der ersten Analyse. Die Heimatzone wird gespeichert,
  bleibt auf Reisen und nach „Analyse neu aufbauen“, die Sicherung nimmt sie mit; nach einem
  Umzug in ein Land mit anderer Zeit folgt sie dem neuen Zuhause, sobald Albumist es findet oder
  es gewählt wird. Es gibt nur eine Heimatzone, keine je früherem Zuhause: Fotos ohne Ort aus der
  Zeit vor dem Umzug zählen dann in der neuen. Zwei Zuhause mit etwa gleich vielen Tagen, einen
  halben Tag auseinander (München und Auckland), behalten die Zone, die sie haben: in der Zeit
  des einen hat das andere die meisten Tage, die Zone wechselte sonst mit jeder Analyse. Eine
  gespeicherte Zone, die das System nicht kennt (aus der Sicherung eines neueren iPhones), bleibt
  gespeichert; solange gilt die des iPhones.
- Ein Foto ohne Ort, das eine Reise über seine Zeit hält (aus einer Kamera ohne GPS, ein im
  Messenger empfangenes Bild), zählt in der Zone des Reiseziels: der häufigsten unter den Fotos
  der Reise, auch wenn sie über mehrere Zonen ging. Außerhalb einer Reise gilt für ein Foto ohne
  Ort die Heimatzone, auch wenn es woanders entstand.
- „Nur 2026“ sieht sich die Fotos an, die nach ihrer Uhr in 2026 liegen, so weit ihre Orte bei
  der Analyse bekannt sind. Bekommt ein Foto erst später einen Ort mit einer anderen Zone (online,
  nahe einer Zonengrenze) und rückt dadurch ins Jahr, kommt es mit der nächsten Analyse dazu.
- Weiter in der Zeitzone des iPhones: Reise-Atlas, Länderseiten und Foto-Geschichte (ihre Jahre
  und Tage), der Vorschlag für „Seit wann wohnst du dort?“ und die Tage in der Reise-Werkstatt.
  Ein Foto der Silvesternacht in New York steht also im Album „Dezember 2026“, im Reise-Atlas
  eines iPhones mit deutscher Zeit aber unter 2027. Eigene Zeiträume und Regeln „von–bis“ sind
  feste Zeitpunkte und bleiben es.
- In der Heimatzone, nicht in der Zeit jedes Fotos: die Erkennung von Reisen und Zuhause (welche
  Tage zu Hause waren). Eine Reise ins Ausland wird danach in der Zeit ihres Ziels eingeordnet
  (Tagesausflug, Wochenende, Halte), wie bisher.
- Ein Foto, das durch die Ortszeit in einen anderen Monat rückt (am Monatsende im Ausland), wird
  dem Album seines neuen Monats zum Ergänzen angeboten; aus dem schon angelegten Album des alten
  Monats nimmt Albumist es nicht heraus.

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
    und Album in `user.reopenedExtensions` (wie alle `user.`-Werte auch in der Sicherheitskopie),
    bis der Vorschlag weder eine Entscheidung noch ein eingetragenes Album hat.
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
- Medizinische Dokumente erkennt Albumist an Wörtern auf Deutsch und Englisch (den Sprachen der
  Texterkennung), seit Masken-Version 5 (Nebenbefund G2-03, 18.11.) auch englische Arztbriefe
  („Diagnosis“, „Discharge summary“, „Medication“, ICD-Codes). Ein Brief, der keines dieser
  Wörter nennt (etwa „Betreff: Depression, stationäre Behandlung“), wird wie ein gewöhnlicher
  Brief gespeichert (IBAN und Karten maskiert). Ein Schlüsselwort zählt nur am Wortanfang
  (zweite Prüfung: „Collab report“, „Bau-Bescheinigung“, „Rezeption“, „Libanon“, „bicycle“,
  „patiently“, „please be patient“ bleiben gewöhnlicher Text), deutsche Wörter auch am Ende
  einer Zusammensetzung („Laborbefund“, „Facharztbrief“). Englische Zusammensetzungen ohne
  Leerzeichen („misdiagnosis“) zählen deshalb nicht. Was weiter als medizinisch gilt, obwohl es
  das nicht ist (der Text wird dann nicht gespeichert und ist nicht per Volltext suchbar): eine
  Anleitung mit „Fehlerdiagnose“/„Fault diagnosis“, ein Kochrezept („Rezept“), ein Arbeitsvertrag
  mit „sick leave“, „patient“ als Eigenschaftswort nach anderen Wörtern als be/so/very/more/
  stay/remain („a patient teacher“). Ein von OCR getrenntes Wort zählt nur, wenn der
  Bindestrich am Zeilenende steht („Diag-⏎nosis“), nicht mitten in der Zeile.
- Gelöschter Text wird seit der zweiten Prüfung von G2-03 in der Datenbankdatei mit Nullen
  überschrieben (`secure_delete`), der Suchindex nach dem Nachmaskieren verdichtet und das
  Protokoll geleert. Seiten, die eine ältere Version freigegeben hat, können alten Text noch
  enthalten, bis SQLite sie wiederverwendet oder die App gelöscht wird (kein `VACUUM`).
- Nicht maskiert und nicht versprochen: Steuer-ID, Telefonnummern, E-Mail-Adressen, die Nummer
  der Gesundheitskarte. Der Text bleibt auf dem Gerät.
- Vorschauen und Titelbilder lassen sensible Dokumente weg (`PreviewRank`), erkennen sie aber
  nur aus dem, was die Analyse gespeichert hat. Im Zweifel wird ausgeblendet: Ein Bild, das die
  Bildanalyse für ein Dokument hielt, gilt als sensibel, solange sein Text es nicht als harmloses
  Dokument erklärt (Text noch nicht gelesen, Original nur in iCloud, unlesbar wegen Spiegelung
  oder Winkel, Kartennummer auf der Rückseite oder verlesen, Ausweis oder Arztbrief ohne
  erkannte Dokumentart). Ebenso sensibel: jedes Bild mit leerem gelesenem Text ohne
  Dokument-Einordnung (so speicherten ältere Versionen Ausweis- und Arzt-Screenshots; nichts wird
  dafür neu gelesen) und ein Bildschirmfoto, dessen Text nicht gelesen ist und das kein
  Screenshot-Thema erklärt. Was trotzdem durchrutschen kann:
  - Ein Foto, das die Bildanalyse **nicht** für ein Dokument hielt, wird nie gelesen und gilt als
    gewöhnliches Foto, auch eine Bankkarte. Welche Bildmerkmale Vision einem Kartenfoto gibt,
    ist noch nicht auf einem Gerät geprüft (Liste `ContentAnalysis.documentLabels` kennt kein
    Karten-Merkmal); Idee in `IMPROVEMENTS.md` (Kartenform ID-1).
  - Sind „Themen“ und „Dokumente“ aus, fragt die Bildanalyse keine Merkmale ab: dann zählt nur
    Visions Kennzeichen für Gebrauchsbilder. Sind „Screenshots“, „Dokumente“ und „Messenger“ aus,
    wird kein Text gelesen: dann fehlen alle Bildschirmfotos und alle Bilder, die die Bildanalyse
    für ein Dokument hielt, in Vorschauen; bei Fotos zählt nur die Bildanalyse.
  - Fotos, die die Bildanalyse noch nicht angesehen hat (vor allem während der ersten Analyse:
    frühe Vorschläge, das Mosaik), kommen erst nach allen angesehenen gewöhnlichen Fotos, werden
    aber gezeigt, wenn es zu wenige angesehene gibt: sie füllen jeden Platz, der übrig bleibt. Ein
    Kartenfoto darunter ist dann noch nicht erkannt. Das Mosaik der ersten Analyse sieht sich je
    Abschnitt höchstens 256 Bilder an und nimmt das erste nicht angesehene, wenn darunter kein
    angesehenes Foto ist. Das Teilen-Bild des Atlas nimmt nie ein solches Foto.
  - Themen, die vor allem aus Bildern mit Dokument-Anschein bestehen (Whiteboards, technische
    Dokumentation), zeigen oft „Vorschau ausgeblendet“: ohne erklärenden Text gelten diese Bilder
    als sensibel. Das Album bekommt trotzdem alle Fotos.
  - Ein Beleg, der „VISA“ oder „girocard“ nennt, gilt für Vorschauen als sensibel und fehlt dort;
    im Beleg-Album bleibt er (die Kartenwörter ändern die Dokument-Einordnung nicht). Ein Beleg,
    der „Kreditkarte“, eine IBAN oder „BIC“ nennt, ist dagegen schon länger als finanziell
    eingeordnet und fehlt deshalb im Beleg-Album, solange „Sensible Dokumente einbeziehen“ aus ist
    (Standard); das ist älteres Verhalten und hier nicht geändert.
  - Eine maskierte Bestell- oder Sendungsnummer, die die Kartenprüfung besteht, macht einen
    Screenshot zum sensiblen Dokument: er fehlt dann nur in der Vorschau.
  - Bildschirmaufnahmen (Videos) werden nie gelesen und sind in Vorschauen immer ausgeblendet
    (entschieden, für den Datenschutz): ein eingeschalteter Vorschlag „Bildschirmaufnahmen“
    zeigt „Vorschau ausgeblendet“; das Album bekommt trotzdem alle Aufnahmen.
  - Rezepte: „Rezept“ ist ein medizinisches Wort, ein Rezept-Screenshot wird deshalb ohne
    gespeicherten Text abgelegt (unverändert). Für Vorschauen zählt ein Bildschirmfoto mit dem
    Thema „Rezepte“, leerem Text und keiner oder nur einer medizinischen Einordnung ohne
    Dokumentart als Dokument. Was dabei durchrutschen kann: ein medizinischer Screenshot, den die
    Themen-Erkennung auch für ein Rezept hält (ein Beipackzettel mit „Teelöffel“ oder
    „Zubereitung“), und ein Rezept-Screenshot, der zusätzlich eine Karte, IBAN oder
    Ausweiszeile zeigt (die Einordnung behält dann nur die medizinische Stufe). Ein Rezept-
    Screenshot mit erkannter Dokumentart bleibt ausgeblendet.
  - Kartenwörter werden über alle üblichen Leerzeichen (auch schmale und ideografische),
    neben Satzzeichen (auch chinesischen und japanischen) und in Vollbreite („ＶＩＳＡ“) erkannt;
    andere Schriften für dieselben Wörter (kyrillische oder griechische Buchstaben, die wie
    lateinische aussehen) nicht.

## Suche
- Orte, denen du einen Namen gibst, findet die Suche unter diesem Namen, auch bevor ihr Album
  angelegt ist (Prüfbefund G1-05). Umbenannte Reisen und andere Vorschläge, die keine Orte
  sind, findet sie unter dem neuen Namen erst über ihr Album.
- Ein Name aus mehreren Wörtern wird als Ganzes gefunden, wie bei Städten und Alben: ein Wort
  daraus allein („Kleingarten“ für „Mein Kleingarten“) findet den Ort nicht. Beim Tippen bietet
  die Suche den ganzen Namen an.

## Jahreszeiten
- Jahreszeiten sind noch nicht als Alben wählbar. Werden sie es, gilt: Frühling und Herbst
  heißen auf beiden Halbkugeln gleich („Herbst 2026“ für April in Sydney und Oktober in
  München) und wären zwei Alben gleichen Namens; wie sie unterschieden werden, ist offen
  (Prüfbefund P1-04 hat nur Winter und Sommer benannt).

## Messenger-Herkunft
iOS speichert keine verlässliche Quell-App. Albumist nutzt nur klare Hinweise (Messenger-
Screenshots, vorhandene Alben, optional Dateinamen-Muster) und markiert alles andere als
unbekannt.

## Ring und Listen der Mediathek
- Ring und Liste „Sortiert“ folgen derselben Regel (`OrganizationStatusResolver.ringPart`,
  Entscheidung Fuchs 18.11.), werden aber zu verschiedenen Zeitpunkten neu gerechnet. Kurz
  auseinander liegen sie:
  - direkt nach „Ignorieren“, „Widerrufen“ oder „Nicht mehr ignorieren“: die Listen folgen dem
    Tippen sofort (`IgnoreChange`), der Ring erst mit der Neuzählung im Hintergrund
    (gewollt, damit keine Zahl zurückspringt; meist unter einer Sekunde, bei 50.000 Fotos
    einige Sekunden);
  - solange der Ring „Wird neu gezählt · Zuletzt X von Y sortiert“ zeigt (`RecountState`, nach
    „Analyse neu aufbauen“ oder während Fotos ihre Labels für „Themen“/„Dokumente“ nachholen):
    der Ring hält die alte Zahl, die Listen zeigen schon den neuen Stand;
  - direkt nach dem Wechsel des Jahres („Nur 2026“): die Listen werden sofort neu gemacht, der
    Ring zählt einen Augenblick später (`changeScope` stößt die Neuzählung sofort an).
- Ein Foto, das ignoriert wird, verschwindet beim Ignorieren aus „Sortiert“ oder „Nicht
  sortiert“; ist es sortiert, werden „x“ und „y“ im Ring je um eins kleiner (der Anteil kann
  dann leicht sinken). Ignorieren eines offenen Fotos oder eines Fotos von zu Hause senkt ihn nie.

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
- Zwei Pläne füllen dasselbe Album (Prüfer 2, P2-09, entschieden 26.11.2026): Rückgängig nimmt
  nur Fotos heraus, die kein anderer angenommener Vorschlag dort haben will (`ChangePlan.wanted`,
  `UndoPlanner.keptForOthers`); Albumist sagt danach, wie viele Fotos in welchem Album bleiben.
  Das spätere Rückgängig des anderen Vorschlags nimmt sie mit. Grenze: Pläne aus Versionen vor
  dieser Änderung haben ihre Wünsche nicht aufgeschrieben; für sie zählt, was sie selbst
  hinzugefügt haben, und ihr Rückgängig verhält sich wie vorher. Ein unterbrochener Plan, der
  mit „Alles zurücknehmen“ zurückgeht, prüft andere Pläne nicht (er legt nur Fehlendes dazu).
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
- Der frühere Arbeitsname „Sortly“ steht nur noch in gespeicherten Namen, die bleiben müssen (Datenbank-Datei älterer Builds, Schlüssel der Album-Einträge; `tools/rename_albumist.py`).
