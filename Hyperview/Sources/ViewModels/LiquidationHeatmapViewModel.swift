import SwiftUI
import Combine

// MARK: - Models

struct HeatmapSnapshot: Decodable {
    let t: Double           // timestamp ms
    let mp: Double          // mark price
    let b: [[Double]]       // [[priceMid, totalUSD], ...]
}

struct HeatmapResponse: Decodable {
    let coin: String
    let snapshotCount: Int
    let intervalMs: Int
    let priceRange: HeatmapPriceRange?
    let maxIntensity: Double
    let snapshots: [HeatmapSnapshot]
}

struct HeatmapPriceRange: Decodable {
    let min: Double
    let max: Double
}

// MARK: - ViewModel

@MainActor
final class LiquidationHeatmapViewModel: ObservableObject {
    @Published var snapshots: [HeatmapSnapshot] = []
    @Published var maxIntensity: Double = 0
    @Published var priceRange: HeatmapPriceRange?
    @Published var selectedCoin: String = "BTC"
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showCoinPicker = false

    // Available coins for heatmap
    let availableCoins = ["BTC", "ETH", "SOL", "HYPE", "XRP", "DOGE", "SUI", "LINK", "AVAX", "ADA", "PEPE", "WIF", "ARB", "OP", "TIA", "JUP", "W", "ONDO", "SEI", "INJ"]

    private static let backendBaseURL = "https://hyperview-backend-production-075c.up.railway.app"
    private var pollTimer: AnyCancellable?

    init() {}

    func startPolling() {
        guard pollTimer == nil else { return }
        Task { await fetch() }
        pollTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else { return }
                Task { await self?.fetch() }
            }
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    func changeCoin(_ coin: String) {
        selectedCoin = coin
        snapshots = []
        priceRange = nil
        maxIntensity = 0
        Task { await fetch() }
    }

    func fetch() async {
        guard let url = URL(string: "\(Self.backendBaseURL)/liquidation-heatmap-history?coin=\(selectedCoin)") else { return }

        if snapshots.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(HeatmapResponse.self, from: data)
            snapshots = response.snapshots
            maxIntensity = response.maxIntensity
            priceRange = response.priceRange
            errorMessage = nil
        } catch {
            if snapshots.isEmpty {
                errorMessage = "Failed to load heatmap"
            }
        }
    }
}
