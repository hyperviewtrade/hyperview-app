import SwiftUI
import Combine
import WidgetKit

@MainActor
final class MarketsViewModel: ObservableObject {
    /// Shared cache of szDecimals per coin, updated when markets load.
    /// Pre-populated with common markets for instant availability before API loads.
    static var szDecimalsCache: [String: Int] = [
        "BTC": 5, "UBTC": 5, "ETH": 4, "SOL": 2, "HYPE": 2, "DOGE": 0,
        "AVAX": 2, "BNB": 3, "LTC": 2, "LINK": 1, "SUI": 1,
        "ARB": 1, "OP": 1, "INJ": 1, "ATOM": 2, "TAO": 2,
        "RENDER": 1, "WIF": 0, "kPEPE": 0, "kSHIB": 0
    ]

    /// Returns szDecimals for a given coin name (e.g. "BTC" → 5, "ETH" → 4)
    static func szDecimals(for coin: String) -> Int {
        szDecimalsCache[coin] ?? 4
    }

    /// Cache of spot pair names: "@107" → "HYPE", "@142" → "BTC", etc.
    static var spotNameMap: [String: String] = [:]

    /// Resolve spot pair names like "@107" → "HYPE/USDC", "@142" → "BTC/USDC"
    static func resolveSpotName(_ raw: String) -> String {
        if !raw.hasPrefix("@") { return raw }
        if let resolved = spotNameMap[raw] { return resolved }
        // Fallback: check markets
        return raw
    }

    /// Shared cache of live mark prices per coin, updated on every WebSocket tick.
    static var markPriceCache: [String: Double] = [:]

    /// Returns the latest mark price for a coin (0 if unknown).
    static func markPrice(for coin: String) -> Double {
        markPriceCache[coin] ?? 0
    }

    @Published var markets:          [Market]          = []
    @Published var livePrices:       [String: Double]  = [:]
    @Published var isLoading         = false
    @Published var errorMessage:     String?
    @Published var searchQuery       = ""
    @Published var sortOption        = SortOption.volume
    @Published var sortAscending     = false
    @Published var customSymbolOrder: [String]? = nil
    @Published var selectedMain:      MainCategory      = .all
    @Published var selectedPerpSub:  PerpSubCategory     = .all
    @Published var selectedCryptoSub: CryptoSubCategory  = .all
    @Published var selectedTradfiSub: TradfiSubCategory  = .all
    @Published var selectedSpotSub:   SpotQuoteCategory   = .all
    @Published var spotStrictMode:    Bool                = true   // default = strict list
    @Published var selectedHIP3Dex:   String             = "All"

    // HIP-4 Outcome markets (testnet)
    @Published var outcomeQuestions:        [OutcomeQuestion]  = []
    @Published var isLoadingOutcomes       = false
    @Published var selectedOptionsUnderlying: OptionsUnderlying = .all
    @Published var selectedOptionsPeriod:    OptionsPeriod      = .all

    /// Cached result of filteredMarkets computation. Updated only when filter/sort inputs change.
    @Published private(set) var cachedFilteredMarkets: [Market] = []

    /// The watched symbols last used for caching; updated via filteredMarkets(watched:) calls.
    private var lastWatched: Set<String> = []

    private let ws             = WebSocketManager.shared
    private var lastUIUpdate:  Date = .distantPast
    private let updateInterval: TimeInterval = 1.5
    private var lastWidgetReload: Date = .distantPast
    private let widgetReloadInterval: TimeInterval = 600  // 10 minutes
    /// Main-DEX asset names — used to distinguish HIP-3 crypto vs tradfi
    private var mainDexAssetNames: Set<String> = []
    private var annotationsSub: AnyCancellable?

    /// Subject to batch rapid filter/sort changes before recomputation.
    private let recomputeSubject = PassthroughSubject<Void, Never>()
    /// Subject for price-based recomputation (debounced at 2s).
    private let priceRecomputeSubject = PassthroughSubject<Void, Never>()
    private var recomputeCancellables = Set<AnyCancellable>()

    init() {
        // When HIP-3 annotations load, force a re-render of the market list
        annotationsSub = NotificationCenter.default.publisher(for: .hip3AnnotationsLoaded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Trigger @Published update to force SwiftUI re-render
                let current = self.markets
                self.markets = current
                print("[MARKETS] Re-rendered with HIP-3 annotations")
            }

        setupRecomputePipeline()
    }

    /// Sets up Combine pipelines to observe filter/sort input changes and trigger recomputation.
    private func setupRecomputePipeline() {
        // Debounce rapid filter/sort changes (100ms)
        recomputeSubject
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.recomputeFilteredMarketsNow()
            }
            .store(in: &recomputeCancellables)

        // Debounce price-based recomputation (2s) — only relevant when sort is price/change
        priceRecomputeSubject
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.recomputeFilteredMarketsNow()
            }
            .store(in: &recomputeCancellables)

        // Observe filter/sort input changes and fire recomputeSubject
        $markets
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $searchQuery
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedMain
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedPerpSub
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $sortOption
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $sortAscending
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $customSymbolOrder
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $spotStrictMode
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedCryptoSub
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedTradfiSub
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedSpotSub
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        $selectedHIP3Dex
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeSubject.send() }
            .store(in: &recomputeCancellables)

        // livePrices: only trigger recompute if sort is price-based, with 2s debounce
        $livePrices
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                switch self.sortOption {
                case .price, .change:
                    self.priceRecomputeSubject.send()
                default:
                    break
                }
            }
            .store(in: &recomputeCancellables)
    }

    /// Performs the actual recomputation and assigns to cachedFilteredMarkets.
    private func recomputeFilteredMarketsNow() {
        cachedFilteredMarkets = computeFilteredMarkets(watched: lastWatched)
    }

    // MARK: - Filtered / sorted list

    /// Moves watched markets to the front of `list`, preserving relative order within each group.
    /// Applied to every code path before sharing with the widget so favorites always appear first.
    private func applyFavoritesFirst(_ list: [Market], watched: Set<String>) -> [Market] {
        guard !watched.isEmpty else { return list }
        let favs    = list.filter { watched.contains($0.symbol) }
        let nonFavs = list.filter { !watched.contains($0.symbol) }
        return favs + nonFavs
    }

    /// Returns cached filtered & sorted markets. Pass watched symbols so favorites
    /// float to the top (sorted by the active sort among themselves).
    /// Uses the cached result; updates the cache if watched set changed.
    func filteredMarkets(watched: Set<String> = []) -> [Market] {
        if watched != lastWatched {
            lastWatched = watched
            cachedFilteredMarkets = computeFilteredMarkets(watched: watched)
        }
        return cachedFilteredMarkets
    }

    /// Core computation: filters + sorts the full markets array.
    private func computeFilteredMarkets(watched: Set<String>) -> [Market] {
        var result = markets

        // Main category filter
        switch selectedMain {
        case .all:
            // When strict mode is on, hide non-strict spot markets from the "All" view
            if spotStrictMode {
                result = result.filter { $0.marketType != .spot || $0.isInStrictList }
            }
        case .perps:
            // Apply perp sub-category filter
            switch selectedPerpSub {
            case .all:
                result = result.filter { $0.marketType == .perp && !$0.isPreLaunch }
            case .crypto:
                result = result.filter { $0.marketType == .perp && !$0.isHIP3 && !$0.isPreLaunch }
                if selectedCryptoSub != .all {
                    result = result.filter { $0.cryptoSubCategory == selectedCryptoSub }
                }
            case .tradfi:
                result = result.filter { $0.isHIP3 && isTradfi($0) }
                if selectedTradfiSub != .all {
                    result = result.filter { $0.tradfiSubCategory == selectedTradfiSub }
                }
            case .hip3:
                result = result.filter { $0.isHIP3 }
                if selectedHIP3Dex != "All" {
                    result = result.filter { $0.dexName == selectedHIP3Dex }
                }
            case .preLaunch:
                result = result.filter { $0.isPreLaunch }
            }
        case .spot:
            result = result.filter { $0.marketType == .spot }
            if spotStrictMode {
                result = result.filter { $0.isInStrictList }
            }
            if selectedSpotSub != .all {
                result = result.filter { $0.spotQuoteCategory == selectedSpotSub }
            }
        case .crypto:
            result = result.filter { $0.marketType == .perp && !$0.isHIP3 && !$0.isPreLaunch }
            if selectedCryptoSub != .all {
                result = result.filter { $0.cryptoSubCategory == selectedCryptoSub }
            }
        case .tradfi:
            result = result.filter { $0.isHIP3 && isTradfi($0) }
            if selectedTradfiSub != .all {
                result = result.filter { $0.tradfiSubCategory == selectedTradfiSub }
            }
        case .hip3:
            result = result.filter { $0.isHIP3 }
            if selectedHIP3Dex != "All" {
                result = result.filter { $0.dexName == selectedHIP3Dex }
            }
        case .trending:
            result = result.filter { $0.marketType == .perp }
        case .preLaunch:
            result = result.filter { $0.isPreLaunch }
        case .predictions, .options:
            return [] // Outcome markets handled via filteredOutcomeMarkets()
        }

        // Search filter (also matches spot display names like "BTC" for UBTC)
        if !searchQuery.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchQuery) ||
                $0.symbol.localizedCaseInsensitiveContains(searchQuery) ||
                $0.spotDisplayBaseName.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Custom manual order (from drag-to-reorder) takes priority over sort criteria.
        // Markets present in the saved order keep their user-defined position.
        // Markets NOT in the saved order (e.g. HIP-3 loaded in Phase 2, after the drag) are
        // sorted by volume and appended after the ordered group — not silently pushed to the
        // very bottom via Int.max. Favorites always float to the top of the final list.
        if let order = customSymbolOrder {
            let orderMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let inOrder    = result.filter { orderMap[$0.symbol] != nil }
                                   .sorted  { orderMap[$0.symbol]! < orderMap[$1.symbol]! }
            let notInOrder = result.filter { orderMap[$0.symbol] == nil }
                                   .sorted  { $0.volume24h > $1.volume24h }
            result = applyFavoritesFirst(inOrder + notInOrder, watched: watched)
            shareMarketsWithWidget(result)
            return result
        }

        // Trending: sort by change%, limit to 50 — favorites still appear first.
        if selectedMain == .trending {
            result.sort { a, b in
                sortAscending ? a.change24h < b.change24h : a.change24h > b.change24h
            }
            result = applyFavoritesFirst(result, watched: watched)
            let trimmed = Array(result.prefix(50))
            shareMarketsWithWidget(trimmed)
            return trimmed
        }

        // Sort — favorites first, then the rest; within each group apply the active sort.
        result.sort { a, b in
            let aFav = watched.contains(a.symbol)
            let bFav = watched.contains(b.symbol)
            if aFav != bFav { return aFav }

            let pa = livePrices[a.symbol] ?? a.price
            let pb = livePrices[b.symbol] ?? b.price
            switch sortOption {
            case .volume: return sortAscending ? a.volume24h    < b.volume24h    : a.volume24h    > b.volume24h
            case .change: return sortAscending ? a.change24h    < b.change24h    : a.change24h    > b.change24h
            case .price:  return sortAscending ? pa             < pb             : pa             > pb
            case .name:   return sortAscending ? a.displayName  < b.displayName  : a.displayName  > b.displayName
            case .oi:     return sortAscending ? a.openInterest < b.openInterest : a.openInterest > b.openInterest
            }
        }
        shareMarketsWithWidget(result)
        return result
    }

    /// Write the top displayed markets to the shared App Group container for the widget.
    /// Throttled: only triggers WidgetKit reload at most once every 10 minutes.
    private func shareMarketsWithWidget(_ markets: [Market]) {
        guard let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview") else { return }
        let top = markets.prefix(10).map { m -> [String: Any] in
            let lp = livePrices[m.symbol] ?? m.price
            let chg: Double = {
                if let open = m.dailyOpenPrice, open > 0 {
                    return ((lp - open) / open) * 100
                }
                return m.change24h
            }()
            return [
                "n": m.displaySymbol,
                "s": m.symbol,
                "p": lp,
                "c": chg,
                "v": m.volume24h,
                "icon": m.hlCoinIconName
            ]
        }
        defaults.set(top, forKey: "widget_shared_markets")

        let now = Date()
        if now.timeIntervalSince(lastWidgetReload) >= widgetReloadInterval {
            lastWidgetReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
        }
    }

    /// Force an immediate widget refresh (bypasses the 10-minute throttle).
    /// Call when the user explicitly reorders or changes favorites.
    /// Optionally writes a unified display order so the widget respects the user's arrangement.
    func forceWidgetReload(unifiedOrder: [String]? = nil) {
        let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview")
        if let order = unifiedOrder {
            defaults?.set(order, forKey: "widget_unified_order")
        }
        // Re-share current top markets to App Group so the widget has fresh data
        if let defaults {
            let top = markets.prefix(10).map { m -> [String: Any] in
                let lp = livePrices[m.symbol] ?? m.price
                let chg: Double = {
                    if let open = m.dailyOpenPrice, open > 0 {
                        return ((lp - open) / open) * 100
                    }
                    return m.change24h
                }()
                return [
                    "n": m.displaySymbol, "s": m.symbol,
                    "p": lp, "c": chg, "v": m.volume24h,
                    "icon": m.hlCoinIconName
                ]
            }
            defaults.set(top, forKey: "widget_shared_markets")
        }
        lastWidgetReload = .now
        WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
    }

    /// Unique HIP-3 DEX names derived from loaded markets (excludes empty DEXes)
    var availableHIP3Dexes: [String] {
        let dexes = Set(markets.compactMap { $0.isHIP3 ? $0.dexName : nil })
        return dexes.sorted()
    }

    /// A HIP-3 market is tradfi if its asset is NOT a known crypto token
    /// and NOT listed on the main DEX
    func isTradfi(_ market: Market) -> Bool {
        guard market.isHIP3 else { return false }
        let raw = market.baseName.uppercased()
        // Strip DEX prefix (e.g. "xyz:GOLD" → "GOLD")
        let name = raw.contains(":") ? String(raw.split(separator: ":").last ?? Substring(raw)) : raw
        return !mainDexAssetNames.contains(name) && !CryptoSubCategory.isCrypto(name)
    }

    func currentPrice(for symbol: String, fallback: Double) -> Double {
        livePrices[symbol] ?? fallback
    }

    // MARK: - Load (two-phase: fast first, HIP-3 background)

    func loadMarkets() async {
        guard !isLoading else { return }
        isLoading    = true
        errorMessage = nil

        let api = HyperliquidAPI.shared

        do {
            // ── Phase 1: spot + main perps concurrently (2 requests, ~500ms) ──
            async let spotTask     = api.fetchSpotMarkets()
            async let mainPerpTask = api.fetchMarketsForDex("")
            let (spotMarkets, mainPerps) = try await (spotTask, mainPerpTask)

            mainDexAssetNames = Set(mainPerps.map { $0.baseName.uppercased() })

            publishMarkets(perps: mainPerps, spots: spotMarkets)
            subscribeToLivePrices()
            isLoading = false
            print("⚡ Phase 1: \(markets.count) markets visible")

            // Fetch daily opens from backend (1 request, no HL rate limit)
            Task { [weak self] in
                await self?.fetchAndApplyDailyOpens()
            }

            // ── Phase 2: HIP-3 ──
            // 1. Load from local cache INSTANTLY (no network)
            let cachedHIP3 = loadCachedHIP3Markets(api: api)
            if !cachedHIP3.isEmpty {
                publishMarkets(perps: mainPerps + cachedHIP3, spots: spotMarkets)
                print("⚡ Phase 2 (cache): +\(cachedHIP3.count) HIP-3 → \(markets.count) total")
            }

            // 2. Update from backend in background (delayed 3s to not compete with balance)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            var hip3Markets = await api.fetchHIP3MarketsFromBackend()
            if hip3Markets.isEmpty {
                // Fallback: fetch directly from HL API (sequential with delay to avoid rate limit)
                let hip3Dexes = await api.fetchPerpDexNamesWithIndices()
                for dex in hip3Dexes {
                    if let m = try? await api.fetchMarketsForDex(dex.name, perpDexIdx: dex.perpDexIdx) {
                        hip3Markets.append(contentsOf: m)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms between DEX fetches
                }
            }
            // Fallback safety: if fresh fetch returned 0, keep cached markets
            if hip3Markets.isEmpty {
                let cached = loadCachedHIP3Markets(api: api)
                if !cached.isEmpty {
                    hip3Markets = cached
                    print("⚡ HIP-3: fresh fetch empty, keeping \(cached.count) cached markets")
                }
            }
            // Only update if we got MORE hip3 than what's cached (never downgrade)
            let currentHIP3Count = markets.filter { $0.isHIP3 }.count
            if !hip3Markets.isEmpty && hip3Markets.count >= max(currentHIP3Count - 5, 10) {
                publishMarkets(perps: mainPerps + hip3Markets, spots: spotMarkets)
                // Save to cache if we got any markets (even partial is better than nothing)
                if hip3Markets.count > 10 {
                    saveCachedHIP3Markets(hip3Markets, api: api)
                }
                print("⚡ Phase 2 (fresh): +\(hip3Markets.count) HIP-3 → \(markets.count) total")
            }

            // Phase 3: Fetch HIP-3 display names + global aliases
            await HIP3AnnotationCache.shared.fetchAnnotations()
            await AliasCache.shared.fetchAliases()

            // Phase 4: Pre-fetch HIP-4 outcome markets from testnet (non-blocking)
            Task { [weak self] in await self?.loadOutcomeMarkets() }

        } catch {
            print("❌ Markets: \(error)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func refresh() { Task { await loadMarkets() } }

    // MARK: - HIP-3 Disk Cache

    private static let hip3CacheKey = "cached_hip3_markets_json"
    private static let hip3CacheTimeKey = "cached_hip3_time"

    /// Save HIP-3 market data to UserDefaults for instant load on next launch.
    private func saveCachedHIP3Markets(_ markets: [Market], api: HyperliquidAPI) {
        // Serialize essential fields to JSON
        let entries: [[String: Any]] = markets.map { m in
            [
                "name": m.asset.name,
                "dex": m.dexName,
                "assetIndex": m.index,
                "szDecimals": m.asset.szDecimals,
                "maxLeverage": m.asset.maxLeverage as Any,
                "markPx": m.context.markPx ?? "0",
                "prevDayPx": m.context.prevDayPx ?? "0",
                "dayNtlVlm": m.context.dayNtlVlm ?? "0",
                "openInterest": m.context.openInterest ?? "0",
                "funding": m.context.funding ?? "0",
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            UserDefaults.standard.set(data, forKey: Self.hip3CacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.hip3CacheTimeKey)
            print("[HIP3-CACHE] Saved \(entries.count) markets to disk")
        }
    }

    /// Load HIP-3 markets from UserDefaults cache. Returns empty if no cache or too old (>24h).
    private func loadCachedHIP3Markets(api: HyperliquidAPI) -> [Market] {
        let cacheTime = UserDefaults.standard.double(forKey: Self.hip3CacheTimeKey)
        guard cacheTime > 0,
              Date().timeIntervalSince1970 - cacheTime < 7 * 24 * 3600, // max 7 days old
              let data = UserDefaults.standard.data(forKey: Self.hip3CacheKey),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var markets: [Market] = []
        for (_, m) in entries.enumerated() {
            guard let name = m["name"] as? String,
                  let dex = m["dex"] as? String
            else { continue }

            let assetIndex = m["assetIndex"] as? Int ?? 0

            let asset = Asset(
                name: name,
                szDecimals: m["szDecimals"] as? Int ?? 0,
                maxLeverage: m["maxLeverage"] as? Int,
                onlyIsolated: nil
            )
            let context = AssetContext(
                funding: m["funding"] as? String,
                openInterest: m["openInterest"] as? String,
                prevDayPx: m["prevDayPx"] as? String,
                dayNtlVlm: m["dayNtlVlm"] as? String,
                premium: nil,
                oraclePx: nil,
                markPx: m["markPx"] as? String,
                midPx: nil,
                impactPxs: nil
            )
            markets.append(Market(
                asset: asset,
                context: context,
                index: assetIndex,
                marketType: .perp,
                dexName: dex,
                spotCoin: ""
            ))
        }
        if !markets.isEmpty {
            print("[HIP3-CACHE] Loaded \(markets.count) markets from disk")
        }
        return markets
    }

    /// Enriches spot prices from perp oracle, filters dead markets, and publishes.
    private func publishMarkets(perps: [Market], spots: [Market]) {
        let wrappedTokens: Set<String> = ["UBTC", "UETH", "USOL"]

        var perpPrices: [String: (mark: Double, prev: Double)] = [:]
        for m in perps where !m.isHIP3 {
            perpPrices[m.asset.name] = (m.price, m.context.prevDayPrice)
        }

        var enriched = perps + spots
        for i in enriched.indices where enriched[i].isSpot {
            guard wrappedTokens.contains(enriched[i].baseName),
                  let perpName = enriched[i].perpEquivalent,
                  let pp = perpPrices[perpName], pp.mark > 0
            else { continue }
            enriched[i].context = AssetContext(
                funding:      enriched[i].context.funding,
                openInterest: enriched[i].context.openInterest,
                prevDayPx:    String(pp.prev),
                dayNtlVlm:    enriched[i].context.dayNtlVlm,
                premium:      enriched[i].context.premium,
                oraclePx:     enriched[i].context.oraclePx,
                markPx:       String(pp.mark),
                midPx:        enriched[i].context.midPx,
                impactPxs:    enriched[i].context.impactPxs
            )
        }

        markets = enriched.filter { $0.isSpot || $0.isHIP3 || $0.volume24h > 0 || $0.openInterest > 0 }

        // Update szDecimals cache for position formatting
        for m in markets {
            Self.szDecimalsCache[m.asset.name] = m.asset.szDecimals
            // Populate spot name map: "@107" → "HYPE/USDC", "@142" → "BTC/USDC"
            if m.isSpot, !m.spotCoin.isEmpty {
                Self.spotNameMap[m.spotCoin] = m.displaySymbol
                // Also map the raw @NNN format
                if m.spotCoin.hasPrefix("@") {
                    Self.spotNameMap[m.spotCoin] = m.displaySymbol
                }
            }
        }

        // Re-apply cached daily opens so change% stays TradingView-style
        applyDailyOpens()

        var lookup: [String: String] = [:]
        for m in markets where m.isSpot && wrappedTokens.contains(m.baseName) {
            if let perpName = m.perpEquivalent {
                lookup[m.symbol] = perpName
            }
        }
        spotPerpLookup = lookup
    }

    // MARK: - Daily candle open prices (TradingView-style change%)

    /// Cached daily open prices keyed by coin name (e.g. "BTC", "cash:INTC").
    /// Fetched from backend in 1 request — no Hyperliquid API rate limit impact.
    private var dailyOpenPrices: [String: Double] = [:]

    /// Fetch daily opens from backend and apply to all markets.
    func fetchAndApplyDailyOpens() async {
        let opens = await HyperliquidAPI.shared.fetchDailyOpens()
        guard !opens.isEmpty else { return }
        dailyOpenPrices = opens
        applyDailyOpens()
        // Share daily opens with widget via App Group
        shareDailyOpensWithWidget()
    }

    /// Write daily open prices to App Group so the widget can use them
    /// instead of rolling 24h prevDayPx.
    private func shareDailyOpensWithWidget() {
        guard let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview"),
              !dailyOpenPrices.isEmpty
        else { return }
        defaults.set(dailyOpenPrices, forKey: "widget_daily_opens")
        WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
        print("📊 Widget: shared \(dailyOpenPrices.count) daily opens")
    }

    /// Apply cached daily open prices to the current markets array.
    private func applyDailyOpens() {
        guard !dailyOpenPrices.isEmpty else { return }
        for i in markets.indices {
            // Try symbol first (perps: "BTC", HIP-3: "xyz:GOLD")
            // Then asset.name (covers spot where symbol is "@105" but asset.name is "PURR/USDC")
            // Then baseName (covers spot where asset.name is "PURR/USDC" but backend stores "PURR")
            if let open = dailyOpenPrices[markets[i].symbol]
                ?? dailyOpenPrices[markets[i].asset.name]
                ?? dailyOpenPrices[markets[i].baseName] {
                markets[i].dailyOpenPrice = open
            }
        }
    }

    // MARK: - WebSocket (throttled)

    /// Maps spot symbol ("@140") → perp coin name ("BTC") for live price cross-reference.
    /// Built once in loadMarkets(), used in onAllMids to override stale spot prices.
    private var spotPerpLookup: [String: String] = [:]

    private func subscribeToLivePrices() {
        ws.connect()
        ws.subscribeAllMids()

        ws.onAllMids = { [weak self] mids in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastUIUpdate) >= self.updateInterval else { return }
            self.lastUIUpdate = now

            var updated = self.livePrices
            for (sym, str) in mids {
                if let price = Double(str) { updated[sym] = price }
            }

            // Override stale spot allMids prices with perp oracle prices.
            // Non-canonical spot pairs (@xxx) return raw/atomic prices via allMids
            // that are unusable. Use the corresponding perp price instead.
            for (spotSym, perpCoin) in self.spotPerpLookup {
                if let perpPrice = updated[perpCoin], perpPrice > 0 {
                    updated[spotSym] = perpPrice
                }
            }

            self.livePrices = updated

            // Update static mark price cache for use by TrackedPosition etc.
            for (sym, price) in updated where price > 0 {
                Self.markPriceCache[sym] = price
            }
        }
    }

    // MARK: - HIP-4 Outcome Markets (testnet)

    /// Load prediction + options markets from Hyperliquid testnet.
    func loadOutcomeMarkets() async {
        guard !isLoadingOutcomes else { return }
        isLoadingOutcomes = true
        defer { isLoadingOutcomes = false }

        let api = HyperliquidAPI.shared
        do {
            async let metaTask   = api.fetchOutcomeMeta()
            async let pricesTask = api.fetchOutcomePrices()
            let (meta, prices) = try await (metaTask, pricesTask)

            // 1. Build OutcomeMarket for each outcome entry
            var outcomesById: [Int: OutcomeMarket] = [:]
            for entry in meta.outcomes {
                let priceBinary = PriceBinaryInfo.parse(entry.description)

                // Build sides from sideSpecs
                var sides: [OutcomeSide] = []
                for spec in entry.sideSpecs {
                    let encoding = 10 * entry.outcomeId + spec.index
                    let price = prices["#\(encoding)"] ?? 0.5
                    sides.append(OutcomeSide(
                        id: "side:\(entry.outcomeId):\(spec.index)",
                        sideIndex: spec.index,
                        name: spec.name,
                        price: price,
                        volume: 0,
                        encoding: encoding
                    ))
                }

                let market = OutcomeMarket(
                    id: "outcome:\(entry.outcomeId)",
                    outcomeId: entry.outcomeId,
                    name: entry.name,
                    description: entry.description,
                    sides: sides,
                    priceBinary: priceBinary
                )
                outcomesById[entry.outcomeId] = market
            }

            // 2. Group into OutcomeQuestion
            var questions: [OutcomeQuestion] = []
            var usedOutcomeIds = Set<Int>()

            // Collect all fallback outcome IDs so we can exclude them everywhere
            let fallbackIds = Set(meta.questions.compactMap(\.fallbackOutcome))

            for q in meta.questions {
                // Exclude fallback "Other" outcome from the question's outcomes
                let filteredIds = q.namedOutcomes.filter { !fallbackIds.contains($0) }
                let qOutcomes = filteredIds.compactMap { outcomesById[$0] }
                guard !qOutcomes.isEmpty else { continue }
                usedOutcomeIds.formUnion(q.namedOutcomes) // Mark ALL including fallback as used
                questions.append(OutcomeQuestion(
                    id: "question:\(q.questionId)",
                    questionId: q.questionId,
                    name: q.name,
                    description: q.description,
                    outcomes: qOutcomes
                ))
            }

            // Orphan outcomes (no question) — wrap each in its own question group
            // Skip fallback outcomes and outcomes named "Other"
            for (oid, market) in outcomesById where !usedOutcomeIds.contains(oid) {
                if fallbackIds.contains(oid) { continue }
                if market.name.lowercased() == "other" { continue }
                questions.append(OutcomeQuestion(
                    id: "question:orphan:\(oid)",
                    questionId: -oid,
                    name: market.name,
                    description: market.description,
                    outcomes: [market]
                ))
            }

            // Publish immediately so UI is responsive
            outcomeQuestions = questions.sorted { a, b in
                if a.isOption != b.isOption { return a.isPrediction }
                if a.outcomes.count != b.outcomes.count { return a.outcomes.count > b.outcomes.count }
                return a.name < b.name
            }

            let predCount = questions.filter(\.isPrediction).count
            let optCount  = questions.filter(\.isOption).count
            print("📊 HIP-4 loaded: \(predCount) prediction questions, \(optCount) option questions (\(outcomesById.count) total outcomes)")

            // Fetch 24h changes in background (non-blocking)
            Task { [weak self] in
                await self?.loadOutcome24hChanges(for: questions)
            }
        } catch {
            print("❌ HIP-4: \(error.localizedDescription)")
        }
    }

    /// Fetches 24h candle data for outcome questions and updates yesChange24h.
    /// Runs after initial data is already published to keep UI fast.
    private func loadOutcome24hChanges(for questions: [OutcomeQuestion]) async {
        let api = HyperliquidAPI.shared
        var openPrices: [String: Double] = [:]

        await withTaskGroup(of: (String, Double).self) { group in
            for q in questions {
                guard let side0 = q.outcomes.first?.sides.first else { continue }
                let coin = side0.apiCoin
                let qid = q.id
                group.addTask {
                    do {
                        let candles = try await api.fetchOutcomeCandles(
                            coin: coin, interval: .oneDay, limit: 2)
                        if let oldest = candles.first, let open = Double(oldest.o) {
                            return (qid, open)
                        }
                    } catch {}
                    return (qid, -1)
                }
            }
            for await (qid, open) in group {
                if open >= 0 { openPrices[qid] = open }
            }
        }

        // Update published array with 24h changes
        var updated = outcomeQuestions
        for i in updated.indices {
            let currentPrice = updated[i].outcomes.first?.side0Price ?? 0.5
            if let open = openPrices[updated[i].id], open > 0 {
                updated[i].yesChange24h = ((currentPrice - open) / open) * 100
            }
        }
        outcomeQuestions = updated
    }

    /// Filtered outcome questions based on selected category.
    func filteredOutcomeQuestions() -> [OutcomeQuestion] {
        var result: [OutcomeQuestion]

        if selectedMain == .predictions {
            result = outcomeQuestions.filter(\.isPrediction)
        } else if selectedMain == .options {
            result = outcomeQuestions.filter(\.isOption)

            if selectedOptionsUnderlying != .all {
                let underlying = selectedOptionsUnderlying.rawValue
                result = result.filter { q in
                    q.outcomes.contains { $0.priceBinary?.underlying == underlying }
                }
            }
            if selectedOptionsPeriod != .all {
                let period = selectedOptionsPeriod.rawValue
                result = result.filter { q in
                    q.outcomes.contains { $0.priceBinary?.period == period }
                }
            }
        } else {
            result = outcomeQuestions
        }

        if !searchQuery.isEmpty {
            result = result.filter { q in
                q.name.localizedCaseInsensitiveContains(searchQuery) ||
                q.outcomes.contains { $0.name.localizedCaseInsensitiveContains(searchQuery) }
            }
        }

        return result
    }
}
