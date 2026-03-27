import Foundation

// MARK: - Raw API types

enum MarketType { case perp, spot }

struct Asset: Codable {
    let name:         String
    let szDecimals:   Int
    let maxLeverage:  Int?       // optional — absent on some HIP-3 assets
    let onlyIsolated: Bool?
}

struct AssetContext: Codable {
    let funding:      String?
    let openInterest: String?
    let prevDayPx:    String?
    let dayNtlVlm:    String?
    let premium:      String?
    let oraclePx:     String?
    let markPx:       String?
    let midPx:        String?
    let impactPxs:    [String]?

    var markPrice:    Double { Double(markPx     ?? "0") ?? 0 }
    var prevDayPrice: Double { Double(prevDayPx  ?? "0") ?? 0 }
    var midPrice:     Double { Double(midPx      ?? "0") ?? 0 }
    var dayVolume:    Double { Double(dayNtlVlm  ?? "0") ?? 0 }
    var oi:           Double { Double(openInterest ?? "0") ?? 0 }
    var fundingRate:  Double { Double(funding    ?? "0") ?? 0 }

    var priceChange24h: Double {
        guard prevDayPrice > 0 else { return 0 }
        return ((markPrice - prevDayPrice) / prevDayPrice) * 100
    }
    var priceChangeAmt: Double { markPrice - prevDayPrice }
}

// MARK: - Domain model

struct Market: Identifiable {
    /// Deterministic ID based on market type + asset name → stable SwiftUI diffing
    var id: String { "\(marketType == .perp ? "perp" : "spot"):\(asset.name)" }
    let asset:     Asset
    var context:   AssetContext
    let index:     Int
    let marketType: MarketType
    let dexName:   String       // "" = main DEX, "xyz" = HIP-3 builder DEX
    let spotCoin:  String       // Spot API coin id ("@105", "PURR/USDC"); empty for perps

    /// Daily candle open price (from 1D candle). When set, change24h is computed from
    /// candle open (like TradingView) instead of rolling 24h prevDayPx (like Hyperliquid).
    var dailyOpenPrice: Double?

    /// Key used for favourites, UI identity. Human-readable.
    /// HIP-3 asset.name is already prefixed (e.g. "xyz:GOLD"), no need to add dexName again.
    var symbol: String {
        if isSpot && !spotCoin.isEmpty { return spotCoin }
        return asset.name
    }

    /// The coin identifier to pass to Hyperliquid API (candles, l2Book, etc.)
    /// HIP-3 asset.name is already prefixed (e.g. "xyz:GOLD"), no need to add dexName again.
    var apiCoin: String {
        if isSpot && !spotCoin.isEmpty { return spotCoin }
        return asset.name
    }

    /// Clean name for display — uses perpAnnotation displayName if available
    var displayName: String {
        if let annotated = HIP3AnnotationCache.shared.displayName(for: asset.name) {
            return "\(dexName):\(annotated)"
        }
        return asset.name
    }

    var isSpot:       Bool   { marketType == .spot }
    var displaySymbol: String {
        if isSpot { return spotDisplayPairName }
        if isHIP3 { return "\(displayName)-\(collateralSymbol)" }
        return "\(displayName)-USD"
    }

    /// Collateral token symbol for HIP-3 DEXes
    private static let dexCollaterals: [String: String] = [
        "xyz": "USDC", "flx": "USDH", "vntl": "USDH",
        "hyna": "USDE", "km": "USDH", "abcd": "USDC", "cash": "USDT"
    ]

    var collateralSymbol: String {
        Self.dexCollaterals[dexName] ?? "USDC"
    }

    var price:        Double { context.markPrice }
    /// Change % from daily candle open (TradingView style) when available, else rolling 24h.
    var change24h:    Double {
        if let open = dailyOpenPrice, open > 0 {
            return ((context.markPrice - open) / open) * 100
        }
        return context.priceChange24h
    }
    var volume24h:    Double { context.dayVolume }
    var openInterest: Double { context.oi }
    var funding:      Double { context.fundingRate }
    var isPositive:   Bool   { change24h >= 0 }

    /// Whether this market belongs to a HIP-3 builder DEX
    var isHIP3: Bool { !dexName.isEmpty }

    /// Icon name for Hyperliquid CDN.
    /// HL CDN has icons for ALL listed assets (crypto + tradfi + HIP-3).
    /// HIP-3: asset.name already prefixed ("xyz:GOLD"). Main DEX: plain name ("BTC", "MEGA").
    /// Spot: use display base name ("BTC" not "UBTC", "PURR" not "PURR/USDC").
    var hlCoinIconName: String {
        let name = isSpot ? spotDisplayBaseName : asset.name
        // k-wrapped tokens (kPEPE, kSHIB, kBONK…) → use base icon (PEPE, SHIB, BONK)
        if name.count > 2,
           name.hasPrefix("k"),
           let second = name.dropFirst().first, second.isUppercase {
            return String(name.dropFirst())
        }
        return name
    }

    /// Pre-launch markets on the main DEX (isolated-only, low leverage)
    var isPreLaunch: Bool { !isHIP3 && marketType == .perp && (asset.onlyIsolated == true) }

    /// Base token name (strips "/USDC" etc. for spot pairs)
    var baseName: String {
        if isSpot, let slash = displayName.firstIndex(of: "/") {
            return String(displayName[..<slash])
        }
        return displayName
    }

    /// Human-readable base name for spot display (UBTC→BTC, UETH→ETH, etc.)
    /// Hyperliquid wraps some tokens with "U" prefix or "0" suffix internally.
    var spotDisplayBaseName: String {
        let b = baseName
        if let mapped = Self.spotNameMap[b] { return mapped }
        return b
    }

    /// Full display pair name for spot (e.g. "BTC/USDC" instead of "UBTC/USDC")
    var spotDisplayPairName: String {
        guard isSpot else { return displayName }
        let quote = quoteName
        return quote.isEmpty ? spotDisplayBaseName : "\(spotDisplayBaseName)/\(quote)"
    }

    /// Perp symbol name that corresponds to this spot token (for price cross-ref)
    var perpEquivalent: String? {
        Self.spotToPerpMap[baseName]
    }

    // MARK: - Spot ↔ Display / Perp mappings

    /// Maps internal spot token names to user-facing display names
    private static let spotNameMap: [String: String] = [
        "UBTC":   "BTC",
        "UETH":   "ETH",
        "USOL":   "SOL",
        "XAUT0":  "XAUT",
        "UFART":  "FARTCOIN",
        "UPUMP":  "PUMP",
        "HPENGU": "PENGU",
        "USDT0":  "USDT",
        "UBONK":  "BONK",
        "UUUSPX": "UUSPX",
        "UENA":   "ENA",
        "UMON":   "MON",
        "UZEC":   "ZEC",
        "UDZ":    "DZ",
        "MMOVE":  "MOVE",
    ]

    /// Maps internal spot base token to its perp equivalent (for oracle prices)
    private static let spotToPerpMap: [String: String] = [
        "UBTC":   "BTC",
        "UETH":   "ETH",
        "USOL":   "SOL",
        "HYPE":   "HYPE",
        "PURR":   "PURR",
        "XAUT0":  "XAUT",
        "UFART":  "FARTCOIN",
        "UPUMP":  "PUMP",
        "HPENGU": "PENGU",
        "UBONK":  "BONK",
        "UENA":   "ENA",
        "UMON":   "MON",
        "UZEC":   "ZEC",
        "MMOVE":  "MOVE",
    ]

    /// Quote currency for spot pairs ("USDC", "USDH", "USDT0" …)
    var quoteName: String {
        if isSpot, let slash = displayName.firstIndex(of: "/") {
            return String(displayName[displayName.index(after: slash)...])
        }
        return ""
    }

    /// Spot quote category (USDC / USDH / USDT)
    var spotQuoteCategory: SpotQuoteCategory { SpotQuoteCategory.detect(forQuote: quoteName) }

    /// Whether this spot token belongs to the Hyperliquid strict (curated) list.
    /// The strict list is a hardcoded set of 42 base token names maintained by HL.
    var isInStrictList: Bool { Self.strictListBaseNames.contains(baseName) }

    /// Crypto sub-category (DeFi, AI, Gaming …) — meaningful for main-DEX perps & spot
    var cryptoSubCategory: CryptoSubCategory { CryptoSubCategory.detect(for: baseName) }

    /// Tradfi sub-category (Stocks, Commodities, Forex, Indices) — meaningful for HIP-3 tradfi
    var tradfiSubCategory: TradfiSubCategory { TradfiSubCategory.detect(for: baseName) }

    // MARK: - Strict list (curated spot tokens)

    /// Hyperliquid strict list: 42 curated base tokens (from HL frontend JS).
    /// Pairs whose base token is in this set appear in "Strict" mode.
    private static let strictListBaseNames: Set<String> = [
        "PURR", "HFUN", "POINTS", "JEFF", "OMNIX", "CATBAL", "SCHIZO",
        "HYPE", "PIP", "ATEHUN", "SOLV", "UBTC", "UETH", "FEUSD",
        "USDE", "BUDDY", "USDT0", "USOL", "UFART", "HPENGU", "XAUT0",
        "USDHL", "LIQD", "UPUMP", "UUUSPX", "UBONK", "USDH", "UXPL",
        "UDZ", "UENA", "KHYPE", "UMON", "KNTQ", "AXL", "SEDA",
        "STABLE", "HAR", "MMOVE", "SWAP", "QONE", "HPL", "UZEC",
    ]

    var maxLeverageDisplay: String {
        guard let lev = asset.maxLeverage else { return "—" }
        return "\(lev)x"
    }

    // MARK: - Formatting

    var formattedPrice: String { format(price) }

    var formattedVolume: String {
        let v = volume24h
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "%.1fK", v / 1_000) }
        return String(format: "%.0f", v)
    }

    var formattedOI: String {
        let v = openInterest * price
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "%.1fM", v / 1_000_000) }
        return String(format: "%.0f", v)
    }

    /// Price decimals using 5 significant figures — matches Hyperliquid's display precision.
    var priceDecimals: Int {
        Self.sigFigDecimals(price)
    }

    func format(_ p: Double) -> String {
        return String(format: "%.\(Self.sigFigDecimals(p))f", p)
    }

    /// Compute the number of decimal places to display for a given price using 5 significant figures.
    /// Capped at 6 decimals to match Hyperliquid's maximum display precision.
    static func sigFigDecimals(_ price: Double, sigFigs: Int = 5) -> Int {
        let p = abs(price)
        guard p > 0 else { return 2 }
        let magnitude = Int(floor(log10(p)))  // e.g., 68265→4, 86→1, 0.09→-2
        let intDigits = magnitude + 1          // digits before decimal point
        if intDigits >= sigFigs {
            return 0
        }
        return min(sigFigs - intDigits, 6)     // Hyperliquid never shows more than 6 decimals
    }
}

// MARK: - Sort

enum SortOption: String, CaseIterable, Identifiable {
    case volume = "Volume"
    case change = "Chg%"
    case price  = "Price"
    case name   = "Name"
    case oi     = "OI"
    var id: String { rawValue }
}

