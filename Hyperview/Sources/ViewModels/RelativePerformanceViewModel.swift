import Foundation
import SwiftUI
import Combine

@MainActor
final class RelativePerformanceViewModel: ObservableObject {

    // MARK: - Types

    enum Timeframe: String, CaseIterable {
        case oneDay      = "1D"
        case sevenDay    = "7D"
        case thirtyDay   = "30D"
        case oneYear     = "1Y"

        var seconds: Int64 {
            switch self {
            case .oneDay:      return 86_400
            case .sevenDay:    return 7 * 86_400
            case .thirtyDay:   return 30 * 86_400
            case .oneYear:     return 365 * 86_400
            }
        }

        var candleInterval: ChartInterval {
            switch self {
            case .oneDay:      return .fifteenMin
            case .sevenDay:    return .fourHour
            case .thirtyDay:   return .oneDay
            case .oneYear:     return .oneWeek
            }
        }
    }

    struct CoinRow: Identifiable {
        let id = UUID()
        let symbol: String
        /// Relative performance per timeframe: (1 + hypeChange) / (1 + coinChange) - 1
        let relativeByTF: [Timeframe: Double]
    }

    // MARK: - Sort

    @Published var sortTF: Timeframe = .sevenDay
    @Published var sortAscending: Bool = false

    // MARK: - Published

    @Published var rows: [CoinRow] = []
    @Published var isLoading = false
    private var unsortedRows: [CoinRow] = []

    // MARK: - Config

    static let comparisonCoins = ["BTC", "ETH", "SOL", "BNB", "AAVE", "XRP", "SUI", "AVAX", "ENA", "LIT", "PENDLE"]

    private let api = HyperliquidAPI.shared

    // MARK: - Load all timeframes at once

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let allCoins = ["HYPE"] + Self.comparisonCoins
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // For each (coin, timeframe) pair, fetch the % change concurrently
        // Key: "COIN:TF"
        var changeMap: [String: Double] = [:]

        await withTaskGroup(of: (String, Double?).self) { group in
            for coin in allCoins {
                for tf in Timeframe.allCases {
                    let key = "\(coin):\(tf.rawValue)"
                    let startMs = nowMs - tf.seconds * 1000
                    group.addTask { [weak self] in
                        guard let self else { return (key, nil) }
                        let change = await self.fetchChange(
                            coin: coin, startMs: startMs, endMs: nowMs,
                            interval: tf.candleInterval
                        )
                        return (key, change)
                    }
                }
            }
            for await (key, change) in group {
                if let change { changeMap[key] = change }
            }
        }

        // Build rows
        var result: [CoinRow] = []
        for coin in Self.comparisonCoins {
            var relMap: [Timeframe: Double] = [:]
            for tf in Timeframe.allCases {
                let hypeKey = "HYPE:\(tf.rawValue)"
                let coinKey = "\(coin):\(tf.rawValue)"
                if let hc = changeMap[hypeKey], let cc = changeMap[coinKey], (1 + cc) != 0 {
                    // Correct ratio formula: HYPE/COIN relative performance
                    relMap[tf] = (1 + hc) / (1 + cc) - 1
                }
            }
            if !relMap.isEmpty {
                result.append(CoinRow(symbol: coin, relativeByTF: relMap))
            }
        }

        unsortedRows = result
        applySorting()
    }

    func toggleSort(_ tf: Timeframe) {
        if sortTF == tf {
            sortAscending.toggle()
        } else {
            sortTF = tf
            sortAscending = false   // default descending (best first)
        }
        applySorting()
    }

    private func applySorting() {
        let tf = sortTF
        let asc = sortAscending
        rows = unsortedRows.sorted {
            let a = $0.relativeByTF[tf] ?? -.infinity
            let b = $1.relativeByTF[tf] ?? -.infinity
            return asc ? a < b : a > b
        }
    }

    // MARK: - Helpers

    private func fetchChange(coin: String, startMs: Int64, endMs: Int64, interval: ChartInterval) async -> Double? {
        do {
            let candles = try await api.fetchCandlesRange(
                coin: coin, interval: interval,
                startMs: startMs, endMs: endMs
            )
            guard let first = candles.first, let last = candles.last,
                  first.open > 0 else { return nil }
            return (last.close - first.open) / first.open
        } catch {
            return nil
        }
    }
}
