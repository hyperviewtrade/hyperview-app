import SwiftUI
import Combine

// MARK: - Data types

struct PortfolioPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

enum PortfolioTimeframe: String, CaseIterable, Identifiable {
    case day     = "24H"
    case week    = "1W"
    case month   = "1M"
    case allTime = "ALL"

    var id: String { rawValue }

    /// Maps to the API period keys (combined, not perp-only)
    var apiKey: String {
        switch self {
        case .day:     return "day"
        case .week:    return "week"
        case .month:   return "month"
        case .allTime: return "allTime"
        }
    }

    /// Perp-specific API key (e.g. "perpDay", "perpAllTime")
    var perpApiKey: String {
        switch self {
        case .day:     return "perpDay"
        case .week:    return "perpWeek"
        case .month:   return "perpMonth"
        case .allTime: return "perpAllTime"
        }
    }
}

enum PortfolioMetric: String, CaseIterable, Identifiable {
    case pnl          = "PnL"
    case accountValue = "Account Value"

    var id: String { rawValue }
}

enum PnlScope: String, CaseIterable, Identifiable {
    case all   = "All"
    case perp  = "Perps"
    case spot  = "Spot"

    var id: String { rawValue }
}

// MARK: - ViewModel

@MainActor
final class PortfolioChartViewModel: ObservableObject {
    @Published var timeframe: PortfolioTimeframe = .allTime
    @Published var metric: PortfolioMetric = .pnl
    @Published var pnlScope: PnlScope = .all

    @Published var points: [PortfolioPoint] = []
    @Published var volume: Double = 0
    @Published var isLoading = false
    @Published var errorMsg: String?

    /// Currently touched point (drag gesture)
    @Published var selectedIndex: Int?

    // Raw data cache — keyed by API period
    private var cache: [String: (acctValue: [PortfolioPoint], pnl: [PortfolioPoint], vlm: Double)] = [:]
    private(set) var hasFetched = false

    private let api = HyperliquidAPI.shared

    // MARK: - Computed

    var currentValue: Double {
        if let idx = selectedIndex, idx >= 0, idx < points.count {
            return points[idx].value
        }
        return points.last?.value ?? 0
    }

    var currentDate: Date? {
        if let idx = selectedIndex, idx >= 0, idx < points.count {
            return points[idx].timestamp
        }
        return nil
    }

    var isPositive: Bool { currentValue >= 0 }

    /// Address being displayed (set by caller)
    var displayAddress: String = ""

    /// All-time stats from portfolio API (for overview)
    var allTimeVolume: Double { cache["allTime"]?.vlm ?? 0 }
    var allTimePnl: Double {
        let raw = cache["allTime"]?.pnl.last?.value ?? 0
        // Assistance Fund: perp PNL is an artifact (fees counted as PNL).
        // Use combined - perp = spot only.
        if displayAddress.lowercased() == "0xfefefefefefefefefefefefefefefefefefefefe" {
            let perpPnl = cache["perpAllTime"]?.pnl.last?.value ?? 0
            return raw - perpPnl
        }
        return raw
    }

    /// Label shown above the chart value
    var scopeLabel: String {
        guard metric == .pnl else { return "Account Value" }
        switch pnlScope {
        case .all:  return "All PnL (Combined)"
        case .perp: return "Perp PnL"
        case .spot: return "Spot PnL"
        }
    }

    /// Perp win rate — % of periods with positive PnL change (from perpAllTime history)
    var perpWinRate: Double {
        guard let perpPnl = cache["perpAllTime"]?.pnl, perpPnl.count >= 2 else { return 0 }
        var wins = 0
        var total = 0
        for i in 1..<perpPnl.count {
            let change = perpPnl[i].value - perpPnl[i - 1].value
            if abs(change) > 0.01 {  // Ignore negligible rounding
                total += 1
                if change > 0 { wins += 1 }
            }
        }
        return total == 0 ? 0 : Double(wins) / Double(total)
    }

    /// Best single-period PnL gain (from perpAllTime history)
    var perpBestPeriod: Double {
        guard let perpPnl = cache["perpAllTime"]?.pnl, perpPnl.count >= 2 else { return 0 }
        var best = 0.0
        for i in 1..<perpPnl.count {
            let change = perpPnl[i].value - perpPnl[i - 1].value
            if change > best { best = change }
        }
        return best
    }

    var chartColor: Color {
        // For PnL: green if positive, red if negative
        // For Account Value: compare last vs first
        if metric == .pnl {
            return currentValue >= 0 ? .hlGreen : .tradingRed
        } else {
            let first = points.first?.value ?? 0
            let last = points.last?.value ?? 0
            return last >= first ? .hlGreen : .tradingRed
        }
    }

    // MARK: - Load

    nonisolated func startLoad(address: String) {
        Task { @MainActor [weak self] in
            await self?.load(address: address)
        }
    }

    func load(address: String) async {
        // Retry if fetched but got no data and account has value
        if hasFetched && points.count < 2 && WalletManager.shared.accountValue > 1 && !isLoading {
            print("[PORTFOLIO] Empty points but account has value, retrying...")
            hasFetched = false
            cache.removeAll()
        }
        guard !hasFetched, !isLoading else { return }
        isLoading = true
        errorMsg = nil
        do {
            let raw = try await api.fetchPortfolio(address: address)
            parseAll(raw)
            hasFetched = true
            applySelection()

            // Note: accountValue is owned by WalletManager REST refresh only.
            // PortfolioChartViewModel must NOT write to WalletManager.shared.accountValue
            // as that would overwrite the authoritative REST-sourced balance.
        } catch is CancellationError {
            // Swipe cancelled — ignore silently
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession cancelled — ignore silently
        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    func refresh(address: String) async {
        hasFetched = false
        cache.removeAll()
        await load(address: address)
    }

    // MARK: - Selection changes

    func selectTimeframe(_ tf: PortfolioTimeframe) {
        timeframe = tf
        selectedIndex = nil
        applySelection()
    }

    func selectMetric(_ m: PortfolioMetric) {
        metric = m
        selectedIndex = nil
        applySelection()
    }

    func selectPnlScope(_ scope: PnlScope) {
        pnlScope = scope
        selectedIndex = nil
        applySelection()
    }

    // MARK: - Parse

    private func parseAll(_ raw: [[String: Any]]) {
        // Cache all periods: combined + perp (for scope toggle)
        let accepted: Set<String> = [
            "day", "week", "month", "allTime",
            "perpDay", "perpWeek", "perpMonth", "perpAllTime"
        ]
        for entry in raw {
            guard let period = entry["period"] as? String,
                  accepted.contains(period)
            else { continue }

            let acctHistory = parseHistory(entry["accountValueHistory"])
            let pnlHistory  = parseHistory(entry["pnlHistory"])
            let vlm: Double
            if let vlmStr = entry["vlm"] as? String, let v = Double(vlmStr) {
                vlm = v
            } else {
                vlm = 0
            }
            cache[period] = (acctValue: acctHistory, pnl: pnlHistory, vlm: vlm)
        }
    }

    private func parseHistory(_ raw: Any?) -> [PortfolioPoint] {
        guard let arr = raw as? [[Any]] else { return [] }
        return arr.compactMap { item -> PortfolioPoint? in
            guard item.count >= 2 else { return nil }
            let ts: Double
            if let n = item[0] as? Double { ts = n }
            else if let n = item[0] as? Int64 { ts = Double(n) }
            else if let n = item[0] as? Int { ts = Double(n) }
            else if let n = item[0] as? NSNumber { ts = n.doubleValue }
            else { return nil }

            let val: Double
            if let s = item[1] as? String, let v = Double(s) { val = v }
            else if let v = item[1] as? Double { val = v }
            else if let n = item[1] as? NSNumber { val = n.doubleValue }
            else { return nil }

            return PortfolioPoint(
                timestamp: Date(timeIntervalSince1970: ts / 1000),
                value: val
            )
        }
    }

    private func applySelection() {
        let combinedKey = timeframe.apiKey   // "day", "week", "month", "allTime"
        let perpKey     = timeframe.perpApiKey // "perpDay", ..., "perpAllTime"

        switch (metric, pnlScope) {
        case (.accountValue, _):
            // Account value always uses combined
            let data = cache[combinedKey]
            points = data?.acctValue ?? []
            volume = data?.vlm ?? 0

        case (.pnl, .all):
            let data = cache[combinedKey]
            points = data?.pnl ?? []
            volume = data?.vlm ?? 0

        case (.pnl, .perp):
            let data = cache[perpKey]
            points = data?.pnl ?? []
            volume = data?.vlm ?? 0

        case (.pnl, .spot):
            let combined = cache[combinedKey]
            let perp     = cache[perpKey]
            // Spot PnL = combined PnL - perp PnL (point by point)
            if let cPnl = combined?.pnl, let pPnl = perp?.pnl {
                let count = min(cPnl.count, pPnl.count)
                points = (0..<count).map { i in
                    PortfolioPoint(
                        timestamp: cPnl[i].timestamp,
                        value: cPnl[i].value - pPnl[i].value
                    )
                }
            } else {
                points = combined?.pnl ?? []
            }
            volume = max((combined?.vlm ?? 0) - (perp?.vlm ?? 0), 0)
        }
    }
}
