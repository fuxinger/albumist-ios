import Photos
import UIKit

/// Photos changed outside Albumist (an album made in the Photos app, new pictures, a changed
/// selection): a moment later the analysis catches up, so "Deine Alben" and the suggestions
/// match what Photos shows (Fuchs, 14.11.: albums made in Photos did not appear).
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
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in LibraryChangeWatcher.shared.scheduleCatchUp() }
    }

    /// Also called when a run ends that saw changes arrive meanwhile.
    func scheduleCatchUp() {
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
        return model.phase == .ready && model.access.canRead && !model.execution.isRunning && !model.analysis.isRunning
    }
}
