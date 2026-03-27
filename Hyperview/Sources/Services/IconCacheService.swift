import Foundation

/// Coin icon cache — loads SVGs directly from Hyperliquid CDN on demand,
/// caches to disk for instant subsequent access.
///
/// Zero backend egress: icons come straight from HL CDN.
/// Lazy loading: only downloads icons for coins the user actually views.
/// Persistent cache: survives app restarts, never re-downloads an icon.
final class IconCacheService {
    static let shared = IconCacheService()

    private static let cdnBase = "https://app.hyperliquid.xyz/coins"
    private let cacheDir: URL
    private let metaFile: URL

    /// In-memory cache of already-loaded SVG data (avoids disk reads)
    private var memoryCache: [String: Data] = [:]
    private let lock = NSLock()

    /// Track in-flight downloads to avoid duplicates
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("coin-icons", isDirectory: true)
        metaFile = cacheDir.appendingPathComponent(".meta.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns cached SVG data for a symbol, or nil if not cached yet.
    /// Non-blocking — returns immediately from memory/disk cache.
    func svgData(for symbol: String) -> Data? {
        // 1. Memory cache (fastest)
        lock.lock()
        if let data = memoryCache[symbol] {
            lock.unlock()
            return data
        }
        lock.unlock()

        // 2. Disk cache
        let file = fileURL(for: symbol)
        if let data = FileManager.default.contents(atPath: file.path) {
            lock.lock()
            memoryCache[symbol] = data
            lock.unlock()
            return data
        }

        return nil
    }

    /// True if the icon bundle has been downloaded at least once.
    var hasCachedIcons: Bool {
        // Check if cache directory has any .svg files
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        return contents.contains(where: { $0.hasSuffix(".svg") })
    }

    /// Call on app launch. Preloads disk cache into memory (non-blocking).
    func refreshIfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            await self?.preloadMemoryCache()
        }
    }

    /// Download a specific icon on demand. Returns SVG data or nil.
    /// Safe to call from any context — deduplicates concurrent requests.
    func fetchIcon(for symbol: String) async -> Data? {
        // Already cached?
        if let data = svgData(for: symbol) { return data }

        // Already downloading?
        lock.lock()
        if let existing = inFlight[symbol] {
            lock.unlock()
            return await existing.value
        }

        let task = Task<Data?, Never> {
            await self.downloadIcon(symbol)
        }
        inFlight[symbol] = task
        lock.unlock()

        let result = await task.value

        lock.lock()
        inFlight.removeValue(forKey: symbol)
        lock.unlock()

        return result
    }

    // MARK: - Private

    private func fileURL(for symbol: String) -> URL {
        // Sanitize symbol for filesystem (e.g. "xyz:GOLD" → "xyz_GOLD.svg")
        let safe = symbol.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return cacheDir.appendingPathComponent("\(safe).svg")
    }

    /// Download a single icon from HL CDN
    private func downloadIcon(_ symbol: String) async -> Data? {
        // For HIP-3 symbols like "xyz:GOLD", try the base name first
        let candidates = iconCandidates(for: symbol)

        for candidate in candidates {
            let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? candidate
            guard let url = URL(string: "\(Self.cdnBase)/\(encoded).svg") else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }

                // Validate it's actually an SVG
                guard let text = String(data: data, encoding: .utf8),
                      text.contains("<svg") else { continue }

                // Cache to disk and memory
                let file = fileURL(for: symbol)
                try? data.write(to: file)

                lock.lock()
                memoryCache[symbol] = data
                lock.unlock()

                return data
            } catch {
                continue
            }
        }

        return nil
    }

    /// Generate candidate icon names for a symbol
    private func iconCandidates(for symbol: String) -> [String] {
        // HIP-3: "xyz:GOLD" → try "GOLD", then "xyz:GOLD"
        if let colonIdx = symbol.firstIndex(of: ":") {
            let base = String(symbol[symbol.index(after: colonIdx)...])
            return [base, symbol]
        }
        return [symbol]
    }

    /// Preload existing disk cache into memory for fast access
    private func preloadMemoryCache() async {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else { return }

        var loaded = 0
        for file in files where file.hasSuffix(".svg") {
            let path = cacheDir.appendingPathComponent(file).path
            if let data = FileManager.default.contents(atPath: path) {
                // Reverse the filename sanitization: "xyz_GOLD.svg" → "xyz:GOLD"
                let symbol = String(file.dropLast(4)) // remove .svg
                    .replacingOccurrences(of: "_", with: ":")
                lock.lock()
                memoryCache[symbol] = data
                lock.unlock()
                loaded += 1
            }
        }

        #if DEBUG
        print("[IconCache] Preloaded \(loaded) icons from disk")
        #endif
    }
}
