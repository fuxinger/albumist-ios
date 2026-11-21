import Photos
import UIKit

/// Photos changed outside Albumist (an album made in the Photos app, new pictures, a changed
/// selection): a moment later the analysis catches up, so "Deine Alben" and the suggestions
/// match what Photos shows (Fuchs, 14.11.: albums made in Photos did not appear), and the
/// thumbnails' video lengths follow (`ThumbnailCache.followChanges`).
@MainActor
final class LibraryChangeWatcher: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = LibraryChangeWatcher()
    private var registered = false
    private var pending: Task<Void, Never>?
    /// Least time between the end of one run and a catch-up run.
    private static let minimumGap: TimeInterval = 20

    /// Only with read access: registering earlier could bring up the permission question.
    func start() {
        guard !registered else { return }
        registered = true
        // Off the main thread: registering talks to the Photos service, which can keep a caller
        // waiting while it sets up or writes the library (a fresh simulator, new photos).
        // A change in the moment before the registration lands may go unreported; the analysis
        // that normally follows a start (at launch; after access is granted) reads the library
        // itself and should pick it up.
        DispatchQueue.global(qos: .utility).async { [self] in
            PHPhotoLibrary.shared().register(self)
        }
    }

    /// Photos tells its changes one after the other, on a queue of its own: they reach the main
    /// actor in that order (the main queue keeps it), so the kept videos' lengths take them in
    /// turn (review V11).
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let change = ThumbnailRequest.Change(changeInstance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { LibraryChangeWatcher.shared.changed(change) }
        }
    }

    /// A change in Photos: a moment later the analysis catches up, and the lengths on the
    /// thumbnails of videos trimmed in Photos follow (review F, F14), all changes of the moment
    /// in one walk (review V11). Albumist's own albums change no photo.
    private func changed(_ change: ThumbnailRequest.Change) {
        if !AppModel.shared.execution.isRunning { ThumbnailCache.shared.changeArrived(change) }
        scheduleCatchUp()
    }

    /// Also called when a run ends that saw changes arrive meanwhile.
    func scheduleCatchUp() {
        MainThreadWatch.shared.section("library change") { scheduleCatchUpNow() }
    }

    private func scheduleCatchUpNow() {
        let model = AppModel.shared
        // Albumist's own changes are followed by an analysis anyway.
        guard !model.execution.isRunning else { return }
        pending?.cancel()
        pending = Task {
            // Several changes in a row (an album and its photos) start one analysis. While
            // iCloud syncs, Photos reports changes every few seconds: at most one check every
            // 20 s then, so full checks of the library do not run back to back and warm the
            // iPhone (each one reads the whole library again).
            var delay: TimeInterval = 3
            if let last = model.analysis.lastRun { delay = max(delay, Self.minimumGap - Date().timeIntervalSince(last)) }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // The lengths of the kept videos follow the changes that waited, in one walk.
            ThumbnailCache.shared.followChanges()
            // A run in progress read the library at its start: one more pass follows it, so
            // new screenshots do not wait for the next app start.
            if model.analysis.isRunning {
                model.catchUpAfterRun = true
                return
            }
            guard Self.mayCatchUp(model) else { return }
            model.startAnalysis()
        }
    }

    private static func mayCatchUp(_ model: AppModel) -> Bool {
        #if targetEnvironment(simulator)
        // The demo library starts its own analysis once every photo is there.
        if DemoLibrary.shared.isSeeding { return false }
        // A UI test launch that only creates photos: every batch it saves is a change, and the
        // analyses they started re-read the growing library while it was created (stress run
        // 43833158673: 33 min for 50,000 photos, and a run cut off at step 4 by the app's end).
        if UITestSupport.createsOnly { return false }
        #endif
        // The sample photos start one analysis after the last chunk, and after a removal.
        if SamplePhotos.shared.isAdding || SamplePhotos.shared.isRemoving { return false }
        // During a change in "Dein Zuhause" startAnalysis queues the run behind it.
        // Paused by the user: a change in Photos (iCloud syncing) never undoes the Pause;
        // "Fortsetzen" reads the library anew (second review of the labels fix, finding 12).
        return model.phase == .ready && model.access.canRead && !model.execution.isRunning && !model.analysis.isRunning
            && !model.analysis.isPausedByUser
    }
}
