import Foundation

/// Tracks data versions to ensure updates are applied in order and stale data is discarded.
/// Used for order book, positions, and price updates to prevent data drift.
@MainActor
final class DataVersionTracker {
    static let shared = DataVersionTracker()

    // MARK: - Version Tracking

    /// Monotonically increasing version per data type
    private var versions: [String: UInt64] = [:]

    /// Timestamps of last successful update
    private var lastUpdated: [String: Date] = [:]

    private init() {}

    // MARK: - Public API

    /// Generate next version for a data type. Returns the new version number.
    func nextVersion(for key: String) -> UInt64 {
        let current = versions[key] ?? 0
        let next = current + 1
        versions[key] = next
        lastUpdated[key] = Date()
        return next
    }

    /// Check if a version is current (not stale). Returns true if version >= current known version.
    func isCurrent(_ version: UInt64, for key: String) -> Bool {
        guard let current = versions[key] else { return true }
        return version >= current
    }

    /// Get time since last update for a data type
    func timeSinceUpdate(for key: String) -> TimeInterval {
        guard let last = lastUpdated[key] else { return .infinity }
        return Date().timeIntervalSince(last)
    }

    /// Check if data is stale (no update within maxAge seconds)
    func isStale(_ key: String, maxAge: TimeInterval) -> Bool {
        return timeSinceUpdate(for: key) > maxAge
    }

    /// Reset tracking for a data type (e.g., on symbol change)
    func reset(for key: String) {
        versions.removeValue(forKey: key)
        lastUpdated.removeValue(forKey: key)
    }

    /// Reset all tracking (e.g., on app background)
    func resetAll() {
        versions.removeAll()
        lastUpdated.removeAll()
    }

    // MARK: - Convenience Keys

    static let orderBook = "orderBook"
    static let positions = "positions"
    static let prices = "prices"
    static let candles = "candles"
    static let hip3Positions = "hip3Positions"
}
