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
