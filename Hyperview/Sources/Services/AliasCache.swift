import Foundation

/// Caches wallet aliases from Hypurrscan (via backend /aliases).
/// Thread-safe. Persisted to UserDefaults for instant load.
final class AliasCache {
    static let shared = AliasCache()

    private var _aliases: [String: String] = [:]  // lowercase address → alias
    private let lock = NSLock()

    private let backendURL = Configuration.backendBaseURL
    private let cacheKey = "cached_global_aliases"
    private let fetchedAtKey = "cached_aliases_fetched_at"

    init() {
        // Load from UserDefaults on init
        if let dict = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] {
            _aliases = dict
            print("[ALIASES] Restored \(_aliases.count) aliases from disk")
        }
    }

    /// Get alias for an address. Thread-safe.
    func alias(for address: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _aliases[address.lowercased()]
    }

    /// Fetch aliases from backend. Called on app launch.
    func fetchAliases() async {
        // Skip if fetched recently (within 1 hour)
        let lastFetch = UserDefaults.standard.double(forKey: fetchedAtKey)
        if lastFetch > 0 && Date().timeIntervalSince1970 - lastFetch < 3600 && !_aliases.isEmpty {
            return
        }

        guard let url = URL(string: "\(backendURL)/aliases") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aliases = json["aliases"] as? [String: String],
                  !aliases.isEmpty
            else { return }

            // Normalize to lowercase keys
            var normalized: [String: String] = [:]
            for (addr, name) in aliases {
                normalized[addr.lowercased()] = name
            }

            lock.lock()
            _aliases = normalized
            lock.unlock()

            UserDefaults.standard.set(normalized, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fetchedAtKey)
            print("[ALIASES] Loaded \(normalized.count) aliases from backend")
        } catch {
            print("[ALIASES] Fetch failed: \(error.localizedDescription)")
        }
    }
}
