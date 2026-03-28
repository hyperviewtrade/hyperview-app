import Foundation

/// Client-side request scheduler that prevents Hyperliquid API rate limiting.
///
/// Features:
/// - Max concurrent requests (default: 5)
/// - Request deduplication (identical requests within window are collapsed)
/// - Exponential backoff on 429 responses
/// - Priority queue (trading > data > analytics)
@MainActor
final class RequestScheduler {
    static let shared = RequestScheduler()

    enum Priority: Int, Comparable {
        case critical = 0   // Order submission, position queries
        case high = 1       // Chart data, order book
        case normal = 2     // Market data, balances
        case low = 3        // Analytics, sentiment, leaderboard

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Configuration

    private let maxConcurrent = 5
    private let deduplicationWindow: TimeInterval = 2.0 // seconds
    private var backoffMultiplier: Double = 1.0

    // MARK: - State

    private var activeTasks = 0
    private var pendingQueue: [(key: String, priority: Priority, work: () async throws -> Data, continuation: CheckedContinuation<Data, Error>)] = []
    private var recentRequests: [String: (time: Date, data: Data)] = [:] // dedup cache
    private var isRateLimited = false
    private var rateLimitResetTime: Date = .distantPast

    private init() {
        // Clean up dedup cache every 30s
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupDedupCache()
            }
        }
    }

    // MARK: - Public API

    /// Schedule a request with deduplication and rate limiting
    func schedule(key: String, priority: Priority = .normal, work: @escaping () async throws -> Data) async throws -> Data {
        // Check dedup cache
        if let cached = recentRequests[key], Date().timeIntervalSince(cached.time) < deduplicationWindow {
            return cached.data
        }

        // If rate limited, wait
        if isRateLimited {
            let waitTime = rateLimitResetTime.timeIntervalSinceNow
            if waitTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            isRateLimited = false
        }

        // If under concurrent limit, execute immediately
        if activeTasks < maxConcurrent {
            return try await executeRequest(key: key, work: work)
        }

        // Otherwise, queue with priority
        return try await withCheckedThrowingContinuation { continuation in
            pendingQueue.append((key: key, priority: priority, work: work, continuation: continuation))
            pendingQueue.sort { $0.priority < $1.priority }
        }
    }

    private var rateLimitLogCount = 0
    private var lastRateLimitLogTime: Date = .distantPast

    /// Report a 429 rate limit response
    func reportRateLimit() {
        isRateLimited = true
        backoffMultiplier = min(backoffMultiplier * 2, 16)
        let delay = backoffMultiplier * 1.0 + Double.random(in: 0...0.5)
        rateLimitResetTime = Date().addingTimeInterval(delay)

        // Deduplicate: only log once per 10 seconds
        let now = Date()
        rateLimitLogCount += 1
        if now.timeIntervalSince(lastRateLimitLogTime) >= 10 {
            let suppressed = rateLimitLogCount - 1
            let extra = suppressed > 0 ? " (+\(suppressed) suppressed)" : ""
            print("[Scheduler] Rate limited. Backing off \(String(format: "%.1f", delay))s (x\(String(format: "%.0f", backoffMultiplier)))\(extra)")
            lastRateLimitLogTime = now
            rateLimitLogCount = 0
        }
    }

    /// Reset backoff after successful request
    func reportSuccess() {
        backoffMultiplier = max(backoffMultiplier * 0.5, 1.0)
    }

    // MARK: - Private

    private func executeRequest(key: String, work: @escaping () async throws -> Data) async throws -> Data {
        activeTasks += 1
        defer {
            activeTasks -= 1
            drainQueue()
        }

        let data = try await work()

        // Cache for dedup
        recentRequests[key] = (time: Date(), data: data)

        return data
    }

    private func drainQueue() {
        guard !pendingQueue.isEmpty, activeTasks < maxConcurrent else { return }
        let next = pendingQueue.removeFirst()

        Task {
            do {
                let data = try await executeRequest(key: next.key, work: next.work)
                next.continuation.resume(returning: data)
            } catch {
                next.continuation.resume(throwing: error)
            }
        }
    }

    private func cleanupDedupCache() {
        let now = Date()
        recentRequests = recentRequests.filter { now.timeIntervalSince($0.value.time) < deduplicationWindow }
    }
}
