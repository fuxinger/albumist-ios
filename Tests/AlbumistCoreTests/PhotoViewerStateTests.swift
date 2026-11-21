import Foundation
import Testing
@testable import AlbumistCore

/// The photo view's rules (design wave 2, DS-10) that are not words: a tap hides and shows
/// everything around the photo but never leaves VoiceOver or Switch Control without controls,
/// a Live Photo moves by itself only where motion is welcome, the share button works only with
/// what is on the iPhone, and a shared photo keeps its own file name.
@Suite("Photo view: bars, Live Photos and sharing (DS-10)")
struct PhotoViewerStateTests {
    // MARK: Tap hides everything

    /// A tap hides the bars (and the status bar and the home indicator), the next one brings
    /// them back, as in Photos.
    @Test func aTapHidesAndTheNextShowsAgain() {
        var chrome = ViewerChrome()
        #expect(chrome.isShown)
        chrome.tap(assistive: false)
        #expect(!chrome.isShown)
        chrome.tap(assistive: false)
        #expect(chrome.isShown)
    }

    /// With VoiceOver or Switch Control a tap (VoiceOver's double tap on the photo) must not
    /// take away the close, share and info buttons: the bars stay.
    @Test func withVoiceOverOrSwitchControlTheBarsStay() {
        var chrome = ViewerChrome()
        chrome.tap(assistive: true)
        #expect(chrome.isShown)
        chrome.tap(assistive: true)
        #expect(chrome.isShown)
    }

    /// Hidden bars come back the moment VoiceOver or Switch Control is turned on; turning it
    /// off changes nothing.
    @Test func turningOnVoiceOverBringsTheBarsBack() {
        var chrome = ViewerChrome()
        chrome.tap(assistive: false)
        #expect(!chrome.isShown)
        chrome.assistiveTechnology(running: false)
        #expect(!chrome.isShown)
        chrome.assistiveTechnology(running: true)
        #expect(chrome.isShown)
        chrome.assistiveTechnology(running: false)
        #expect(chrome.isShown)
    }

    /// Zooming in hides the bars, as in Photos, so no title stands on the zoomed photo (design
    /// rule 1; review D, L6); a tap brings them back. With VoiceOver or Switch Control they stay.
    @Test func zoomingInHidesTheBars() {
        var chrome = ViewerChrome()
        chrome.zoomed(assistive: false)
        #expect(!chrome.isShown)
        chrome.zoomed(assistive: false)
        #expect(!chrome.isShown)
        chrome.tap(assistive: false)
        #expect(chrome.isShown)
        var assisted = ViewerChrome()
        assisted.zoomed(assistive: true)
        #expect(assisted.isShown)
    }

    // MARK: Live Photos

    /// A Live Photo plays its short motion by itself when it comes into view, as in Photos,
    /// but not with Reduce Motion, in Low Power Mode or with "Auto-Play Video Previews" off.
    /// A long press plays it in every case: the user asked for it.
    @Test(arguments: [
        (false, false, true, true),
        (true, false, true, false),
        (false, true, true, false),
        (false, false, false, false),
        (true, true, false, false),
    ])
    func theShortMotionOnlyWhereMotionIsWelcome(reduceMotion: Bool, lowPower: Bool, autoplay: Bool, plays: Bool) {
        #expect(LiveMotion.playsHint(reduceMotion: reduceMotion, lowPowerMode: lowPower, autoplayVideos: autoplay) == plays)
    }

    // MARK: Sharing

    /// The share button works while the photo is not looked at yet (a tap looks first) and when
    /// the whole photo is on the iPhone; it is disabled when only a preview is here and the
    /// photo itself is in iCloud (Albumist never loads from iCloud), or when Photos has nothing.
    @Test func sharingNeedsTheWholePhotoOnTheIPhone() {
        #expect(ShareAvailability.unknown.canShare)
        #expect(ShareAvailability.onDevice.canShare)
        #expect(!ShareAvailability.onlyInICloud.canShare)
        #expect(!ShareAvailability.unavailable.canShare)
    }

    /// What the end of reading a photo's first bytes says (review D2, N5): no error, the photo
    /// is on the iPhone; only Photos' "network access required" (also under another error)
    /// means it is only in iCloud. Any other error says nothing about where it is: unknown, so
    /// nothing is kept and the next tap asks again; before, every error turned the button off
    /// with "Das ganze Foto liegt nur in iCloud", which was not true.
    @Test func onlyPhotosNetworkErrorMeansOnlyInICloud() {
        let photos = "PHPhotosErrorDomain"
        #expect(ShareAvailability.photosErrorDomain == photos)
        #expect(ShareAvailability.networkAccessRequired == 3164)
        #expect(ShareAvailability.afterReading(errors: []) == .onDevice)
        #expect(ShareAvailability.afterReading(errors: [(photos, 3164)]) == .onlyInICloud)
        // Under an error of another kind, the cause still is the network.
        #expect(ShareAvailability.afterReading(errors: [("NSCocoaErrorDomain", 4), (photos, 3164)]) == .onlyInICloud)
        // Other errors of Photos: cancelled, a network error, a file missing, an invalid one,
        // no room, access restricted or denied, its internal error.
        for code in [3072, 3169, 3303, 3302, 3305, 3310, 3311, -1, 3114] {
            #expect(ShareAvailability.afterReading(errors: [(photos, code)]) == .unknown, "\(code)")
        }
        // The same number in another domain is another error.
        #expect(ShareAvailability.afterReading(errors: [("NSCocoaErrorDomain", 3164)]) == .unknown)
        #expect(ShareAvailability.afterReading(errors: [("NSURLErrorDomain", -1009)]) == .unknown)
        // Unknown is no verdict: the button stays on.
        #expect(ShareAvailability.afterReading(errors: [("NSCocoaErrorDomain", 4)]).canShare)
    }

    // MARK: The share being prepared (review D2, N1 and N7)

    static let first = AssetID("first"), second = AssetID("second")

    /// `begin`, `end` and the step they give, outside the test macros (which cannot call a
    /// mutating method).
    static func begin(_ share: inout SharePreparation, _ id: AssetID) throws -> SharePreparation.Ticket {
        let ticket = share.begin(id)
        return try #require(ticket, "no share begun for \(id)")
    }

    /// A tap on "Teilen" prepares the share of the photo on screen; its button waits until the
    /// file is ready, then the share sheet shows it. One share at a time.
    @Test func aShareIsShownForThePhotoOnScreen() throws {
        var share = SharePreparation()
        #expect(!share.isPreparing)
        let ticket = try Self.begin(&share, Self.first)
        #expect(share.isPreparing)
        let second = share.begin(Self.first)
        #expect(second == nil, "a second share while one is prepared")
        let step = share.end(ticket, with: .file, onScreen: Self.first)
        #expect(step == .present)
        #expect(!share.isPreparing)
        #expect(!share.failed)
    }

    /// A swipe to another photo (or its details, or closing the view) leaves the share: the
    /// button is free at once for the photo now on screen, and what the left share ends with is
    /// neither shown nor said; its file goes (review D2, N7: "Teilen" stayed dimmed up to a
    /// minute on the next photo, and its failure was said for a photo no longer on screen).
    @Test func aSwipeLeavesTheShare() throws {
        var share = SharePreparation()
        let left = try Self.begin(&share, Self.first)
        share.leave()
        #expect(!share.isPreparing)
        let next = try Self.begin(&share, Self.second)
        let file = share.end(left, with: .file, onScreen: Self.second)
        #expect(file == .discard)
        let failure = share.end(left, with: .failed, onScreen: Self.second)
        #expect(failure == .discard)
        #expect(!share.failed)
        #expect(share.isPreparing, "the left share freed the button of the new one")
        let shown = share.end(next, with: .file, onScreen: Self.second)
        #expect(shown == .present)
    }

    /// Back on the same photo, a new share: the end of the left one (cancelled, so it fails)
    /// is not taken for the new one's.
    @Test func aLeftShareIsNotTheNewOne() throws {
        var share = SharePreparation()
        let left = try Self.begin(&share, Self.first)
        share.leave()
        let again = try Self.begin(&share, Self.first)
        let old = share.end(left, with: .failed, onScreen: Self.first)
        #expect(old == .discard)
        #expect(!share.failed)
        #expect(share.isPreparing)
        let shown = share.end(again, with: .file, onScreen: Self.first)
        #expect(shown == .present)
    }

    /// A failure is said only for the photo on screen, by the photo view itself, until the user
    /// taps OK (review D2, N1: the app's own alert could not show over the full-screen photo
    /// view and came up after it had closed). Leaving or a new share takes it back.
    @Test func aFailureIsSaidOnlyForThePhotoOnScreen() throws {
        var share = SharePreparation()
        let ticket = try Self.begin(&share, Self.first)
        let said = share.end(ticket, with: .failed, onScreen: Self.first)
        #expect(said == .sayFailed)
        #expect(share.failed)
        #expect(!share.isPreparing, "the button stays off after a failure")
        share.failureSeen()
        #expect(!share.failed)
        // The photo on screen changed without the share being left: nothing said.
        let other = try Self.begin(&share, Self.first)
        let unsaid = share.end(other, with: .failed, onScreen: Self.second)
        #expect(unsaid == .discard)
        #expect(!share.failed)
        // A failure not seen yet is not said later, for this photo or another.
        let third = try Self.begin(&share, Self.second)
        _ = share.end(third, with: .failed, onScreen: Self.second)
        share.leave()
        #expect(!share.failed, "leaving keeps an old failure")
        let fourth = try Self.begin(&share, Self.second)
        _ = share.end(fourth, with: .failed, onScreen: Self.second)
        _ = try Self.begin(&share, Self.first)
        #expect(!share.failed, "a new share keeps an old failure")
    }

    /// Why a photo cannot be shared is kept for it, also when the user has left its share: it
    /// is true of the photo and turns its button off with its reason.
    @Test func aVerdictIsKeptForItsPhoto() throws {
        var share = SharePreparation()
        let ticket = try Self.begin(&share, Self.first)
        let kept = share.end(ticket, with: .unavailable(.onlyInICloud), onScreen: Self.first)
        #expect(kept == .remember(.onlyInICloud))
        let left = try Self.begin(&share, Self.first)
        share.leave()
        let keptLeft = share.end(left, with: .unavailable(.unavailable), onScreen: Self.second)
        #expect(keptLeft == .remember(.unavailable))
        #expect(!share.failed)
        // "Unknown" is no reason: never kept, a failure for the photo on screen.
        let unknown = try Self.begin(&share, Self.first)
        let step = share.end(unknown, with: .unavailable(.unknown), onScreen: Self.first)
        #expect(step == .sayFailed)
    }

    /// A shared photo is called as in Photos: its original name when the data is of that type,
    /// the original's name with the type's extension for an edited photo Photos hands out in
    /// another format, the fallback name when Photos knows none. Never a path or a hidden file.
    @Test func aSharedPhotoKeepsItsName() {
        #expect(SharedPhotoFile.name(original: "IMG_1234.HEIC", typeExtension: "heic", fallback: "Foto") == "IMG_1234.HEIC")
        #expect(SharedPhotoFile.name(original: "IMG_1234.JPG", typeExtension: "jpeg", fallback: "Foto") == "IMG_1234.JPG")
        #expect(SharedPhotoFile.name(original: "IMG_1234.jpeg", typeExtension: "jpg", fallback: "Foto") == "IMG_1234.jpeg")
        #expect(SharedPhotoFile.name(original: "IMG_1234.HEIC", typeExtension: "jpeg", fallback: "Foto") == "IMG_1234.jpeg")
        #expect(SharedPhotoFile.name(original: "IMG_1234", typeExtension: "png", fallback: "Foto") == "IMG_1234.png")
        #expect(SharedPhotoFile.name(original: nil, typeExtension: "heic", fallback: "Foto") == "Foto.heic")
        #expect(SharedPhotoFile.name(original: "  ", typeExtension: "heic", fallback: "Photo") == "Photo.heic")
        #expect(SharedPhotoFile.name(original: nil, typeExtension: nil, fallback: "Foto") == "Foto")
        #expect(SharedPhotoFile.name(original: "IMG_9.DNG", typeExtension: nil, fallback: "Foto") == "IMG_9.DNG")
        #expect(SharedPhotoFile.name(original: "../Urlaub/IMG_1.JPG", typeExtension: "jpeg", fallback: "Foto") == "-Urlaub-IMG_1.JPG")
        #expect(SharedPhotoFile.name(original: "Scan.TIF", typeExtension: "tiff", fallback: "Foto") == "Scan.TIF")
        #expect(SharedPhotoFile.name(original: ".hidden.jpg", typeExtension: "jpeg", fallback: "Foto") == "hidden.jpg")
        #expect(SharedPhotoFile.name(original: "Mo:Di.png", typeExtension: "png", fallback: "Foto") == "Mo-Di.png")
        #expect(SharedPhotoFile.name(original: ".jpg", typeExtension: "jpeg", fallback: "Foto") == "Foto.jpeg")
        #expect(SharedPhotoFile.name(original: "IMG.", typeExtension: "heic", fallback: "Foto") == "IMG.heic")
        #expect(SharedPhotoFile.name(original: "Zeile\neins.png", typeExtension: "png", fallback: "Foto") == "Zeileeins.png")
    }

    /// A name longer than a file name may be is shortened, keeping its type.
    @Test func aVeryLongNameIsShortened() {
        let name = SharedPhotoFile.name(original: String(repeating: "ä", count: 300) + ".JPG", typeExtension: "jpeg", fallback: "Foto")
        #expect(name.utf8.count <= 200)
        #expect(name.hasPrefix("äää"))
        #expect(name.hasSuffix(".JPG"))
    }
}
