import SwiftUI
import Combine

@MainActor
final class ChartViewModel: ObservableObject {
    @Published var selectedSymbol       = "BTC"
    @Published var selectedDisplayName   = "BTC"
    /// True when the current chart is a custom TradingView symbol (not Hyperliquid)
    @Published var isCustomTVChart       = false
    @Published var selectedInterval: ChartInterval = {
        let raw = UserDefaults.standard.string(forKey: "hl_defaultInterval") ?? "1h"
        return ChartInterval(rawValue: raw) ?? .oneHour
    }()
    @Published var candles:               [Candle]   = []
    @Published var orderBook:             OrderBook?
    @Published var recentTrades:          [Trade]    = []
    @Published var isLoading              = false
    @Published var errorMessage:          String?
    @Published var livePrice:             Double     = 0

    /// Incremented to signal the TradingView WebView to re-fetch data
    @Published var refreshTrigger:       Int        = 0

    // Chart display type
    @Published var chartType:             ChartType  = .candles

    // Local full-depth orderbook — seeded by REST snapshot, updated by WS deltas.
    // Maintained as price→size dicts so delta application is O(1) per level.
    private var localBids: [Double: Double] = [:]
    private var localAsks: [Double: Double] = [:]

    // Pre-sorted display arrays cached between WS updates so we only re-sort
    // the side that actually changed (partial rebuild = ~50% less work per delta).
    private var cachedBids: [OrderBookLevel] = []
    private var cachedAsks: [OrderBookLevel] = []

    // For spot markets with a perp equivalent, use the perp coin name
    // when reading allMids so the live price reflects the oracle price
    // (spot @xxx allMids prices are stale/atomic for non-canonical pairs).
    private var livePriceCoin: String?

    /// Human-readable display name for the chart header.
    /// Set via changeSymbol / loadChart — resolves @xxx to pair names.
    var displayName: String { selectedDisplayName }

    /// Base token name for icons and size labels (e.g. "BTC" from "BTC/USDC").
    var displayBaseName: String {
        if let slash = selectedDisplayName.firstIndex(of: "/") {
            return String(selectedDisplayName[..<slash])
        }
        return selectedDisplayName
    }

    /// Icon name for Hyperliquid CDN (all markets).
    /// HIP-3 symbol = "dex:dex:NAME" → strip outer prefix → "dex:NAME" for CDN.
    /// Main DEX / Spot → use displayBaseName ("BTC", "MEGA", "PURR").
    var hlCoinIconName: String {
        var name: String
        if let idx = selectedSymbol.firstIndex(of: ":") {
            name = String(selectedSymbol[selectedSymbol.index(after: idx)...])
        } else {
            name = displayBaseName
        }
        // k-wrapped tokens (kPEPE, kSHIB…) → use base icon (PEPE, SHIB)
        if name.count > 2,
           name.hasPrefix("k"),
           let second = name.dropFirst().first, second.isUppercase {
            name = String(name.dropFirst())
        }
        return name
    }

    /// "PERP" or "SPOT" based on selectedSymbol.
    /// Spot symbols start with "@" (non-canonical) or contain "/" (canonical like "PURR/USDC").
    var marketTypeBadge: String {
        isSpotMarket ? "SPOT" : "PERP"
    }

    /// Whether the currently selected symbol is a spot market
    var isSpotMarket: Bool {
        selectedSymbol.hasPrefix("@") ||
        (selectedSymbol.contains("/") && !selectedSymbol.contains(":"))
    }

    private let ws  = WebSocketManager.shared
    private let api = HyperliquidAPI.shared

    // Combine subscriptions (price ticker, etc.)
    private var cancellables = Set<AnyCancellable>()

    // Track the coin name currently subscribed to WS order book
    private var subscribedOrderBookCoin: String?

    // Background task that periodically re-seeds the local book from REST
    // to keep deep levels populated as the market moves.
    private var bookRefreshTask: Task<Void, Never>?

    // Significant-figure precision for the current REST/WS l2Book subscription.
    // 5 = 1-unit resolution for BTC, 4 = 10-unit, 3 = 100-unit, 2 = 1000-unit.
    private var currentNSigFigs: Int = 5

    // Timestamp of last WS l2Book delta — used to skip REST polling when WS is healthy.
    private var lastL2BookUpdate: Date = .distantPast

    // Reconnection observer token
    private var reconnectObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        // Listen for WebSocket reconnection to reconcile stale data
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: WebSocketManager.didReconnect, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Use DispatchQueue.main.async to defer any @Published mutations
            // until after the current run loop iteration (avoids publishing
            // during an in-progress SwiftUI view update).
            DispatchQueue.main.async {
                Task { @MainActor in
                    await self.fetchAndSeedOrderBook()
                    await self.fillCandleGap()
                }
            }
        }
    }

    deinit {
        if let observer = reconnectObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    /// Debounce: last requested symbol to prevent rapid-fire API calls
    private var pendingLoadSymbol: String?
    private var loadDebounceTask: Task<Void, Never>?

    func loadChart(symbol: String, interval: ChartInterval,
                   displayName: String? = nil, perpEquivalent: String? = nil) async {

        // Debounce rapid market switches: cancel pending load if user switches again within 150ms
        pendingLoadSymbol = symbol
        loadDebounceTask?.cancel()
        loadDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            guard !Task.isCancelled, pendingLoadSymbol == symbol else { return }
        }
        try? await loadDebounceTask?.value
        guard pendingLoadSymbol == symbol else { return } // Another switch happened

        // Unsubscribe previous candles & order book (use full symbol with dex prefix)
        let prevCoin     = selectedSymbol
        let prevInterval = selectedInterval
        ws.unsubscribeCandles(coin: prevCoin, interval: prevInterval)
        unsubscribeOrderBook(clearDisplay: true)

        selectedSymbol   = symbol
        selectedInterval = interval
        livePriceCoin    = perpEquivalent

        // Derive display name: custom → keep existing → strip dex prefix → raw symbol
        if let dn = displayName {
            selectedDisplayName = dn
        } else if selectedDisplayName.isEmpty || selectedDisplayName == symbol {
            if let idx = symbol.firstIndex(of: ":") {
                selectedDisplayName = String(symbol[symbol.index(after: idx)...])
            } else {
                selectedDisplayName = symbol
            }
        }

        isLoading        = true
        errorMessage     = nil
        candles          = []


        do {
            var fetched = try await api.fetchCandles(coin: symbol, interval: interval)
            // Guarantee ascending time order regardless of API response ordering
            fetched.sort { $0.t < $1.t }
            candles   = fetched
            livePrice = candles.last?.close ?? 0
            print("✅ REST candles: \(candles.count) for \(symbol)/\(interval.rawValue) | first.t=\(candles.first?.t ?? 0) last.t=\(candles.last?.t ?? 0)")
            subscribeCandles()
        } catch let apiErr as APIError {
            switch apiErr {
            case .serverError(500):
                errorMessage = "Chart data unavailable for this market"
            default:
                errorMessage = apiErr.localizedDescription
            }
            print("❌ fetchCandles error: \(apiErr)")
        } catch {
            errorMessage = error.localizedDescription
            print("❌ fetchCandles error: \(error)")
        }

        isLoading = false

        // Signal TradingView chart to re-fetch bars from the bridge
        refreshTrigger += 1

        // Re-subscribe order book for the new symbol so it doesn't stay
        // empty if the user was already on the Order Book tab.
        await refreshOrderBook()
    }

    func changeInterval(_ interval: ChartInterval) {
        // Only reload candles — the order book is independent of the candle interval.
        let prevCoin     = selectedSymbol
        let prevInterval = selectedInterval
        ws.unsubscribeCandles(coin: prevCoin, interval: prevInterval)
        // Clear candle handler immediately so no stale WS candle arrives
        // into an empty array (which would show as a single huge candle flash).
        ws.onCandle = nil

        selectedInterval = interval

        Task {
            isLoading = true
            candles   = []
            do {
                var fetched = try await api.fetchCandles(coin: selectedSymbol, interval: interval)
                fetched.sort { $0.t < $1.t }
                candles   = fetched
                livePrice = candles.last?.close ?? 0
                subscribeCandles()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func changeSymbol(_ symbol: String, displayName: String? = nil, perpEquivalent: String? = nil) {
        guard symbol != selectedSymbol else { return }
        Task { await loadChart(symbol: symbol, interval: selectedInterval,
                               displayName: displayName, perpEquivalent: perpEquivalent) }
    }

    // Called when the Order Book tab becomes visible.
    // Starts WS immediately (so the book appears as soon as the first WS snapshot arrives),
    // then enriches depth from a REST snapshot if the REST call returns non-empty data.
    // For HIP-3 markets where the REST l2Book endpoint may not return data, the WS
    // first-message full snapshot seeds the local book on its own.
    func refreshOrderBook(nSigFigs: Int = 5) async {
        // When precision changes, tear down the old WS subscription before re-seeding.
        if nSigFigs != currentNSigFigs { unsubscribeOrderBook() }
        currentNSigFigs = nSigFigs

        // 1. Start WS FIRST — the first WS message is a full l2Book snapshot that seeds
        //    the book regardless of whether the REST call below succeeds.
        subscribeOrderBook(nSigFigs: nSigFigs)

        // 2. Try REST to get deeper levels. Pass selectedSymbol so fetchOrderBook
        //    includes the dex parameter for HIP-3 markets and finds the correct book.
        do {
            let snapshot = try await api.fetchOrderBook(coin: selectedSymbol, nSigFigs: nSigFigs)
            // Only seed from REST if it returned real data — don't overwrite a WS-seeded
            // book with an empty snapshot (happens when the endpoint can't find the coin).
            guard !snapshot.bids.isEmpty else {
                print("⚠️ REST snapshot empty for \(selectedSymbol) — relying on WS seed")
                return
            }
            // Only apply REST snapshot if WS hasn't sent a delta in the last 500ms.
            // This prevents flickering from REST overwriting fresh WS state.
            let timeSinceLastWSDelta = Date().timeIntervalSince(lastL2BookUpdate)
            if timeSinceLastWSDelta > 0.5 {
                // WS is stale, apply full REST snapshot
                localBids = Dictionary(uniqueKeysWithValues: snapshot.bids.map { ($0.price, $0.size) })
                localAsks = Dictionary(uniqueKeysWithValues: snapshot.asks.map { ($0.price, $0.size) })
                rebuildOrderBook()
                print("✅ REST snapshot seeded (nSigFigs=\(nSigFigs)): bids=\(localBids.count) asks=\(localAsks.count)")
            } else {
                // WS is active — only backfill deep levels that WS doesn't cover
                let restBids = Dictionary(uniqueKeysWithValues: snapshot.bids.map { ($0.price, $0.size) })
                let restAsks = Dictionary(uniqueKeysWithValues: snapshot.asks.map { ($0.price, $0.size) })
                var changed = false
                for (price, size) in restBids where localBids[price] == nil {
                    localBids[price] = size; changed = true
                }
                for (price, size) in restAsks where localAsks[price] == nil {
                    localAsks[price] = size; changed = true
                }
                if changed { rebuildOrderBook() }
                print("✅ REST deep-fill only (WS active, delta \(String(format: "%.0f", timeSinceLastWSDelta * 1000))ms ago): bids=\(localBids.count) asks=\(localAsks.count)")
            }
        } catch {
            print("❌ fetchOrderBook error: \(error) — relying on WS seed")
        }
    }

    /// Called by OrderBookView when the user changes the aggregation tick size.
    /// Resubscribes REST + WS at the precision needed to fill all visible buckets.
    func updateOrderBookNSigFigs(_ nSigFigs: Int) {
        guard nSigFigs != currentNSigFigs else { return }
        Task { await refreshOrderBook(nSigFigs: nSigFigs) }
    }

    // Converts local price→size dicts to sorted OrderBookLevel arrays and publishes orderBook.
    // Called after every REST seed and every WS delta batch.
    // bidsChanged / asksChanged: only re-sort the side that actually changed.
    // Unchanged sides reuse the previous cachedBids / cachedAsks (O(1) cost).
    private func rebuildOrderBook(bidsChanged: Bool = true, asksChanged: Bool = true) {
        if bidsChanged {
            cachedBids = localBids
                .map { OrderBookLevel(px: String(format: "%.8f", $0.key),
                                      sz: String(format: "%.8f", $0.value), n: 1) }
                .sorted { $0.price > $1.price }
        }
        if asksChanged {
            cachedAsks = localAsks
                .map { OrderBookLevel(px: String(format: "%.8f", $0.key),
                                      sz: String(format: "%.8f", $0.value), n: 1) }
                .sorted { $0.price < $1.price }
        }
        let newBook = OrderBook(coin: selectedSymbol, bids: cachedBids, asks: cachedAsks)
        if orderBook != newBook {
            orderBook = newBook
        }
    }

    // MARK: - WebSocket: candles

    private func subscribeCandles() {
        // Pass full symbol including dex prefix (e.g. "xyz:SP500") for HIP-3 markets
        let rawCoin = selectedSymbol
        let rawInterval = selectedInterval.rawValue

        ws.connect()
        ws.subscribeCandles(coin: rawCoin, interval: selectedInterval)
        print("📡 Subscribed WS candles: \(rawCoin)/\(rawInterval)")

        // Live price: subscribe to allMids ticker (updates every ~1 s)
        // Uses the Combine publisher so MarketsViewModel's onAllMids callback isn't overwritten
        // For spot markets with a perp equivalent, use the perp coin for live price
        // (spot @xxx allMids prices are stale/atomic for non-canonical pairs).
        let priceCoin = livePriceCoin ?? rawCoin
        cancellables.removeAll()
        ws.allMidsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mids in
                guard let self else { return }
                if let priceStr = mids[priceCoin], let price = Double(priceStr) {
                    // Defer to next run loop to avoid publishing during a view update
                    DispatchQueue.main.async {
                        self.livePrice = price
                    }
                }
            }
            .store(in: &cancellables)

        // Candle updates — use DispatchQueue.main.async to avoid publishing
        // @Published changes during an in-progress SwiftUI view update pass.
        // (Task { @MainActor } can be scheduled mid-update, causing the
        // "Publishing changes from within view updates" warning.)
        ws.onCandle = { [weak self] candle in
            guard candle.s == rawCoin, candle.i == rawInterval else { return }
            DispatchQueue.main.async {
                self?.upsertCandle(candle)
            }
        }
    }

    /// Validate candle OHLC consistency to prevent fake wicks.
    /// Candle fields are `let` Strings, so we create a corrected copy when needed.
    private func validateCandle(_ candle: Candle) -> Candle {
        let o = candle.open, c = candle.close
        var h = candle.high, l = candle.low
        // Ensure high >= max(open, close) and low <= min(open, close)
        h = max(h, max(o, c))
        l = min(l, min(o, c))
        // Ensure high >= low
        if h < l { swap(&h, &l) }
        // Only create a new Candle if values actually changed
        guard h != candle.high || l != candle.low else { return candle }
        return Candle(t: candle.t, T: candle.T, s: candle.s, i: candle.i,
                      o: candle.o, c: candle.c,
                      h: String(h), l: String(l),
                      v: candle.v, n: candle.n)
    }

    private func upsertCandle(_ rawCandle: Candle) {
        let candle = validateCandle(rawCandle)
        guard let last = candles.last else {
            candles.append(candle)
            print("🕯 upsert: first candle appended t=\(candle.t) | total=1")
            return
        }

        // Match by interval bucket: both t values should fall in the same period.
        // Using exact-t comparison alone fails when server rounds the open-time differently.
        let intervalMs = Int64(selectedInterval.durationSeconds) * 1_000
        let lastBucket   = intervalMs > 0 ? last.t   / intervalMs : last.t
        let candleBucket = intervalMs > 0 ? candle.t / intervalMs : candle.t

        if lastBucket == candleBucket {
            // Hyperliquid WS sends h = l = c on each tick (no server-side accumulation).
            // Accumulate running high/low locally; preserve the period's original open.
            let newHigh = last.high >= candle.close ? last.h : candle.c
            let newLow  = last.low  <= candle.close ? last.l : candle.c
            let merged  = Candle(t: candle.t, T: candle.T, s: candle.s, i: candle.i,
                                 o: last.o,
                                 c: candle.c,
                                 h: newHigh,
                                 l: newLow,
                                 v: candle.v,
                                 n: candle.n)
            candles[candles.count - 1] = merged
            print("🕯 upsert: merged last | c=\(candle.c) h=\(merged.h) l=\(merged.l) | total=\(candles.count)")
        } else if candle.t > last.t {
            // New period started → append
            candles.append(candle)
            if candles.count > 1000 { candles.removeFirst(candles.count - 1000) }
            print("🕯 upsert: NEW candle appended t=\(candle.t) c=\(candle.c) | total=\(candles.count)")
        } else {
            // Stale or out-of-order → ignore
            print("🕯 upsert: IGNORED stale candle t=\(candle.t) last.t=\(last.t)")
        }
    }

    // MARK: - WebSocket: order book

    private func subscribeOrderBook(nSigFigs: Int = 5) {
        // Pass full symbol (e.g. "xyz:SP500") — the WS l2Book accepts the dex prefix in coin
        let rawCoin = selectedSymbol
        guard subscribedOrderBookCoin != rawCoin else { return }
        subscribedOrderBookCoin = rawCoin

        ws.connect()
        ws.subscribeOrderBook(coin: rawCoin, nSigFigs: nSigFigs)
        print("📡 Subscribed WS orderBook: \(rawCoin) nSigFigs=\(nSigFigs)")

        // Health-check REST fallback — only fetch if no WS l2Book delta in 5 s.
        // This replaces the previous unconditional 2-second polling (30 req/min → ~12 req/min max,
        // typically 0 when WS is healthy).
        bookRefreshTask?.cancel()
        bookRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)    // 5 s
                guard !Task.isCancelled, let self else { break }
                guard self.subscribedOrderBookCoin == rawCoin,
                      self.currentNSigFigs == nSigFigs else { continue }
                // Skip REST fetch if WS is delivering fresh data
                if Date().timeIntervalSince(self.lastL2BookUpdate) < 5.0 { continue }
                guard let snapshot = try? await self.api.fetchOrderBook(coin: self.selectedSymbol,
                                                                        nSigFigs: nSigFigs),
                      !Task.isCancelled,
                      self.subscribedOrderBookCoin == rawCoin,
                      self.currentNSigFigs == nSigFigs,
                      !snapshot.bids.isEmpty else { continue }
                // Only update if the snapshot actually differs from current state
                let newBids = Dictionary(uniqueKeysWithValues: snapshot.bids.map { ($0.price, $0.size) })
                let newAsks = Dictionary(uniqueKeysWithValues: snapshot.asks.map { ($0.price, $0.size) })
                guard newBids != self.localBids || newAsks != self.localAsks else { continue }
                self.localBids = newBids
                self.localAsks = newAsks
                self.rebuildOrderBook()
            }
        }

        ws.onOrderBook = { [weak self] book, coin in
            // Use DispatchQueue.main.async to avoid publishing @Published changes
            // during an in-progress SwiftUI view update pass.
            DispatchQueue.main.async {
                guard let self, coin == rawCoin else { return }
                // No localBids.isEmpty gate — the first WS message is always a full
                // snapshot that seeds the book even when REST returned nothing.

                // Hyperliquid WS l2Book sends near-spread snapshots: each message
                // contains the CURRENT levels in its price range. Levels absent from
                // the message no longer exist and must be removed.
                //
                // Strategy: clear all local levels within the WS message's price range,
                // then add the WS levels. Deep REST levels outside the range are kept
                // so large aggregation ticks still have enough data.

                var bidsChanged = !book.bids.isEmpty
                var asksChanged = !book.asks.isEmpty

                if !book.bids.isEmpty {
                    let wsBidPrices = book.bids.compactMap { $0.size > 0 ? $0.price : nil }
                    if let wsMinBid = wsBidPrices.min() {
                        // Remove all local bids at or above the deepest WS bid
                        // (WS covers this range authoritatively)
                        self.localBids = self.localBids.filter { $0.key < wsMinBid }
                        bidsChanged = true
                    }
                    // Add WS bid levels
                    for level in book.bids where level.size > 0 {
                        self.localBids[level.price] = level.size
                    }
                }

                if !book.asks.isEmpty {
                    let wsAskPrices = book.asks.compactMap { $0.size > 0 ? $0.price : nil }
                    if let wsMaxAsk = wsAskPrices.max() {
                        // Remove all local asks at or below the deepest WS ask
                        self.localAsks = self.localAsks.filter { $0.key > wsMaxAsk }
                        asksChanged = true
                    }
                    // Add WS ask levels
                    for level in book.asks where level.size > 0 {
                        self.localAsks[level.price] = level.size
                    }
                }

                self.lastL2BookUpdate = Date()
                self.rebuildOrderBook(bidsChanged: bidsChanged, asksChanged: asksChanged)
            }
        }
    }

    // MARK: - Order book cleanup

    private func unsubscribeOrderBook(clearDisplay: Bool = false) {
        bookRefreshTask?.cancel()
        bookRefreshTask = nil
        guard let coin = subscribedOrderBookCoin else { return }
        ws.unsubscribeOrderBook(coin: coin, nSigFigs: currentNSigFigs)
        subscribedOrderBookCoin = nil
        ws.onOrderBook = nil
        // Reset local book so stale depth from the previous pair is never shown.
        localBids = [:]
        localAsks = [:]
        cachedBids = []
        cachedAsks = []
        // Only clear the displayed book on coin/symbol changes.
        // On nSigFigs-only changes we keep the old orderBook visible so OrderBookView
        // is never destroyed — destroying it would reset its @State aggIndex to 0,
        // which would immediately trigger the wrong nSigFigs for the new tick size.
        if clearDisplay { orderBook = nil }
    }

    // MARK: - Reconnection reconciliation

    /// Fetch a fresh REST order book snapshot and replace the local state.
    /// Called after WebSocket reconnection to reconcile stale data.
    private func fetchAndSeedOrderBook() async {
        guard subscribedOrderBookCoin != nil else { return }
        do {
            let snapshot = try await api.fetchOrderBook(coin: selectedSymbol, nSigFigs: currentNSigFigs)
            guard !snapshot.bids.isEmpty else { return }
            localBids = Dictionary(uniqueKeysWithValues: snapshot.bids.map { ($0.price, $0.size) })
            localAsks = Dictionary(uniqueKeysWithValues: snapshot.asks.map { ($0.price, $0.size) })
            rebuildOrderBook()
            print("🔄 Reconnect: order book re-seeded bids=\(localBids.count) asks=\(localAsks.count)")
        } catch {
            print("❌ Reconnect fetchOrderBook error: \(error)")
        }
    }

    /// Fetch candles from the last known timestamp to now and merge them
    /// into the existing array to fill any gap caused by a WS disconnect.
    private func fillCandleGap() async {
        guard let lastCandle = candles.last else { return }
        let startMs = lastCandle.t
        let endMs = Int64(Date().timeIntervalSince1970 * 1000)
        // No gap to fill if the last candle is very recent
        guard endMs - startMs > 1000 else { return }
        do {
            var fetched = try await api.fetchCandlesRange(
                coin: selectedSymbol, interval: selectedInterval,
                startMs: startMs, endMs: endMs
            )
            fetched.sort { $0.t < $1.t }
            guard !fetched.isEmpty else { return }

            let intervalMs = Int64(selectedInterval.durationSeconds) * 1_000
            for candle in fetched {
                let validated = validateCandle(candle)
                // Check if this candle overlaps with the last one in the array
                if let last = candles.last {
                    let lastBucket   = intervalMs > 0 ? last.t / intervalMs : last.t
                    let candleBucket = intervalMs > 0 ? validated.t / intervalMs : validated.t
                    if lastBucket == candleBucket {
                        // Update the existing last candle with REST data (more authoritative)
                        candles[candles.count - 1] = validated
                    } else if validated.t > last.t {
                        candles.append(validated)
                    }
                } else {
                    candles.append(validated)
                }
            }
            if candles.count > 1000 { candles.removeFirst(candles.count - 1000) }
            livePrice = candles.last?.close ?? livePrice
            print("🔄 Reconnect: filled candle gap with \(fetched.count) candles, total=\(candles.count)")
        } catch {
            print("❌ Reconnect fillCandleGap error: \(error)")
        }
    }
}
