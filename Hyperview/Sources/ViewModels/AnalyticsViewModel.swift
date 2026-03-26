import Foundation
import SwiftUI
import Combine

@MainActor
final class AnalyticsViewModel: ObservableObject {
    // Dashboard data — sourced from MarketsViewModel
    @Published var topOIMarkets: [OIMarketRow] = []
    @Published var globalStats: GlobalStats = GlobalStats()
    @Published var selectedCoin: String = "BTC" {
        didSet { recomputeSelectedCoinHistory() }
    }

    // OI History tracker
    @Published var oiHistory: [OIDataPoint] = [] {
        didSet { recomputeSelectedCoinHistory() }
    }
    @Published var selectedSort: OISortOption = .oi

    /// Cached filtered + sorted OI history for the selected coin.
    @Published private(set) var selectedCoinHistory: [OIDataPoint] = []

    enum OISortOption: String, CaseIterable {
        case oi = "OI"
        case funding = "Funding"
        case volume = "Volume"
    }

    private var cancellables = Set<AnyCancellable>()

    // Persist OI history across app launches
    private let historyKey = "hl_oi_history"
    private let maxPointsPerCoin = 1440 // 24h at 1 point/min

    func start(markets: [Market]) {
        updateDashboard(markets: markets)
        loadPersistedHistory()
        // Subscribe to MarketDataService for shared OI polling
        MarketDataService.shared.startPolling()
        MarketDataService.shared.dataUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.pollOI()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        MarketDataService.shared.stopPolling()
        cancellables.removeAll()
    }

    func updateDashboard(markets: [Market]) {
        // Filter perp markets only
        let perps = markets.filter { $0.marketType == .perp }

        // Top OI markets — openInterest is in coin units, multiply by price for USD
        var rows = perps.map { m in
            OIMarketRow(
                coin: m.displayName,
                symbol: m.symbol,
                openInterest: m.openInterest * m.price,
                fundingRate: m.funding,
                volume24h: m.volume24h
            )
        }

        switch selectedSort {
        case .oi:      rows.sort { $0.openInterest > $1.openInterest }
        case .funding: rows.sort { abs($0.fundingRate) > abs($1.fundingRate) }
        case .volume:  rows.sort { $0.volume24h > $1.volume24h }
        }

        topOIMarkets = Array(rows.prefix(20))

        // Global stats — OI in USD, volume already in USD
        let totalOI  = perps.reduce(0.0) { $0 + $1.openInterest * $1.price }
        let totalVol = perps.reduce(0.0) { $0 + $1.volume24h }
        let avgFunding = perps.isEmpty
            ? 0
            : perps.reduce(0.0) { $0 + $1.funding } / Double(perps.count)
        globalStats = GlobalStats(totalOI: totalOI, totalVolume24h: totalVol, avgFunding: avgFunding)
    }

    // MARK: - OI Polling (via MarketDataService)

    private func pollOI() async {
        guard let (universe, ctxs) = await MarketDataService.shared.fetchIfNeeded() else {
            print("[Analytics] OI poll: no data from MarketDataService")
            return
        }

        let now = Date()
        var newPoints: [OIDataPoint] = []

        for (i, ctx) in ctxs.enumerated() where i < universe.count {
            let coin = universe[i]["name"] as? String ?? ""
            let oiStr = ctx["openInterest"] as? String ?? "0"
            let markStr = ctx["markPx"] as? String ?? "0"
            let oi = (Double(oiStr) ?? 0) * (Double(markStr) ?? 0) // OI in USD
            if oi > 0 {
                newPoints.append(OIDataPoint(coin: coin, oi: oi, timestamp: now))
            }
        }

        // Append and trim
        oiHistory.append(contentsOf: newPoints)
        trimHistory()
        persistHistory()
    }

    /// Recomputes the cached selected coin history from oiHistory.
    private func recomputeSelectedCoinHistory() {
        selectedCoinHistory = oiHistory
            .filter { $0.coin == selectedCoin }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - History management

    private func trimHistory() {
        // Group by coin, keep max points per coin
        var byCoin: [String: [OIDataPoint]] = [:]
        for point in oiHistory {
            byCoin[point.coin, default: []].append(point)
        }
        var trimmed: [OIDataPoint] = []
        for (_, points) in byCoin {
            let sorted = points.sorted { $0.timestamp < $1.timestamp }
            trimmed.append(contentsOf: sorted.suffix(maxPointsPerCoin))
        }
        oiHistory = trimmed
    }

    private func persistHistory() {
        // Persist last ~2000 points to UserDefaults
        let recent = oiHistory.suffix(2000)
        let encoded = recent.map {
            ["c": $0.coin, "o": $0.oi, "t": $0.timestamp.timeIntervalSince1970] as [String: Any]
        }
        UserDefaults.standard.set(encoded, forKey: historyKey)
    }

    private func loadPersistedHistory() {
        guard let arr = UserDefaults.standard.array(forKey: historyKey) as? [[String: Any]] else { return }
        oiHistory = arr.compactMap { dict in
            guard let coin = dict["c"] as? String,
                  let oi = dict["o"] as? Double,
                  let ts = dict["t"] as? Double else { return nil }
            return OIDataPoint(coin: coin, oi: oi, timestamp: Date(timeIntervalSince1970: ts))
        }
    }
}

// MARK: - Models

struct OIMarketRow: Identifiable {
    let id = UUID()
    let coin: String
    let symbol: String
    let openInterest: Double   // USD
    let fundingRate: Double
    let volume24h: Double      // USD
}

struct OIDataPoint: Identifiable {
    let id = UUID()
    let coin: String
    let oi: Double             // USD
    let timestamp: Date
}

struct GlobalStats {
    var totalOI: Double = 0
    var totalVolume24h: Double = 0
    var avgFunding: Double = 0
}
