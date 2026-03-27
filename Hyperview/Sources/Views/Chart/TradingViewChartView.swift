import SwiftUI
import WebKit
import Combine

// MARK: - TradingView Chart (WKWebView wrapper)

struct TradingViewChartView: UIViewRepresentable {
    @EnvironmentObject var chartVM: ChartViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.userContentController.add(context.coordinator, name: "tradingview")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        let bg = UIColor(red: 10/255, green: 10/255, blue: 10/255, alpha: 1)
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        context.coordinator.chartVM = chartVM

        // Prefetch candles NOW — starts the API call immediately while WebView
        // parses 25MB of TradingView JS. By the time getBars fires, data is ready.
        if !chartVM.isCustomTVChart {
            context.coordinator.prefetchCandles(
                symbol: chartVM.selectedSymbol,
                interval: chartVM.selectedInterval
            )
        }

        // Load the HTML from TradingView subfolder (copied by build script)
        let tvDir = Bundle.main.bundleURL.appendingPathComponent("TradingView")
        let htmlURL = tvDir.appendingPathComponent("tradingview.html")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: tvDir)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.chartVM = chartVM

        guard coord.isChartReady else { return }

        // Detect symbol changes → tell TradingView to switch without full reload
        let sym = chartVM.selectedSymbol
        let isCustom = chartVM.isCustomTVChart
        let symbolChanged = coord.currentSymbol != sym || coord.currentIsCustom != isCustom

        if symbolChanged {
            coord.currentSymbol = sym
            coord.currentIsCustom = isCustom
            coord.changeSymbol(sym, interval: chartVM.selectedInterval, isCustom: isCustom)
            // Also consume the refresh trigger so we don't double-fetch
            coord.lastRefreshTrigger = chartVM.refreshTrigger
            return
        }

        // Detect refresh trigger → force TV chart to re-fetch data
        let trigger = chartVM.refreshTrigger
        if trigger != coord.lastRefreshTrigger {
            coord.lastRefreshTrigger = trigger
            coord.refreshChart()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var chartVM: ChartViewModel?
        var isChartReady = false
        var currentSymbol: String?
        var currentIsCustom: Bool = false
        var lastRefreshTrigger: Int = 0
        private var candleSub: AnyCancellable?
        private var livePriceSub: AnyCancellable?
        private var previousLivePrice: Double = 0

        // Track current WS subscription
        private var subscribedSymbol: String?
        private var subscribedInterval: String?

        // MARK: - Candle Prefetch
        // Single shared Task per symbol — getBars awaits it instead of making a 2nd request.
        // Key insight: prefetch starts in makeUIView (before JS loads), getBars just awaits the result.

        /// The active prefetch task. getBars can `await` this instead of making a duplicate call.
        private var activePrefetch: (key: String, task: Task<[Candle], Error>)?

        /// In-memory LRU cache for previously viewed coins.
        private static var candleCache: [String: (candles: [Candle], date: Date)] = [:]
        private static let maxCacheEntries = 8
        private static let cacheMaxAge: TimeInterval = 120 // 2 min

        /// Start prefetching candles. If already in-flight for same key, no-op.
        func prefetchCandles(symbol: String, interval: ChartInterval) {
            let key = "\(symbol):\(interval.rawValue)"

            // Already cached and fresh? Nothing to do.
            if let cached = Self.candleCache[key], Date().timeIntervalSince(cached.date) < Self.cacheMaxAge {
                return
            }

            // Already prefetching this exact key? Don't duplicate.
            if activePrefetch?.key == key { return }

            // Cancel previous prefetch (different symbol)
            activePrefetch?.task.cancel()

            let task = Task<[Candle], Error> {
                let candles = try await HyperliquidAPI.shared.fetchCandles(coin: symbol, interval: interval)
                // Store in cache
                if Self.candleCache.count >= Self.maxCacheEntries {
                    let oldest = Self.candleCache.min(by: { $0.value.date < $1.value.date })
                    if let k = oldest?.key { Self.candleCache.removeValue(forKey: k) }
                }
                Self.candleCache[key] = (candles, Date())
                return candles
            }

            activePrefetch = (key, task)
        }

        /// Get candles: returns from cache, awaits in-flight prefetch, or fetches fresh.
        /// This is the SINGLE source of truth — never duplicates a request.
        func getCandles(symbol: String, interval: ChartInterval) async throws -> [Candle] {
            let key = "\(symbol):\(interval.rawValue)"

            // 1. Check memory cache
            if let cached = Self.candleCache[key], Date().timeIntervalSince(cached.date) < Self.cacheMaxAge {
                return cached.candles
            }

            // 2. Await in-flight prefetch if it matches
            if let prefetch = activePrefetch, prefetch.key == key {
                return try await prefetch.task.value
            }

            // 3. No prefetch in flight — fetch now (and cache)
            let candles = try await HyperliquidAPI.shared.fetchCandles(coin: symbol, interval: interval)
            if Self.candleCache.count >= Self.maxCacheEntries {
                let oldest = Self.candleCache.min(by: { $0.value.date < $1.value.date })
                if let k = oldest?.key { Self.candleCache.removeValue(forKey: k) }
            }
            Self.candleCache[key] = (candles, Date())
            return candles
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let vm = chartVM else { return }
            let symbol = vm.selectedSymbol
            currentSymbol = symbol
            let isCustom = vm.isCustomTVChart
            currentIsCustom = isCustom

            let interval = Self.hlIntervalToTV(vm.selectedInterval)
            let js = "initChart('\(Self.escapeJS(symbol))', '\(interval)', 'dark', \(isCustom));"
            webView.evaluateJavaScript(js)
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }

            let requestId = json["id"] as? Int

            switch type {
            case "chartReady":
                isChartReady = true
                startLivePriceLineUpdates()

            case "resolveSymbol":
                handleResolveSymbol(json, requestId: requestId)

            case "getBars":
                handleGetBars(json, requestId: requestId)

            case "subscribeBars":
                handleSubscribeBars(json, requestId: requestId)

            case "unsubscribeBars":
                handleUnsubscribeBars(json, requestId: requestId)

            default:
                break
            }
        }

        // MARK: - Symbol Resolution

        private func handleResolveSymbol(_ json: [String: Any], requestId: Int?) {
            guard let requestId else { return }

            let symbol = json["symbol"] as? String ?? "BTC"
            let isCustom = json["isCustom"] as? Bool ?? false

            if isCustom {
                handleResolveSymbolExternal(symbol, requestId: requestId)
            } else {
                // Run async so we can await prefetched candles for accurate pricescale
                Task { @MainActor in
                    await handleResolveSymbolHL(symbol, requestId: requestId)
                }
            }
        }

        private func handleResolveSymbolHL(_ symbol: String, requestId: Int) async {
            let vm = chartVM
            let interval = vm?.selectedInterval ?? .oneHour

            // IMPORTANT: Only use symbol-specific price sources.
            // vm.candles and vm.livePrice may still hold the PREVIOUS symbol's data
            // during changeSymbol, which would give completely wrong pricescale.

            var referencePrice: Double = 0

            // 1. Candle cache — keyed by exact symbol, always correct
            if referencePrice == 0 {
                let key = "\(symbol):\(interval.rawValue)"
                referencePrice = Self.candleCache[key]?.candles.last?.close ?? 0
            }

            // 2. Await in-flight prefetch for THIS symbol — guarantees correct data
            if referencePrice == 0, let prefetch = activePrefetch, prefetch.key.hasPrefix("\(symbol):") {
                if let candles = try? await prefetch.task.value, let last = candles.last {
                    referencePrice = last.close
                }
            }

            // 3. Only use vm.candles if the symbol matches (not stale from previous)
            if referencePrice == 0, vm?.selectedSymbol == symbol {
                referencePrice = vm?.candles.last?.close ?? 0
            }

            // Compute pricescale using 5 significant figures — matches header display
            let priceDecimals: Int
            if referencePrice > 0 {
                priceDecimals = Market.sigFigDecimals(referencePrice)
            } else {
                // No price available yet — use 2 as safe default
                priceDecimals = 2
            }
            let pricescale = Int(pow(10.0, Double(priceDecimals)))

            let displayName = vm?.displayName ?? symbol
            let info: [String: Any] = [
                "name": symbol,
                "description": displayName,
                "type": "crypto",
                "pricescale": pricescale
            ]
            print("[CHART] resolveSymbol \(symbol) refPrice=\(referencePrice) decimals=\(priceDecimals) pricescale=\(pricescale)")
            resolveJSRequest(requestId, data: info)
        }

        private func handleResolveSymbolExternal(_ symbol: String, requestId: Int) {
            // Check if this is an expression (ratio) symbol like "BINANCE:HYPEUSDT/BINANCE:LITUSDT"
            if Self.isExpressionSymbol(symbol) {
                handleResolveSymbolExpression(symbol, requestId: requestId)
                return
            }

            // symbol = "BINANCE:ETHUSDT" or "HYPERLIQUID:HYPE" etc.
            let parts = symbol.split(separator: ":", maxSplits: 1)
            let exchange = parts.count > 1 ? String(parts[0]) : ""
            let pair = parts.count > 1 ? String(parts[1]) : symbol

            // Fetch latest price to auto-detect pricescale — routes to correct exchange
            Task { @MainActor in
                var pricescale = 100  // default 2 decimals
                if let price = await Self.fetchLatestPriceForExchange(exchange: exchange, pair: pair) {
                    pricescale = Self.pricescaleFromPrice(price)
                }

                let info: [String: Any] = [
                    "name": symbol,
                    "description": self.chartVM?.displayName ?? pair,
                    "type": "crypto",
                    "exchange": exchange,
                    "pricescale": pricescale
                ]
                self.resolveJSRequest(requestId, data: info)
            }
        }

        /// Detect expression symbols like "BINANCE:HYPEUSDT/BINANCE:LITUSDT"
        private static func isExpressionSymbol(_ symbol: String) -> Bool {
            // Must contain "/" with content on both sides, and at least one side must have ":"
            let sides = symbol.split(separator: "/", maxSplits: 1)
            return sides.count == 2 && !sides[0].isEmpty && !sides[1].isEmpty
                && (sides[0].contains(":") || sides[1].contains(":"))
        }

        /// Parse expression into (numerator, denominator) — each is "EXCHANGE:PAIR"
        private static func parseExpression(_ symbol: String) -> (num: String, den: String)? {
            let sides = symbol.split(separator: "/", maxSplits: 1)
            guard sides.count == 2 else { return nil }
            return (String(sides[0]), String(sides[1]))
        }

        /// Extract exchange + pair from "EXCHANGE:PAIR" or just "PAIR"
        private static func parseExchangePair(_ s: String) -> (exchange: String, pair: String) {
            let parts = s.split(separator: ":", maxSplits: 1)
            if parts.count > 1 {
                return (String(parts[0]), String(parts[1]))
            }
            return ("BINANCE", s)
        }

        /// Resolve an expression symbol — fetch prices for both sides to compute pricescale
        private func handleResolveSymbolExpression(_ symbol: String, requestId: Int) {
            Task { @MainActor in
                var pricescale = 100000  // 5 decimals for ratios by default

                if let expr = Self.parseExpression(symbol) {
                    let numEP = Self.parseExchangePair(expr.num)
                    let denEP = Self.parseExchangePair(expr.den)

                    async let numPrice = Self.fetchLatestPriceForExchange(exchange: numEP.exchange, pair: numEP.pair)
                    async let denPrice = Self.fetchLatestPriceForExchange(exchange: denEP.exchange, pair: denEP.pair)

                    if let np = await numPrice, let dp = await denPrice, dp > 0 {
                        let ratio = np / dp
                        pricescale = Self.pricescaleFromPrice(ratio)
                    }
                }

                let displayName = self.chartVM?.displayName ?? symbol
                let info: [String: Any] = [
                    "name": symbol,
                    "description": displayName,
                    "type": "crypto",
                    "exchange": "Expression",
                    "pricescale": pricescale
                ]
                self.resolveJSRequest(requestId, data: info)
            }
        }

        /// Determine pricescale from price magnitude
        private static func pricescaleFromPrice(_ price: Double) -> Int {
            if price >= 10000     { return 100 }       // 2 decimals
            if price >= 100       { return 100 }       // 2 decimals
            if price >= 1         { return 1000 }      // 3 decimals
            if price >= 0.01      { return 10000 }     // 4 decimals
            if price >= 0.0001    { return 1000000 }   // 6 decimals
            return 100000000                           // 8 decimals
        }

        /// Quick price check for a custom symbol
        private static func fetchLatestPrice(exchange: String, pair: String) async -> Double? {
            let resolved = resolveBinancePair(pair)
            let urlStr = "\(resolved.apiBase)/ticker/price?symbol=\(resolved.symbol)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let priceStr = json["price"] as? String,
                   let price = Double(priceStr) {
                    return price
                }
            } catch {}
            return nil
        }

        // MARK: - Historical Bars

        private func handleGetBars(_ json: [String: Any], requestId: Int?) {
            guard let requestId,
                  let symbol = json["symbol"] as? String,
                  let interval = json["interval"] as? String,
                  let from = json["from"] as? Double,
                  let to = json["to"] as? Double else {
                if let rid = requestId { rejectJSRequest(rid, error: "Invalid params") }
                return
            }

            let isCustom = json["isCustom"] as? Bool ?? false
            let countBack = json["countBack"] as? Int ?? 300
            let firstDataRequest = json["firstDataRequest"] as? Bool ?? false

            if isCustom {
                handleGetBarsExternal(symbol: symbol, interval: interval,
                                      from: from, to: to, countBack: countBack,
                                      requestId: requestId)
            } else {
                handleGetBarsHL(symbol: symbol, interval: interval,
                                from: from, to: to, countBack: countBack,
                                firstDataRequest: firstDataRequest,
                                requestId: requestId)
            }
        }

        private func handleGetBarsHL(symbol: String, interval: String,
                                     from: Double, to: Double, countBack: Int,
                                     firstDataRequest: Bool, requestId: Int) {
            Task { @MainActor in
                do {
                    let hlInterval = ChartInterval(rawValue: interval) ?? .oneHour
                    let startMs = Int64(from) * 1000
                    let endMs   = Int64(to) * 1000

                    var candles: [Candle]

                    if firstDataRequest {
                        // Uses cache → awaits in-flight prefetch → or fetches fresh.
                        // NEVER duplicates a request.
                        candles = try await getCandles(symbol: symbol, interval: hlInterval)
                    } else {
                        // Scrolling back in history — always fresh range fetch
                        candles = try await HyperliquidAPI.shared.fetchCandlesRange(
                            coin: symbol, interval: hlInterval,
                            startMs: startMs, endMs: endMs
                        )
                    }

                    candles.sort { $0.t < $1.t }
                    candles = candles.filter { c in
                        let cTimeSec = Double(c.t) / 1000.0
                        return cTimeSec >= from && cTimeSec <= to
                    }
                    if candles.count > countBack {
                        candles = Array(candles.suffix(countBack))
                    }

                    let bars: [[String: Any]] = candles.map { c in
                        ["time": c.t, "open": c.open, "high": c.high,
                         "low": c.low, "close": c.close, "volume": c.volume]
                    }
                    self.resolveJSRequest(requestId, data: ["bars": bars, "noData": candles.isEmpty])
                } catch {
                    self.rejectJSRequest(requestId, error: error.localizedDescription)
                }
            }
        }

        private func handleGetBarsExternal(symbol: String, interval: String,
                                           from: Double, to: Double, countBack: Int,
                                           requestId: Int) {
            // Expression symbol (ratio chart) — fetch both sides and compute ratio
            if Self.isExpressionSymbol(symbol) {
                handleGetBarsExpression(symbol: symbol, interval: interval,
                                        from: from, to: to, countBack: countBack,
                                        requestId: requestId)
                return
            }

            Task { @MainActor in
                do {
                    let parts = symbol.split(separator: ":", maxSplits: 1)
                    let exchange = parts.count > 1 ? String(parts[0]).uppercased() : ""
                    let pair = parts.count > 1 ? String(parts[1]) : symbol

                    let startMs = Int64(from) * 1000
                    let endMs   = Int64(to) * 1000

                    let bars = try await Self.fetchKlinesForExchange(
                        exchange: exchange, pair: pair, interval: interval,
                        startMs: startMs, endMs: endMs, limit: min(countBack, 1000))

                    self.resolveJSRequest(requestId, data: ["bars": bars, "noData": bars.isEmpty])
                } catch {
                    // Return noData gracefully — don't break the chart
                    self.resolveJSRequest(requestId, data: ["bars": [] as [[String: Any]], "noData": true])
                }
            }
        }

        /// Fetch bars for both sides of an expression and compute the ratio
        private func handleGetBarsExpression(symbol: String, interval: String,
                                              from: Double, to: Double, countBack: Int,
                                              requestId: Int) {
            Task { @MainActor in
                guard let expr = Self.parseExpression(symbol) else {
                    self.resolveJSRequest(requestId, data: ["bars": [] as [[String: Any]], "noData": true])
                    return
                }

                let numEP = Self.parseExchangePair(expr.num)
                let denEP = Self.parseExchangePair(expr.den)

                let startMs = Int64(from) * 1000
                let endMs   = Int64(to) * 1000
                let limit = min(countBack, 1000)
                let bucketMs = Self.intervalToMs(interval)

                do {
                    // Fetch both sides in parallel — each routes to its own exchange
                    async let numBars = Self.fetchKlinesForExchange(
                        exchange: numEP.exchange, pair: numEP.pair, interval: interval,
                        startMs: startMs, endMs: endMs, limit: limit)
                    async let denBars = Self.fetchKlinesForExchange(
                        exchange: denEP.exchange, pair: denEP.pair, interval: interval,
                        startMs: startMs, endMs: endMs, limit: limit)

                    let numResult = try await numBars
                    let denResult = try await denBars

                    // Index denominator bars by normalized timestamp for cross-exchange matching
                    var denByBucket: [Int64: [String: Any]] = [:]
                    for bar in denResult {
                        if let t = bar["time"] as? Int64 {
                            let bucket = (t / bucketMs) * bucketMs
                            denByBucket[bucket] = bar
                        }
                    }

                    // Compute ratio bars (only where both sides have data)
                    var ratioBars: [[String: Any]] = []
                    for numBar in numResult {
                        guard let t = numBar["time"] as? Int64,
                              let nO = numBar["open"] as? Double,
                              let nH = numBar["high"] as? Double,
                              let nL = numBar["low"] as? Double,
                              let nC = numBar["close"] as? Double
                        else { continue }

                        let bucket = (t / bucketMs) * bucketMs
                        guard let denBar = denByBucket[bucket],
                              let dO = denBar["open"] as? Double, dO > 0,
                              let dH = denBar["high"] as? Double, dH > 0,
                              let dL = denBar["low"] as? Double, dL > 0,
                              let dC = denBar["close"] as? Double, dC > 0
                        else { continue }

                        ratioBars.append([
                            "time": t,
                            "open": nO / dO,
                            "high": nH / dH,    // OHLC/OHLC matching (same as TradingView)
                            "low": nL / dL,
                            "close": nC / dC,
                            "volume": (numBar["volume"] as? Double ?? 0)
                        ])
                    }

                    self.resolveJSRequest(requestId, data: ["bars": ratioBars, "noData": ratioBars.isEmpty])
                } catch {
                    self.resolveJSRequest(requestId, data: ["bars": [] as [[String: Any]], "noData": true])
                }
            }
        }

        /// Convert interval string to milliseconds for timestamp normalization
        private static func intervalToMs(_ interval: String) -> Int64 {
            switch interval {
            case "1m":  return 60_000
            case "2m":  return 120_000
            case "3m":  return 180_000
            case "5m":  return 300_000
            case "15m": return 900_000
            case "30m": return 1_800_000
            case "1h":  return 3_600_000
            case "2h":  return 7_200_000
            case "4h":  return 14_400_000
            case "8h":  return 28_800_000
            case "12h": return 43_200_000
            case "1d":  return 86_400_000
            case "3d":  return 259_200_000
            case "1w":  return 604_800_000
            case "1M":  return 2_592_000_000  // ~30 days
            default:    return 3_600_000
            }
        }

        // MARK: - Generic Klines Fetch (routes to correct exchange)

        /// Fetch klines from the appropriate exchange API.
        /// Routes to exchange-specific APIs. Falls back to Binance if unknown exchange or if the primary fails.
        private static func fetchKlinesForExchange(exchange: String, pair: String, interval: String,
                                                    startMs: Int64, endMs: Int64, limit: Int) async throws -> [[String: Any]] {
            let ex = exchange.uppercased()

            // Primary: route to the correct exchange
            do {
                let bars = try await fetchKlinesForExchangeDirect(
                    exchange: ex, pair: pair, interval: interval,
                    startMs: startMs, endMs: endMs, limit: limit)
                if !bars.isEmpty { return bars }
            } catch {}

            // Fallback: try Binance spot if the primary exchange failed or returned empty
            if ex != "BINANCE" && ex != "HYPERLIQUID" && ex != "HL" {
                let fallbackBars = try? await fetchBinanceKlines(pair: pair, interval: interval,
                                                                  startMs: startMs, endMs: endMs, limit: limit)
                if let fb = fallbackBars, !fb.isEmpty { return fb }

                // Last resort: try Binance futures
                let futuresPair = pair.replacingOccurrences(of: ".P", with: "")
                let futuresUrl = "https://fapi.binance.com/fapi/v1/klines?symbol=\(futuresPair)&interval=\(hlToBinanceInterval(interval))&limit=\(limit)"
                    + (startMs > 0 ? "&startTime=\(startMs)" : "")
                    + (endMs > 0 ? "&endTime=\(endMs)" : "")
                if let url = URL(string: futuresUrl),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[Any]], !json.isEmpty {
                    return parseBinanceKlineArray(json)
                }
            }

            return []
        }

        /// Direct exchange-specific fetch without fallback
        private static func fetchKlinesForExchangeDirect(exchange: String, pair: String, interval: String,
                                                          startMs: Int64, endMs: Int64, limit: Int) async throws -> [[String: Any]] {
            switch exchange {
            case "HYPERLIQUID", "HL":
                let coin = stripQuoteSuffix(pair)
                return try await fetchHyperliquidKlines(coin: coin, interval: interval,
                                                        startMs: startMs, endMs: endMs, limit: limit)
            case "BINANCE":
                return try await fetchBinanceKlines(pair: pair, interval: interval,
                                                     startMs: startMs, endMs: endMs, limit: limit)
            case "BYBIT":
                return try await fetchBybitKlines(pair: pair, interval: interval,
                                                   startMs: startMs, endMs: endMs, limit: limit)
            case "OKX", "OKEX":
                return try await fetchOKXKlines(pair: pair, interval: interval,
                                                 startMs: startMs, endMs: endMs, limit: limit)
            case "KUCOIN":
                return try await fetchKuCoinKlines(pair: pair, interval: interval,
                                                    startMs: startMs, endMs: endMs, limit: limit)
            case "COINBASE", "COINBASEPRO":
                return try await fetchCoinbaseKlines(pair: pair, interval: interval,
                                                      startMs: startMs, endMs: endMs, limit: limit)
            case "KRAKEN":
                return try await fetchKrakenKlines(pair: pair, interval: interval,
                                                    startMs: startMs, endMs: endMs, limit: limit)
            case "GATEIO", "GATE":
                return try await fetchGateIOKlines(pair: pair, interval: interval,
                                                    startMs: startMs, endMs: endMs, limit: limit)
            case "MEXC":
                return try await fetchMEXCKlines(pair: pair, interval: interval,
                                                  startMs: startMs, endMs: endMs, limit: limit)
            case "HTX", "HUOBI":
                return try await fetchHTXKlines(pair: pair, interval: interval,
                                                 startMs: startMs, endMs: endMs, limit: limit)
            case "BITGET":
                return try await fetchBitgetKlines(pair: pair, interval: interval,
                                                    startMs: startMs, endMs: endMs, limit: limit)
            default:
                // Unknown exchange: try Binance format directly
                return try await fetchBinanceKlines(pair: pair, interval: interval,
                                                     startMs: startMs, endMs: endMs, limit: limit)
            }
        }

        /// Fetch latest price from the appropriate exchange (with Binance fallback)
        private static func fetchLatestPriceForExchange(exchange: String, pair: String) async -> Double? {
            let ex = exchange.uppercased()

            // Primary: exchange-specific
            if let price = await fetchLatestPriceDirect(exchange: ex, pair: pair) {
                return price
            }

            // Fallback: Binance
            if ex != "BINANCE" && ex != "HYPERLIQUID" && ex != "HL" {
                if let price = await fetchLatestPrice(exchange: "BINANCE", pair: pair) {
                    return price
                }
            }
            return nil
        }

        /// Direct exchange-specific price fetch
        private static func fetchLatestPriceDirect(exchange: String, pair: String) async -> Double? {
            switch exchange {
            case "HYPERLIQUID", "HL":
                let coin = stripQuoteSuffix(pair)
                guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "allMids"])
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    if let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let priceStr = mids[coin], let price = Double(priceStr) {
                        return price
                    }
                } catch {}
                return nil

            case "BYBIT":
                let clean = pair.replacingOccurrences(of: ".P", with: "")
                let urlStr = "https://api.bybit.com/v5/market/tickers?category=spot&symbol=\(clean)"
                guard let url = URL(string: urlStr) else { return nil }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = json["result"] as? [String: Any],
                       let list = result["list"] as? [[String: Any]],
                       let first = list.first,
                       let priceStr = first["lastPrice"] as? String,
                       let price = Double(priceStr) { return price }
                } catch {}
                return nil

            case "OKX", "OKEX":
                let instId = tvPairToOKXInstId(pair)
                let urlStr = "https://www.okx.com/api/v5/market/ticker?instId=\(instId)"
                guard let url = URL(string: urlStr) else { return nil }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let dataArr = json["data"] as? [[String: Any]],
                       let first = dataArr.first,
                       let priceStr = first["last"] as? String,
                       let price = Double(priceStr) { return price }
                } catch {}
                return nil

            case "KUCOIN":
                let kcSymbol = tvPairToKuCoinSymbol(pair)
                let urlStr = "https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=\(kcSymbol)"
                guard let url = URL(string: urlStr) else { return nil }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let innerData = json["data"] as? [String: Any],
                       let priceStr = innerData["price"] as? String,
                       let price = Double(priceStr) { return price }
                } catch {}
                return nil

            case "COINBASE", "COINBASEPRO":
                let cbProduct = tvPairToCoinbaseProduct(pair)
                let urlStr = "https://api.exchange.coinbase.com/products/\(cbProduct)/ticker"
                guard let url = URL(string: urlStr) else { return nil }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let priceStr = json["price"] as? String,
                       let price = Double(priceStr) { return price }
                } catch {}
                return nil

            case "KRAKEN":
                let krakenPair = tvPairToKrakenPair(pair)
                let urlStr = "https://api.kraken.com/0/public/Ticker?pair=\(krakenPair)"
                guard let url = URL(string: urlStr) else { return nil }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = json["result"] as? [String: Any],
                       let first = result.values.first as? [String: Any],
                       let cArr = first["c"] as? [String], let priceStr = cArr.first,
                       let price = Double(priceStr) { return price }
                } catch {}
                return nil

            default:
                return await fetchLatestPrice(exchange: exchange, pair: pair)
            }
        }

        /// Strip quote currency suffix to get the base coin name.
        /// "HYPEUSDT" → "HYPE", "BTCUSDC" → "BTC", "ETH" → "ETH"
        private static func stripQuoteSuffix(_ pair: String) -> String {
            let upper = pair.uppercased()
            for suffix in ["USDT", "USDC", "BUSD", "USD", "PERP"] {
                if upper.hasSuffix(suffix) && upper.count > suffix.count {
                    return String(upper.dropLast(suffix.count))
                }
            }
            return pair
        }

        // MARK: - Pair Format Converters

        /// "HYPEUSDT" → "HYPE-USDT" (KuCoin format)
        private static func tvPairToKuCoinSymbol(_ pair: String) -> String {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            for quote in ["USDT", "USDC", "BUSD", "BTC", "ETH", "KCS",
                          "EUR", "GBP", "BRL", "TRY", "ARS", "USD"] {
                if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                    let base = String(clean.dropLast(quote.count))
                    return "\(base)-\(quote)"
                }
            }
            return clean
        }

        /// "HYPEUSDT" → "HYPE-USDT" (OKX instId format)
        private static func tvPairToOKXInstId(_ pair: String) -> String {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            // OKX uses "BASE-QUOTE" format — match longest quote suffix first
            for quote in ["USDT", "USDC", "BUSD", "BTC", "ETH",
                          "EUR", "GBP", "BRL", "TRY", "ARS", "USD"] {
                if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                    let base = String(clean.dropLast(quote.count))
                    return "\(base)-\(quote)"
                }
            }
            return clean
        }

        /// "HYPEUSDT" → "HYPE-USDT" (Coinbase product format — also handles USD)
        private static func tvPairToCoinbaseProduct(_ pair: String) -> String {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            for quote in ["USDT", "USDC", "BUSD", "BTC", "ETH",
                          "EUR", "GBP", "BRL", "TRY", "ARS", "USD"] {
                if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                    let base = String(clean.dropLast(quote.count))
                    return "\(base)-\(quote)"
                }
            }
            return clean
        }

        /// "HYPEUSDT" → "HYPEUSDT" (Kraken uses concatenated, some legacy pairs differ)
        private static func tvPairToKrakenPair(_ pair: String) -> String {
            pair.replacingOccurrences(of: ".P", with: "")
        }

        /// "HYPEUSDT" → "HYPE_USDT" (Gate.io format)
        private static func tvPairToGateIOSymbol(_ pair: String) -> String {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            for quote in ["USDT", "USDC", "BUSD", "BTC", "ETH",
                          "EUR", "GBP", "BRL", "TRY", "ARS", "USD"] {
                if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                    let base = String(clean.dropLast(quote.count))
                    return "\(base)_\(quote)"
                }
            }
            return clean
        }

        // MARK: - Hyperliquid Klines

        /// Fetch candles from Hyperliquid API and return in bar format
        private static func fetchHyperliquidKlines(coin: String, interval: String,
                                                    startMs: Int64, endMs: Int64,
                                                    limit: Int) async throws -> [[String: Any]] {
            let hlInterval = ChartInterval(rawValue: interval) ?? .oneHour
            let candles: [Candle]
            if startMs > 0 {
                candles = try await HyperliquidAPI.shared.fetchCandlesRange(
                    coin: coin, interval: hlInterval,
                    startMs: startMs, endMs: endMs)
            } else {
                candles = try await HyperliquidAPI.shared.fetchCandles(
                    coin: coin, interval: hlInterval, limit: limit)
            }

            return candles.sorted { $0.t < $1.t }
                .prefix(limit)
                .map { c in
                    ["time": c.t, "open": c.open, "high": c.high,
                     "low": c.low, "close": c.close, "volume": c.volume]
                }
        }

        // MARK: - Binance Klines

        /// Detect TradingView suffixes and resolve the correct Binance API endpoint.
        /// ".P" = perpetual futures → fapi.binance.com, everything else → api.binance.com
        private static func resolveBinancePair(_ pair: String) -> (apiBase: String, symbol: String) {
            var clean = pair.replacingOccurrences(of: "/", with: "")

            // TradingView perpetual suffix ".P" → Binance USD-M futures
            if clean.hasSuffix(".P") {
                clean = String(clean.dropLast(2))
                return ("https://fapi.binance.com/fapi/v1", clean)
            }

            return ("https://api.binance.com/api/v3", clean)
        }

        private static func fetchBinanceKlines(pair: String, interval: String,
                                               startMs: Int64, endMs: Int64,
                                               limit: Int) async throws -> [[String: Any]] {
            let resolved = resolveBinancePair(pair)
            let binanceInterval = hlToBinanceInterval(interval)
            var urlStr = "\(resolved.apiBase)/klines?symbol=\(resolved.symbol)&interval=\(binanceInterval)&limit=\(limit)"
            if startMs > 0 { urlStr += "&startTime=\(startMs)" }
            if endMs > 0 { urlStr += "&endTime=\(endMs)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
            return parseBinanceKlineArray(json)
        }

        /// Parse Binance-format kline array (also used by MEXC which shares the same format)
        private static func parseBinanceKlineArray(_ json: [[Any]]) -> [[String: Any]] {
            json.compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let t = arr[0] as? Int64 ?? (arr[0] as? Double).map({ Int64($0) }),
                      let o = Double(arr[1] as? String ?? ""),
                      let h = Double(arr[2] as? String ?? ""),
                      let l = Double(arr[3] as? String ?? ""),
                      let c = Double(arr[4] as? String ?? ""),
                      let v = Double(arr[5] as? String ?? "") else { return nil }
                return ["time": t, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToBinanceInterval(_ hl: String) -> String {
            switch hl {
            case "1m", "3m", "5m", "15m", "30m": return hl
            case "2m": return "1m"  // Binance has no 2m
            case "1h", "2h", "4h", "8h", "12h":  return hl
            case "1d", "3d", "1w", "1M":          return hl
            default: return "1h"
            }
        }

        // MARK: - Bybit Klines

        private static func fetchBybitKlines(pair: String, interval: String,
                                              startMs: Int64, endMs: Int64,
                                              limit: Int) async throws -> [[String: Any]] {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let bybitInterval = hlToBybitInterval(interval)
            var urlStr = "https://api.bybit.com/v5/market/kline?category=spot&symbol=\(clean)&interval=\(bybitInterval)&limit=\(limit)"
            if startMs > 0 { urlStr += "&start=\(startMs)" }
            if endMs > 0 { urlStr += "&end=\(endMs)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let list = result["list"] as? [[String]] else { return [] }

            // Bybit returns [timestamp, open, high, low, close, volume, turnover] — newest first
            return list.reversed().compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let t = Int64(arr[0]),
                      let o = Double(arr[1]), let h = Double(arr[2]),
                      let l = Double(arr[3]), let c = Double(arr[4]),
                      let v = Double(arr[5]) else { return nil }
                return ["time": t, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToBybitInterval(_ hl: String) -> String {
            switch hl {
            case "1m": return "1"; case "3m": return "3"; case "5m": return "5"
            case "15m": return "15"; case "30m": return "30"
            case "1h": return "60"; case "2h": return "120"; case "4h": return "240"
            case "8h": return "480"; case "12h": return "720"
            case "1d": return "D"; case "1w": return "W"; case "1M": return "M"
            default: return "60"
            }
        }

        // MARK: - OKX Klines

        private static func fetchOKXKlines(pair: String, interval: String,
                                            startMs: Int64, endMs: Int64,
                                            limit: Int) async throws -> [[String: Any]] {
            let instId = tvPairToOKXInstId(pair)
            let okxBar = hlToOKXBar(interval)
            var urlStr = "https://www.okx.com/api/v5/market/candles?instId=\(instId)&bar=\(okxBar)&limit=\(min(limit, 300))"
            if endMs > 0 { urlStr += "&before=\(startMs > 0 ? startMs : 0)&after=\(endMs)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String]] else { return [] }

            // OKX returns [ts, o, h, l, c, vol, volCcy, volCcyQuote, confirm] — newest first
            return dataArr.reversed().compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let t = Int64(arr[0]),
                      let o = Double(arr[1]), let h = Double(arr[2]),
                      let l = Double(arr[3]), let c = Double(arr[4]),
                      let v = Double(arr[5]) else { return nil }
                return ["time": t, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToOKXBar(_ hl: String) -> String {
            switch hl {
            case "1m": return "1m"; case "3m": return "3m"; case "5m": return "5m"
            case "15m": return "15m"; case "30m": return "30m"
            case "1h": return "1H"; case "2h": return "2H"; case "4h": return "4H"
            case "8h": return "8H"; case "12h": return "12H"
            case "1d": return "1D"; case "3d": return "3D"; case "1w": return "1W"; case "1M": return "1M"
            default: return "1H"
            }
        }

        // MARK: - KuCoin Klines

        private static func fetchKuCoinKlines(pair: String, interval: String,
                                               startMs: Int64, endMs: Int64,
                                               limit: Int) async throws -> [[String: Any]] {
            let kcSymbol = tvPairToKuCoinSymbol(pair)
            let kcType = hlToKuCoinType(interval)
            var urlStr = "https://api.kucoin.com/api/v1/market/candles?type=\(kcType)&symbol=\(kcSymbol)"
            if startMs > 0 { urlStr += "&startAt=\(startMs / 1000)" }
            if endMs > 0 { urlStr += "&endAt=\(endMs / 1000)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String]] else { return [] }

            // KuCoin returns [time(s), open, close, high, low, volume, turnover] — newest first
            return dataArr.reversed().compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let tSec = Int64(arr[0]),
                      let o = Double(arr[1]), let c = Double(arr[2]),
                      let h = Double(arr[3]), let l = Double(arr[4]),
                      let v = Double(arr[5]) else { return nil }
                return ["time": tSec * 1000, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToKuCoinType(_ hl: String) -> String {
            switch hl {
            case "1m": return "1min"; case "3m": return "3min"; case "5m": return "5min"
            case "15m": return "15min"; case "30m": return "30min"
            case "1h": return "1hour"; case "2h": return "2hour"; case "4h": return "4hour"
            case "8h": return "8hour"; case "12h": return "12hour"
            case "1d": return "1day"; case "1w": return "1week"
            default: return "1hour"
            }
        }

        // MARK: - Coinbase Klines

        private static func fetchCoinbaseKlines(pair: String, interval: String,
                                                 startMs: Int64, endMs: Int64,
                                                 limit: Int) async throws -> [[String: Any]] {
            let product = tvPairToCoinbaseProduct(pair)
            let granularity = hlToCoinbaseGranularity(interval)
            var urlStr = "https://api.exchange.coinbase.com/products/\(product)/candles?granularity=\(granularity)"
            if startMs > 0 {
                let startISO = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(startMs) / 1000))
                let endISO = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(endMs > 0 ? endMs : Int64(Date().timeIntervalSince1970 * 1000)) / 1000))
                urlStr += "&start=\(startISO)&end=\(endISO)"
            }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }

            // Coinbase returns [timestamp(s), low, high, open, close, volume] — newest first
            return json.reversed().compactMap { arr -> [String: Any]? in
                guard arr.count >= 6 else { return nil }
                let tSec: Int64
                if let t = arr[0] as? Int64 { tSec = t }
                else if let t = arr[0] as? Double { tSec = Int64(t) }
                else { return nil }
                guard let l = arr[1] as? Double, let h = arr[2] as? Double,
                      let o = arr[3] as? Double, let c = arr[4] as? Double,
                      let v = arr[5] as? Double else { return nil }
                return ["time": tSec * 1000, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToCoinbaseGranularity(_ hl: String) -> Int {
            switch hl {
            case "1m": return 60; case "5m": return 300; case "15m": return 900
            case "1h": return 3600; case "6h": return 21600; case "1d": return 86400
            default: return 3600
            }
        }

        // MARK: - Kraken Klines

        private static func fetchKrakenKlines(pair: String, interval: String,
                                               startMs: Int64, endMs: Int64,
                                               limit: Int) async throws -> [[String: Any]] {
            let krakenPair = tvPairToKrakenPair(pair)
            let krakenInterval = hlToKrakenInterval(interval)
            var urlStr = "https://api.kraken.com/0/public/OHLC?pair=\(krakenPair)&interval=\(krakenInterval)"
            if startMs > 0 { urlStr += "&since=\(startMs / 1000)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else { return [] }

            // Kraken returns { "XXBTZUSD": [[time, o, h, l, c, vwap, vol, count], ...], "last": ... }
            for (key, value) in result {
                if key == "last" { continue }
                guard let ohlcArr = value as? [[Any]] else { continue }
                return ohlcArr.compactMap { arr -> [String: Any]? in
                    guard arr.count >= 7 else { return nil }
                    let tSec: Int64
                    if let t = arr[0] as? Int64 { tSec = t }
                    else if let t = arr[0] as? Double { tSec = Int64(t) }
                    else { return nil }
                    guard let o = Double(arr[1] as? String ?? ""),
                          let h = Double(arr[2] as? String ?? ""),
                          let l = Double(arr[3] as? String ?? ""),
                          let c = Double(arr[4] as? String ?? ""),
                          let v = Double(arr[6] as? String ?? "") else { return nil }
                    return ["time": tSec * 1000, "open": o, "high": h, "low": l, "close": c, "volume": v]
                }
            }
            return []
        }

        private static func hlToKrakenInterval(_ hl: String) -> Int {
            switch hl {
            case "1m": return 1; case "5m": return 5; case "15m": return 15; case "30m": return 30
            case "1h": return 60; case "4h": return 240
            case "1d": return 1440; case "1w": return 10080
            default: return 60
            }
        }

        // MARK: - Gate.io Klines

        private static func fetchGateIOKlines(pair: String, interval: String,
                                               startMs: Int64, endMs: Int64,
                                               limit: Int) async throws -> [[String: Any]] {
            let gateSymbol = tvPairToGateIOSymbol(pair)
            let gateInterval = hlToGateIOInterval(interval)
            var urlStr = "https://api.gateio.ws/api/v4/spot/candlesticks?currency_pair=\(gateSymbol)&interval=\(gateInterval)&limit=\(min(limit, 1000))"
            if startMs > 0 { urlStr += "&from=\(startMs / 1000)" }
            if endMs > 0 { urlStr += "&to=\(endMs / 1000)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String]] else { return [] }

            // Gate.io returns [unix_ts(s), vol, close, high, low, open, ...
            return json.compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let tSec = Int64(arr[0]),
                      let v = Double(arr[1]), let c = Double(arr[2]),
                      let h = Double(arr[3]), let l = Double(arr[4]),
                      let o = Double(arr[5]) else { return nil }
                return ["time": tSec * 1000, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToGateIOInterval(_ hl: String) -> String {
            switch hl {
            case "1m": return "1m"; case "5m": return "5m"; case "15m": return "15m"; case "30m": return "30m"
            case "1h": return "1h"; case "4h": return "4h"; case "8h": return "8h"
            case "1d": return "1d"; case "1w": return "7d"
            default: return "1h"
            }
        }

        // MARK: - MEXC Klines (Binance-compatible format)

        private static func fetchMEXCKlines(pair: String, interval: String,
                                             startMs: Int64, endMs: Int64,
                                             limit: Int) async throws -> [[String: Any]] {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let mexcInterval = hlToBinanceInterval(interval) // MEXC uses same interval format as Binance
            var urlStr = "https://api.mexc.com/api/v3/klines?symbol=\(clean)&interval=\(mexcInterval)&limit=\(limit)"
            if startMs > 0 { urlStr += "&startTime=\(startMs)" }
            if endMs > 0 { urlStr += "&endTime=\(endMs)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
            return parseBinanceKlineArray(json)
        }

        // MARK: - HTX (Huobi) Klines

        private static func fetchHTXKlines(pair: String, interval: String,
                                            startMs: Int64, endMs: Int64,
                                            limit: Int) async throws -> [[String: Any]] {
            let clean = pair.replacingOccurrences(of: ".P", with: "").lowercased()
            let htxPeriod = hlToHTXPeriod(interval)
            let urlStr = "https://api.huobi.pro/market/history/kline?symbol=\(clean)&period=\(htxPeriod)&size=\(min(limit, 2000))"

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else { return [] }

            // HTX returns [{id(s), open, close, high, low, vol, ...}] — newest first
            return dataArr.reversed().compactMap { d -> [String: Any]? in
                guard let tSec = d["id"] as? Int64 ?? (d["id"] as? Double).map({ Int64($0) }),
                      let o = d["open"] as? Double, let h = d["high"] as? Double,
                      let l = d["low"] as? Double, let c = d["close"] as? Double,
                      let v = d["vol"] as? Double else { return nil }
                return ["time": tSec * 1000, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToHTXPeriod(_ hl: String) -> String {
            switch hl {
            case "1m": return "1min"; case "5m": return "5min"; case "15m": return "15min"; case "30m": return "30min"
            case "1h": return "60min"; case "4h": return "4hour"
            case "1d": return "1day"; case "1w": return "1week"; case "1M": return "1mon"
            default: return "60min"
            }
        }

        // MARK: - Bitget Klines

        private static func fetchBitgetKlines(pair: String, interval: String,
                                               startMs: Int64, endMs: Int64,
                                               limit: Int) async throws -> [[String: Any]] {
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let bitgetGranularity = hlToBitgetGranularity(interval)
            var urlStr = "https://api.bitget.com/api/v2/spot/market/candles?symbol=\(clean)&granularity=\(bitgetGranularity)&limit=\(min(limit, 1000))"
            if startMs > 0 { urlStr += "&startTime=\(startMs)" }
            if endMs > 0 { urlStr += "&endTime=\(endMs)" }

            guard let url = URL(string: urlStr) else { return [] }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String]] else { return [] }

            // Bitget returns [ts, o, h, l, c, vol, quoteVol] — newest first
            return dataArr.reversed().compactMap { arr -> [String: Any]? in
                guard arr.count >= 6,
                      let t = Int64(arr[0]),
                      let o = Double(arr[1]), let h = Double(arr[2]),
                      let l = Double(arr[3]), let c = Double(arr[4]),
                      let v = Double(arr[5]) else { return nil }
                return ["time": t, "open": o, "high": h, "low": l, "close": c, "volume": v]
            }
        }

        private static func hlToBitgetGranularity(_ hl: String) -> String {
            switch hl {
            case "1m": return "1min"; case "5m": return "5min"; case "15m": return "15min"; case "30m": return "30min"
            case "1h": return "1h"; case "4h": return "4h"; case "12h": return "12h"
            case "1d": return "1day"; case "1w": return "1week"
            default: return "1h"
            }
        }

        // MARK: - Real-time Subscription

        private var externalPollTimer: Timer?

        private func handleSubscribeBars(_ json: [String: Any], requestId: Int?) {
            guard let symbol = json["symbol"] as? String,
                  let interval = json["interval"] as? String else {
                if let rid = requestId { resolveJSRequest(rid, data: ["ok": true]) }
                return
            }

            let isCustom = json["isCustom"] as? Bool ?? false

            // Cleanup previous subscription
            candleSub?.cancel()
            externalPollTimer?.invalidate()
            externalPollTimer = nil

            if let prevSym = subscribedSymbol, let prevInt = subscribedInterval {
                let prevHL = ChartInterval(rawValue: prevInt) ?? .oneHour
                WebSocketManager.shared.unsubscribeCandles(coin: prevSym, interval: prevHL)
            }

            subscribedSymbol = symbol
            subscribedInterval = interval

            if isCustom {
                // External symbols: poll Binance every 10s for latest bar
                startExternalPolling(symbol: symbol, interval: interval)
            } else {
                // Hyperliquid: use WebSocket real-time
                let hlInterval = ChartInterval(rawValue: interval) ?? .oneHour
                WebSocketManager.shared.subscribeCandles(coin: symbol, interval: hlInterval)

                candleSub = WebSocketManager.shared.candlePublisher
                    .receive(on: DispatchQueue.main)
                    .filter { [weak self] candle in
                        candle.s == self?.subscribedSymbol && candle.i == (self?.subscribedInterval ?? "")
                    }
                    .sink { [weak self] candle in
                        guard let self else { return }
                        let bar: [String: Any] = [
                            "time": candle.t, "open": candle.open, "high": candle.high,
                            "low": candle.low, "close": candle.close, "volume": candle.volume
                        ]
                        self.pushRealtimeBar(bar)
                    }
            }

            if let rid = requestId { resolveJSRequest(rid, data: ["ok": true]) }
        }

        private func startExternalPolling(symbol: String, interval: String) {
            // Expression symbol — poll both sides and compute ratio
            if Self.isExpressionSymbol(symbol) {
                startExpressionPolling(symbol: symbol, interval: interval)
                return
            }

            // Single symbol: route through the generic fetch
            let parts = symbol.split(separator: ":", maxSplits: 1)
            let exchange = parts.count > 1 ? String(parts[0]).uppercased() : "BINANCE"
            let pair = parts.count > 1 ? String(parts[1]) : symbol

            externalPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, self.subscribedSymbol == symbol else { return }
                Task { @MainActor in
                    do {
                        let bars = try await Self.fetchKlinesForExchange(
                            exchange: exchange, pair: pair, interval: interval,
                            startMs: 0, endMs: 0, limit: 1)
                        guard let bar = bars.last else { return }
                        self.pushRealtimeBar(bar)
                    } catch {}
                }
            }
        }

        /// Poll both sides of a ratio expression and push computed ratio bar
        private func startExpressionPolling(symbol: String, interval: String) {
            guard let expr = Self.parseExpression(symbol) else { return }
            let numEP = Self.parseExchangePair(expr.num)
            let denEP = Self.parseExchangePair(expr.den)

            externalPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, self.subscribedSymbol == symbol else { return }
                Task { @MainActor in
                    do {
                        // Fetch latest bar from each side using the generic method
                        async let numBars = Self.fetchKlinesForExchange(
                            exchange: numEP.exchange, pair: numEP.pair, interval: interval,
                            startMs: 0, endMs: 0, limit: 1)
                        async let denBars = Self.fetchKlinesForExchange(
                            exchange: denEP.exchange, pair: denEP.pair, interval: interval,
                            startMs: 0, endMs: 0, limit: 1)

                        let nResult = try await numBars
                        let dResult = try await denBars

                        guard let nBar = nResult.last, let dBar = dResult.last,
                              let t = nBar["time"] as? Int64,
                              let nO = nBar["open"] as? Double,
                              let nH = nBar["high"] as? Double,
                              let nL = nBar["low"] as? Double,
                              let nC = nBar["close"] as? Double,
                              let dO = dBar["open"] as? Double, dO > 0,
                              let dH = dBar["high"] as? Double, dH > 0,
                              let dL = dBar["low"] as? Double, dL > 0,
                              let dC = dBar["close"] as? Double, dC > 0
                        else { return }

                        let bar: [String: Any] = [
                            "time": t,
                            "open": nO / dO,
                            "high": nH / dH,
                            "low": nL / dL,
                            "close": nC / dC,
                            "volume": (nBar["volume"] as? Double ?? 0)
                        ]
                        self.pushRealtimeBar(bar)
                    } catch {}
                }
            }
        }

        private func handleUnsubscribeBars(_ json: [String: Any], requestId: Int?) {
            candleSub?.cancel()
            candleSub = nil
            externalPollTimer?.invalidate()
            externalPollTimer = nil
            if let sym = subscribedSymbol, let intv = subscribedInterval {
                let hlInterval = ChartInterval(rawValue: intv) ?? .oneHour
                WebSocketManager.shared.unsubscribeCandles(coin: sym, interval: hlInterval)
            }
            subscribedSymbol = nil
            subscribedInterval = nil
            if let rid = requestId { resolveJSRequest(rid, data: ["ok": true]) }
        }

        // MARK: - JS Bridge

        private func resolveJSRequest(_ id: Int, data: [String: Any]) {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
            let js = "resolveRequest(\(id), \(jsonStr));"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
        }

        private func rejectJSRequest(_ id: Int, error: String) {
            let escaped = Self.escapeJS(error)
            let js = "rejectRequest(\(id), '\(escaped)');"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
        }

        private func pushRealtimeBar(_ bar: [String: Any]) {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: bar),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
            let js = "onRealtimeBar(\(jsonStr));"
            DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
        }

        // MARK: - Public API

        func changeSymbol(_ symbol: String, interval: ChartInterval, isCustom: Bool = false) {
            // Reset price line for new symbol
            previousLivePrice = 0

            // Prefetch candles immediately — runs in parallel with TV's symbol switch animation
            if !isCustom {
                prefetchCandles(symbol: symbol, interval: interval)
            }
            let tvInterval = Self.hlIntervalToTV(interval)
            let js = "changeSymbol('\(Self.escapeJS(symbol))', '\(tvInterval)', \(isCustom));"
            webView?.evaluateJavaScript(js)
        }

        func refreshChart() {
            webView?.evaluateJavaScript("refreshData();")
        }

        func changeResolution(_ interval: ChartInterval) {
            let tvInterval = Self.hlIntervalToTV(interval)
            let js = "changeResolution('\(tvInterval)');"
            webView?.evaluateJavaScript(js)
        }

        func setChartType(_ type: ChartType) {
            let tvType: Int
            switch type {
            case .bars:       tvType = 1
            case .candles:    tvType = 2
            case .line:       tvType = 3
            case .area:       tvType = 4
            case .heikinAshi: tvType = 8
            }
            let js = "setChartType(\(tvType));"
            webView?.evaluateJavaScript(js)
        }

        // MARK: - Live Price Line

        func startLivePriceLineUpdates() {
            livePriceSub?.cancel()
            guard let vm = chartVM else { return }

            livePriceSub = vm.$livePrice
                .receive(on: DispatchQueue.main)
                .removeDuplicates()
                .sink { [weak self] price in
                    guard let self, self.isChartReady, price > 0 else { return }
                    let isUp = price >= self.previousLivePrice && self.previousLivePrice > 0
                    self.previousLivePrice = price
                    let js = "updateLivePrice(\(price), \(isUp));"
                    self.webView?.evaluateJavaScript(js)
                }
        }

        func stopLivePriceLineUpdates() {
            livePriceSub?.cancel()
            livePriceSub = nil
            previousLivePrice = 0
            webView?.evaluateJavaScript("removeLivePriceLine();")
        }

        // MARK: - Helpers

        static func hlIntervalToTV(_ interval: ChartInterval) -> String {
            switch interval {
            case .oneMin:     return "1"
            case .twoMin:     return "2"
            case .threeMin:   return "3"
            case .fiveMin:    return "5"
            case .fifteenMin: return "15"
            case .thirtyMin:  return "30"
            case .oneHour:    return "60"
            case .twoHour:    return "120"
            case .fourHour:   return "240"
            case .eightHour:  return "480"
            case .twelveHour: return "720"
            case .oneDay:     return "1D"
            case .threeDays:  return "3D"
            case .oneWeek:    return "1W"
            case .oneMonth:   return "1M"
            }
        }

        static func escapeJS(_ str: String) -> String {
            str.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "'", with: "\\'")
               .replacingOccurrences(of: "\"", with: "\\\"")
               .replacingOccurrences(of: "\n", with: "\\n")
        }
    }
}
