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

    static func load() -> FreeAlbumLedger? {
        MainThreadWatch.shared.section("keychain read") { loadNow() }
    }

    private static func loadNow() -> FreeAlbumLedger? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FreeAlbumLedger.self, from: data)
    }

    /// Readable after the first unlock, so a plan that finishes in the background can count.
    static func save(_ ledger: FreeAlbumLedger) {
        MainThreadWatch.shared.section("keychain write") { saveNow(ledger) }
    }

    private static func saveNow(_ ledger: FreeAlbumLedger) {
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
