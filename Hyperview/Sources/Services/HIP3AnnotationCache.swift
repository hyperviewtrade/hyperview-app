import Foundation

extension Notification.Name {
    static let hip3AnnotationsLoaded = Notification.Name("hip3AnnotationsLoaded")
}

/// Caches HIP-3 market display names from perpAnnotation API.
/// Thread-safe — can be read from any thread.
/// Persisted to UserDefaults so display names are instant on next launch.
final class HIP3AnnotationCache {
    static let shared = HIP3AnnotationCache()

    private var _displayNames: [String: String] = [:]
    private var _categories: [String: String] = [:]
    private let lock = NSLock()

    private let backendURL = Configuration.backendBaseURL
    private let namesKey = "hip3_display_names_v2"
    private let catsKey = "hip3_categories_v2"
    private let fetchedAtKey = "hip3_annotations_fetched_at_v2"

    init() {
        if let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] {
            _displayNames = names
        }
        if let cats = UserDefaults.standard.dictionary(forKey: catsKey) as? [String: String] {
            _categories = cats
        }
        if !_displayNames.isEmpty {
            print("[ANNOTATIONS] Restored \(_displayNames.count) display names from disk")
            // Notify immediately so markets render with cached names
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hip3AnnotationsLoaded, object: nil)
            }
        }
    }

    func displayName(for coin: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _displayNames[coin]
    }

    func category(for coin: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _categories[coin]
    }

    func fetchAnnotations() async {
        print("[ANNOTATIONS] fetchAnnotations() called")

        // Skip if fetched recently (within 24h) AND we have data
        let lastFetch = UserDefaults.standard.double(forKey: fetchedAtKey)
        let oneDay: Double = 24 * 60 * 60
        if lastFetch > 0 && Date().timeIntervalSince1970 - lastFetch < oneDay && !_displayNames.isEmpty {
            print("[ANNOTATIONS] Using cached \(_displayNames.count) display names (fresh)")
            return
        }

        print("[ANNOTATIONS] Fetching from backend...")
        guard let url = URL(string: "\(backendURL)/hip3-annotations") else { return }

        // IMPORTANT: bypass URLSession cache to avoid stale empty responses
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            print("[ANNOTATIONS] Got \(data.count) bytes")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let annotations = json["annotations"] as? [String: [String: Any]],
                  !annotations.isEmpty
            else {
                print("[ANNOTATIONS] Empty — backend not ready yet")
                return
            }

            var names: [String: String] = [:]
            var cats: [String: String] = [:]

            for (coin, info) in annotations {
                if let dn = info["displayName"] as? String, !dn.isEmpty {
                    names[coin] = dn
                }
                if let cat = info["category"] as? String, !cat.isEmpty {
                    cats[coin] = cat
                }
            }

            lock.lock()
            _displayNames = names
            _categories = cats
            lock.unlock()

            UserDefaults.standard.set(names, forKey: namesKey)
            UserDefaults.standard.set(cats, forKey: catsKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fetchedAtKey)

            print("[ANNOTATIONS] Loaded \(names.count) display names")

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hip3AnnotationsLoaded, object: nil)
            }
        } catch {
            print("[ANNOTATIONS] Fetch failed: \(error.localizedDescription)")
        }
    }
}
