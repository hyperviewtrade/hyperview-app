import SwiftUI
import Combine

// MARK: - HomeViewModel
// Manages the smart money activity feed:
//  - 1-second aggregation buffer before UI update
//  - 10-second window for aggregating same-asset/direction whale trades

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var events:         [SmartMoneyEvent] = [] {
        didSet { recomputeFilteredEvents() }
    }
    @Published var selectedFilter: FeedFilter        = .home {
        didSet { recomputeFilteredEvents() }
    }
    @Published var isLive          = false

    /// Cached filtered events — recomputed when events or selectedFilter changes.
    @Published private(set) var filteredEvents: [SmartMoneyEvent] = []

    private let service = SmartMoneyService.shared
    private var cancellables = Set<AnyCancellable>()

    // 1-second UI buffer
    private var pendingEvents: [SmartMoneyEvent] = []
    private var bufferTimer:   AnyCancellable?

    // 10-second aggregation window
    private let aggregationWindowSeconds: TimeInterval = 10
    private let maxFeedSize = 120

    /// Maps (asset + direction) -> index in events array for O(1) whale aggregation.
    private var whaleAggregationIndex: [String: Int] = [:]

    init() {
        subscribeToEvents()
        startBuffer()
    }

    // MARK: - Filtered events cache

    private func recomputeFilteredEvents() {
        if selectedFilter == .home {
            filteredEvents = events
        } else {
            filteredEvents = events.filter { $0.filter == selectedFilter }
        }
    }

    // MARK: - Start feed

    func start(markets: [Market]) {
        service.start(markets: markets)
        isLive = true
    }

    // MARK: - Subscription

    private func subscribeToEvents() {
        service.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.pendingEvents.append(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - 1-Second Buffer flush

    private func startBuffer() {
        bufferTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.flushBuffer() }
    }

    private func flushBuffer() {
        guard !pendingEvents.isEmpty else { return }
        let batch = pendingEvents
        pendingEvents.removeAll()
        for event in batch { insertOrAggregate(event) }
        if events.count > maxFeedSize {
            events = Array(events.prefix(maxFeedSize))
            rebuildWhaleAggregationIndex()
        }
    }

    // MARK: - 10-Second Whale Aggregation

    /// Generates the lookup key for whale aggregation: "asset|direction"
    private func whaleKey(asset: String, isLong: Bool) -> String {
        "\(asset)|\(isLong ? "L" : "S")"
    }

    /// Rebuilds the whale aggregation index from scratch. Called after trimming events.
    private func rebuildWhaleAggregationIndex() {
        whaleAggregationIndex.removeAll(keepingCapacity: true)
        let cutoff = Date().addingTimeInterval(-aggregationWindowSeconds)
        for (idx, existing) in events.enumerated() {
            if case .whaleTrade(let stored) = existing,
               stored.timestamp > cutoff {
                let key = whaleKey(asset: stored.asset, isLong: stored.isLong)
                // Keep the first (most recent) match per key
                if whaleAggregationIndex[key] == nil {
                    whaleAggregationIndex[key] = idx
                }
            }
        }
    }

    private func insertOrAggregate(_ event: SmartMoneyEvent) {
        if case .whaleTrade(let incoming) = event {
            let key = whaleKey(asset: incoming.asset, isLong: incoming.isLong)
            let cutoff = Date().addingTimeInterval(-aggregationWindowSeconds)

            // O(1) lookup via dictionary
            if let idx = whaleAggregationIndex[key],
               idx < events.count,
               case .whaleTrade(var stored) = events[idx],
               stored.asset == incoming.asset,
               stored.isLong == incoming.isLong,
               stored.timestamp > cutoff {
                stored.whaleCount    += 1
                stored.totalSizeUSD  += incoming.sizeUSD
                stored.currentPrice   = incoming.currentPrice
                events[idx] = .whaleTrade(stored)
                return
            }

            // No match found — insert at front and update index.
            // Shift all existing indices by +1 since we're inserting at position 0.
            var shifted: [String: Int] = [:]
            shifted.reserveCapacity(whaleAggregationIndex.count + 1)
            for (k, v) in whaleAggregationIndex {
                shifted[k] = v + 1
            }
            shifted[key] = 0
            whaleAggregationIndex = shifted
            events.insert(event, at: 0)
            return
        }
        // Non-whale events: shift indices and insert
        var shifted: [String: Int] = [:]
        shifted.reserveCapacity(whaleAggregationIndex.count)
        for (k, v) in whaleAggregationIndex {
            shifted[k] = v + 1
        }
        whaleAggregationIndex = shifted
        events.insert(event, at: 0)
    }
}
