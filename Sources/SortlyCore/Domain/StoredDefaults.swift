import Foundation

/// Reads a value that an earlier version of Albumist stored, after an update added fields to
/// its type.
///
/// Synthesized `Decodable` fails on a missing key even when the property has a default value.
/// A field added to the settings in the next build would make the stored settings unreadable,
/// and the app would not start ("Albumist konnte nicht starten"; "Neu aufbauen" brings the same
/// row back from the backup copy). Plugin review 15.11., finding K3.
///
/// Every key the stored JSON lacks is taken from `defaults`, at every depth; what the user set
/// stays as it is; keys that no longer exist are ignored. Arrays and sets are kept whole (a
/// new category does not switch itself on for someone who chose theirs).
public enum StoredDefaults {
    public static func decode<T: Codable>(
        _ type: T.Type, from data: Data, defaults: T, encoder: JSONEncoder, decoder: JSONDecoder
    ) throws -> T {
        // Written by this version: nothing to fill in.
        if let value = try? decoder.decode(T.self, from: data) { return value }
        let stored = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let base = try JSONSerialization.jsonObject(with: encoder.encode(defaults), options: [.fragmentsAllowed])
        let merged = try JSONSerialization.data(withJSONObject: merge(stored, over: base), options: [.fragmentsAllowed])
        return try decoder.decode(T.self, from: merged)
    }

    /// The stored value wins; objects are merged key by key. An object with exactly one key on
    /// both sides, and a different one, is an enum case (`{"year": {"_0": 2025}}` against the
    /// default `{"all": {}}`): the stored case is kept whole, mixing two cases breaks decoding.
    static func merge(_ stored: Any, over base: Any) -> Any {
        guard let object = stored as? [String: Any], let defaults = base as? [String: Any] else { return stored }
        if object.count == 1, defaults.count == 1, object.keys.first != defaults.keys.first { return stored }
        var result = defaults
        for (key, value) in object {
            result[key] = defaults[key].map { merge(value, over: $0) } ?? value
        }
        return result
    }
}
