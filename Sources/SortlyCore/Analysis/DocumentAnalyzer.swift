import Foundation

public enum DocumentType: String, Sendable, Codable, CaseIterable {
    case invoice, receipt, contract, warranty, order, ticket, booking, letter, manual, offer, craftsman, vehicle, other
}

/// How carefully a document must be handled (prompt §4.8).
public enum DocumentSensitivity: String, Sendable, Codable, Comparable {
    case normal
    /// Bank statements, IBAN, salary slips, contracts.
    case financial
    /// Passports, ID cards, driving licences.
    case identity
    /// Diagnoses, prescriptions, health insurance.
    case medical

    private var rank: Int { [.normal: 0, .financial: 1, .identity: 2, .medical: 2][self]! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct MoneyAmount: Hashable, Sendable, Codable {
    /// Amount in minor units (cents) to avoid floating point errors.
    public var minorUnits: Int
    public var currency: String

    public var decimalString: String {
        String(format: "%d.%02d", minorUnits / 100, abs(minorUnits % 100))
    }
}

/// Structured information extracted from recognized document text.
/// Every field is optional – nothing is guessed when the text does not contain it.
public struct DocumentInfo: Hashable, Sendable, Codable {
    public var type: DocumentType
    public var typeReliability: Reliability
    /// Date printed on the document. Kept apart from the photo's capture date.
    public var documentDate: Date?
    public var merchant: String?
    public var orderNumber: String?
    public var invoiceNumber: String?
    public var totalAmount: MoneyAmount?
    public var subject: String?
    public var keywords: [String]
    public var sensitivity: DocumentSensitivity
}

/// Rule-based document understanding on top of on-device OCR output.
/// Deterministic and testable; bilingual (German / English) keyword sets.
public struct DocumentAnalyzer: Sendable {
    public init() {}

    static let typeKeywords: [(DocumentType, [String])] = [
        (.invoice, ["rechnung", "rechnungsnummer", "rechnungsnr", "invoice", "invoice no", "ust-id", "umsatzsteuer", "zahlbar bis", "amount due"]),
        (.receipt, ["kassenbon", "bon-nr", "beleg-nr", "summe eur", "bar ", "ec-karte", "girocard", "receipt", "change due", "kassierer", "mwst"]),
        (.contract, ["vertrag", "vertragsnummer", "vertragspartner", "laufzeit", "kündigungsfrist", "contract", "agreement", "unterschrift"]),
        (.warranty, ["garantie", "gewährleistung", "garantieschein", "warranty", "guarantee"]),
        (.order, ["bestellung", "bestellnummer", "bestellbestätigung", "order number", "order confirmation", "your order", "lieferung", "versandbestätigung"]),
        (.ticket, ["ticket", "fahrkarte", "eintrittskarte", "boarding pass", "bordkarte", "gate", "sitzplatz", "seat", "zug", "gleis", "einlass"]),
        (.booking, ["buchungsbestätigung", "buchungsnummer", "reservierung", "booking", "reservation", "check-in", "check-out", "hotel", "unterkunft", "flugnummer", "flight"]),
        (.letter, ["sehr geehrte", "mit freundlichen grüßen", "dear ", "sincerely", "betreff:", "ihr zeichen"]),
        (.manual, ["bedienungsanleitung", "gebrauchsanweisung", "sicherheitshinweise", "user manual", "instructions", "installation"]),
        (.offer, ["angebot", "angebotsnummer", "kostenvoranschlag", "quotation", "quote", "gültig bis"]),
        (.craftsman, ["handwerker", "montage", "arbeitszeit", "material", "meisterbetrieb", "stundenlohn", "anfahrt"]),
        (.vehicle, ["fahrzeugschein", "zulassungsbescheinigung", "fahrgestellnummer", "tüv", "hauptuntersuchung", "kfz", "kennzeichen", "inspektion", "ölwechsel"]),
    ]

    static let sensitivityKeywords: [(DocumentSensitivity, [String])] = [
        (.identity, ["personalausweis", "reisepass", "passport", "identity card", "führerschein", "driving licence", "aufenthaltstitel", "nationalität", "date of birth", "geburtsdatum",
                     // The back of an ID card names no document (review P2-04).
                     "augenfarbe", "eye colour", "eye color", "colour of eyes", "color of eyes", "ordensname", "künstlername"]),
        (.medical, ["diagnose", "befund", "rezept", "arztbrief", "krankenkasse", "versichertennummer", "arbeitsunfähigkeit", "patient", "medikament", "prescription"]),
        (.financial, ["kontoauszug", "iban", "bic", "lohnabrechnung", "gehaltsabrechnung", "kreditkarte", "steuerbescheid", "kontostand", "bank statement", "salary"]),
    ]

    /// Words printed on a bank card or naming one ("Visa Debit", "girocard", "VALID THRU").
    /// They do not make a document sensitive where it has a type (a receipt paid by girocard
    /// stays a receipt and keeps its album): they name a card where no document type was
    /// recognised (`analyze` → `.other`), and keep a picture out of previews (`PreviewRank`,
    /// `TextMinimizer.looksSensitive`). Short parts count as whole words only (`SensitiveWords`).
    static let paymentCardKeywords = [
        "visa", "mastercard", "maestro", "girocard", "debit", "kreditkarte", "debitkarte", "credit card", "debit card",
        "american express", "amex", "valid thru", "valid through", "good thru", "card number", "card no", "kartennummer",
        "kartennr", "cvc", "cvv", "v pay", "unionpay", "diners",
    ]

    static let knownMerchants = [
        "amazon", "ikea", "mediamarkt", "media markt", "saturn", "zalando", "otto", "lidl", "aldi", "rewe", "edeka", "dm", "rossmann",
        "obi", "bauhaus", "hornbach", "apple", "deutsche bahn", "db fernverkehr", "lufthansa", "ryanair", "easyjet", "booking.com",
        "airbnb", "ebay", "paypal", "decathlon", "h&m", "tchibo", "kaufland", "netto", "penny", "telekom", "vodafone", "o2",
    ]

    public func analyze(text rawText: String) -> DocumentInfo? {
        let text = rawText.lowercased()
        guard text.count >= 20 else { return nil }

        var scores: [DocumentType: Int] = [:]
        for (type, words) in Self.typeKeywords {
            let hits = words.filter { text.contains($0) }.count
            if hits > 0 { scores[type] = hits }
        }
        let amount = Self.totalAmount(in: rawText)
        if amount != nil { scores[.invoice, default: 0] += scores[.invoice] != nil ? 1 : 0; scores[.receipt, default: 0] += scores[.receipt] != nil ? 1 : 0 }

        guard let best = scores.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }) else {
            // No document type, but a card, a statement, an ID or a medical paper (second review
            // of the build 36 fix): reported as `.other` with its sensitivity so the picture is
            // never a preview. Nothing else of it is kept (no subject, sender, number or amount),
            // and `.other` never becomes an album of its own (`ProposalEngine`). What is stored of
            // the text is decided apart from this (`TextMinimizer.storable`) and does not change.
            // Short words only as whole words: "bic" in "Arabic … cubic" is no bank (third review).
            var sensitivity = SensitiveWords.sensitivity(of: rawText)
            if Self.containsIBAN(rawText) || TextMinimizer.namesPaymentCard(rawText) { sensitivity = max(sensitivity, .financial) }
            if sensitivity < .identity, Self.hasMachineReadableZone(rawText) { sensitivity = .identity }
            guard sensitivity > .normal else { return nil }
            return DocumentInfo(type: .other, typeReliability: .uncertain, keywords: [], sensitivity: sensitivity)
        }
        let reliability: Reliability = best.value >= 3 ? .likely : (best.value == 2 ? .plausible : .uncertain)

        var sensitivity = DocumentSensitivity.normal
        for (level, words) in Self.sensitivityKeywords where words.contains(where: { text.contains($0) }) {
            sensitivity = max(sensitivity, level)
        }
        if Self.containsIBAN(rawText) { sensitivity = max(sensitivity, .financial) }
        if sensitivity < .identity, Self.hasMachineReadableZone(rawText) { sensitivity = .identity }
        // The subject line is stored with these facts: masked like the text, and not kept at all
        // for an ID or a medical document (whose text is not stored either).
        let subject = sensitivity >= .identity ? nil : Self.subject(in: rawText).map(TextMinimizer.masked)

        return DocumentInfo(
            type: best.key,
            typeReliability: reliability,
            documentDate: Self.firstDate(in: rawText),
            merchant: Self.merchant(in: text),
            orderNumber: Self.labeledNumber(in: rawText, labels: ["bestellnummer", "bestell-nr", "bestellnr", "order number", "order no", "order #", "auftragsnummer"]),
            invoiceNumber: Self.labeledNumber(in: rawText, labels: ["rechnungsnummer", "rechnungs-nr", "rechnungsnr", "invoice number", "invoice no", "invoice #"]),
            totalAmount: amount,
            subject: subject,
            keywords: Self.typeKeywords.flatMap(\.1).filter { text.contains($0) }.prefix(8).map { $0 },
            sensitivity: sensitivity
        )
    }

    // MARK: - Field extraction

    static func labeledNumber(in text: String, labels: [String]) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            for label in labels {
                guard let range = lower.range(of: label) else { continue }
                let rest = String(line[range.upperBound...])
                if let token = firstIdentifier(in: rest) { return token }
                if i + 1 < lines.count, let token = firstIdentifier(in: lines[i + 1]) { return token }
            }
        }
        return nil
    }

    /// First token with at least 4 characters that contains a digit, e.g. "302-1234567-1234567".
    static func firstIdentifier(in text: String) -> String? {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":;,"))
        for raw in text.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".#()"))
            if token.count >= 4, token.rangeOfCharacter(from: .decimalDigits) != nil,
               token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }) {
                return token
            }
        }
        return nil
    }

    /// Amount following "Summe/Gesamt/Total/Betrag", else the largest amount with a currency.
    static func totalAmount(in text: String) -> MoneyAmount? {
        let pattern = #"(?:(EUR|€|USD|\$|CHF|GBP|£)\s?)?(\d{1,3}(?:[.\s']\d{3})*(?:[.,]\d{2})|\d+[.,]\d{2})\s?(EUR|€|USD|\$|CHF|GBP|£)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        var labeled: [MoneyAmount] = []
        var all: [MoneyAmount] = []
        for line in lines {
            let ns = line as NSString
            let lower = line.lowercased()
            let isTotal = ["summe", "gesamt", "total", "betrag", "zu zahlen", "amount due", "endbetrag"].contains { lower.contains($0) }
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let currencyRaw = [1, 3].compactMap { idx -> String? in
                    let r = m.range(at: idx)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                }.first
                guard let currencyRaw, let currency = normalizeCurrency(currencyRaw) else { continue }
                let numberRange = m.range(at: 2)
                guard numberRange.location != NSNotFound, let minor = parseMinorUnits(ns.substring(with: numberRange)) else { continue }
                let amount = MoneyAmount(minorUnits: minor, currency: currency)
                all.append(amount)
                if isTotal { labeled.append(amount) }
            }
        }
        return labeled.last ?? all.max { $0.minorUnits < $1.minorUnits }
    }

    static func normalizeCurrency(_ raw: String) -> String? {
        switch raw {
        case "EUR", "€": "EUR"
        case "USD", "$": "USD"
        case "CHF": "CHF"
        case "GBP", "£": "GBP"
        default: nil
        }
    }

    /// Parses "1.234,56", "1,234.56", "12,99", "12.99" into minor units.
    static func parseMinorUnits(_ s: String) -> Int? {
        let cleaned = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        guard cleaned.count >= 4 else { return nil }
        let decimalSeparator = cleaned[cleaned.index(cleaned.endIndex, offsetBy: -3)]
        guard decimalSeparator == "," || decimalSeparator == "." else { return nil }
        let integerPart = cleaned[..<cleaned.index(cleaned.endIndex, offsetBy: -3)].filter(\.isNumber)
        let fraction = cleaned.suffix(2)
        guard let i = Int(integerPart.isEmpty ? "0" : String(integerPart)), let f = Int(fraction) else { return nil }
        return i * 100 + f
    }

    static func firstDate(in text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let numeric = #"\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})\b"#
        let iso = #"\b(\d{4})-(\d{2})-(\d{2})\b"#
        let months = ["januar": 1, "january": 1, "februar": 2, "february": 2, "märz": 3, "march": 3, "april": 4, "mai": 5, "may": 5,
                      "juni": 6, "june": 6, "juli": 7, "july": 7, "august": 8, "september": 9, "oktober": 10, "october": 10,
                      "november": 11, "dezember": 12, "december": 12]
        let named = #"\b(\d{1,2})\.?\s+([A-Za-zäÄ]+)\s+(\d{4})\b"#

        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            let year = y < 100 ? 2000 + y : y
            guard (1...12).contains(m), (1...31).contains(d), (1900...2100).contains(year) else { return nil }
            let comps = DateComponents(year: year, month: m, day: d, hour: 12)
            guard let date = calendar.date(from: comps), calendar.component(.day, from: date) == d else { return nil }
            return date
        }

        var candidates: [(Int, Date)] = []
        let ns = text as NSString
        if let r = try? NSRegularExpression(pattern: numeric) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))), let y = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        if let r = try? NSRegularExpression(pattern: iso) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let y = Int(ns.substring(with: m.range(at: 1))), let mo = Int(ns.substring(with: m.range(at: 2))), let d = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        if let r = try? NSRegularExpression(pattern: named) {
            for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = Int(ns.substring(with: m.range(at: 1))), let mo = months[ns.substring(with: m.range(at: 2)).lowercased()],
                   let y = Int(ns.substring(with: m.range(at: 3))), let date = make(y, mo, d) {
                    candidates.append((m.range.location, date))
                }
            }
        }
        return candidates.min { $0.0 < $1.0 }?.1
    }

    static func merchant(in lowercasedText: String) -> String? {
        let hits = knownMerchants.compactMap { name -> (String, String.Index)? in
            guard let r = lowercasedText.range(of: name) else { return nil }
            // Require a word boundary to avoid "dm" in "admin".
            let before = r.lowerBound == lowercasedText.startIndex ? " " : lowercasedText[lowercasedText.index(before: r.lowerBound)]
            let after = r.upperBound == lowercasedText.endIndex ? " " : lowercasedText[r.upperBound]
            guard !before.isLetter, !after.isLetter else { return nil }
            return (name, r.lowerBound)
        }
        guard let first = hits.min(by: { $0.1 < $1.1 }) else { return nil }
        return first.0.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            .replacingOccurrences(of: "Db ", with: "DB ").replacingOccurrences(of: "H&m", with: "H&M")
    }

    static func subject(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            for label in ["betreff:", "betreff", "subject:", "re:"] where lower.hasPrefix(label) {
                let value = line.dropFirst(label.count).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
                if !value.isEmpty { return String(value.prefix(120)) }
            }
        }
        return nil
    }

    /// IBAN with checksum validation (mod 97) to avoid false positives. Spaces, dots, hyphens
    /// and slashes between the groups do not count (review P2-04).
    static func containsIBAN(_ text: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "./-–_"))
        let compact = String(String.UnicodeScalarView(text.uppercased().unicodeScalars.filter { !separators.contains($0) }))
        guard let regex = try? NSRegularExpression(pattern: #"[A-Z]{2}[0-9O]{2}[A-Z0-9]{11,30}"#) else { return false }
        let ns = compact as NSString
        for m in regex.matches(in: compact, range: NSRange(location: 0, length: ns.length)) {
            if startsWithValidIBAN(ns.substring(with: m.range)) { return true }
        }
        return false
    }

    /// Whether `compact` (upper case, no separators) starts with an IBAN of its country's length
    /// whose checksum holds, also when OCR read a 0 as the letter O or a 1 as I or L after the
    /// country code. Only the country's length is tried: trying every length from 34 to 15 let
    /// about one order number in five in IBAN shape pass ("AB68-9302-4282-7546", third review
    /// of P2-04).
    static func startsWithValidIBAN(_ compact: String) -> Bool {
        guard let length = ibanLengths[String(compact.prefix(2))], compact.count >= length else { return false }
        let ocr = String(compact.prefix(2)) + String(compact.dropFirst(2).map { c -> Character in
            switch c { case "O": "0"; case "I", "L": "1"; default: c }
        })
        return Set([compact, ocr]).contains { isValidIBAN(String($0.prefix(length))) }
    }

    /// IBAN length by country: the SWIFT IBAN registry, the French overseas territories and
    /// Åland (they use the French and Finnish forms), and the countries whose banks use IBANs
    /// outside the registry (West and Central Africa, Algeria, Iran, Madagascar, Morocco,
    /// Mozambique, Angola, Cape Verde). One too many only masks more.
    static let ibanLengths: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22, "BI": 27, "BR": 29, "BY": 28,
        "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DJ": 27, "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18,
        "FK": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HN": 28, "HR": 21, "HU": 28,
        "IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20, "LB": 28, "LC": 32, "LI": 21, "LT": 20,
        "LU": 20, "LV": 21, "LY": 25, "MC": 27, "MD": 24, "ME": 22, "MK": 19, "MN": 20, "MR": 27, "MT": 31, "MU": 30, "NI": 28,
        "NL": 18, "NO": 15, "OM": 23, "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "RU": 33, "SA": 24,
        "SC": 31, "SD": 18, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "SO": 23, "ST": 25, "SV": 28, "TL": 23, "TN": 24, "TR": 26,
        "UA": 29, "VA": 22, "VG": 24, "XK": 20, "YE": 30,
        "AX": 18, "BL": 27, "GF": 27, "GP": 27, "MF": 27, "MQ": 27, "NC": 27, "PF": 27, "PM": 27, "RE": 27, "TF": 27, "WF": 27, "YT": 27,
        "AO": 25, "BF": 28, "BJ": 28, "CF": 27, "CG": 27, "CI": 28, "CM": 27, "CV": 25, "DZ": 26, "GA": 27, "GQ": 27, "GW": 25,
        "IR": 26, "KM": 27, "MA": 28, "MG": 27, "ML": 28, "MZ": 25, "NE": 28, "SN": 28, "TD": 27, "TG": 28,
    ]

    /// The machine-readable zone of an ID card or passport: long runs of "<" fillers
    /// ("IDD<<L01X00T471<<<<<<<<<"). OCR sometimes reads them as "«" or "‹".
    static func hasMachineReadableZone(_ text: String) -> Bool {
        let fillers = text.filter { $0 == "<" || $0 == "«" || $0 == "‹" }.count
        return fillers >= 10 && (text.contains("<<<") || text.contains("«««") || text.contains("‹‹‹"))
    }

    static func isValidIBAN(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue { value = d }
            else if let a = ch.asciiValue, (65...90).contains(a) { value = Int(a) - 55 }
            else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }
}
