import Foundation

/// Language knowledge of the search: German and English words, singular and plural, for
/// everything the analysis stores (Vision labels, taxonomy categories, document types,
/// screenshot categories, media types, library state). Built once per process.
///
/// Vision identifiers come from Apple's on-device classifier vocabulary (the same names as
/// `ImageTaxonomy`); an identifier the classifier does not know simply never matches.
struct SearchLexicon: Sendable {
    enum Language: Sendable { case german, english, neutral }

    struct Entry: Sendable {
        var criterion: SearchCriterion
        var kind: SearchToken.Kind
        var german: String
        var english: String
        var dimension: String?
        var importance: Int
        /// The typed word is also looked up in the recognized text ("Rechnung" finds a
        /// screenshot that says "Rechnung" even if it was not classified as an invoice).
        var alsoText = false
        /// Offered as autocomplete when photos match.
        var suggest = true
    }

    struct Form: Sendable {
        var entry: Int
        var language: Language
    }

    private(set) var entries: [Entry] = []
    private(set) var forms: [String: [Form]] = [:]
    /// The longest form in words, for the phrase search.
    private(set) var maxWords = 1

    static let shared = SearchLexicon()

    func lookup(_ key: String) -> [Form] { forms[key] ?? [] }

    // MARK: Words that carry no meaning for the search

    static let stopwords: Set<String> = [
        // German
        "alle", "aller", "alles", "allen", "fotos", "foto", "bilder", "bild", "aufnahme", "aufnahmen", "pics", "aus", "im", "in", "am", "an",
        "der", "die", "das", "dem", "den", "des", "von", "vom", "mit", "einer", "einem", "eine", "ein", "einen", "eines", "meines", "meinem",
        "meinen", "meine", "mein", "meiner", "unser", "unsere", "unserem", "unseren", "unserer", "unseres", "zeig", "zeige", "zeigen", "mir",
        "und", "oder", "bei", "beim", "zu", "zum", "zur", "auf", "fur", "uber", "unter", "wo", "wann", "wie", "was", "welche", "ich", "wir",
        "du", "sind", "ist", "war", "waren", "habe", "hab", "haben", "hatte", "gemacht", "aufgenommen", "geschossen", "nur", "auch", "mal",
        "bitte", "gibt", "es", "sich", "mich", "uns", "etwas", "paar", "jahr", "jahre", "jahres", "tag", "tage", "monat", "woche", "da",
        "dort", "hier", "sowie", "so", "als", "nach", "vor", "seit", "bis", "um", "gegen", "durch", "ins", "suche", "such", "finde", "finden",
        // English
        "all", "photos", "photo", "pictures", "picture", "pic", "images", "image", "from", "the", "of", "my", "with", "a", "at", "on", "to",
        "for", "by", "during", "near", "show", "me", "and", "or", "i", "we", "our", "took", "taken", "some", "any", "please", "where", "when",
        "that", "this", "these", "those", "last", "ago", "year", "years", "day", "days", "month", "months", "week", "weeks", "find",
        "search", "us", "is", "was", "were", "it", "its", "into", "around", "about", "only", "also", "just",
    ]

    /// Words that turn the next term around ("Strand ohne Hund").
    static let negations: Set<String> = ["ohne", "kein", "keine", "keinen", "keiner", "nicht", "ausser", "without", "no", "not", "except", "excluding"]

    // MARK: Building

    private mutating func add(_ entry: Entry, de: String, en: String) {
        let index = entries.count
        entries.append(entry)
        let german = Self.split(de), english = Self.split(en)
        for form in Set(german + english) {
            let language: Language = german.contains(form) && english.contains(form) ? .neutral : (german.contains(form) ? .german : .english)
            forms[form, default: []].append(Form(entry: index, language: language))
            maxWords = max(maxWords, form.split(separator: "-").count)
        }
    }

    private static func split(_ forms: String) -> [String] {
        forms.split(separator: "|").map { SearchText.key(String($0)) }.filter { !$0.isEmpty }
    }

    private static func labels(_ list: String) -> [SearchCriterion] {
        list.split(separator: " ").map { .label(String($0)) }
    }

    private static func one(_ list: [SearchCriterion]) -> SearchCriterion {
        list.count == 1 ? list[0] : .any(list)
    }

    /// A topic the classifier recognizes: taxonomy categories and/or Vision identifiers.
    private mutating func topic(_ german: String, _ english: String, _ de: String, _ en: String, categories: [String] = [], labels: String = "") {
        let criteria = categories.map { SearchCriterion.category($0) } + Self.labels(labels)
        add(Entry(criterion: Self.one(criteria), kind: .category, german: german, english: english, importance: 3), de: de, en: en)
    }

    /// A kind of document or screenshot; also searched in the recognized text.
    private mutating func document(_ german: String, _ english: String, _ de: String, _ en: String, _ criteria: [SearchCriterion]) {
        add(Entry(criterion: Self.one(criteria), kind: .document, german: german, english: english, importance: 4, alsoText: true), de: de, en: en)
    }

    private mutating func media(_ german: String, _ english: String, _ de: String, _ en: String, _ criterion: SearchCriterion, kind: SearchToken.Kind = .mediaType, dimension: String? = nil, importance: Int = 5) {
        add(Entry(criterion: criterion, kind: kind, german: german, english: english, dimension: dimension, importance: importance), de: de, en: en)
    }

    private mutating func region(_ german: String, _ english: String, _ de: String, _ en: String, _ codes: String) {
        let set = Set(codes.split(separator: " ").map(String.init))
        add(Entry(criterion: set.count == 1 ? .country(set.first!) : .countries(set), kind: .country, german: german, english: english,
                  dimension: "country", importance: 6), de: de, en: en)
    }

    private init() {
        // MARK: Media types and library state
        media("Videos", "Videos", "video|videos|film|filme|clip|clips|filmchen|videoaufnahme|videoaufnahmen", "video|videos|movie|movies|clip|clips|film|films", .mediaKind(.video), dimension: "kind")
        media("Screenshots", "Screenshots", "screenshot|screenshots|bildschirmfoto|bildschirmfotos|screenshoot|screenshoots", "screenshot|screenshots|screen shot|screen shots", .subtype(.screenshot))
        media("Bildschirmaufnahmen", "Screen recordings", "bildschirmaufnahme|bildschirmaufnahmen|bildschirmvideo|bildschirmvideos", "screen recording|screen recordings|screencast|screencasts", .subtype(.screenRecording))
        media("Panoramen", "Panoramas", "panorama|panoramen|panoramas|panoramafoto|panoramafotos|pano", "panorama|panoramas|pano|panoramic", .subtype(.panorama))
        media("Live Photos", "Live Photos", "live photo|live photos|livephoto|livephotos|live foto|live fotos|live-fotos", "live photo|live photos|livephoto|livephotos", .subtype(.livePhoto))
        media("Zeitlupe", "Slow motion", "zeitlupe|zeitlupen|zeitlupenvideo|zeitlupenvideos", "slow motion|slo-mo|slomo|slowmo|slow-mo", .subtype(.slowMotion))
        media("Zeitraffer", "Time-lapse", "zeitraffer|zeitraffervideo|zeitraffervideos", "timelapse|time-lapse|time lapse|timelapses", .subtype(.timelapse))
        media("Porträts", "Portraits", "porträt|porträts|portrait|portraits|porträtmodus|portraitmodus|porträtfoto|porträtfotos", "portrait|portraits|portrait mode", .subtype(.depthEffect))
        media("HDR", "HDR", "hdr", "hdr", .subtype(.hdr))
        media("RAW", "RAW", "raw|proraw|rohdaten", "raw|proraw", .subtype(.raw))
        media("Serienbilder", "Bursts", "serienbild|serienbilder|serienaufnahme|serienaufnahmen", "burst|bursts|burst photos", .subtype(.burst))
        media("Kinomodus", "Cinematic", "kinomodus|kino modus", "cinematic|cinematic mode|cinematic videos", .subtype(.cinematic))
        media("Räumlich", "Spatial", "räumlich|räumliche|räumliches|3d", "spatial|3d", .subtype(.spatial))
        media("Favoriten", "Favorites", "favorit|favoriten|lieblingsfoto|lieblingsfotos|lieblingsbild|lieblingsbilder|herzchen", "favorite|favorites|favourite|favourites|faves|fave|loved", .favorite, kind: .favorite)
        media("Reisen", "Trips", "urlaub|urlaube|urlaubsfotos|urlaubsbilder|reise|reisen|reisefotos|ferien|trip|trips|ausflug|ausflüge", "vacation|vacations|trip|trips|travel|travels|journey|journeys|holidays", .trip, kind: .trip)
        media("Ausland", "Abroad", "ausland|im ausland|auslandsreise|auslandsreisen", "abroad|overseas", .outsideHome, kind: .country, dimension: "country", importance: 6)
        media("ohne Standort", "without location", "ohne ort|ohne standort|ohne gps|ohne position|kein ort|kein standort|ohne geodaten|ohne ortsangabe|ohne koordinaten",
              "without location|no location|without gps|no gps|unlocated|not geotagged|without place", .hasLocation(false), kind: .location, dimension: "location", importance: 6)
        media("mit Standort", "with location", "mit ort|mit standort|mit gps|mit position|mit geodaten", "with location|with gps|geotagged", .hasLocation(true), kind: .location, dimension: "location", importance: 6)
        media("nicht sortiert", "not sorted", "nicht sortiert|unsortiert|nicht organisiert|unorganisiert|noch nicht sortiert|noch nicht organisiert|ungeordnet|nicht einsortiert",
              "unsorted|not sorted|unorganized|not organized|unorganised|not organised", .status([.unorganized, .partiallyOrganized, .pending]), kind: .status, dimension: "status", importance: 6)
        media("mit Bestellnummer", "with order number", "bestellnummer|bestellnummern|bestellnr|auftragsnummer", "order number|order numbers|order no", .orderNumber, kind: .field, importance: 4)
        media("mit Rechnungsnummer", "with invoice number", "rechnungsnummer|rechnungsnummern|rechnungsnr", "invoice number|invoice numbers|invoice no", .invoiceNumber, kind: .field, importance: 4)

        // MARK: Continents and regions (single countries come from the system's country names)
        region("Europa", "Europe", "europa", "europe", Continent.codes(.europe))
        region("Asien", "Asia", "asien", "asia", Continent.codes(.asia))
        region("Afrika", "Africa", "afrika", "africa", Continent.codes(.africa))
        region("Nordamerika", "North America", "nordamerika", "north america", Continent.codes(.northAmerica))
        region("Südamerika", "South America", "südamerika|lateinamerika", "south america|latin america", Continent.codes(.southAmerica))
        region("Ozeanien", "Oceania", "ozeanien", "oceania", Continent.codes(.oceania))
        region("Antarktis", "Antarctica", "antarktis", "antarctica", Continent.codes(.antarctica))
        region("Skandinavien", "Scandinavia", "skandinavien|nordeuropa", "scandinavia|nordics", "DK NO SE FI IS")
        region("Karibik", "Caribbean", "karibik", "caribbean", "AG AI AW BB BL BQ BS CU CW DM DO GD GP HT JM KN KY LC MF MQ MS PR SX TC TT VC VG VI")
        region("Benelux", "Benelux", "benelux", "benelux", "BE NL LU")
        region("Balkan", "Balkans", "balkan", "balkans", "AL BA BG HR ME MK RS SI XK")
        region("USA", "USA", "usa|amerika|vereinigte staaten|vereinigten staaten", "usa|america|united states|u s a", "US")
        region("Großbritannien", "United Kingdom", "großbritannien|england|schottland|wales|nordirland|vereinigtes königreich|grossbritannien",
               "uk|britain|great britain|england|scotland|wales|northern ireland|united kingdom", "GB")
        region("Niederlande", "Netherlands", "holland|niederlande", "holland|netherlands|the netherlands", "NL")
        region("Tschechien", "Czechia", "tschechien|tschechei|tschechische republik", "czechia|czech republic", "CZ")
        region("Türkei", "Turkey", "türkei|turkei", "turkey|turkiye|türkiye", "TR")
        region("Südkorea", "South Korea", "korea|südkorea", "korea|south korea", "KR")
        region("Vereinigte Arabische Emirate", "United Arab Emirates", "vae|emirate|vereinigte arabische emirate", "uae|emirates|united arab emirates", "AE")

        // MARK: Documents and screenshots
        document("Rechnungen", "Invoices", "rechnung|rechnungen|faktura|stromrechnung|handyrechnung", "invoice|invoices|bill|bills",
                 [.documentType(.invoice), .screenshotCategory("invoice")])
        document("Kassenbons", "Receipts", "kassenbon|kassenbons|kassenzettel|quittung|quittungen|bon|bons|einkaufsbeleg", "receipt|receipts|till receipt",
                 [.documentType(.receipt), .label("receipt")])
        document("Belege", "Receipts and invoices", "beleg|belege|nachweis|nachweise", "proof of purchase|expense|expenses",
                 [.documentType(.receipt), .documentType(.invoice), .screenshotCategory("invoice")])
        document("Verträge", "Contracts", "vertrag|verträge|vertrage|kündigung|mietvertrag", "contract|contracts|agreement|agreements", [.documentType(.contract)])
        document("Garantien", "Warranties", "garantie|garantien|garantieschein|gewährleistung", "warranty|warranties|guarantee", [.documentType(.warranty)])
        document("Bestellungen", "Orders", "bestellung|bestellungen|bestellbestätigung|lieferung|lieferungen|sendung|sendungen|paket|pakete|sendungsverfolgung",
                 "order|orders|delivery|deliveries|package|packages|parcel|parcels|shipping|tracking", [.documentType(.order), .screenshotCategory("order")])
        document("Tickets", "Tickets", "ticket|tickets|eintrittskarte|eintrittskarten|konzertkarte|konzertkarten|einlass", "ticket|tickets|admission",
                 [.documentType(.ticket), .screenshotCategory("ticket"), .screenshotCategory("flight")])
        let trainWords: [SearchCriterion] = [.merchant("deutsche-bahn"), .merchant("db-fernverkehr"), .merchant("db"), .merchant("sbb"), .merchant("obb"),
                                             .text("bahn"), .text("db"), .text("ice"), .text("zug"), .text("gleis"), .text("fahrkarte"), .text("train"),
                                             .text("rail"), .text("sbb"), .text("obb"), .text("hbf")]
        document("Bahntickets", "Train tickets", "bahnticket|bahntickets|zugticket|zugtickets|fahrkarte|fahrkarten|bahnfahrkarte|bahnfahrkarten|deutschlandticket|db ticket",
                 "train ticket|train tickets|rail ticket|rail tickets",
                 [.all([.any([.documentType(.ticket), .screenshotCategory("ticket")]), .any(trainWords)])])
        document("Flüge", "Flights", "flug|flüge|flugticket|flugtickets|bordkarte|bordkarten|boarding|boardingpass|flugbuchung|flugbuchungen|flugschein",
                 "flight|flights|boarding pass|boarding passes|boardingpass|plane ticket|plane tickets|flight booking", [.screenshotCategory("flight")])
        document("Buchungen", "Bookings", "buchung|buchungen|reservierung|reservierungen|buchungsbestätigung", "booking|bookings|reservation|reservations",
                 [.documentType(.booking), .screenshotCategory("hotel"), .screenshotCategory("flight")])
        document("Briefe", "Letters", "brief|briefe|schreiben|post|anschreiben", "letter|letters|mail", [.documentType(.letter)])
        document("Anleitungen", "Manuals", "anleitung|anleitungen|bedienungsanleitung|bedienungsanleitungen|gebrauchsanweisung|gebrauchsanweisungen",
                 "manual|manuals|instructions|how to|how-to|guide", [.documentType(.manual), .screenshotCategory("manual")])
        document("Angebote", "Offers", "angebot|angebote|kostenvoranschlag|rabatt|rabatte|sale|schnäppchen", "offer|offers|deal|deals|quote|discount|sale",
                 [.documentType(.offer), .screenshotCategory("offer")])
        document("Handwerker", "Tradespeople", "handwerker|handwerkerrechnung|handwerkerrechnungen|montage", "craftsman|contractor|tradesman", [.documentType(.craftsman)])
        document("Fahrzeugpapiere", "Vehicle papers", "fahrzeugschein|fahrzeugpapiere|kfz|tüv|zulassung|hauptuntersuchung", "vehicle registration|car papers",
                 [.documentType(.vehicle)])
        document("Dokumente", "Documents", "dokument|dokumente|papiere|unterlagen|scan|scans", "document|documents|papers|paperwork|scan|scans",
                 [.anyDocument, .label("document"), .label("printed_page")])
        document("Rezepte", "Recipes", "rezept|rezepte|kochrezept|kochrezepte|backrezept|backrezepte", "recipe|recipes", [.screenshotCategory("recipe")])
        document("Gutscheine", "Coupons", "gutschein|gutscheine|coupon|coupons|rabattcode|rabattcodes|gutscheincode|gutscheincodes|geschenkkarte",
                 "coupon|coupons|voucher|vouchers|promo code|gift card|gift cards", [.screenshotCategory("coupon"), .label("coupon"), .label("gift_card")])
        document("Chats", "Chats", "chat|chats|nachricht|nachrichten|unterhaltung|unterhaltungen|sms", "chat|chats|message|messages|conversation|conversations|text message|texts",
                 [.screenshotCategory("chat")])
        document("WhatsApp", "WhatsApp", "whatsapp", "whatsapp", [.messenger(.whatsApp)])
        document("Telegram", "Telegram", "telegram", "telegram", [.messenger(.telegram)])
        document("iMessage", "iMessage", "imessage", "imessage", [.messenger(.iMessage)])
        document("Produkte", "Products", "produkt|produkte|warenkorb", "product|products|shopping cart", [.screenshotCategory("product")])
        document("Social Media", "Social media", "social media|instagram|facebook|tiktok|twitter|posts", "social media|instagram|facebook|tiktok|twitter|posts",
                 [.screenshotCategory("socialMedia")])
        document("Nachrichten", "News", "nachrichten|news|artikel|zeitung|zeitungen|schlagzeile|schlagzeilen", "news|article|articles|newspaper|newspapers|headline|headlines",
                 [.screenshotCategory("news"), .label("newspaper")])
        document("Immobilien", "Real estate", "wohnung|wohnungen|immobilie|immobilien|mietwohnung|wohnungssuche|exposé|expose", "apartment|apartments|flat|flats|real estate|property",
                 [.screenshotCategory("realEstate"), .category("home.realEstate")])
        document("Jobs", "Jobs", "job|jobs|stellenanzeige|stellenanzeigen|stellenangebot|stellenangebote|bewerbung|bewerbungen", "job|jobs|job offer|job posting|job application",
                 [.screenshotCategory("job")])
        document("QR-Codes", "QR codes", "qr|qr code|qr codes|qrcode|qrcodes|barcode|barcodes|strichcode", "qr|qr code|qr codes|qrcode|barcode|barcodes",
                 [.screenshotCategory("qrCode")])
        document("Notizen", "Notes", "notiz|notizen|einkaufsliste|einkaufslisten|liste|listen|todo|to do|merkzettel", "note|notes|shopping list|list|lists|todo|to-do",
                 [.screenshotCategory("note"), .label("sticky_note"), .label("handwriting")])
        document("Fehlermeldungen", "Error messages", "fehlermeldung|fehlermeldungen|fehler|einstellungen|seriennummer", "error|errors|error message|settings|serial number",
                 [.screenshotCategory("technical")])
        document("Karten", "Maps", "karte|karten|landkarte|landkarten|stadtplan|navigation|route|routen|wegbeschreibung", "map|maps|navigation|directions|route|routes",
                 [.screenshotCategory("mapNavigation"), .label("map")])
        document("Hotels", "Hotels", "hotel|hotels|unterkunft|unterkünfte|hotelbuchung|ferienwohnung|airbnb", "hotel|hotels|accommodation|airbnb",
                 [.screenshotCategory("hotel"), .label("hotel")])

        // MARK: Animals
        let dogBreeds = "dog canine dog_other australian_shepherd basenji basset beagle bernese_mountain bichon bulldog chihuahua collie corgi dachshund dalmatian "
            + "doberman german_shepherd greyhound husky irish_wolfhound jack_russell_terrier malamute malinois mastiff newfoundland pitbull pomeranian poodle "
            + "pug retriever ridgeback rottweiler saint_bernard schnauzer setter sheepdog spaniel terrier vizsla weimaraner hound"
        topic("Hunde", "Dogs", "hund|hunde|hündchen|welpe|welpen|hündin|hunden|wauwau", "dog|dogs|puppy|puppies|doggy|doggo", categories: ["animal.dog"], labels: dogBreeds)
        topic("Dackel", "Dachshunds", "dackel", "dachshund|dachshunds|sausage dog", labels: "dachshund")
        topic("Schäferhunde", "German shepherds", "schäferhund|schäferhunde", "german shepherd|german shepherds", labels: "german_shepherd")
        topic("Möpse", "Pugs", "mops|möpse", "pug|pugs", labels: "pug")
        topic("Pudel", "Poodles", "pudel", "poodle|poodles", labels: "poodle")
        topic("Retriever", "Retrievers", "retriever|labrador|labradore|golden retriever", "retriever|retrievers|labrador|labradors|golden retriever", labels: "retriever")
        topic("Katzen", "Cats", "katze|katzen|kätzchen|kater|mieze|miezekatze|stubentiger", "cat|cats|kitten|kittens|kitty|kitties", categories: ["animal.cat"], labels: "cat feline kitten adult_cat")
        topic("Pferde", "Horses", "pferd|pferde|pony|ponys|fohlen|pferden", "horse|horses|pony|ponies|foal", categories: ["animal.horse"], labels: "horse equestrian dressage jockey_horse")
        topic("Vögel", "Birds", "vogel|vögel|vögeln", "bird|birds", categories: ["animal.bird"],
              labels: "bird bird_other parrot gull swan hummingbird sparrow pigeon dove owl eagle raven heron stork pelican penguin flamingo peacock puffin toucan woodpecker cockatoo parakeet ostrich")
        topic("Wildtiere", "Wildlife", "wildtier|wildtiere|safari", "wildlife|wild animals|safari", categories: ["animal.wildlife"])
        topic("Tiere", "Animals", "tier|tiere|tierfotos|tieren", "animal|animals", categories: ["animal"])
        topic("Haustiere", "Pets", "haustier|haustiere|haustieren", "pet|pets", categories: ["animal.dog", "animal.cat"],
              labels: "rabbit hamster gerbil chinchilla ferret goldfish guppy parakeet fishbowl fishtank")
        topic("Fische", "Fish", "fisch|fische|fischen", "fish|fishes",
              labels: "fish fish_other goldfish koi clownfish angelfish catfish guppy lionfish puffer_fish swordfish shark stingray aquarium fishtank fishbowl")
        topic("Kühe", "Cows", "kuh|kühe|rind|rinder|kälbchen|kalb", "cow|cows|cattle|calf", labels: "cow")
        topic("Schafe", "Sheep", "schaf|schafe|lamm|lämmer", "sheep|lamb|lambs", labels: "sheep")
        topic("Ziegen", "Goats", "ziege|ziegen", "goat|goats", labels: "goat")
        topic("Schweine", "Pigs", "schwein|schweine|ferkel", "pig|pigs|piglet", labels: "pig")
        topic("Esel", "Donkeys", "esel", "donkey|donkeys", labels: "donkey")
        topic("Schwäne", "Swans", "schwan|schwäne", "swan|swans", labels: "swan")
        topic("Möwen", "Gulls", "möwe|möwen", "gull|gulls|seagull|seagulls", labels: "gull")
        topic("Tauben", "Pigeons", "taube|tauben", "pigeon|pigeons|dove|doves", labels: "pigeon dove")
        topic("Eulen", "Owls", "eule|eulen", "owl|owls", labels: "owl")
        topic("Adler", "Eagles", "adler|greifvogel|greifvögel", "eagle|eagles|bird of prey", labels: "eagle raptor peregrine")
        topic("Papageien", "Parrots", "papagei|papageien|wellensittich|wellensittiche|sittich", "parrot|parrots|budgie|budgies", labels: "parrot parakeet cockatoo")
        topic("Pinguine", "Penguins", "pinguin|pinguine", "penguin|penguins", labels: "penguin")
        topic("Flamingos", "Flamingos", "flamingo|flamingos", "flamingo|flamingos|flamingoes", labels: "flamingo")
        topic("Kaninchen", "Rabbits", "kaninchen|hase|hasen|häschen", "rabbit|rabbits|bunny|bunnies|hare", labels: "rabbit")
        topic("Hamster", "Hamsters", "hamster|meerschweinchen|wüstenrennmaus", "hamster|hamsters|gerbil|guinea pig", labels: "hamster gerbil")
        topic("Eichhörnchen", "Squirrels", "eichhörnchen|eichhörnchens", "squirrel|squirrels", labels: "squirrel")
        topic("Igel", "Hedgehogs", "igel", "hedgehog|hedgehogs", labels: "hedgehog")
        topic("Füchse", "Foxes", "fuchs|füchse", "fox|foxes", labels: "fox")
        topic("Rehe und Hirsche", "Deer", "reh|rehe|hirsch|hirsche|elch|elche|rentier|rentiere", "deer|elk|moose|reindeer|caribou", labels: "deer elk moose caribou")
        topic("Bären", "Bears", "bär|bären|eisbär|panda|pandas", "bear|bears|panda|pandas|polar bear", labels: "bear panda")
        topic("Elefanten", "Elephants", "elefant|elefanten", "elephant|elephants", labels: "elephant")
        topic("Giraffen", "Giraffes", "giraffe|giraffen", "giraffe|giraffes", labels: "giraffe")
        topic("Zebras", "Zebras", "zebra|zebras", "zebra|zebras", labels: "zebra")
        topic("Löwen", "Lions", "löwe|löwen", "lion|lions", labels: "lion")
        topic("Tiger", "Tigers", "tiger", "tiger|tigers", labels: "tiger")
        topic("Affen", "Monkeys", "affe|affen", "monkey|monkeys|ape|apes", labels: "monkey primate lemur")
        topic("Kamele", "Camels", "kamel|kamele|dromedar", "camel|camels|dromedary", labels: "camel")
        topic("Lamas", "Llamas", "lama|lamas|alpaka|alpakas", "llama|llamas|alpaca|alpacas", labels: "llama")
        topic("Kängurus", "Kangaroos", "känguru|kängurus", "kangaroo|kangaroos", labels: "kangaroo")
        topic("Koalas", "Koalas", "koala|koalas", "koala|koalas", labels: "koala")
        topic("Schildkröten", "Turtles", "schildkröte|schildkröten", "turtle|turtles|tortoise|tortoises", labels: "turtle tortoise")
        topic("Schlangen", "Snakes", "schlange|schlangen", "snake|snakes", labels: "snake python rattlesnake")
        topic("Eidechsen", "Lizards", "eidechse|eidechsen|echse|echsen|gecko|leguan", "lizard|lizards|gecko|iguana", labels: "lizard gecko iguana chameleon")
        topic("Frösche", "Frogs", "frosch|frösche|kröte|kröten", "frog|frogs|toad|toads", labels: "frog toad")
        topic("Schmetterlinge", "Butterflies", "schmetterling|schmetterlinge|falter", "butterfly|butterflies|moth", labels: "butterfly moth")
        topic("Bienen", "Bees", "biene|bienen|bienenstock|imker", "bee|bees|beehive|beekeeping", labels: "bee beehive beekeeping")
        topic("Insekten", "Insects", "insekt|insekten|käfer|libelle|marienkäfer", "insect|insects|bug|bugs|beetle|dragonfly|ladybug",
              labels: "insect insect_other ladybug bee butterfly dragonfly ant caterpillar")
        topic("Spinnen", "Spiders", "spinne|spinnen|spinnennetz", "spider|spiders|spiderweb|cobweb", labels: "spider spiderweb")
        topic("Delfine", "Dolphins", "delfin|delfine|delphin|delphine", "dolphin|dolphins", labels: "dolphin")
        topic("Wale", "Whales", "wal|wale", "whale|whales", labels: "whale cetacean")
        topic("Haie", "Sharks", "hai|haie", "shark|sharks", labels: "shark")
        topic("Robben", "Seals", "robbe|robben|seehund|seehunde|seelöwe|seelöwen|walross", "seal|seals|sea lion|sea lions|walrus", labels: "seal sealion walrus")
        topic("Quallen", "Jellyfish", "qualle|quallen", "jellyfish", labels: "jellyfish")
        topic("Krabben", "Crabs", "krabbe|krabben|krebs|krebse|hummer", "crab|crabs|lobster|lobsters", labels: "crab lobster")
        topic("Muscheln", "Shells", "muschel|muscheln|seestern|seesterne", "shell|shells|seashell|seashells|starfish", labels: "seashell conch starfish")
        topic("Aquarium", "Aquariums", "aquarium|aquarien", "aquarium|aquariums", labels: "aquarium fishtank")
        topic("Zoo", "Zoo", "zoo|tierpark|tiergarten|wildpark", "zoo|zoos", labels: "zoo")
        topic("Bauernhof", "Farm", "bauernhof|bauernhöfe|scheune", "farm|farms|barn", labels: "farm barn")

        // MARK: Food and drink
        topic("Essen", "Food", "essen|mahlzeit|mahlzeiten|gericht|gerichte|speisen|lebensmittel|essensfotos|food",
              "food|meal|meals|dish|dishes|foodie", categories: ["food.dish", "food.restaurant"],
              labels: "food_other pizza pasta spaghetti hamburger sandwich salad soup steak sushi burrito taco curry ramen dumpling kebab paella risotto "
                + "omelet pancake waffle cake dessert ice_cream bread croissant fries hotdog meat seafood")
        topic("Pizza", "Pizza", "pizza|pizzen|pizzas", "pizza|pizzas", labels: "pizza calzone")
        topic("Pasta", "Pasta", "pasta|nudeln|nudel|spaghetti|lasagne", "pasta|noodles|spaghetti|lasagna", labels: "pasta spaghetti ramen")
        topic("Burger", "Burgers", "burger|hamburger|cheeseburger", "burger|burgers|hamburger|hamburgers|cheeseburger", labels: "hamburger")
        topic("Pommes", "Fries", "pommes|pommes frites|fritten", "fries|french fries", labels: "fries")
        topic("Salat", "Salad", "salat|salate", "salad|salads", labels: "salad caprese coleslaw")
        topic("Sushi", "Sushi", "sushi", "sushi", labels: "sushi")
        topic("Fleisch", "Meat", "fleisch|steak|steaks|braten|schnitzel", "meat|steak|steaks|roast", labels: "steak meat beef pork spareribs")
        topic("Meeresfrüchte", "Seafood", "meeresfrüchte|garnelen|muscheln essen|austern", "seafood|shrimp|prawns|oysters|mussels",
              labels: "seafood shellfish_prepared mussel oyster lobster scallop clam")
        topic("Suppe", "Soup", "suppe|suppen|eintopf", "soup|soups|stew", labels: "soup ramen")
        topic("Kuchen", "Cake", "kuchen|torte|torten|gebäck|kuchenstück", "cake|cakes|pastry|pastries|pie",
              labels: "cake cake_regular cake_other cheesecake cupcake birthday_cake wedding_cake pie strudel baked_goods pastry")
        topic("Desserts", "Desserts", "dessert|desserts|nachtisch|nachspeise|süßes|süßigkeiten", "dessert|desserts|sweets|candy",
              labels: "dessert dessert_other ice_cream frozen_dessert pudding tiramisu custard candy chocolate brownie donut cupcake")
        topic("Eis", "Ice cream", "eis|eiscreme|speiseeis|eisbecher|eisdiele", "ice cream|gelato|ice-cream", labels: "ice_cream frozen_dessert popsicle frozen_yogurt")
        topic("Obst", "Fruit", "obst|früchte|frucht", "fruit|fruits",
              labels: "fruit fruit_other banana apple strawberry grape oranges citrus_fruit berry watermelon pineapple mango cherry peach pear lemon")
        topic("Gemüse", "Vegetables", "gemüse", "vegetables|vegetable|veggies", labels: "vegetable vegetable_other tomato carrot broccoli cucumber potato lettuce bell_pepper corn onion")
        topic("Brot", "Bread", "brot|brote|brötchen|semmel|semmeln|breze|brezel|brezn|brezen", "bread|bun|buns|pretzel|pretzels", labels: "bread white_bread bagel pretzel croissant baked_goods")
        topic("Frühstück", "Breakfast", "frühstück|brunch|frühstücken", "breakfast|brunch", labels: "croissant pancake waffle fried_egg scrambled_eggs omelet cereal oatmeal bagel yogurt")
        topic("Kaffee", "Coffee", "kaffee|cappuccino|espresso|latte macchiato|café", "coffee|cappuccino|espresso|latte", labels: "coffee")
        topic("Tee", "Tea", "tee", "tea", labels: "tea_drink teapot")
        topic("Bier", "Beer", "bier|biere|maß|weißbier", "beer|beers", labels: "beer keg")
        topic("Wein", "Wine", "wein|weine|rotwein|weißwein|weinprobe", "wine|wines|red wine|white wine|wine tasting", labels: "wine red_wine white_wine wine_bottle wine_other sparkling_wine")
        topic("Sekt", "Champagne", "sekt|champagner|prosecco", "champagne|prosecco|sparkling wine|bubbly", labels: "sparkling_wine")
        topic("Cocktails", "Cocktails", "cocktail|cocktails|aperol|longdrink", "cocktail|cocktails|spritz", labels: "cocktail cocktail_other margarita martini mojito sangria")
        topic("Getränke", "Drinks", "getränk|getränke|drink|drinks", "drink|drinks|beverage|beverages", categories: ["food.drink"])
        topic("Restaurants", "Restaurants", "restaurant|restaurants|gasthaus|wirtshaus|lokal|essen gehen|abendessen|mittagessen", "restaurant|restaurants|dinner|lunch|dining",
              categories: ["food.restaurant"])
        topic("Grillen", "Barbecue", "grillen|grill|grillabend|grillfest|grillparty|grillfleisch", "barbecue|bbq|grill|grilling|cookout",
              labels: "grill grilled_chicken satay spareribs rotisserie kebab")
        topic("Schokolade", "Chocolate", "schokolade|pralinen|praline", "chocolate|chocolates", labels: "chocolate")
        topic("Plätzchen", "Cookies", "plätzchen|kekse|keks|lebkuchen", "cookies|cookie|biscuits|gingerbread", labels: "cookie biscuit gingerbread")
        topic("Käse", "Cheese", "käse|fondue|raclette", "cheese|fondue|raclette", labels: "cheese fondue")
        topic("Döner", "Kebab", "döner|kebab|dürüm|döner kebab", "kebab|doner|shawarma", labels: "kebab shawarma")
        topic("Tacos", "Tacos", "taco|tacos|burrito|burritos|nachos", "taco|tacos|burrito|burritos|nachos", labels: "taco burrito quesadilla nachos fajita")
        topic("Pfannkuchen", "Pancakes", "pfannkuchen|crêpe|crêpes|eierkuchen|palatschinken", "pancake|pancakes|crepe|crepes", labels: "pancake crepe")

        // MARK: Nature, landscape and weather
        topic("Strand", "Beach", "strand|strände|strandes|badestrand|sandstrand|strandurlaub|strandtag", "beach|beaches|seaside|beach day", labels: "beach shore sandcastle sunbathing")
        topic("Meer", "Sea", "meer|meere|ozean|ozeane|küste|küsten", "sea|seas|ocean|oceans|coast|coastline", categories: ["nature.sea"], labels: "ocean shore beach")
        topic("Seen", "Lakes", "see|seen|bergsee|badesee", "lake|lakes", categories: ["nature.lake"], labels: "lake")
        topic("Sonnenuntergänge", "Sunsets", "sonnenuntergang|sonnenuntergänge|sonnenaufgang|sonnenaufgänge|abendrot|morgenrot|abendstimmung|abendhimmel",
              "sunset|sunsets|sunrise|sunrises|dusk|dawn|golden hour", categories: ["nature.sunset"], labels: "sunset_sunrise")
        topic("Berge", "Mountains", "berg|berge|bergen|gebirge|gipfel|alpen|bergtour", "mountain|mountains|alps|peak|peaks|summit", categories: ["nature.mountain"],
              labels: "mountain hill cliff glacier")
        topic("Wald", "Forest", "wald|wälder|forst|wäldern", "forest|forests|woods", categories: ["nature.forest"], labels: "forest jungle")
        topic("Bäume", "Trees", "baum|bäume|bäumen", "tree|trees",
              labels: "tree tree_other palm_tree oak_tree maple_tree evergreen sequoia willow eucalyptus_tree")
        topic("Palmen", "Palm trees", "palme|palmen", "palm|palms|palm tree|palm trees", labels: "palm_tree")
        topic("Blumen", "Flowers", "blume|blumen|blüte|blüten|blumenstrauß|blumensträuße|blumenwiese", "flower|flowers|blossom|blossoms|bouquet|bouquets",
              categories: ["nature.flower"], labels: "flower flower_other blossom rose tulip sunflower daisy orchid lily dahlia daffodil bouquet flower_arrangement")
        topic("Rosen", "Roses", "rose|rosen", "rose|roses", labels: "rose")
        topic("Tulpen", "Tulips", "tulpe|tulpen", "tulip|tulips", labels: "tulip")
        topic("Sonnenblumen", "Sunflowers", "sonnenblume|sonnenblumen", "sunflower|sunflowers", labels: "sunflower")
        topic("Natur", "Nature", "natur|draußen|outdoor", "nature|outdoors|outdoor", categories: ["nature"])
        topic("Landschaften", "Landscapes", "landschaft|landschaften|aussicht|ausblick|panoramablick", "landscape|landscapes|scenery|view|views",
              categories: ["nature.landscape", "nature.mountain", "nature.lake", "nature.sea", "nature.forest"])
        topic("Flüsse", "Rivers", "fluss|flüsse|bach|bäche|ufer", "river|rivers|creek|stream|riverside", labels: "river creek waterways")
        topic("Wasserfälle", "Waterfalls", "wasserfall|wasserfälle", "waterfall|waterfalls", labels: "waterfall")
        topic("Wüste", "Desert", "wüste|wüsten|düne|dünen", "desert|deserts|dune|dunes", labels: "desert sand_dune")
        topic("Inseln", "Islands", "insel|inseln", "island|islands", labels: "island")
        topic("Höhlen", "Caves", "höhle|höhlen|grotte|grotten", "cave|caves|grotto", labels: "cave")
        topic("Vulkane", "Volcanoes", "vulkan|vulkane|lava", "volcano|volcanoes|lava", labels: "volcano lava")
        topic("Gletscher", "Glaciers", "gletscher|eisberg|eisberge", "glacier|glaciers|iceberg|icebergs", labels: "glacier iceberg")
        topic("Schluchten", "Canyons", "schlucht|schluchten|canyon|klamm", "canyon|canyons|gorge|gorges", labels: "canyon")
        topic("Himmel", "Sky", "himmel|wolken|wolke|wolkenhimmel", "sky|skies|clouds|cloud", labels: "sky blue_sky cloudy sky_other")
        topic("Sternenhimmel", "Night sky", "sterne|sternenhimmel|nachthimmel|milchstraße|sternbild", "stars|night sky|milky way|starry sky", labels: "night_sky celestial_body")
        topic("Mond", "Moon", "mond|vollmond|mondfinsternis", "moon|full moon|lunar eclipse", labels: "moon")
        topic("Polarlichter", "Northern lights", "nordlicht|nordlichter|polarlicht|polarlichter", "northern lights|aurora|auroras|aurora borealis", labels: "aurora")
        topic("Regenbogen", "Rainbows", "regenbogen", "rainbow|rainbows", labels: "rainbow")
        topic("Gewitter", "Thunderstorms", "gewitter|blitz|blitze|unwetter|sturm", "thunderstorm|thunderstorms|lightning|storm|storms", labels: "thunderstorm lightning")
        topic("Regen", "Rain", "regen|regnerisch|pfütze|pfützen", "rain|rainy|puddle|puddles", labels: "rain puddle")
        topic("Schnee", "Snow", "schnee|verschneit|winterlandschaft|schneelandschaft", "snow|snowy|snowfall", labels: "snow snowman snowball blizzard")
        topic("Schneemänner", "Snowmen", "schneemann|schneemänner|schneeballschlacht", "snowman|snowmen|snowball fight", labels: "snowman snowball")
        topic("Nebel", "Fog", "nebel|neblig|dunst", "fog|foggy|mist|misty|haze", labels: "haze")
        topic("Garten", "Garden", "garten|gärten|gartenarbeit|schrebergarten", "garden|gardens|gardening|backyard|yard", categories: ["home.garden"], labels: "garden backyard")
        topic("Parks", "Parks", "park|parks|stadtpark|englischer garten", "park|parks", labels: "park")
        topic("Spielplatz", "Playground", "spielplatz|spielplätze|schaukel|rutsche|sandkasten", "playground|playgrounds|swing|slide|sandbox",
              labels: "playground swing_playground slide_toy seesaw sandbox")
        topic("Pflanzen", "Plants", "pflanze|pflanzen|zimmerpflanze|zimmerpflanzen|kaktus|kakteen", "plant|plants|houseplant|houseplants|cactus|cacti",
              categories: ["home.garden"], labels: "decorative_plant plant cactus bonsai")

        // MARK: Leisure and places
        topic("Freizeitpark", "Amusement park", "freizeitpark|freizeitparks|vergnügungspark|achterbahn|achterbahnen|riesenrad|karussell",
              "amusement park|theme park|rollercoaster|roller coaster|ferris wheel|carousel", labels: "amusement_park rollercoaster ferris_wheel carousel")
        topic("Jahrmarkt", "Fair", "jahrmarkt|kirmes|volksfest|rummel|kirchweih|dult", "fair|funfair|fairground", labels: "fairground carousel ferris_wheel")
        topic("Zirkus", "Circus", "zirkus", "circus", labels: "circus")
        topic("Schwimmbad", "Swimming pool", "schwimmbad|freibad|hallenbad|pool|swimmingpool|therme", "pool|swimming pool|pools", labels: "pool")
        topic("Schwimmen", "Swimming", "schwimmen|baden|planschen", "swimming|swim", labels: "swimming pool")
        topic("Sauna", "Sauna", "sauna|whirlpool|wellness|spa", "sauna|jacuzzi|hot tub|spa", labels: "sauna jacuzzi")
        topic("Kirchen", "Churches", "kirche|kirchen|dom|kathedrale|kapelle|basilika", "church|churches|cathedral|chapel|basilica",
              labels: "church_exterior church_interior belltower stained_glass")
        topic("Moscheen", "Mosques", "moschee|moscheen|minarett", "mosque|mosques|minaret", labels: "mosque_exterior mosque_interior minaret")
        topic("Tempel", "Temples", "tempel", "temple|temples", labels: "temple_exterior")
        topic("Burgen und Schlösser", "Castles", "burg|burgen|schloss|schlösser|festung|palast", "castle|castles|palace|palaces|fortress", labels: "castle")
        topic("Museen", "Museums", "museum|museen|museumsbesuch|ausstellung|ausstellungen|galerie", "museum|museums|exhibition|exhibitions|gallery", labels: "museum")
        topic("Brücken", "Bridges", "brücke|brücken", "bridge|bridges", labels: "bridge")
        topic("Türme", "Towers", "turm|türme|kirchturm", "tower|towers", labels: "tower clock_tower belltower")
        topic("Leuchttürme", "Lighthouses", "leuchtturm|leuchttürme", "lighthouse|lighthouses", labels: "lighthouse")
        topic("Hochhäuser", "Skyscrapers", "hochhaus|hochhäuser|wolkenkratzer", "skyscraper|skyscrapers|high-rise|high rise", labels: "skyscraper")
        topic("Städte", "Cities", "stadt|städte|skyline|innenstadt|stadtansicht|großstadt|städtereise", "city|cities|skyline|downtown|cityscape|city trip",
              labels: "cityscape skyscraper")
        topic("Architektur", "Architecture", "architektur|gebäude", "architecture|building|buildings", categories: ["misc.architecture"], labels: "building")
        topic("Sehenswürdigkeiten", "Landmarks", "sehenswürdigkeit|sehenswürdigkeiten|wahrzeichen", "landmark|landmarks|sights|sightseeing",
              categories: ["misc.landmark", "misc.architecture"])
        topic("Denkmäler", "Monuments", "denkmal|denkmäler|statue|statuen|skulptur|skulpturen|monument", "monument|monuments|statue|statues|sculpture|sculptures",
              labels: "monument statue obelisk")
        topic("Ruinen", "Ruins", "ruine|ruinen|ausgrabung|ausgrabungen|antike", "ruins|ruin|ancient|excavation", labels: "ruins megalith")
        topic("Pyramiden", "Pyramids", "pyramide|pyramiden", "pyramid|pyramids", labels: "pyramid")
        topic("Brunnen", "Fountains", "brunnen|springbrunnen", "fountain|fountains", labels: "fountain")
        topic("Häfen", "Harbours", "hafen|häfen|anlegestelle|steg|yachthafen|seebrücke", "harbour|harbor|port|marina|pier|dock", labels: "harbour dock pier")
        topic("Flughäfen", "Airports", "flughafen|flughäfen", "airport|airports", labels: "airport hangar")
        topic("Bahnhöfe", "Train stations", "bahnhof|bahnhöfe|bahnsteig|hauptbahnhof", "train station|train stations|station|railway station", labels: "train_station")
        topic("Straßen", "Streets", "straße|straßen|gasse|gassen", "street|streets|road|roads|alley|alleys", labels: "street road alley crosswalk")
        topic("Häuser", "Houses", "haus|häuser|einfamilienhaus|eigenheim", "house|houses", labels: "house_single domicile")
        topic("Küche", "Kitchen", "küche|küchen", "kitchen|kitchens", labels: "kitchen kitchen_room kitchen_countertop")
        topic("Wohnzimmer", "Living room", "wohnzimmer|stube", "living room|lounge", labels: "living_room")
        topic("Schlafzimmer", "Bedroom", "schlafzimmer|bett|betten", "bedroom|bedrooms|bed|beds", labels: "bedroom bed")
        topic("Badezimmer", "Bathroom", "bad|badezimmer|bäder|dusche|badewanne", "bathroom|bathrooms|shower|bathtub", labels: "bathroom bathroom_room bath shower")
        topic("Einrichtung", "Interior", "einrichtung|innenraum|innenräume|zimmer|räume|wohnen", "interior|interiors|room|rooms", categories: ["home.interior"])
        topic("Möbel", "Furniture", "möbel|sofa|couch|stuhl|stühle|tisch|tische", "furniture|sofa|couch|chair|chairs|table|tables", categories: ["home.furniture"], labels: "sofa")
        topic("Büro", "Office", "büro|arbeitsplatz|schreibtisch|meeting|besprechung", "office|desk|workplace|meeting|conference", labels: "office desk cubicle conference")
        topic("Krankenhaus", "Hospital", "krankenhaus|klinik|kreißsaal", "hospital|clinic", labels: "hospital")
        topic("Schule", "School", "schule|klassenzimmer|schulhof|einschulung|uni|universität|hörsaal", "school|classroom|university|lecture hall", labels: "classroom chalkboard")
        topic("Bibliotheken", "Libraries", "bibliothek|bücherei|bibliotheken", "library|libraries", labels: "library bookshelf")
        topic("Theater", "Theatre", "theater|bühne|oper|kino|musical", "theater|theatre|stage|opera|cinema|musical", labels: "theater auditorium performance")
        topic("Bars", "Bars", "bar|bars|kneipe|kneipen|pub|biergarten", "bar|bars|pub|pubs|beer garden", labels: "bar")
        topic("Clubs", "Clubs", "club|disco|diskothek|nachtclub|clubbing|tanzen", "club|clubs|nightclub|disco|clubbing|dancing", labels: "nightclub disco_ball")
        topic("Shopping", "Shopping", "shopping|einkaufen|einkaufsbummel|laden|geschäft|geschäfte|supermarkt|einkaufszentrum", "shopping|shop|shops|store|stores|mall|supermarket",
              categories: ["misc.shopping"], labels: "storefront interior_shop shopping_cart shopping_bag")
        topic("Weinberge", "Vineyards", "weinberg|weinberge|weingut|weinlese", "vineyard|vineyards|winery", labels: "vineyard")
        topic("Baustellen", "Construction sites", "baustelle|baustellen|bagger|kran|hausbau|neubau", "construction|construction site|excavator|crane",
              categories: ["work.construction"], labels: "crane_construction scaffolding backhoe bulldozer")
        topic("Renovierung", "Renovation", "renovierung|renovieren|umbau|heimwerken|streichen|sanierung", "renovation|diy|remodeling|refurbishment", categories: ["home.renovation"])
        topic("Werkzeug", "Tools", "werkzeug|werkzeuge|werkstatt", "tool|tools|workshop", categories: ["work.tools"])
        topic("Camping", "Camping", "camping|zelt|zelte|zelten|campingplatz|wohnwagen", "camping|tent|tents|campsite|campground", labels: "camping tent")
        topic("Wohnmobile", "Campervans", "wohnmobil|wohnmobile|camper|bulli", "camper|campervan|motorhome|rv", labels: "motorhome")

        // MARK: Vehicles
        topic("Autos", "Cars", "auto|autos|wagen|pkw|sportwagen|oldtimer", "car|cars|sports car|classic car", categories: ["vehicle.car"],
              labels: "car automobile sportscar convertible suv jeep limousine")
        topic("Motorräder", "Motorcycles", "motorrad|motorräder|roller|vespa|moped", "motorcycle|motorcycles|motorbike|motorbikes|scooter", categories: ["vehicle.motorcycle"])
        topic("Fahrräder", "Bicycles", "fahrrad|fahrräder|rad|radl|velo|e-bike|ebike", "bicycle|bicycles|bike|bikes|e-bike", categories: ["vehicle.bicycle"], labels: "bicycle cycling")
        topic("Flugzeuge", "Airplanes", "flugzeug|flugzeuge|flieger", "airplane|airplanes|plane|planes|aircraft|aeroplane", categories: ["vehicle.airplane"], labels: "airplane aircraft airshow")
        topic("Züge", "Trains", "zug|züge|bahn|eisenbahn|lok|lokomotive", "train|trains|railway|railroad|locomotive", categories: ["vehicle.train"])
        topic("Straßenbahnen", "Trams", "straßenbahn|straßenbahnen|tram|trambahn", "tram|trams|streetcar|streetcars|trolley", labels: "tramway streetcar")
        topic("Boote", "Boats", "boot|boote|schiff|schiffe|segelboot|segelboote|kreuzfahrt|fähre|yacht|bootsfahrt", "boat|boats|ship|ships|sailboat|cruise|ferry|yacht|boat trip",
              categories: ["vehicle.boat"], labels: "watercraft")
        topic("Busse", "Buses", "bus|busse|reisebus", "bus|buses|coach", labels: "bus")
        topic("Lastwagen", "Trucks", "lkw|laster|lastwagen|transporter", "truck|trucks|lorry|van", labels: "truck semi_truck van")
        topic("Traktoren", "Tractors", "traktor|traktoren|trecker", "tractor|tractors", labels: "tractor")
        topic("Hubschrauber", "Helicopters", "hubschrauber|helikopter", "helicopter|helicopters", labels: "helicopter")
        topic("Seilbahnen", "Cable cars", "seilbahn|seilbahnen|gondel|sessellift|skilift|bergbahn", "cable car|cable cars|gondola|chairlift|ski lift", labels: "cableway chairlift")
        topic("Feuerwehr", "Fire trucks", "feuerwehr|feuerwehrauto|feuerwehrautos", "fire truck|fire engine|fire trucks", labels: "firetruck")
        topic("Fahrzeuge", "Vehicles", "fahrzeug|fahrzeuge", "vehicle|vehicles", categories: ["vehicle"])

        // MARK: Sport
        topic("Sport", "Sports", "sport|sportlich", "sport|sports", categories: ["sport"], labels: "sport_other athletics")
        topic("Fußball", "Football", "fußball|fussball|kicken|fußballspiel|bundesliga", "soccer|football|football match", categories: ["sport.football"])
        topic("Fitness", "Fitness", "fitness|fitnessstudio|gym|training|workout|krafttraining", "fitness|gym|workout|training", categories: ["sport.fitness"], labels: "workout health_club barbell")
        topic("Wandern", "Hiking", "wandern|wanderung|wanderungen|wanderweg|bergwandern|trekking", "hiking|hike|hikes|trail|trails|trekking", categories: ["sport.hiking"])
        topic("Skifahren", "Skiing", "ski|skifahren|skiurlaub|skilaufen|piste|pisten|skigebiet|skitour|langlauf", "skiing|ski|ski trip|slopes|ski resort|cross-country skiing",
              labels: "skiing ski_equipment ski_boot")
        topic("Snowboarden", "Snowboarding", "snowboard|snowboarden", "snowboard|snowboarding", labels: "snowboard snowboarding")
        topic("Wintersport", "Winter sports", "wintersport", "winter sports|winter sport", categories: ["sport.winter"])
        topic("Eislaufen", "Ice skating", "schlittschuh|schlittschuhe|schlittschuhlaufen|eislaufen|eisbahn", "ice skating|skating|skating rink|ice rink", labels: "ice_skating ice_skates rink")
        topic("Rodeln", "Sledding", "rodeln|schlitten|schlittenfahren", "sledding|sled|sledge|tobogganing", labels: "sledding sled")
        topic("Surfen", "Surfing", "surfen|wellenreiten|kitesurfen|windsurfen|surfbrett", "surfing|surf|kitesurfing|windsurfing|surfboard",
              labels: "surfing surfboard kiteboarding windsurfing")
        topic("Segeln", "Sailing", "segeln|segeltörn", "sailing|sail", labels: "sailboat")
        topic("Tauchen", "Diving", "tauchen|schnorcheln|unterwasser|tauchgang", "diving|scuba|scuba diving|snorkeling|snorkelling|underwater",
              labels: "diving scuba snorkeling underwater coral_reef")
        topic("Kajak", "Kayaking", "kajak|kanu|paddeln|stand up paddling|kanufahren", "kayak|kayaking|canoe|canoeing|paddling|paddleboarding", labels: "kayak canoe rafting")
        topic("Klettern", "Climbing", "klettern|bouldern|klettersteig", "climbing|bouldering|rock climbing", labels: "rock_climbing")
        topic("Radfahren", "Cycling", "radfahren|radtour|fahrradtour|mountainbike|mountainbiken|radeln", "cycling|bike ride|bike tour|mountain biking", labels: "cycling bicycle")
        topic("Golf", "Golf", "golf|golfen|golfplatz", "golf|golfing|golf course", labels: "golf golf_course golf_ball golf_club")
        topic("Tennis", "Tennis", "tennis|tennisplatz", "tennis", labels: "tennis")
        topic("Basketball", "Basketball", "basketball", "basketball", labels: "basketball")
        topic("Volleyball", "Volleyball", "volleyball|beachvolleyball", "volleyball|beach volleyball", labels: "volleyball")
        topic("Yoga", "Yoga", "yoga", "yoga", labels: "yoga")
        topic("Reiten", "Horse riding", "reiten|ausritt|reitstall", "horse riding|riding|equestrian", labels: "equestrian dressage horse")
        topic("Angeln", "Fishing", "angeln|fischen gehen", "fishing", labels: "fishing")
        topic("Boxen", "Boxing", "boxen|kampfsport|karate|judo", "boxing|martial arts|karate|judo", labels: "boxing kickboxing martial_arts")
        topic("Bowling", "Bowling", "bowling|kegeln", "bowling", labels: "bowling")
        topic("Billard", "Billiards", "billard", "billiards|snooker", labels: "billiards")
        topic("Tischtennis", "Table tennis", "tischtennis", "ping pong|table tennis", labels: "ping_pong")
        topic("Eishockey", "Ice hockey", "eishockey|hockey", "hockey|ice hockey", labels: "hockey")
        topic("Motorsport", "Motorsport", "motorsport|formel 1|formel1|autorennen|rennen", "motorsport|formula 1|formula one|f1|racing|grand prix",
              categories: ["sport.motorsport"], labels: "grand_prix")
        topic("Kartfahren", "Karting", "kart|kartfahren|gokart|go-kart", "go kart|karting|go-kart|go-karts", labels: "go_kart")
        topic("Stadien", "Stadiums", "stadion|stadien|arena", "stadium|stadiums|arena", labels: "stadium arena bleachers scoreboard")

        // MARK: Events
        topic("Hochzeiten", "Weddings", "hochzeit|hochzeiten|trauung|heirat|braut|bräutigam|hochzeitstorte|standesamt|polterabend",
              "wedding|weddings|bride|groom|marriage|wedding cake",
              labels: "wedding wedding_dress wedding_cake bride groom bridesmaid chinese_wedding indian_wedding japanese_wedding muslim_wedding boutonniere")
        topic("Geburtstage", "Birthdays", "geburtstag|geburtstage|geburtstagsfeier|geburtstagskuchen|geburtstagstorte|kindergeburtstag|geburtstagsparty",
              "birthday|birthdays|birthday party|birthday cake|bday", labels: "birthday_cake")
        topic("Feiern", "Parties", "party|partys|feier|feiern|fest|feste|fete|sause", "party|parties|celebration|celebrations",
              labels: "celebration balloon streamer pinata disco_ball")
        topic("Konzerte", "Concerts", "konzert|konzerte|festival|festivals|live-musik|livemusik|band", "concert|concerts|festival|festivals|gig|gigs|live music",
              labels: "concert performance orchestra")
        topic("Feuerwerk", "Fireworks", "feuerwerk|feuerwerke|feuerwerks|böller|wunderkerze|wunderkerzen", "fireworks|firework|sparkler|sparklers",
              labels: "fireworks firecracker sparkler pyrotechnics")
        topic("Abschlussfeiern", "Graduations", "abschluss|abschlussfeier|abiball|abi|abitur|graduierung|zeugnisübergabe", "graduation|graduations|prom", labels: "graduation")
        topic("Oktoberfest", "Oktoberfest", "oktoberfest|wiesn|wiesnbesuch", "oktoberfest", labels: "oktoberfest")
        topic("Veranstaltungen", "Events", "veranstaltung|veranstaltungen|event|events", "event|events", categories: ["misc.event"])
        topic("Kostüme", "Costumes", "kostüm|kostüme|verkleidung|verkleidet", "costume|costumes|dress up|fancy dress", labels: "costume")
        topic("Weihnachtsbäume", "Christmas trees", "weihnachtsbaum|weihnachtsbäume|christbaum|tannenbaum", "christmas tree|christmas trees", labels: "christmas_tree")
        topic("Weihnachtsmärkte", "Christmas markets", "weihnachtsmarkt|weihnachtsmärkte|christkindlmarkt|christkindlesmarkt", "christmas market|christmas markets",
              labels: "christmas_decoration")
        topic("Kerzen", "Candles", "kerze|kerzen|kerzenschein|adventskranz", "candle|candles|candlelight|advent wreath", labels: "candle candlestick wreath")
        topic("Geschenke", "Gifts", "geschenk|geschenke|bescherung", "gift|gifts|present|presents", labels: "gift gift_card")
        topic("Luftballons", "Balloons", "ballon|ballons|luftballon|luftballons", "balloon|balloons", labels: "balloon")
        topic("Heißluftballons", "Hot-air balloons", "heißluftballon|heißluftballons|ballonfahrt", "hot air balloon|hot-air balloon|hot air balloons", labels: "balloon_hotair")
        topic("Musik", "Music", "musik|instrument|instrumente|musizieren", "music|instrument|instruments", labels: "musical_instrument guitar piano violin drum")
        topic("Gitarren", "Guitars", "gitarre|gitarren|e-gitarre", "guitar|guitars", labels: "guitar")
        topic("Klavier", "Piano", "klavier|flügel|piano", "piano|grand piano|keyboard", labels: "piano")
        topic("Kunst", "Art", "kunst|kunstwerk|kunstwerke|gemälde|malerei", "art|artwork|artworks|painting|paintings", categories: ["misc.art"], labels: "painting graffiti")
        topic("Graffiti", "Graffiti", "graffiti|street art|streetart", "graffiti|street art|mural|murals", labels: "graffiti")
        topic("Tattoos", "Tattoos", "tattoo|tattoos|tätowierung|tätowierungen", "tattoo|tattoos", labels: "tattoo")

        // MARK: Things
        topic("Smartphones", "Phones", "handy|handys|smartphone|smartphones|telefon|iphone", "phone|phones|smartphone|smartphones|iphone|cellphone", labels: "cellphone phone telephone")
        topic("Computer", "Computers", "computer|laptop|laptops|pc|rechner|notebook|bildschirm|monitor", "computer|computers|laptop|laptops|pc|monitor",
              labels: "computer laptop computer_monitor computer_keyboard")
        topic("Technik", "Technology", "technik|elektronik|gadget|gadgets", "technology|tech|electronics|gadget|gadgets", categories: ["misc.technology"])
        topic("Fernseher", "TVs", "fernseher|tv|fernsehen|glotze", "tv|television|tvs", labels: "television")
        topic("Kameras", "Cameras", "kamera|kameras|fotoapparat|spiegelreflex", "camera|cameras|dslr", labels: "camera")
        topic("Uhren", "Watches and clocks", "uhr|uhren|armbanduhr|armbanduhren|wecker", "watch|watches|clock|clocks", labels: "watch clock timepiece")
        topic("Bücher", "Books", "buch|bücher|lesen|roman", "book|books|reading|novel", labels: "book bookshelf")
        topic("Brillen", "Glasses", "brille|brillen|sonnenbrille|sonnenbrillen", "glasses|sunglasses|eyeglasses|spectacles", labels: "eyeglasses sunglasses")
        topic("Schmuck", "Jewellery", "schmuck|ring|ringe|kette|ketten|ohrringe|armband", "jewelry|jewellery|ring|rings|necklace|earrings|bracelet", labels: "jewelry")
        topic("Kleidung", "Clothing", "kleidung|klamotten|outfit|outfits|mode|anziehsachen", "clothes|clothing|outfit|outfits|fashion", categories: ["misc.clothing"],
              labels: "clothing dress jacket")
        topic("Schuhe", "Shoes", "schuh|schuhe|sneaker|sneakers|stiefel|turnschuhe", "shoe|shoes|sneakers|boots|trainers", labels: "shoes sneaker boot footwear high_heel sandal loafer")
        topic("Kleider", "Dresses", "kleid|kleider|abendkleid", "dress|dresses|gown|evening dress", labels: "dress gown")
        topic("Hüte", "Hats", "hut|hüte|mütze|mützen|kappe|kappen", "hat|hats|cap|caps|beanie", labels: "hat baseball_hat beanie fedora sunhat straw_hat cowboy_hat")
        topic("Spielzeug", "Toys", "spielzeug|spielsachen|lego|kuscheltier|kuscheltiere|teddy|teddybär|puppe|puppen|playmobil",
              "toy|toys|lego|teddy|teddy bear|stuffed animal|stuffed animals|doll|dolls", labels: "toy toy_other stuffed_animals doll blocks vehicle_toy train_toy electronic_toy")
        topic("Spiele", "Games", "spiel|spiele|brettspiel|brettspiele|puzzle|puzzles|schach|kartenspiel|spieleabend", "game|games|board game|board games|puzzle|puzzles|chess|card game",
              labels: "board_game chess play_card puzzles jigsaw videogame")
        topic("Geld", "Money", "geld|münzen|münze|geldscheine|bargeld", "money|coins|coin|cash|banknotes", labels: "currency coin")
        topic("Flaggen", "Flags", "flagge|flaggen|fahne|fahnen", "flag|flags", labels: "flag")
        topic("Schilder", "Signs", "schild|schilder|verkehrsschild|verkehrsschilder|straßenschild", "sign|signs|street sign|road sign", labels: "sign street_sign warning_sign")
        topic("Whiteboards", "Whiteboards", "whiteboard|tafel|flipchart", "whiteboard|blackboard|flipchart", labels: "whiteboard chalkboard flipchart")
        topic("Diagramme", "Charts", "diagramm|diagramme|grafik|grafiken|chart", "chart|charts|diagram|diagrams|graph|graphs", labels: "diagram chart pie_chart")
        topic("Technische Dokumentation", "Technical documentation", "technische dokumentation|schaltplan|baupläne|bauplan", "technical documentation|schematic|blueprint",
              categories: ["work.documentation"])
        topic("Koffer", "Luggage", "koffer|gepäck|reisegepäck|rucksack", "suitcase|suitcases|luggage|backpack", labels: "suitcase luggage backpack")
    }
}

extension Continent {
    /// The ISO codes of a continent, space separated (the lexicon's region format).
    static func codes(_ continent: Continent) -> String {
        Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && forCountryCode($0) == continent }.sorted().joined(separator: " ")
    }
}
