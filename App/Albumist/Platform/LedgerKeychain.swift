import Foundation
import Security
import AlbumistCore

/// A second copy of the free-album count in the keychain (plugin review N4). The user
/// defaults go away when Albumist is deleted, so installing it again handed out ten new free
/// albums; keychain items of an app stay on the device after it is deleted. The item stays on
/// this device and in its encrypted backup, never in iCloud Keychain, and holds counts per plan
/// only (no names, no photos). `Purchases` puts both copies together with
/// `FreeAlbumLedger.merged(with:)`, so neither copy can lose a counted album.
enum LedgerKeychain {
    private static let service = "app.albumist.ios.freeAlbums"
    private static let account = "ledger"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The keychain copy as `Purchases` uses it: every read and write on one serial queue, in
    /// the order they were asked for, never on the main thread (UI run 45589509156: the read at
    /// launch held the main thread for 2.3 s). Unit tests pass their own `read` and `write`.
    struct Copy: Sendable {
        let read: @Sendable () -> FreeAlbumLedger?
        let write: @Sendable (FreeAlbumLedger) -> Void
        let queue: DispatchQueue

        init(queue: DispatchQueue = DispatchQueue(label: "app.albumist.ios.ledgerKeychain", qos: .userInitiated),
             read: @escaping @Sendable () -> FreeAlbumLedger?, write: @escaping @Sendable (FreeAlbumLedger) -> Void) {
            self.queue = queue
            self.read = read
            self.write = write
        }

        /// The app's keychain item.
        static var device: Copy { Copy(read: { LedgerKeychain.loadNow() }, write: { LedgerKeychain.saveNow($0) }) }

        /// Queues the read now, ahead of every write asked for after this call (a count made
        /// while the keychain answers must not be what the read sees, or the merge would drop
        /// the keychain's own count); the returned function waits for its answer.
        func beginLoad() -> @Sendable () async -> FreeAlbumLedger? {
            let answer = Answer()
            let done = DispatchGroup()
            queue.async(group: done) { [read] in answer.set(read()) }
            return {
                await withCheckedContinuation { finished in
                    done.notify(queue: .global(qos: .userInitiated)) { finished.resume(returning: answer.get()) }
                }
            }
        }

        private final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var ledger: FreeAlbumLedger?
            func set(_ value: FreeAlbumLedger?) { lock.withLock { ledger = value } }
            func get() -> FreeAlbumLedger? { lock.withLock { ledger } }
        }

        /// Queued after every read and write asked for before it; returns at once.
        func save(_ ledger: FreeAlbumLedger) {
            queue.async { write(ledger) }
        }
    }

    static func loadNow() -> FreeAlbumLedger? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FreeAlbumLedger.self, from: data)
    }

    /// Readable after the first unlock, so a plan that finishes in the background can count.
    static func saveNow(_ ledger: FreeAlbumLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = baseQuery.merging(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
