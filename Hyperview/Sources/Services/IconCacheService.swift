import Foundation

/// Downloads all coin SVG icons from the backend in a single request,
/// then stores them on disk for instant local access.
/// Icons never change → one download, always cached.
///
/// First launch: icons load from CDN normally, bundle downloads in background.
/// Second launch+: icons load from disk cache, instant.
final class IconCacheService {
    static let shared = IconCacheService()

    private let backendURL = "\(Configuration.backendBaseURL)/icons"
    private let cacheDir: URL
    private let metaFile: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("coin-icons", isDirectory: true)
        metaFile = cacheDir.appendingPathComponent(".meta.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns cached SVG data for a symbol, or nil if not cached.
    func svgData(for symbol: String) -> Data? {
        let file = cacheDir.appendingPathComponent("\(symbol).svg")
        return FileManager.default.contents(atPath: file.path)
    }

    /// True if the icon bundle has been downloaded at least once.
    var hasCachedIcons: Bool {
        FileManager.default.fileExists(atPath: metaFile.path)
    }

    /// Call on app launch. NEVER blocks UI.
    /// First launch: fires background download, icons will load from CDN this time.
    /// Second launch+: icons already on disk, background refresh for new coins only.
    func refreshIfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.downloadBundle()
        }
    }

    private func downloadBundle() async {
        guard let url = URL(string: backendURL) else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60

            // Send ETag for conditional request
            if let meta = loadMeta(), let etag = meta["etag"] as? String {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else { return }

            // 304 Not Modified — cache is still valid
            if http.statusCode == 304 { return }
            guard http.statusCode == 200 else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let icons = json["icons"] as? [String: String] else { return }

            // Write each SVG to disk
            for (symbol, svg) in icons {
                let file = cacheDir.appendingPathComponent("\(symbol).svg")
                try? svg.data(using: .utf8)?.write(to: file)
            }

            // Save metadata
            let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
            let meta: [String: Any] = [
                "etag": etag,
                "count": icons.count,
                "downloadedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            try? JSONSerialization.data(withJSONObject: meta)
                .write(to: metaFile)

            #if DEBUG
            print("[IconCache] \(icons.count) icons cached to disk")
            #endif
        } catch {
            #if DEBUG
            print("[IconCache] Download failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func loadMeta() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: metaFile.path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
