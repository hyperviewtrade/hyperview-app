import Foundation

/// Shared cache for the Hyperliquid leaderboard (~17MB response).
/// Uses streaming JSON parsing to deliver rows incrementally —
/// first 30 rows available within seconds, rest streams in background.
actor LeaderboardCache {
    static let shared = LeaderboardCache()

    private var parsedRows: [[String: Any]] = []
    private var downloadComplete = false
    private var isDownloading = false
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 300
    private var downloadError: Error?
    private var downloadTask: Task<Void, Never>?
    private var waiters: [(minCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private init() {}

    /// Start streaming download if not already running. Non-blocking.
    func ensureDownloadStarted() {
        guard !isDownloading, !isFresh else { return }
        isDownloading = true
        downloadComplete = false
        downloadError = nil
        parsedRows = []
        downloadTask = Task { await streamDownload() }
    }

    private var isFresh: Bool {
        downloadComplete && downloadError == nil &&
        fetchedAt.map { Date().timeIntervalSince($0) < ttl } ?? false
    }

    /// Get a page of rows. Waits only until enough rows are streamed.
    func getRows(from: Int, count: Int) async throws -> [[String: Any]] {
        ensureDownloadStarted()

        let needed = from + count
        if parsedRows.count < needed && !downloadComplete {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append((needed, cont))
            }
        }

        if let error = downloadError, parsedRows.count <= from { throw error }

        let end = min(from + count, parsedRows.count)
        guard from < end else { return [] }
        return Array(parsedRows[from..<end])
    }

    /// Get ALL rows. Waits for complete download. Used by LargestPositionsVM.
    func getAllRows() async throws -> [[String: Any]] {
        ensureDownloadStarted()

        if !downloadComplete {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters.append((Int.max, cont))
            }
        }

        if let error = downloadError { throw error }
        return parsedRows
    }

    /// Check if more rows exist beyond the given offset.
    func hasMoreRows(beyond from: Int) -> Bool {
        if !downloadComplete { return true }
        return parsedRows.count > from
    }

    func invalidate() {
        downloadTask?.cancel()
        downloadTask = nil
        parsedRows = []
        downloadComplete = false
        isDownloading = false
        fetchedAt = nil
        downloadError = nil
        // Resume any waiters so they don't hang
        for (_, cont) in waiters { cont.resume() }
        waiters = []
    }

    // MARK: - Streaming Download + Incremental Parse

    private func streamDownload() async {
        do {
            let url = URL(string: "https://stats-data.hyperliquid.xyz/Mainnet/leaderboard")!
            let (bytes, _) = try await URLSession.shared.bytes(from: url)

            var currentObject = Data()
            var braceDepth = 0
            var inString = false
            var escaped = false
            var foundArrayStart = false
            var inObject = false

            for try await byte in bytes {
                if Task.isCancelled { break }

                // Skip until we find the opening `[` of the JSON array
                // Works for both `[{...}]` and `{"leaderboardRows": [{...}]}`
                if !foundArrayStart {
                    if byte == UInt8(ascii: "[") { foundArrayStart = true }
                    continue
                }

                // Not inside an object — look for next `{`
                if !inObject {
                    if byte == UInt8(ascii: "{") {
                        inObject = true
                        braceDepth = 1
                        inString = false
                        escaped = false
                        currentObject = Data([byte])
                    }
                    continue
                }

                // Accumulate bytes for current JSON object
                currentObject.append(byte)

                // Handle JSON string escaping
                if escaped { escaped = false; continue }
                if byte == UInt8(ascii: "\\") && inString { escaped = true; continue }
                if byte == UInt8(ascii: "\"") { inString = !inString; continue }
                if inString { continue }

                // Track brace depth
                if byte == UInt8(ascii: "{") {
                    braceDepth += 1
                } else if byte == UInt8(ascii: "}") {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        // Complete JSON object — parse it
                        if let dict = try? JSONSerialization.jsonObject(with: currentObject) as? [String: Any] {
                            parsedRows.append(dict)
                            // Notify waiters every 30 rows
                            if parsedRows.count % 30 == 0 {
                                notifyWaiters()
                            }
                        }
                        currentObject = Data()
                        inObject = false
                    }
                }
            }

            downloadComplete = true
            fetchedAt = Date()
        } catch {
            if !Task.isCancelled {
                downloadError = error
            }
            downloadComplete = true
        }

        isDownloading = false
        notifyWaiters()
    }

    private func notifyWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (minCount, cont) in waiters {
            if parsedRows.count >= minCount || downloadComplete {
                cont.resume()
            } else {
                remaining.append((minCount, cont))
            }
        }
        waiters = remaining
    }
}
