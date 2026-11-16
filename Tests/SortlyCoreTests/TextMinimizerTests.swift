import Testing
@testable import SortlyCore

@Suite("Text minimization before storage")
struct TextMinimizerTests {
    @Test func identityAndMedicalTextIsNotStored() {
        #expect(TextMinimizer.storable("BUNDESREPUBLIK DEUTSCHLAND PERSONALAUSWEIS Name Mustermann Geburtsdatum 12.08.1964") == "")
        #expect(TextMinimizer.storable("Arztbrief Diagnose: Bronchitis, Patient Max Muster") == "")
    }

    @Test func ibanIsMasked() {
        let text = "Kontoauszug IBAN: DE89 3704 0044 0532 0130 00 Saldo 1.234,00 EUR"
        let stored = TextMinimizer.storable(text)
        #expect(!stored.contains("3704"))
        #expect(stored.contains("Kontoauszug"))
        #expect(stored.contains("1.234,00"))
        #expect(!TextMinimizer.storable("IBAN DE89370400440532013000").contains("370400"))
    }

    /// Audit 6.4: lower-case and differently spaced IBANs (OCR, chat screenshots) are masked too,
    /// but only with a valid checksum, so similar-looking words stay searchable.
    @Test func lowerCaseAndSpacedIBANsAreMasked() {
        #expect(!TextMinimizer.storable("iban de89 3704 0044 0532 0130 00").contains("3704"))
        #expect(!TextMinimizer.storable("Konto: De89370400440532013000 danke").contains("370400"))
        #expect(!TextMinimizer.storable("IBAN DE89\t3704\t0044\t0532\t0130\t00").contains("0532"))
        #expect(!TextMinimizer.storable("IBAN DE89\u{00A0}3704\u{00A0}0044\u{00A0}0532\u{00A0}0130\u{00A0}00").contains("0532"))
        let lookalike = "ab12 cdef ghij klmn"
        #expect(TextMinimizer.storable(lookalike) == lookalike)
    }

    @Test func onlyValidCardNumbersAreMasked() {
        let card = TextMinimizer.storable("Visa 4111 1111 1111 1111 gültig bis 12/29")
        #expect(!card.contains("4111 1111"))
        #expect(card.contains("gültig bis 12/29"))
        // Order numbers that fail the Luhn check stay searchable.
        let order = "Bestellnummer 3021 4567 8901 2345"
        #expect(TextMinimizer.storable(order) == order)
        #expect(TextMinimizer.storable("Rechnung Nr. 2024-0815 Summe 49,90 EUR") == "Rechnung Nr. 2024-0815 Summe 49,90 EUR")
    }

    /// Audit 2, 6.1: OCR splits long numbers over lines and prints unusual spaces; a date or an
    /// amount right after a card number must not hide it.
    @Test func numbersSplitByOCRAreMasked() {
        // IBAN over two lines, with a narrow no-break space, and with Windows line ends.
        #expect(!TextMinimizer.storable("IBAN DE89 3704 0044\n0532 0130 00").contains("0532"))
        #expect(!TextMinimizer.storable("IBAN DE89\u{202F}3704\u{202F}0044\u{202F}0532\u{202F}0130\u{202F}00").contains("0044"))
        #expect(!TextMinimizer.storable("iban de89 3704 0044 0532\r\n0130 00").contains("0130"))
        // Card over two lines, with hyphens, with no-break spaces, as Amex 4-6-5.
        #expect(!TextMinimizer.storable("Karte 4111 1111\n1111 1111").contains("1111"))
        #expect(!TextMinimizer.storable("4111-1111-1111-1111").contains("1111"))
        #expect(!TextMinimizer.storable("4111\u{00A0}1111\u{00A0}1111\u{00A0}1111").contains("1111"))
        #expect(!TextMinimizer.storable("Amex 3782 822463 10005").contains("822463"))
        // A date or an amount right after the number: the card is masked, the rest stays.
        let dated = TextMinimizer.storable("4111 1111 1111 1111 12 29 Betrag 49,90")
        #expect(!dated.contains("4111"))
        #expect(dated.contains("Betrag 49,90"))
        // Numbers that are no card stay searchable, also over lines.
        let order = "Bestellnummer 3021 4567\n8901 2345"
        #expect(TextMinimizer.storable(order) == order)
    }
}
