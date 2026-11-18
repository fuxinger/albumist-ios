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
/// German letters. Words of four letters or fewer count only as whole words ("bic", "visa",
/// "iban": not in "public", "Revisaa" or "Libanon"); longer ones anywhere, as
/// `DocumentAnalyzer` matches them.
struct SensitiveWords: Sendable {
    /// The words by their first byte (256 entries: a table, no hashing per byte).
    private let byFirstByte: [[(bytes: [UInt8], whole: Bool)]]

    init(_ words: [String]) {
        var index = [[(bytes: [UInt8], whole: Bool)]](repeating: [], count: 256)
        for word in words {
            let bytes = Array(word.lowercased().utf8)
            guard let first = bytes.first else { continue }
            index[Int(first)].append((bytes, word.count <= 4))
        }
        byFirstByte = index
    }

    /// Masked numbers, every sensitivity word of `DocumentAnalyzer` and the card words.
    static let all = SensitiveWords([TextMinimizer.cardMask, TextMinimizer.ibanMask]
                                    + DocumentAnalyzer.sensitivityKeywords.flatMap(\.1) + DocumentAnalyzer.paymentCardKeywords)
    static let cards = SensitiveWords(DocumentAnalyzer.paymentCardKeywords)

    func occurs(in text: String) -> Bool {
        var bytes = Array(text.utf8)
        // Lower case: ASCII, and the upper-case letters of Latin-1 (Ä, Ö, Ü, É …) after 0xC3.
        for i in bytes.indices {
            let b = bytes[i]
            if b >= 0x41 && b <= 0x5A {
                bytes[i] = b + 0x20
            } else if i > 0, bytes[i - 1] == 0xC3, b >= 0x80, b <= 0x9E, b != 0x97 {
                bytes[i] = b + 0x20
            }
        }
        return bytes.withUnsafeBufferPointer { text in
            func isLetter(_ i: Int) -> Bool {
                guard i >= 0, i < text.count else { return false }
                let b = text[i]
                return (b >= 0x61 && b <= 0x7A) || b >= 0x80
            }
            for start in text.indices {
                let candidates = byFirstByte[Int(text[start])]
                if candidates.isEmpty { continue }
                for (word, whole) in candidates where start + word.count <= text.count {
                    var same = true
                    for k in 1..<max(word.count, 1) where text[start + k] != word[k] { same = false; break }
                    guard same else { continue }
                    if whole && (isLetter(start - 1) || isLetter(start + word.count)) { continue }
                    return true
                }
            }
            return false
        }
    }
}
