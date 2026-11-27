import SwiftUI
import AlbumistCore

/// Under a video in the photo view (design wave 3, DS-16), on a solid ground (design rule 1: no
/// text on the photo), as Photos has them: "Abspielen" or "Anhalten", the slider with the time
/// passed and the time left above it, and the sound ("Ton an", "Ton aus"). It goes with the bars
/// on a tap, as in Photos, and stays with VoiceOver and Switch Control (`ViewerChrome`).
///
/// For everyone: the buttons say what they do (VoiceOver and Voice Control read the words, the
/// symbols alone show), the slider says where the video is in words and moves by a step that
/// fits the length (`VideoPosition`), and VoiceOver's two-finger double tap plays and pauses on
/// each of them as on the video's page; the times stand on a line of their own, stacked where a
/// large text size leaves no room for both, so it never cuts them, and the symbols stop growing
/// at the second accessibility size.
struct VideoControls: View {
    var video: ViewerVideo
    var words: ProposalWords

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            times
            HStack(spacing: Theme.Spacing.m) {
                playButton
                slider
                soundButton
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .floatingPanel(cornerRadius: 22)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.video")
    }

    /// Known from Photos before the video plays; the shortest until then.
    private var length: VideoDuration { video.length ?? .oneSecond }

    private var position: VideoPosition { VideoPosition(at: video.time, of: length) }

    /// "0:03" and "−0:12", the slider says them to VoiceOver. Side by side as in Photos;
    /// stacked where a large text size leaves no room for both on a line (a video of an hour or
    /// more), so neither is ever cut.
    private var times: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                elapsedTime
                Spacer(minLength: Theme.Spacing.s)
                remainingTime
            }
            VStack(alignment: .leading, spacing: 0) {
                elapsedTime
                remainingTime
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.noteText)
        .accessibilityHidden(true)
    }

    private var elapsedTime: Text { Text(verbatim: position.elapsedText) }

    private var remainingTime: Text { Text(verbatim: position.remainingText) }

    private var playButton: some View {
        Button { video.togglePlay() } label: {
            Label {
                video.isPlaying ? Text("Anhalten") : Text("Abspielen")
            } icon: {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            // The 44-pt tap area is the label's: around a borderless button a frame only adds
            // empty space, and a near miss would move the slider.
            .labelStyle(.iconOnly)
            .minimumHitTarget()
        }
        .font(.title2)
        .buttonStyle(.borderless)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityShowsLargeContentViewer()
        .accessibilityAction(.magicTap) { video.togglePlay() }
        .accessibilityIdentifier("viewer.video.play")
    }

    /// The time in the video: the picture follows the finger; VoiceOver hears where it is and
    /// moves it a step with a swipe up or down.
    private var slider: some View {
        Slider(value: Binding(get: { video.time }, set: { video.scrub(to: $0) }),
               in: 0...Double(length.seconds),
               onEditingChanged: { editing in
                   if editing { video.beginScrub() } else { video.endScrub() }
               })
        .tint(Theme.accent)
        .accessibilityLabel(Text("Wiedergabeposition"))
        .accessibilityValue(Text(verbatim: position.spoken(words)))
        .accessibilityAdjustableAction { direction in
            let step = VideoPosition.step(for: length)
            switch direction {
            case .increment: video.move(by: step)
            case .decrement: video.move(by: -step)
            @unknown default: break
            }
        }
        .accessibilityAction(.magicTap) { video.togglePlay() }
        .accessibilityIdentifier("viewer.video.position")
    }

    private var soundButton: some View {
        Button { video.toggleSound() } label: {
            Label {
                video.sound.isOn ? Text("Ton aus") : Text("Ton an")
            } icon: {
                Image(systemName: video.sound.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.iconOnly)
            .minimumHitTarget()
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityShowsLargeContentViewer()
        .accessibilityAction(.magicTap) { video.togglePlay() }
        .accessibilityIdentifier("viewer.video.sound")
    }
}

/// Why a video does not play (DS-16), under it on a solid ground with the bars, as the share's
/// note (`ShareInICloudNote`): its file is only in iCloud (Albumist never loads from iCloud, the
/// Photos app does), or Photos has nothing to play now. Calm words, no spinner, no download.
struct VideoNoteView: View {
    var note: VideoNote

    var body: some View {
        Label {
            switch note {
            case .onlyInICloud: Text("Das Video liegt nur in iCloud. Abspielen kannst du es in der Fotos-App.")
            case .unavailable: Text("Dieses Video lässt sich gerade nicht abspielen.")
            }
        } icon: {
            Image(systemName: note == .onlyInICloud ? "icloud" : "exclamationmark.circle")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .floatingPanel(cornerRadius: 22)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("viewer.videoNote")
    }
}
