import Foundation

// MARK: - HIP-4 Outcome Market Models

/// A single outcome within a question. Has two sides (usually Yes/No, but can be custom).
struct OutcomeMarket: Identifiable {
    let id: String              // "outcome:<outcomeId>" for stable SwiftUI diffing
    let outcomeId: Int
    let name: String            // e.g. "Akami", "100m dash", "Recurring"
    let description: String

    // Side specs — the two sides of this outcome (e.g. Yes/No, Hypurr/Usain Bolt)
    let sides: [OutcomeSide]

    // Parsed priceBinary fields (nil for event predictions)
    var priceBinary: PriceBinaryInfo?

    /// Whether sides are standard Yes/No or custom names
    var hasCustomSides: Bool {
        guard sides.count == 2 else { return true }
        let names = Set(sides.map { $0.name.lowercased() })
        return !names.isSubset(of: ["yes", "no"])
    }

    /// Price of side 0 (typically "Yes" or first custom side)
    var side0Price: Double { sides.first?.price ?? 0.5 }

    /// Price of side 1 (typically "No" or second custom side)
    var side1Price: Double { sides.count > 1 ? sides[1].price : 0.5 }

    /// Human-readable probability (side 0)
    var probabilityFormatted: String {
        String(format: "%.1f%%", side0Price * 100)
    }

    /// Whether this is a priceBinary (options-like) market
    var isOption: Bool { priceBinary != nil }

    /// Whether this is a pure event prediction market
    var isPrediction: Bool { priceBinary == nil }

    /// Short display symbol (e.g. "BTC above $70836")
    var displaySymbol: String {
        if let pb = priceBinary {
            return "\(pb.underlying) above \(pb.formattedStrike)"
        }
        return name
    }

    /// Full display with expiry (e.g. "BTC above $70836 · Mar 25, 15:45")
    var displaySymbolFull: String {
        if let pb = priceBinary {
            let expiry = pb.formattedExpiry
            return "\(pb.underlying) above \(pb.formattedStrike) · \(expiry)"
        }
        return name
    }

    /// Formatted volume
    var formattedVolume: String {
        let v = sides.reduce(0.0) { $0 + $1.volume }
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "%.1fK", v / 1_000) }
        if v > 0              { return String(format: "%.0f", v) }
        return "—"
    }
}

/// One side of an outcome (e.g. "Yes" at 0.65, or "Hypurr" at 0.84)
struct OutcomeSide: Identifiable {
    let id: String              // "side:<outcomeId>:<sideIndex>"
    let sideIndex: Int          // 0 or 1
    let name: String            // "Yes", "No", "Hypurr", "Usain Bolt"
    var price: Double           // 0–1
    var volume: Double

    /// Encoding for API: 10 * outcomeId + sideIndex
    var encoding: Int

    /// API coin: "#<encoding>"
    var apiCoin: String { "#\(encoding)" }
}

// MARK: - Question Group (groups outcomes by question)

/// A question that can have one or more outcomes.
/// "What will Hypurr eat?" → outcomes: [Akami, Otoro, Canned Tuna]
/// "Who wins the 100m dash?" → outcomes: [100m dash] (single, with custom sides)
struct OutcomeQuestion: Identifiable {
    let id: String              // "question:<questionId>"
    let questionId: Int
    let name: String            // "What will Hypurr eat the most of in Feb 2026?"
    let description: String
    let outcomes: [OutcomeMarket]

    /// 24h change of the Yes (side 0) price, in percentage points (e.g. +5.2 means Yes went from 60% to 65.2%).
    var yesChange24h: Double = 0

    /// Single outcome with custom sides (e.g. Hypurr vs Usain Bolt)
    var isBinarySingleOutcome: Bool {
        outcomes.count == 1 && outcomes.first?.hasCustomSides == true
    }

    /// Multi-outcome question (multiple things to bet on)
    var isMultiOutcome: Bool { outcomes.count > 1 }

    /// Simple binary Yes/No with single outcome
    var isSimpleBinary: Bool {
        outcomes.count == 1 && outcomes.first?.hasCustomSides == false
    }

    /// Whether any outcome is priceBinary (options)
    var isOption: Bool { outcomes.first?.isOption == true }
    var isPrediction: Bool { outcomes.first?.isPrediction == true }

    /// Display: for options show "BTC $70836", for predictions show question name
    var displayTitle: String {
        if isOption, let outcome = outcomes.first {
            return outcome.displaySymbol
        }
        return name
    }

    /// Summary subtitle
    var subtitle: String? {
        if isMultiOutcome {
            return "\(outcomes.count) outcomes"
        }
        return nil
    }
}

// MARK: - Price Binary Info (options-like markets)

/// Parsed metadata for priceBinary outcome markets.
/// Description format: "class:priceBinary|underlying:BTC|expiry:20260326-0300|targetPrice:70836|period:1d"
struct PriceBinaryInfo {
    let underlying: String
    let targetPrice: Double
    let expiry: Date?
    let period: String

    var formattedStrike: String {
        if targetPrice >= 10_000 { return String(format: "$%.0f", targetPrice) }
        if targetPrice >= 1      { return String(format: "$%.2f", targetPrice) }
        return String(format: "$%.4f", targetPrice)
    }

    var formattedExpiry: String {
        guard let expiry else { return "—" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: expiry)
    }

    /// Human-friendly expiry label: "Today 3:45 PM UTC" or "Mar 26, 3:00 AM UTC"
    var formattedExpiryFull: String {
        guard let expiry else { return "—" }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: "UTC")
        if cal.isDateInToday(expiry) {
            fmt.dateFormat = "'Today' h:mm a 'UTC'"
        } else if cal.isDateInTomorrow(expiry) {
            fmt.dateFormat = "'Tomorrow' h:mm a 'UTC'"
        } else {
            fmt.dateFormat = "MMM d, h:mm a 'UTC'"
        }
        return fmt.string(from: expiry)
    }

    var timeRemaining: String {
        guard let expiry else { return "—" }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        if remaining < 60 { return String(format: "%.0fs left", remaining) }
        if remaining < 3600 { return String(format: "%.0fm left", remaining / 60) }
        if remaining < 86400 { return String(format: "%.0fh left", remaining / 3600) }
        return String(format: "%.0fd left", remaining / 86400)
    }

    /// Period display name: "15m" → "15min period", "1h" → "1h period", "1d" → "1d period"
    var periodDisplay: String {
        if period.isEmpty { return "" }
        return "\(period) period"
    }

    var isExpired: Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSinceNow <= 0
    }

    static func parse(_ desc: String) -> PriceBinaryInfo? {
        guard desc.contains("class:priceBinary") else { return nil }
        var underlying = ""
        var targetPrice = 0.0
        var expiry: Date?
        var period = ""

        for part in desc.split(separator: "|") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let val = String(kv[1])
            switch key {
            case "underlying":  underlying = val
            case "targetPrice": targetPrice = Double(val) ?? 0
            case "period":      period = val
            case "expiry":
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyyMMdd-HHmm"
                fmt.timeZone = TimeZone(identifier: "UTC")
                expiry = fmt.date(from: val)
            default: break
            }
        }

        guard !underlying.isEmpty, targetPrice > 0 else { return nil }
        return PriceBinaryInfo(underlying: underlying, targetPrice: targetPrice,
                               expiry: expiry, period: period)
    }
}

// MARK: - API Response Models

struct OutcomeMetaResponse {
    let outcomes: [OutcomeEntry]
    let questions: [QuestionEntry]

    struct OutcomeEntry {
        let outcomeId: Int
        let name: String
        let description: String
        let sideSpecs: [(name: String, index: Int)]
    }

    struct QuestionEntry {
        let questionId: Int
        let name: String
        let description: String
        let fallbackOutcome: Int?
        let namedOutcomes: [Int]
        let settledNamedOutcomes: [Int]
    }
}

// MARK: - Options Sub-Categories

enum OptionsUnderlying: String, CaseIterable, Identifiable {
    case all  = "All"
    case btc  = "BTC"
    case eth  = "ETH"
    case hype = "HYPE"
    case sol  = "SOL"
    var id: String { rawValue }
}

enum OptionsPeriod: String, CaseIterable, Identifiable {
    case all  = "All"
    case m15  = "15m"
    case h1   = "1h"
    case d1   = "1d"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .m15: return "15min"
        case .h1:  return "1h"
        case .d1:  return "1d"
        }
    }
}
