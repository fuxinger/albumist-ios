import Foundation

/// The words Albumist writes itself on a suggestion's card and on the open suggestion (design
/// wave 1, decision "Punkt 3" of 16.11.2026: the status as a sentence with the album's name), in
/// the app's language. Like the album titles (`TitleLanguage`, `DateRangeFormatter`) and the
/// search's words, they are made here in German and English, so every case is tested on Linux;
/// the app passes its own localization (`Bundle.main.preferredLocalizations`), so a card never
/// speaks another language than the screen around it, and the region of the iPhone for the
/// thousands separator ("1.354 Fotos", "1,354 photos").
///
/// Words the app's string catalog has too ("Neues Album", "Name fehlt", "Vorschau ausgeblendet",
/// "Sicher" …, the counts) are the catalog's, word for word in both languages
/// (`ProposalCardTextTests.wordsAreTheCatalogs`).
public struct ProposalWords: Equatable, Sendable {
    public enum Language: String, Equatable, Sendable {
        case german = "de"
        case english = "en"
    }

    public let language: Language
    /// The app's language with the iPhone's region: its number format.
    public let locale: Locale

    /// `region` is the iPhone's region ("DE", "AT", "US", "GB"); nil or empty: the language's own.
    public init(language: Language, region: String? = nil) {
        self.language = language
        let region = region.flatMap { $0.isEmpty ? nil : $0 } ?? (language == .german ? "DE" : "US")
        self.locale = Locale(identifier: "\(language.rawValue)_\(region)")
    }

    /// From the app's localization ("de", "de-AT", "en", "en-GB"): German for German, English for
    /// every other. Without one, German, the app's source language (as `AppInfo` decides).
    public init(localization: String?, region: String? = nil) {
        let german = localization.map { $0.lowercased().hasPrefix("de") } ?? true
        self.init(language: german ? .german : .english, region: region)
    }

    public static let german = ProposalWords(language: .german)
    public static let english = ProposalWords(language: .english)

    var isGerman: Bool { language == .german }

    func t(_ german: String, _ english: String) -> String { isGerman ? german : english }

    // MARK: Counts

    /// "1.354" / "1,354": the locale's thousands separator, as `n.formatted()` shows it in the app.
    func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    /// "1 Foto", "16 Fotos", "1.354 Fotos"; "1 photo", "1,354 photos" (catalog: "%lld %@ Fotos").
    func photos(_ n: Int) -> String {
        let shown = number(n)
        return n == 1 ? t("\(shown) Foto", "\(shown) photo") : t("\(shown) Fotos", "\(shown) photos")
    }

    /// "+12 Fotos", "+1 Foto"; "+12 photos" (catalog: "+%lld %@ Fotos").
    func addedPhotos(_ n: Int) -> String { "+" + photos(n) }

    // MARK: The card

    var newAlbum: String { t("Neues Album", "New album") }
    var nameMissing: String { t("Name fehlt", "Name missing") }
    var personal: String { t("Persönlicher Inhalt", "Personal content") }
    var pleaseLook: String { t("Bitte kurz ansehen", "Please take a look") }
    var previewHidden: String { t("Vorschau ausgeblendet", "Preview hidden") }

    /// The confidence, as the label of the open suggestion says it (`Reliability.label`).
    func reliability(_ reliability: Reliability) -> String {
        switch reliability {
        case .certain: t("Sicher", "Certain")
        case .likely: t("Wahrscheinlich", "Likely")
        case .plausible: t("Möglich", "Possible")
        case .uncertain: t("Unsicher", "Uncertain")
        }
    }

    /// „Toskana“ / “Tuscany”: an album or folder name, exactly as it is, in the language's quotes.
    func quoted(_ name: String) -> String { t("„\(name)“", "“\(name)”") }

    /// "Kommt in dein Album „Toskana“"; an album whose name is not known: "Kommt in dein Album".
    func addsTo(album: String) -> String {
        album.isEmpty ? t("Kommt in dein Album", "Goes into your album")
            : t("Kommt in dein Album \(quoted(album))", "Goes into your album \(quoted(album))")
    }

    /// "Schon in deinem Album „Island“".
    func alreadyIn(album: String) -> String {
        album.isEmpty ? t("Schon in deinem Album", "Already in your album")
            : t("Schon in deinem Album \(quoted(album))", "Already in your album \(quoted(album))")
    }

    /// "Benennt dein Album „Sommer“ um": the album gets the name the card shows.
    func renames(album: String) -> String {
        album.isEmpty ? t("Benennt dein Album um", "Renames your album")
            : t("Benennt dein Album \(quoted(album)) um", "Renames your album \(quoted(album))")
    }

    /// "Verschiebt dein Album „Garten“": the album goes into another folder.
    func moves(album: String) -> String {
        album.isEmpty ? t("Verschiebt dein Album", "Moves your album")
            : t("Verschiebt dein Album \(quoted(album))", "Moves your album \(quoted(album))")
    }

    // MARK: The open suggestion

    /// The folder where a new album goes, as Photos shows the way there: "Reisen › 2024".
    func folder(_ path: [String]) -> String { path.joined(separator: " › ") }

    /// "Kommt als neues Album in „Reisen › 2024“"; at the top of the albums: "Kommt als neues
    /// Album zu deinen Alben".
    func newAlbum(in path: [String]) -> String {
        path.isEmpty ? t("Kommt als neues Album zu deinen Alben", "Becomes a new album among your albums")
            : t("Kommt als neues Album in \(quoted(folder(path)))", "Becomes a new album in \(quoted(folder(path)))")
    }

    var severalAlbums: String { t("Mehrere deiner Alben passen", "Several of your albums fit") }

    /// "Dein Album „Sommer“ heißt dann „Gardasee“".
    func renamed(album: String, to title: String) -> String {
        album.isEmpty ? t("Dein Album heißt dann \(quoted(title))", "Your album will be called \(quoted(title))")
            : t("Dein Album \(quoted(album)) heißt dann \(quoted(title))", "Your album \(quoted(album)) will be called \(quoted(title))")
    }

    /// "Dein Album „Garten“ kommt in „Zuhause“"; to the top of the albums: "Dein Album „Garten“
    /// kommt aus seinem Ordner zu deinen Alben".
    func moved(album: String, to path: [String]) -> String {
        let german = album.isEmpty ? "Dein Album" : "Dein Album \(quoted(album))"
        let english = album.isEmpty ? "Your album" : "Your album \(quoted(album))"
        return path.isEmpty ? t("\(german) kommt aus seinem Ordner zu deinen Alben", "\(english) moves out of its folder to your albums")
            : t("\(german) kommt in \(quoted(folder(path)))", "\(english) moves to \(quoted(folder(path)))")
    }

    /// The sign under the cover: it is a suggestion, nothing of it is in Photos yet (E2).
    var notInPhotosYet: String { t("Vorschlag · noch nicht in Fotos", "Suggestion · not in Photos yet") }
    /// The album is the user's own and exists: its photos are not in it yet.
    var notAddedYet: String { t("Vorschlag · noch nicht ergänzt", "Suggestion · not added yet") }
    var alreadyInPhotos: String { t("Schon in Fotos", "Already in Photos") }
    /// The user's album gets a new name or another folder: that is not done yet.
    var notChangedYet: String { t("Vorschlag · noch nicht geändert", "Suggestion · not changed yet") }

    var noDate: String { t("Ohne Datum", "No date") }

    // MARK: Days

    private var monthNames: DateRangeFormatter { DateRangeFormatter(language: isGerman ? .german : .english) }

    func month(_ month: Int) -> String { monthNames.monthName(month) }

    /// Weekday 1 is Sunday, as `Calendar` counts.
    func weekday(_ weekday: Int) -> String {
        let names = isGerman
            ? ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
            : ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (1...7).contains(weekday) ? names[weekday - 1] : ""
    }

    /// A day of photos, as Photos heads its days: "Samstag, 12. Oktober" / "Saturday, October 12",
    /// with the year when the photos span several years.
    func dayTitle(_ day: CalendarDay, withYear: Bool) -> String {
        if isGerman {
            return "\(weekday(day.weekday)), \(day.day). \(month(day.month))" + (withYear ? " \(day.year)" : "")
        }
        return "\(weekday(day.weekday)), \(month(day.month)) \(day.day)" + (withYear ? ", \(day.year)" : "")
    }

    /// The time the photos span, in the words of the drafts (E2: "12. bis 16. Oktober"):
    /// - one day: "12. Oktober" / "October 12"
    /// - one month: "12. bis 16. Oktober" / "October 12–16"
    /// - up to two months: "28. September bis 3. Oktober" / "September 28 – October 3"
    /// - longer, in one year: "März bis Oktober" / "March – October"
    /// - longer, over the turn of one year: "Dezember 2023 bis März 2024" / "December 2023 – March 2024"
    /// - several years: "2019 bis 2024" / "2019 – 2024"
    /// The year is added where the title does not say it already (`withYear`); spans over the
    /// turn of a year always name it.
    func span(from a: CalendarDay, to b: CalendarDay, withYear: Bool) -> String {
        let german = isGerman
        func year(_ y: Int) -> String { withYear ? (german ? " \(y)" : ", \(y)") : "" }
        if a == b {
            return german ? "\(a.day). \(month(a.month))" + year(a.year) : "\(month(a.month)) \(a.day)" + year(a.year)
        }
        let days = b.number - a.number
        if days <= 62 {
            if a.year == b.year && a.month == b.month {
                return german ? "\(a.day). bis \(b.day). \(month(a.month))" + year(a.year)
                    : "\(month(a.month)) \(a.day)–\(b.day)" + year(a.year)
            }
            if a.year == b.year {
                return german ? "\(a.day). \(month(a.month)) bis \(b.day). \(month(b.month))" + year(a.year)
                    : "\(month(a.month)) \(a.day) – \(month(b.month)) \(b.day)" + year(a.year)
            }
            return german ? "\(a.day). \(month(a.month)) \(a.year) bis \(b.day). \(month(b.month)) \(b.year)"
                : "\(month(a.month)) \(a.day), \(a.year) – \(month(b.month)) \(b.day), \(b.year)"
        }
        // More than two months: in different months.
        if a.year == b.year {
            return german ? "\(month(a.month)) bis \(month(b.month))" + (withYear ? " \(a.year)" : "")
                : "\(month(a.month)) – \(month(b.month))" + (withYear ? " \(a.year)" : "")
        }
        if b.year == a.year + 1 && days <= 366 {
            return german ? "\(month(a.month)) \(a.year) bis \(month(b.month)) \(b.year)"
                : "\(month(a.month)) \(a.year) – \(month(b.month)) \(b.year)"
        }
        return german ? "\(a.year) bis \(b.year)" : "\(a.year) – \(b.year)"
    }
}

/// A calendar day on the clock where photos were taken (`LocalTime`): its number
/// (`LocalTime.day`), its date and its weekday.
struct CalendarDay: Equatable, Sendable {
    let number: Int
    let year: Int
    let month: Int
    let day: Int
    /// 1 is Sunday.
    let weekday: Int

    /// The calendar the days are read with: Gregorian in UTC, as wall clocks are kept. One for
    /// every day: making a calendar is slow, and the photos of a suggestion are grouped again
    /// whenever their page changes (second review of design wave 1).
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LocalTime.utc
        return calendar
    }()

    /// The day of a wall clock (`LocalTime.wallClock`), read in UTC.
    init(wallClock: Date) {
        self.init(number: LocalTime.day(wallClock))
    }

    /// The day with this number (`LocalTime.day`).
    init(number: Int) {
        self.number = number
        // Midnight of that day, so a wall clock of 23:59 and one of 00:00 read the same day.
        let midnight = Date(timeIntervalSinceReferenceDate: Double(number) * 86_400)
        let c = Self.calendar.dateComponents([.year, .month, .day, .weekday], from: midnight)
        year = c.year ?? 0
        month = c.month ?? 0
        day = c.day ?? 0
        weekday = c.weekday ?? 0
    }
}
