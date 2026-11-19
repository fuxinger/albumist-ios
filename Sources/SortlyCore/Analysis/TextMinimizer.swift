import Foundation

/// Data minimization for recognized text before it is stored (search index and analysis
/// results). Analysis itself still sees the full text; only what is kept on disk shrinks:
/// - ID documents and medical papers: no text is stored at all (only the classification).
/// - IBANs and valid card numbers are masked in every other text.
public enum TextMinimizer {
    public static func sensitivity(of rawText: String) -> DocumentSensitivity {
        let text = rawText.lowercased()
        var level = DocumentSensitivity.normal
        for (candidate, words) in DocumentAnalyzer.sensitivityKeywords where words.contains(where: { text.contains($0) }) {
            level = max(level, candidate)
        }
        // The back of an ID card or a passport page names no document, but carries the
        // machine-readable zone (review P2-04).
        if level < .identity, DocumentAnalyzer.hasMachineReadableZone(rawText) { level = .identity }
        return level
    }

    /// The text that may be stored for `rawText`.
    public static func storable(_ rawText: String) -> String {
        switch sensitivity(of: rawText) {
        case .identity, .medical:
            return ""
        case .normal, .financial:
            return masked(rawText)
        }
    }

    /// `text` with IBANs and card numbers masked (for short texts stored on their own, such as
    /// the subject line of a letter).
    public static func masked(_ text: String) -> String {
        maskCardNumbers(maskIBANs(text))
    }

    /// What stands in a stored text where an IBAN was.
    static let ibanMask = "IBAN ••••"
    /// What stands in a stored text where a card number was.
    static let cardMask = "•••• ••••"

    /// Whether a stored text had an IBAN or a card number masked: the photo shows a bank card,
    /// a statement or a banking app, also when no document type was recognised in it (a card
    /// says "Visa Debit", not "Kontoauszug"). Such a photo is never a preview (`PreviewRank`).
    public static func showsMaskedNumber(_ storedText: String) -> Bool {
        storedText.contains(cardMask) || storedText.contains(ibanMask)
    }

    /// Whether a stored text (`storable`) shows that the picture is a bank card, a statement, a
    /// banking app or another sensitive paper: a masked card number or IBAN, a financial,
    /// identity or medical word, or a card word ("Visa Debit", "girocard"; `DocumentAnalyzer.
    /// paymentCardKeywords`). Worked out once where the facts are assembled
    /// (`AssetFacts.textLooksSensitive`), off the main thread, in one pass over the text's bytes:
    /// a library has thousands of stored texts. Such a picture is never a preview.
    public static func looksSensitive(_ storedText: String) -> Bool {
        guard !storedText.isEmpty else { return false }
        return SensitiveWords.all.occurs(in: storedText)
    }

    /// Whether lower-cased `text` has a card word (`DocumentAnalyzer.paymentCardKeywords`).
    static func namesPaymentCard(_ text: String) -> Bool {
        SensitiveWords.cards.occurs(in: text)
    }

    // MARK: Masks

    /// Raised when the masks change, so texts stored by an older version are masked again
    /// (see `AnalysisPipeline`). 2: numbers split over lines or by unusual spaces (audit 2, 6.1).
    /// 3: dots, hyphens, slashes and wide spaces between groups, the back of an ID card
    /// (review P2-04, 18.11.2026). 4: a space or underscore after the country code, underscores
    /// between groups, the checksum for IBANs in an unusual form, card groups of four around a
    /// slash (second review of P2-04).
    public static let maskVersion = 4

    /// IBAN shape in any letter case. Between groups: up to four spaces of any kind, a line
    /// break (OCR splits long lines), nothing, or one dot, hyphen, slash or underscore with a
    /// space on either side ("DE89.3704.…", "DE89 / 3704 / …", "DE89_3704_…"); after the
    /// country code a space or an underscore ("DE 89 3704 …").
    private static let ibanPattern = try! NSRegularExpression(
        pattern: #"\b[A-Za-z]{2}[\s_]?[0-9]{2}(?:(?:\s{0,4}|\s?[./\-–_]\s?)[A-Za-z0-9]{4}){2,7}(?:(?:\s{0,4}|\s?[./\-–_]\s?)[A-Za-z0-9]{1,3})?(?![A-Za-z0-9])"#)
    /// The form IBANs are printed in on statements: upper case, the check digits right after the
    /// country code, groups apart by spaces only (or none).
    private static let printedIBANPattern = try! NSRegularExpression(
        pattern: #"^[A-Z]{2}[0-9]{2}(?:\s{0,4}[A-Z0-9]{4}){2,7}(?:\s{0,4}[A-Z0-9]{1,3})?$"#)
    /// A group of digits; card numbers are printed as one group or several (4-4-4-4, 4-6-5).
    private static let digitGroupPattern = try! NSRegularExpression(pattern: #"[0-9]+"#)

    /// IBANs in the form printed on statements are always masked. Any other shape (lower-case
    /// letters from OCR, handwriting or chat screenshots; dots, hyphens, slashes, underscores, a
    /// space after the country code) is masked when the IBAN checksum holds, so order numbers
    /// such as "AB12-3456-7890-1234" and words that happen to look similar stay searchable
    /// (second review of P2-04).
    static func maskIBANs(_ text: String) -> String {
        var result = text
        let matches = ibanPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            let compact = candidate.uppercased().filter { $0.isLetter || $0.isNumber }
            let printed = printedIBANPattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            if printed || DocumentAnalyzer.startsWithValidIBAN(compact) { result.replaceSubrange(range, with: ibanMask) }
        }
        return result
    }

    /// Card numbers: consecutive digit groups with 13 to 19 digits in all that pass the Luhn
    /// check. Groups may be separated by up to four spaces of any kind, hyphens, underscores or a
    /// line break (OCR often splits "4111 1111 / 1111 1111" over two lines), groups of three
    /// digits or more also by a dot ("4111.1111.…"; dates such as "01.02.2021" are not joined),
    /// and groups of four by a slash ("4111/1111/…"; a phone number such as "04321/12345678",
    /// which passes the Luhn check, is no card).
    /// Every passing run of whole groups is masked, so a date or amount right after the number
    /// does not hide it.
    static func maskCardNumbers(_ text: String) -> String {
        let ns = text as NSString
        let groups = digitGroupPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        guard !groups.isEmpty else { return text }
        func separated(_ a: NSRange, _ b: NSRange) -> Bool {
            let gap = ns.substring(with: NSRange(location: a.location + a.length, length: b.location - a.location - a.length))
            guard gap.count <= 4 else { return false }
            let marks = gap.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            if marks.isEmpty { return true }
            guard marks.count == 1, let mark = marks.first else { return false }
            if mark == "-" || mark == "–" || mark == "_" { return true }
            if mark == "/" { return a.length == 4 && b.length == 4 }
            return mark == "." && a.length >= 3 && b.length >= 3
        }
        func digits(_ r: NSRange) -> [Int] { ns.substring(with: r).compactMap(\.wholeNumberValue) }
        var masked: [NSRange] = []
        for first in groups.indices {
            var run: [Int] = []
            var last = first
            while last < groups.count {
                if last > first, !separated(groups[last - 1], groups[last]) { break }
                run += digits(groups[last])
                if run.count > 19 { break }
                if run.count >= 13, luhnValid(run) {
                    let start = groups[first].location
                    masked.append(NSRange(location: start, length: groups[last].location + groups[last].length - start))
                }
                last += 1
            }
        }
        guard !masked.isEmpty else { return text }
        // Overlapping runs become one masked stretch.
        var merged: [NSRange] = []
        for r in masked.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, r.location <= previous.location + previous.length {
                let end = max(previous.location + previous.length, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: previous.location, length: end - previous.location)
            } else {
                merged.append(r)
            }
        }
        let result = NSMutableString(string: text)
        for r in merged.reversed() { result.replaceCharacters(in: r, with: cardMask) }
        return result as String
    }

    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// Words searched for in a text in one pass over its UTF-8 bytes, ignoring case for ASCII and
/// the upper-case letters of Latin-1 ("FÜHRERSCHEIN"), and taking any run of white space (also
/// a line break or a non-breaking space) as one space ("VALID\nTHRU"). A word whose first part
/// has four letters or fewer must start a word, one whose last part has four letters or fewer
/// must end one ("bic", "visa", "card no": not in "Arabic", "Bicycle", "Revisaa" or "card not");
/// longer parts match inside words ("Kreditkartenabrechnung"). Only letters count against a
/// word boundary: punctuation, symbols and emoji („VISA“, VISA®, 💳VISA, »IBAN«) do not.
struct SensitiveWords: Sendable {
    private struct Word: Sendable {
        var bytes: [UInt8]
        /// The byte before must not be part of a letter.
        var startsWord: Bool
        /// The byte after must not start a letter.
        var endsWord: Bool
    }

    /// The words by their first byte (256 entries: a table, no hashing per byte).
    private let byFirstByte: [[Word]]

    /// `exact`: matched anywhere, also inside words (the masks).
    init(_ words: [String], exact: [String] = []) {
        var index = [[Word]](repeating: [], count: 256)
        func add(_ word: String, startsWord: Bool, endsWord: Bool) {
            let bytes = Self.normalized(Array(word.utf8))
            guard let first = bytes.first else { return }
            index[Int(first)].append(Word(bytes: bytes, startsWord: startsWord, endsWord: endsWord))
        }
        for word in words {
            let parts = word.split(separator: " ")
            add(word, startsWord: (parts.first?.count ?? 0) <= 4, endsWord: (parts.last?.count ?? 0) <= 4)
        }
        for word in exact { add(word, startsWord: false, endsWord: false) }
        byFirstByte = index
    }

    /// Masked numbers, every sensitivity word of `DocumentAnalyzer` and the card words.
    static let all = SensitiveWords(DocumentAnalyzer.sensitivityKeywords.flatMap(\.1) + DocumentAnalyzer.paymentCardKeywords,
                                    exact: [TextMinimizer.cardMask, TextMinimizer.ibanMask])
    static let cards = SensitiveWords(DocumentAnalyzer.paymentCardKeywords)
    /// The sensitivity words of `DocumentAnalyzer` per level.
    static let levels = DocumentAnalyzer.sensitivityKeywords.map { ($0.0, SensitiveWords($0.1)) }

    /// The highest level whose words occur in `text`, matched as whole words where they are
    /// short (`DocumentAnalyzer.analyze` for a text without a document type).
    static func sensitivity(of text: String) -> DocumentSensitivity {
        levels.filter { $0.1.occurs(in: text) }.map(\.0).max() ?? .normal
    }

    /// Lower case (ASCII and Latin-1 upper-case letters) and every run of white space as one space.
    static func normalized(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let b = input[i]
            let next: UInt8? = i + 1 < input.count ? input[i + 1] : nil
            if (b >= 0x09 && b <= 0x0D) || b == 0x20 || (b == 0xC2 && next == 0xA0) {
                if out.last != 0x20 { out.append(0x20) }
                i += b == 0xC2 ? 2 : 1
                continue
            }
            if b >= 0x41 && b <= 0x5A {
                out.append(b + 0x20)
            } else if b == 0xC3, let next, next >= 0x80, next <= 0x9E, next != 0x97 {
                // À–Þ (not ×) to à–þ: "Ü" C3 9C → "ü" C3 BC.
                out.append(b)
                out.append(next + 0x20)
                i += 2
                continue
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    /// Whether the character whose first byte is `lead` (followed by `next`) is a letter:
    /// ASCII letters (the text is lower-cased) and the letters of other scripts. Not letters:
    /// ASCII digits and punctuation; 0xC2 (non-breaking space, ©, ®, «, »); × and ÷; 0xE2
    /// (general punctuation „ “ – •, ™, arrows); private use and specials; emoji (4 bytes).
    static func isLetter(lead: UInt8, next: UInt8?) -> Bool {
        switch lead {
        case 0x61...0x7A: true
        case 0xC3: next != 0x97 && next != 0xB7
        case 0xC4...0xDF: true
        case 0xE0, 0xE1, 0xE3...0xED: true
        default: false
        }
    }

    func occurs(in text: String) -> Bool {
        let bytes = Self.normalized(Array(text.utf8))
        return bytes.withUnsafeBufferPointer { text in
            // The character that ends right before `index`: back over continuation bytes.
            func letterBefore(_ index: Int) -> Bool {
                var lead = index - 1
                while lead > 0, lead > index - 4, text[lead] & 0xC0 == 0x80 { lead -= 1 }
                guard lead >= 0 else { return false }
                return Self.isLetter(lead: text[lead], next: lead + 1 < index ? text[lead + 1] : nil)
            }
            func letterAt(_ index: Int) -> Bool {
                guard index < text.count else { return false }
                return Self.isLetter(lead: text[index], next: index + 1 < text.count ? text[index + 1] : nil)
            }
            for start in text.indices {
                let candidates = byFirstByte[Int(text[start])]
                if candidates.isEmpty { continue }
                for word in candidates where start + word.bytes.count <= text.count {
                    var same = true
                    for k in 1..<max(word.bytes.count, 1) where text[start + k] != word.bytes[k] { same = false; break }
                    guard same else { continue }
                    if word.startsWord && letterBefore(start) { continue }
                    if word.endsWord && letterAt(start + word.bytes.count) { continue }
                    return true
                }
            }
            return false
        }
    }
}
