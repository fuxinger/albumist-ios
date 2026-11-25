import Foundation
import Testing
import AlbumistCore
@testable import Albumist

/// The keychain copy of the free-album count (`LedgerKeychain.Copy`), read off the main thread.
/// UI run 45589509156 (25.11.2026, flow-other): the read in `Purchases.init` held the main thread
/// for 2.3 s at launch ("keychain read" stall), because the keychain answers through another
/// process. A stand-in copy replaces the keychain here; what matters is where it is read, that
/// a plan waits for it and that no count gets lost while it is read.
@Suite("Free-album count in the keychain")
@MainActor
struct PurchasesKeychainTests {
    /// What the stand-in keychain was asked, thread-safe (the copy's queue calls it).
    final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: FreeAlbumLedger?
        private var readOnMain: [Bool] = []
        private var written: [FreeAlbumLedger] = []
        /// A slow keychain: reads wait until `answer.signal()`, from then on none waits.
        let answer = DispatchSemaphore(value: 0)
        let slow: Bool

        init(holding ledger: FreeAlbumLedger?, slow: Bool = false) {
            stored = ledger
            self.slow = slow
        }

        /// One copy, so one queue, as in the app.
        private(set) lazy var copy = LedgerKeychain.Copy(read: { [self] in
            if slow {
                answer.wait()
                answer.signal()
            }
            return lock.withLock {
                readOnMain.append(Thread.isMainThread)
                return stored
            }
        }, write: { [self] ledger in
            lock.withLock {
                stored = ledger
                written.append(ledger)
            }
        })

        /// Waits until every read and write queued so far is done.
        func drained() async {
            await withCheckedContinuation { done in copy.queue.async { done.resume() } }
        }

        var reads: [Bool] { lock.withLock { readOnMain } }
        var current: FreeAlbumLedger? { lock.withLock { stored } }
        var writes: [FreeAlbumLedger] { lock.withLock { written } }
    }

    func freshDefaults() -> UserDefaults {
        let suite = "albumist.tests.keychain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theKeychainIsReadOffTheMainThread() async {
        let keychain = Keychain(holding: nil)
        let purchases = Purchases(defaults: freshDefaults(), keychain: keychain.copy)
        await purchases.keychainRead()
        #expect(keychain.reads.first == false)
        #expect(!keychain.reads.contains(true))
        await keychain.drained()
    }

    /// Deleted and installed again: the defaults are empty, the keychain knows 7 used albums.
    @Test func aNewInstallKnowsTheCountOnceTheKeychainWasRead() async {
        let keychain = Keychain(holding: FreeAlbumLedger(startingWithUsed: 7))
        let purchases = Purchases(defaults: freshDefaults(), keychain: keychain.copy)
        await purchases.keychainRead()
        #expect(purchases.albumsUsed == 7)
        #expect(purchases.remainingFreeAlbums == Purchases.freeAlbumLimit - 7)
        #expect(!purchases.allows(albums: Purchases.freeAlbumLimit - 6))
        #expect(purchases.allows(albums: Purchases.freeAlbumLimit - 7))
        await keychain.drained()
        #expect(keychain.current == purchases.ledger)
    }

    /// Second review of 10e2331: a count written before the merge (a plan settled at launch)
    /// must not replace what only the keychain knew, even if the app ends before the merge.
    @Test func aWriteBeforeTheMergeKeepsTheKeychainsCount() async {
        let keychain = Keychain(holding: FreeAlbumLedger(startingWithUsed: 5), slow: true)
        let purchases = Purchases(defaults: freshDefaults(), keychain: keychain.copy)
        purchases.recordUsage(plan: AlbumistID(), albums: 1)
        keychain.answer.signal()
        // The read and the write ran; the merge on the main actor has not (the app could end here).
        await keychain.drained()
        let copy = keychain.current ?? FreeAlbumLedger()
        #expect(copy.used == 6)
        await purchases.keychainRead()
        await keychain.drained()
    }

    /// A plan counted while the keychain still answers: its write is queued after the read, so
    /// the read sees the keychain's own count, and the merge writes both back. Nothing gets lost
    /// (a read started in a task would come after this write, see the 2 albums only and drop 4).
    @Test func aCountMadeWhileTheKeychainIsReadIsKept() async {
        let keychain = Keychain(holding: FreeAlbumLedger(startingWithUsed: 4), slow: true)
        let defaults = freshDefaults()
        let purchases = Purchases(defaults: defaults, keychain: keychain.copy)
        let plan = AlbumistID()
        purchases.recordUsage(plan: plan, albums: 2)
        keychain.answer.signal()
        await purchases.keychainRead()
        #expect(purchases.albumsUsed == 6)
        // The last write (after everything queued before it) is the merged count.
        await keychain.drained()
        #expect(keychain.current == purchases.ledger)
        #expect(keychain.writes.count >= 2)
        // And a relaunch with the same defaults and keychain still knows both.
        let relaunched = Purchases(defaults: defaults, keychain: keychain.copy)
        await relaunched.keychainRead()
        #expect(relaunched.albumsUsed == 6)
        await keychain.drained()
    }

    @Test func withoutAKeychainCopyNothingWaits() async {
        let purchases = Purchases(defaults: freshDefaults())
        await purchases.keychainRead()
        #expect(purchases.albumsUsed == 0)
    }
}
