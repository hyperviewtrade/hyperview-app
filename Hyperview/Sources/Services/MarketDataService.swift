import Foundation
import Combine

/// Centralized market data service — single source of truth for metaAndAssetCtxs.
/// Eliminates duplicate fetching between MarketsViewModel and AnalyticsViewModel.
@MainActor
final class MarketDataService: ObservableObject {
    static let shared = MarketDataService()

    /// Raw parsed response from metaAndAssetCtxs (perp markets only)
    @Published private(set) var latestPerps: [[String: Any]] = []
    /// Raw contexts array
    @Published private(set) var latestContexts: [[String: Any]] = []
    /// Timestamp of last successful fetch
    private(set) var lastFetchTime: Date = .distantPast

    /// Publisher that fires when new data arrives
    let dataUpdated = PassthroughSubject<Void, Never>()

    private var pollTimer: Timer?
    private var isPolling = false

    private init() {}

    /// Fetch metaAndAssetCtxs if stale (older than cacheTTL seconds)
    func fetchIfNeeded(cacheTTL: TimeInterval = 55) async -> ([[String: Any]], [[String: Any]])? {
        if Date().timeIntervalSince(lastFetchTime) < cacheTTL && !latestPerps.isEmpty {
            return (latestPerps, latestContexts)
        }
        return await fetchNow()
    }

    /// Force fetch regardless of cache
    @discardableResult
    func fetchNow() async -> ([[String: Any]], [[String: Any]])? {
        do {
            let data = try await HyperliquidAPI.shared.post(body: ["type": "metaAndAssetCtxs"])
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 2,
                  let metaDict = arr[0] as? [String: Any],
                  let universe = metaDict["universe"] as? [[String: Any]],
                  let contexts = arr[1] as? [[String: Any]]
            else { return nil }

            latestPerps = universe
            latestContexts = contexts
            lastFetchTime = Date()
            dataUpdated.send()
            return (universe, contexts)
        } catch {
            print("[MarketDataService] fetchNow error: \(error)")
            return nil
        }
    }

    /// Start 60-second polling (for analytics OI tracking)
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchNow()
            }
        }
    }

    func stopPolling() {
        isPolling = false
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
