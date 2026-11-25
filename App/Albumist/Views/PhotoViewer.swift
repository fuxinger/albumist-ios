import SwiftUI
import UIKit
import AlbumistCore

/// Photos in full screen, like the Photos app: swipe from one to the next, pinch or double-tap
/// to zoom, swipe down to close. First device test 15.11.: "Hier müsste man die Bilder öffnen
/// bzw. groß machen können." The images come straight from Photos (only what is on the device,
/// nothing is downloaded or stored).
///
/// Design review 15.11. (W11, W12): the controls are the system's toolbar (Liquid Glass, not
/// home-made black circles); a tap on a photo opens this viewer everywhere, and its details
/// are behind the "i" button, as in Photos.
///
/// Design wave 2 (DS-10), as in Photos: the title is the photo's place, day and time
/// (`PhotoTitle`, before "1 von 176", which VoiceOver still says with the photo); "Teilen"
/// shares the photo from the iPhone (`PhotoShare`); a tap hides the bars, the status bar and
/// the home indicator and the next brings them back, but never while VoiceOver or Switch
/// Control runs (`ViewerChrome`); Live Photos move (`LivePhotoPlayer`).
///
/// Design wave 3: videos play as in Photos (DS-16, `ViewerVideo`): by themselves and looping
/// where motion is welcome, without sound until the user turns it on, only from the iPhone, with
/// their controls under them on a solid ground, going with the bars. While a photo comes, the
/// thumbnail the grid showed stands in for it, never a spinner, and a picture that would only be
/// big and blurry never stands: the calm note says why (DS-18, `ViewerPicture`).
struct PhotoViewer: View {
    struct Start: Identifiable {
        var id: AssetID
        /// The photos to swipe through, fixed when the viewer opens (a photo ignored from its
        /// details must not reshuffle the pages under the user's finger).
        var ids: [AssetID] = []
    }

    var ids: [AssetID]
    @State var current: AssetID
    /// Shows the "i" button with the photo's details, album and ignore actions.
    var showsInfo: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) var switchControl
    @State var info: AssetFacts?
    @State private var addingToAlbum: [AssetID]?
    /// How far the photo was pulled down to close.
    @State var pull: CGFloat = 0
    /// The pages built: a window around the photo shown, moved on while swiping (review
    /// P4-11: the library hands over 3,000 photos and more, and every one was a page).
    @State var window: PageWindow
    /// The bars, the status bar and the home indicator: a tap on the photo hides and shows them.
    @State var chrome = ViewerChrome()
    /// The top of the photos' area: under the bar while the bars show, kept while they are
    /// hidden, so the photo never moves (on an iPhone with a Home button the status bar's height
    /// goes with it) and the bar's title never stands on the photo (design rule 1).
    @State var top: CGFloat = 0
    /// Whether each photo looked at can be shared (asked once per photo).
    @State var sharing: [AssetID: ShareAvailability] = [:]
    /// The share being prepared for the photo on screen, and whether it failed
    /// (`SharePreparation`; review D2, N1 and N7).
    @State var preparation = SharePreparation()
    /// Making the file for the share sheet; stopped when the user leaves the share.
    @State var shareTask: Task<Void, Never>?
    /// The photos whose Live Photo motion is on the iPhone: their title shows the symbol.
    @State var livePhotos: Set<AssetID> = []
    /// The photo whose Live Photo plays under a long press: the pager holds still meanwhile
    /// (review D2, N4), as in Photos.
    @State var pressing: AssetID?
    /// What Photos says of each photo looked at: its date, for the title while Albumist has no
    /// facts of it, and its kind (`PhotoBasics`).
    @State var basics: [AssetID: PhotoBasics] = [:]
    /// The photos whose kind Photos was asked on screen, answered or not (`lookAtCurrent`): one it
    /// could not tell is taken for a photo, so the page on screen never waits for good (review X6).
    @State var kindsAsked: Set<AssetID> = []
    /// 12 or 24 hours as the iPhone is set; read again when its settings change.
    @State var clock = AppModel.deviceClock()
    /// The clock the analysis tells photos without a place on, asked once before the first date
    /// shows: a photo not analysed yet is told on it (review D2, N10).
    @State var homeZone: TimeZone?
    @State var homeZoneAsked = false
    /// The video on screen: one player at most (DS-16).
    @State var video = ViewerVideo()
    /// The pages whose picture did not come sharp: they say so themselves, the video's note under
    /// them would say it twice.
    @State var unavailablePictures: Set<AssetID> = []
    @Environment(\.scenePhase) var scenePhase

    init(ids: [AssetID], current: AssetID, showsInfo: Bool = false) {
        self.ids = ids
        _current = State(initialValue: current)
        self.showsInfo = showsInfo
        _window = State(initialValue: PageWindow(around: ids.firstIndex(of: current) ?? 0, count: ids.count))
    }

    var body: some View {
        NavigationRoot { pager }
            // Dark inside the viewer only; the sheets below keep the app's own appearance.
            .environment(\.colorScheme, .dark)
            .accessibilityAction(.escape) { closeNow() }
            .sheet(item: $info) { facts in details(facts).sheetSize(.short) }
            .sheet(isPresented: addingBinding) { addSheet.sheetSize(.page) }
            // Said here, over the photo: the app's own alert cannot show over this full-screen
            // view and came up after it had closed (review D2, N1).
            .alert("Das hat nicht geklappt", isPresented: shareFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Das Foto konnte nicht zum Teilen vorbereitet werden. Versuch es gleich noch einmal.")
            }
            .onAppear { opened() }
            .onDisappear { closed() }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in clock = AppModel.deviceClock() }
    }

    /// A share the app could not clean up after (it was ended while the sheet was open) goes;
    /// the app's sound is set to mix with the user's before any Live Photo plays (review D2, N9).
    private func opened() {
        PhotoShare.removeLeftovers()
        LiveAudio.prepare()
    }

    /// The photo view closes by the button, a pull or VoiceOver's escape: a video stops at once,
    /// so its sound does not run on over the grid while the view slides away (review F, F15).
    func closeNow() {
        video.pause()
        dismiss()
    }

    /// The video stops, and the app's sound mixes with the user's again (DS-16).
    private func closed() {
        leaveShare()
        PhotoShare.removeLeftovers()
        video.close()
    }

    // MARK: Sheets

    private func details(_ facts: AssetFacts) -> some View {
        AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
            // A half-height sheet is see-through glass in iOS 26: over the black viewer
            // the light text lost its contrast ("Taken", UI run 43773339053). Solid.
            .presentationBackground(Theme.background)
    }

    private var addingBinding: Binding<Bool> {
        Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })
    }

    /// The share of the photo on screen failed: said until the user taps OK.
    private var shareFailed: Binding<Bool> {
        Binding(get: { preparation.failed }, set: { if !$0 { preparation.failureSeen() } })
    }

    private var addSheet: some View {
        AddToAlbumSheet(assets: addingToAlbum ?? []) {}
            .presentationBackground(Theme.background)
    }
}
