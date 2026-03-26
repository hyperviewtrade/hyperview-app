import Foundation

// MARK: - Feed Filter

enum FeedFilter: String, CaseIterable, Identifiable {
    case home         = "Home"
    case whales       = "Whales"
    case liquidations = "Liquidations"
    case heatmap      = "Heatmap"
    case topTraders   = "Top Traders"
    case twap         = "TWAP"
    case signals      = "Signals"
    case staking      = "Staking"
    case earn         = "Earn"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .home:         return "Home"
        case .whales:       return "🐋 Whales"
        case .liquidations: return "💥 Liquidations"
        case .heatmap:      return "🔥 Heatmap"
        case .topTraders:   return "🏆 Top Traders"
        case .twap:         return "⏱ TWAP"
        case .signals:      return "📊 Analytics"
        case .staking:      return "🔐 Staking"
        case .earn:         return "💰 Earn"
        }
    }
}

// MARK: - Smart Money Event

enum SmartMoneyEvent: Identifiable {
    case whaleTrade(WhaleTradeEvent)
    case liquidation(LiquidationEvent)
    case topTraderMove(TopTraderEvent)
    case signal(SignalEvent)
    case staking(StakingEvent)
    case oiSurge(OISurgeEvent)

    var id: String {
        switch self {
        case .whaleTrade(let e):    return e.id
        case .liquidation(let e):   return e.id
        case .topTraderMove(let e): return e.id
        case .signal(let e):        return e.id
        case .staking(let e):       return e.id
        case .oiSurge(let e):       return e.id
        }
    }

    var timestamp: Date {
        switch self {
        case .whaleTrade(let e):    return e.timestamp
        case .liquidation(let e):   return e.timestamp
        case .topTraderMove(let e): return e.timestamp
        case .signal(let e):        return e.timestamp
        case .staking(let e):       return e.timestamp
        case .oiSurge(let e):       return e.timestamp
        }
    }

    var filter: FeedFilter {
        switch self {
        case .whaleTrade:    return .whales
        case .liquidation:   return .liquidations
        case .topTraderMove: return .topTraders
        case .signal:        return .signals
        case .staking:       return .staking
        case .oiSurge:       return .signals
        }
    }
}

// MARK: - Whale Trade Event

struct WhaleTradeEvent: Identifiable {
    var id: String
    let asset: String
    let isLong: Bool
    let sizeUSD: Double
    let entryPrice: Double
    var currentPrice: Double
    let walletAddress: String
    let timestamp: Date
    // Aggregation
    var whaleCount: Int
    var totalSizeUSD: Double

    var shortAddress: String {
        guard walletAddress.count > 10 else { return walletAddress }
        return "\(walletAddress.prefix(6))…\(walletAddress.suffix(4))"
    }

    var formattedSize: String { formatUSD(totalSizeUSD) }
    var formattedEntryPrice: String { formatPrice(entryPrice) }
    var formattedCurrentPrice: String { formatPrice(currentPrice) }

    private func formatUSD(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "$%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "$%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "$%.0fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "$%.1f", p) }
        if p >= 1      { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }
}

// MARK: - Liquidation Event

struct LiquidationEvent: Identifiable {
    let id: String
    let asset: String
    let sizeUSD: Double
    let wasLong: Bool
    let walletAddress: String
    let timestamp: Date

    var shortAddress: String {
        guard walletAddress.count > 10 else { return walletAddress }
        return "\(walletAddress.prefix(6))…\(walletAddress.suffix(4))"
    }

    var formattedSize: String {
        if sizeUSD >= 1_000_000 { return String(format: "$%.1fM", sizeUSD / 1_000_000) }
        if sizeUSD >= 1_000     { return String(format: "$%.0fK", sizeUSD / 1_000) }
        return String(format: "$%.0f", sizeUSD)
    }
}

// MARK: - Top Trader Event

struct TopTraderEvent: Identifiable {
    let id: String
    let asset: String
    let isLong: Bool
    let sizeUSD: Double
    let entryPrice: Double
    let exitPrice: Double?
    let pnl: Double
    let winrate: Double
    let walletAddress: String
    let timestamp: Date

    var shortAddress: String {
        guard walletAddress.count > 10 else { return walletAddress }
        return "\(walletAddress.prefix(6))…\(walletAddress.suffix(4))"
    }

    var isClosed: Bool { exitPrice != nil }

    var formattedPnl: String {
        let sign = pnl >= 0 ? "+" : "-"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        let formatted = formatter.string(from: NSNumber(value: abs(pnl))) ?? String(format: "%.2f", abs(pnl))
        return "PNL : \(sign)$\(formatted)"
    }

    var formattedROI: String {
        guard sizeUSD > 0 else { return "—" }
        let roi = (pnl / sizeUSD) * 100
        let sign = roi >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", roi))%"
    }

    var formattedWinrate: String { "\(Int(winrate * 100))%" }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "$%.1f", p) }
        if p >= 1      { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }

    var formattedEntry: String { formatPrice(entryPrice) }
    var formattedExit: String  { exitPrice.map { formatPrice($0) } ?? "—" }
    var formattedSize: String {
        if sizeUSD >= 1_000_000 { return String(format: "$%.1fM", sizeUSD / 1_000_000) }
        if sizeUSD >= 1_000     { return String(format: "$%.0fK", sizeUSD / 1_000) }
        return String(format: "$%.0f", sizeUSD)
    }
}

// MARK: - Signal Event

enum SignalType: String {
    case crowdedTrade = "Crowded Trade"
    case fundingSpike = "Funding Spike"
    case oiSpike      = "OI Spike"
}

struct SignalEvent: Identifiable {
    let id: String
    let asset: String
    let signalType: SignalType
    let longPercent: Double
    let shortPercent: Double
    let value: Double
    let timestamp: Date

    var formattedLong:  String { "\(Int(longPercent  * 100))% Long" }
    var formattedShort: String { "\(Int(shortPercent * 100))% Short" }

    var formattedValue: String {
        switch signalType {
        case .fundingSpike:
            return String(format: "%.4f%%", value * 100)
        case .oiSpike:
            if abs(value) >= 1_000_000 { return String(format: "$%.1fM", value / 1_000_000) }
            return String(format: "$%.0fK", value / 1_000)
        case .crowdedTrade:
            return String(format: "%.0f%%", longPercent * 100)
        }
    }
}

// MARK: - Staking Event

struct StakingEvent: Identifiable {
    let id: String
    let walletAddress: String
    let amountHYPE: Double
    let usdValue: Double
    let isStaking: Bool
    let unstakingCompletesAt: Date?
    let timestamp: Date

    var shortAddress: String {
        guard walletAddress.count > 10 else { return walletAddress }
        return "\(walletAddress.prefix(6))…\(walletAddress.suffix(4))"
    }

    var formattedAmount: String {
        if amountHYPE >= 1_000_000 { return String(format: "%.1fM HYPE", amountHYPE / 1_000_000) }
        if amountHYPE >= 1_000     { return String(format: "%.1fK HYPE", amountHYPE / 1_000) }
        return String(format: "%.0f HYPE", amountHYPE)
    }

    var formattedUSD: String {
        if usdValue >= 1_000_000 { return String(format: "$%.1fM", usdValue / 1_000_000) }
        if usdValue >= 1_000     { return String(format: "$%.0fK", usdValue / 1_000) }
        return String(format: "$%.0f", usdValue)
    }

    var remainingUnstakingTime: String? {
        guard let end = unstakingCompletesAt else { return nil }
        let diff = Int(end.timeIntervalSinceNow)
        guard diff > 0 else { return "Ready to claim" }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        if days > 0 { return "\(days)d \(hours)h remaining" }
        return "\(hours)h remaining"
    }
}

// MARK: - OI Surge Event

struct OISurgeEvent: Identifiable {
    let id: String
    let asset: String
    let oiChangeUSD: Double
    let windowMinutes: Int
    let timestamp: Date

    var formattedOI: String {
        let sign = oiChangeUSD >= 0 ? "+" : ""
        if abs(oiChangeUSD) >= 1_000_000_000 {
            return "\(sign)$\(String(format: "%.1fB", oiChangeUSD / 1_000_000_000))"
        }
        if abs(oiChangeUSD) >= 1_000_000 {
            return "\(sign)$\(String(format: "%.0fM", oiChangeUSD / 1_000_000))"
        }
        return "\(sign)$\(String(format: "%.0fK", oiChangeUSD / 1_000))"
    }
}
