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

    /// Review finding P2-04 (18.11.2026): IBANs and card numbers written with dots, hyphens,
    /// slashes or wide spaces stayed readable in the stored text.
    @Test func numbersWithUnusualSeparatorsAreMasked() {
        let ibans = [
            "Bitte überweisen auf DE89.3704.0044.0532.0130.00 danke",
            "Konto DE89-3704-0044-0532-0130-00",
            "IBAN DE89   3704   0044   0532   0130   00",
            "IBAN DE89    3704    0044    0532    0130    00",
            "IBAN DE89/3704/0044/0532/0130/00",
            "IBAN DE89 / 3704 / 0044 / 0532 / 0130 / 00",
            "iban de89.3704.0044.0532.0130.00",
            // OCR reads the digit 0 as the letter O: the checksum holds once it is read back.
            "iban de89 37o4 0044 0532 0130 00",
        ]
        for text in ibans {
            let stored = TextMinimizer.storable(text)
            #expect(!stored.contains("0532"), "IBAN stays readable: \(stored)")
            #expect(DocumentAnalyzer.containsIBAN(text), "not seen as an IBAN: \(text)")
        }
        let cards = ["Karte 4111.1111.1111.1111", "Karte 4111/1111/1111/1111", "Karte 4111    1111    1111    1111",
                     "Karte 4111 / 1111 / 1111 / 1111", "Amex 3782.822463.10005"]
        for text in cards {
            let stored = TextMinimizer.storable(text)
            #expect(!stored.contains("1111") && !stored.contains("822463"), "card stays readable: \(stored)")
            #expect(stored.hasPrefix("Karte ") || stored.hasPrefix("Amex "))
        }
        // Dates, amounts, phone numbers and order numbers stay searchable.
        for kept in ["Fahrt am 01.02.2021, 03.04.2022 und 05.06.2023", "Gültig 12/29 Betrag 1.234,56 EUR", "Tel. 0171/2345678",
                     "Bestellnummer 3021.4567.8901.2345", "Version 2.4.11 vom 3.5.2026"] {
            #expect(TextMinimizer.storable(kept) == kept, "\(kept) was changed")
        }
    }

    /// Review finding P2-04: the back of a German ID card names no "Personalausweis"; its
    /// eye colour, address and machine-readable zone were stored in full.
    @Test func theBackOfAnIDCardIsNotStored() {
        let back = "Augenfarbe BRAUN Größe 178 cm Datum 01.02.2021 Behörde Stadt Musterstadt Anschrift 12345 Musterstadt Heidestr. 17 "
            + "IDD<<L01X00T471<<<<<<<<<<<<<<< 6408125<2702283D<<<<<<<<<<<<<4 MUSTERMANN<<ERIKA<<<<<<<<<<<<<"
        #expect(TextMinimizer.storable(back) == "")
        // The machine-readable zone alone (a passport page cut off at the top) is enough.
        #expect(TextMinimizer.storable("P<D<<MUSTERMANN<<ERIKA<<<<<<<<<<<<<<<<<<<<<<<<\nC01X00T478D<<6408125F2702283<<<<<<<<<<<<<<<4") == "")
        // English cards name the eye colour too.
        #expect(TextMinimizer.storable("Eye colour BROWN Height 178 cm Address 1 High Street") == "")
        // Ordinary text with an arrow or a size stays.
        for kept in ["Größe 42, Farbe braun, Anschrift auf dem Paket", "a << b in code"] {
            #expect(TextMinimizer.storable(kept) == kept)
        }
    }

    /// The masks are newer than texts stored by version 2: they are masked once more.
    @Test func theMaskVersionIsRaised() {
        // 4: second review of P2-04 (see below).
        #expect(TextMinimizer.maskVersion == 4)
    }

    /// Second review of P2-04: a space or underscore after the country code and underscores
    /// between groups kept IBANs and card numbers readable; upper-case order numbers with
    /// hyphens were masked as IBANs, and a phone number with a slash as a card.
    @Test func moreSeparatorsAreMaskedAndOrderNumbersStay() {
        for text in ["IBAN DE 89 3704 0044 0532 0130 00", "IBAN DE89_3704_0044_0532_0130_00", "iban de 89 3704 0044 0532 0130 00",
                     "IBAN DE_89_3704_0044_0532_0130_00"] {
            let stored = TextMinimizer.storable(text)
            #expect(!stored.contains("0532"), "IBAN stays readable: \(stored)")
            #expect(DocumentAnalyzer.containsIBAN(text), "not seen as an IBAN: \(text)")
        }
        let card = TextMinimizer.storable("Karte 4111_1111_1111_1111")
        #expect(!card.contains("1111"), "card stays readable: \(card)")
        // Printed IBANs in their usual form are masked without the checksum, as before.
        #expect(!TextMinimizer.storable("IBAN DE12 3456 7890 1234 5678 90").contains("5678"))
        // Order and invoice numbers in IBAN shape but with hyphens fail the checksum: they stay.
        for kept in ["Bestellung AB12-3456-7890-1234", "Rechnung RE24-1118-0001", "Ticket XY99.1234.5678.9012", "Tel. 04321/12345678",
                     "Fax 0432/1234/5678/9", "Code AB12/3456/7890"] {
            #expect(TextMinimizer.storable(kept) == kept, "\(kept) was changed to \(TextMinimizer.storable(kept))")
        }
        // "04321/12345678" passes the Luhn check, so only the groups tell it is no card.
        #expect(TextMinimizer.luhnValid("0432112345678".compactMap(\.wholeNumberValue)))
    }

    /// Third review of P2-04: every length from 34 down to 15 was tried, so about one order
    /// number in five in IBAN shape passed the checksum at some length and was masked. An IBAN
    /// has the one length its country gives it (DE 22, FR 27, an unknown code none).
    @Test func onlyTheLengthOfTheCountryCounts() {
        // Each of these passes the checksum for its first 15 or 16 characters.
        for kept in ["Bestellung AB68-9302-4282-7546", "Auftrag DE41-5489-6599-1447", "Ticket FR79.9121.1911.2583",
                     "Ref. XY12-8548-5068-3004"] {
            #expect(TextMinimizer.storable(kept) == kept, "\(kept) was changed to \(TextMinimizer.storable(kept))")
            #expect(!DocumentAnalyzer.containsIBAN(kept), "\(kept)")
        }
        // Real IBANs of other lengths in unusual forms stay masked.
        for iban in ["no 93 8601 1117 947", "be68-5390-0754-7034", "fr14_2004_1010_0505_0001_3m02_606", "mt84-malt-0110-0001-2345-mtlc-ast0-01s",
                     "DE 89 3704 0044 0532 0130 00"] {
            let stored = TextMinimizer.storable("Konto " + iban)
            #expect(stored == "Konto IBAN ••••", "\(iban): \(stored)")
        }
    }

    /// The subject line of a letter is stored with the document facts: it goes through the
    /// same masks, and an ID or medical document keeps none.
    @Test func theSubjectOfALetterIsMaskedToo() throws {
        let letter = "Musterbank AG\nBetreff: Ihr Konto DE89.3704.0044.0532.0130.00\nSehr geehrte Frau Mustermann, Rechnung anbei"
        let info = try #require(DocumentAnalyzer().analyze(text: letter))
        #expect(info.subject?.contains("0532") == false, "\(info.subject ?? "")")
        let medical = "Arztbrief\nBetreff: Diagnose Bronchitis bei Erika Mustermann\nSehr geehrte Kollegin"
        #expect(try #require(DocumentAnalyzer().analyze(text: medical)).subject == nil)
    }
}
