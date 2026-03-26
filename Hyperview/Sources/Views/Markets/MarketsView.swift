import SwiftUI

struct MarketsView: View {
    @EnvironmentObject var vm:      MarketsViewModel
    @EnvironmentObject var chartVM: ChartViewModel
    @EnvironmentObject var watchVM: WatchlistViewModel
    @ObservedObject private var appState = AppState.shared
    @State private var selectedQuestion: OutcomeQuestion?
    @State private var showAddCustomChart = false
    @State private var isReordering = false
    @ObservedObject private var customChartStore = CustomChartStore.shared

    /// Live price + 24h change for custom TradingView charts (fetched from Binance)
    @State private var customPrices: [String: (price: Double, change: Double)] = [:]
    /// Timestamp of last custom price fetch — avoid re-fetching within 30s on tab switches
    @State private var lastCustomPriceFetch: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            // ── Search + Add button ─────────────────────────────
            HStack(spacing: 8) {
                SearchBarView(text: $vm.searchQuery)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isReordering.toggle() }
                } label: {
                    Image(systemName: isReordering ? "checkmark.circle.fill" : "arrow.up.arrow.down.circle")
                        .font(.system(size: 24))
                        .foregroundColor(isReordering ? .hlGreen : Color(white: 0.5))
                }
                Button { showAddCustomChart = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.hlGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // ── Category chips ──────────────────────────────────
            categoryChips

            Divider().background(Color.hlDivider)

            // ── Sort strip + column headers (hidden for outcome markets) ──
            if vm.selectedMain != .predictions && vm.selectedMain != .options {
                sortStrip
                Divider().background(Color.hlSurface)
                columnHeaders
                Divider().background(Color.hlCardBackground)
            }

            // ── Content ─────────────────────────────────────────
            ZStack {
                if vm.selectedMain == .predictions || vm.selectedMain == .options {
                    outcomeList
                } else if vm.isLoading && vm.markets.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = vm.errorMessage, vm.markets.isEmpty {
                    errorView(err)
                } else {
                    marketsList
                }
            }
        }
        .background(Color.hlBackground)
        .navigationTitle("Markets")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneBar()
        .sheet(item: $selectedQuestion) { question in
            OutcomeDetailView(question: question)
        }
        .sheet(isPresented: $showAddCustomChart) {
            AddCustomChartView()
                .environmentObject(chartVM)
        }
        .onAppear {
            if vm.markets.isEmpty { vm.refresh() }
            // Apply pending category from Home "View All"
            if let cat = appState.pendingMarketCategory {
                appState.pendingMarketCategory = nil
                vm.selectedMain = cat
                if let sub = appState.pendingPerpSub {
                    appState.pendingPerpSub = nil
                    vm.selectedPerpSub = sub
                }
                if (cat == .predictions || cat == .options),
                   vm.outcomeQuestions.isEmpty, !vm.isLoadingOutcomes {
                    Task { await vm.loadOutcomeMarkets() }
                }
            }
            Task { await fetchCustomChartPrices() }
        }
        .onChange(of: watchVM.symbols) { _, _ in
            vm.customSymbolOrder = nil
        }
        .onChange(of: customChartStore.charts) { _, _ in
            Task { await fetchCustomChartPrices(force: true) }
        }
    }

    // MARK: - Display name helpers

    /// Strip exchange prefixes from a symbol or expression.
    /// "BINANCE:ETHBTC" → "ETHBTC"
    /// "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P" → "HYPE/LITUSDT.P"
    private static func cleanDisplayName(_ symbol: String) -> String {
        // Expression with "/"
        if symbol.contains("/") {
            let sides = symbol.split(separator: "/", maxSplits: 1)
            let cleanNum = stripExchange(String(sides[0]))
            let cleanDen = sides.count > 1 ? stripExchange(String(sides[1])) : ""
            return cleanDen.isEmpty ? cleanNum : "\(cleanNum)/\(cleanDen)"
        }
        return stripExchange(symbol)
    }

    /// "BINANCE:ETHBTC" → "ETHBTC", "ETHBTC" → "ETHBTC"
    private static func stripExchange(_ s: String) -> String {
        if let idx = s.firstIndex(of: ":") {
            return String(s[s.index(after: idx)...])
        }
        return s
    }

    /// Extract just the exchange name(s) from a symbol for the subtitle.
    /// "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P" → "Hyperliquid / Binance"
    /// "BINANCE:ETHBTC" → "Binance"
    private static func abbreviatedSource(_ symbol: String) -> String {
        if symbol.contains("/") {
            let sides = symbol.split(separator: "/", maxSplits: 1)
            let a = extractExchangeName(String(sides[0]))
            let b = sides.count > 1 ? extractExchangeName(String(sides[1])) : ""
            if a == b { return a }  // same source both sides → show once
            return b.isEmpty ? a : "\(a) / \(b)"
        }
        return extractExchangeName(symbol)
    }

    /// "BINANCE:ETHBTC" → "Binance", "ETHBTC" → "ETHBTC"
    private static func extractExchangeName(_ s: String) -> String {
        guard let colonIdx = s.firstIndex(of: ":") else { return s }
        let raw = String(s[..<colonIdx])
        return exchangeDisplayName(raw)
    }

    private static func exchangeDisplayName(_ exchange: String) -> String {
        switch exchange.uppercased() {
        case "HYPERLIQUID":  return "Hyperliquid"
        case "BINANCE":      return "Binance"
        case "COINBASE":     return "Coinbase"
        case "BYBIT":        return "Bybit"
        case "OKX":          return "OKX"
        case "KRAKEN":       return "Kraken"
        case "BITSTAMP":     return "Bitstamp"
        case "BITFINEX":     return "Bitfinex"
        case "GATEIO":       return "Gate.io"
        case "KUCOIN":       return "KuCoin"
        case "MEXC":         return "MEXC"
        case "HUOBI", "HTX": return "HTX"
        case "CRYPTOCAP":    return "CryptoCap"
        case "TVC":          return "TradingView"
        case "UPBIT":        return "Upbit"
        case "BITHUMB":      return "Bithumb"
        case "GEMINI":       return "Gemini"
        case "POLONIEX":     return "Poloniex"
        case "NASDAQ":       return "Nasdaq"
        case "NYSE":         return "NYSE"
        case "AMEX":         return "AMEX"
        case "CBOE":         return "CBOE"
        case "CME_MINI":     return "CME"
        case "FOREXCOM":     return "Forex.com"
        case "OANDA":        return "Oanda"
        default:
            // Capitalize first letter, lowercase rest
            return exchange.prefix(1).uppercased() + exchange.dropFirst().lowercased()
        }
    }

    // MARK: - Fetch custom chart prices (multi-exchange)

    private func fetchCustomChartPrices(force: Bool = false) async {
        let charts = customChartStore.charts
        guard !charts.isEmpty else { return }
        // Skip if fetched recently (30s cache) unless forced
        if !force && !customPrices.isEmpty && Date().timeIntervalSince(lastCustomPriceFetch) < 30 { return }

        var newPrices: [String: (price: Double, change: Double)] = [:]

        // Separate simple Binance spot symbols (bulk fetch) from others (individual fetch)
        var binanceSpotCharts: [(tvSymbol: String, binancePair: String)] = []
        var otherCharts: [CustomChart] = []

        for chart in charts {
            if Self.isExpression(chart.symbol) {
                otherCharts.append(chart)
            } else {
                let (exchange, pair) = Self.parseExchangePair(chart.symbol)
                let upper = exchange.uppercased()
                if (upper == "BINANCE" || upper.isEmpty) && !pair.hasSuffix(".P") {
                    binanceSpotCharts.append((chart.symbol, pair.replacingOccurrences(of: "/", with: "")))
                } else {
                    otherCharts.append(chart)
                }
            }
        }

        // ── Bulk fetch for simple Binance spot symbols ──
        if !binanceSpotCharts.isEmpty {
            let pairs = binanceSpotCharts.map { "\"\($0.binancePair)\"" }.joined(separator: ",")
            let urlStr = "https://api.binance.com/api/v3/ticker/24hr?symbols=[\(pairs)]"
            if let url = URL(string: urlStr) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let reverseMap = Dictionary(uniqueKeysWithValues:
                            binanceSpotCharts.map { ($0.binancePair, $0.tvSymbol) })
                        for item in arr {
                            guard let binPair = item["symbol"] as? String,
                                  let priceStr = item["lastPrice"] as? String,
                                  let changeStr = item["priceChangePercent"] as? String,
                                  let price = Double(priceStr),
                                  let change = Double(changeStr),
                                  let tvSymbol = reverseMap[binPair] else { continue }
                            newPrices[tvSymbol] = (price, change)
                        }
                    }
                } catch {}
            }
        }

        // ── Individual fetch for expressions, futures (.P), and HL symbols ──
        await withTaskGroup(of: (String, Double, Double)?.self) { group in
            for chart in otherCharts {
                group.addTask {
                    return await Self.fetchSingleChartPrice(chart.symbol)
                }
            }
            for await result in group {
                if let (sym, price, change) = result {
                    newPrices[sym] = (price, change)
                }
            }
        }

        await MainActor.run {
            customPrices = newPrices
            lastCustomPriceFetch = Date()
        }
    }

    /// Check if a symbol is an expression (ratio) like "BINANCE:X/OKX:Y"
    private static func isExpression(_ symbol: String) -> Bool {
        let sides = symbol.split(separator: "/", maxSplits: 1)
        return sides.count == 2 && !sides[0].isEmpty && !sides[1].isEmpty
            && (sides[0].contains(":") || sides[1].contains(":"))
    }

    /// Parse "BINANCE:ETHBTC" → ("BINANCE", "ETHBTC")
    private static func parseExchangePair(_ s: String) -> (exchange: String, pair: String) {
        let parts = s.split(separator: ":", maxSplits: 1)
        if parts.count > 1 { return (String(parts[0]), String(parts[1])) }
        return ("", s)
    }

    /// Fetch price + 24h change for a single custom chart (any source)
    private static func fetchSingleChartPrice(_ symbol: String) async -> (String, Double, Double)? {
        if isExpression(symbol) {
            return await fetchExpressionPrice(symbol)
        }

        let (exchange, pair) = parseExchangePair(symbol)

        switch exchange.uppercased() {
        case "HYPERLIQUID", "HL":
            let coin = stripQuoteSuffix(pair)
            guard let (price, change) = await fetchHLPriceAndChange(coin: coin) else { return nil }
            return (symbol, price, change)

        case "BYBIT":
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let urlStr = "https://api.bybit.com/v5/market/tickers?category=spot&symbol=\(clean)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let list = result["list"] as? [[String: Any]],
                      let first = list.first,
                      let priceStr = first["lastPrice"] as? String,
                      let price = Double(priceStr),
                      let pctStr = first["price24hPcnt"] as? String,
                      let pct = Double(pctStr) else { return nil }
                return (symbol, price, pct * 100)
            } catch { return nil }

        case "OKX", "OKEX":
            let instId = tvPairToHyphenated(pair)
            let urlStr = "https://www.okx.com/api/v5/market/ticker?instId=\(instId)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArr = json["data"] as? [[String: Any]],
                      let first = dataArr.first,
                      let priceStr = first["last"] as? String,
                      let openStr = first["open24h"] as? String,
                      let price = Double(priceStr),
                      let open = Double(openStr), open > 0 else { return nil }
                return (symbol, price, ((price - open) / open) * 100)
            } catch { return nil }

        case "KUCOIN":
            let kcSymbol = tvPairToHyphenated(pair)
            let urlStr = "https://api.kucoin.com/api/v1/market/stats?symbol=\(kcSymbol)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let innerData = json["data"] as? [String: Any],
                      let priceStr = innerData["last"] as? String,
                      let changeStr = innerData["changeRate"] as? String,
                      let price = Double(priceStr),
                      let changeRate = Double(changeStr) else { return nil }
                return (symbol, price, changeRate * 100)
            } catch { return nil }

        case "COINBASE", "COINBASEPRO":
            let product = tvPairToHyphenated(pair)
            // Coinbase: use ticker for price, stats for 24h open
            let urlStr = "https://api.exchange.coinbase.com/products/\(product)/stats"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let lastStr = json["last"] as? String,
                      let openStr = json["open"] as? String,
                      let price = Double(lastStr),
                      let open = Double(openStr), open > 0 else { return nil }
                return (symbol, price, ((price - open) / open) * 100)
            } catch { return nil }

        case "KRAKEN":
            let krakenPair = pair.replacingOccurrences(of: ".P", with: "")
            let urlStr = "https://api.kraken.com/0/public/Ticker?pair=\(krakenPair)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let first = result.values.first as? [String: Any],
                      let cArr = first["c"] as? [String], let priceStr = cArr.first,
                      let oArr = first["o"] as? [String], let openStr = oArr.first,
                      let price = Double(priceStr),
                      let open = Double(openStr), open > 0 else { return nil }
                return (symbol, price, ((price - open) / open) * 100)
            } catch { return nil }

        case "GATEIO", "GATE":
            let gateSymbol = tvPairToUnderscore(pair)
            let urlStr = "https://api.gateio.ws/api/v4/spot/tickers?currency_pair=\(gateSymbol)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let first = arr.first,
                      let priceStr = first["last"] as? String,
                      let pctStr = first["change_percentage"] as? String,
                      let price = Double(priceStr),
                      let pct = Double(pctStr) else { return nil }
                return (symbol, price, pct)
            } catch { return nil }

        case "MEXC":
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let urlStr = "https://api.mexc.com/api/v3/ticker/24hr?symbol=\(clean)"
            return await fetchBinanceStyleTicker(symbol: symbol, urlStr: urlStr)

        case "HTX", "HUOBI":
            let clean = pair.replacingOccurrences(of: ".P", with: "").lowercased()
            let urlStr = "https://api.huobi.pro/market/detail/merged?symbol=\(clean)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tick = json["tick"] as? [String: Any],
                      let close = tick["close"] as? Double,
                      let open = tick["open"] as? Double, open > 0 else { return nil }
                return (symbol, close, ((close - open) / open) * 100)
            } catch { return nil }

        case "BITGET":
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            let urlStr = "https://api.bitget.com/api/v2/spot/market/tickers?symbol=\(clean)"
            guard let url = URL(string: urlStr) else { return nil }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArr = json["data"] as? [[String: Any]],
                      let first = dataArr.first,
                      let priceStr = first["lastPr"] as? String,
                      let openStr = first["open"] as? String,
                      let price = Double(priceStr),
                      let open = Double(openStr), open > 0 else { return nil }
                return (symbol, price, ((price - open) / open) * 100)
            } catch { return nil }

        default:
            // Binance (spot or futures) — also fallback for unknown exchanges
            let isFutures = pair.hasSuffix(".P")
            let cleanPair = isFutures ? String(pair.dropLast(2)) : pair.replacingOccurrences(of: "/", with: "")
            let base = isFutures ? "https://fapi.binance.com/fapi/v1" : "https://api.binance.com/api/v3"
            let urlStr = "\(base)/ticker/24hr?symbol=\(cleanPair)"
            return await fetchBinanceStyleTicker(symbol: symbol, urlStr: urlStr)
        }
    }

    /// Fetch from Binance-format 24hr ticker (used by Binance + MEXC)
    private static func fetchBinanceStyleTicker(symbol: String, urlStr: String) async -> (String, Double, Double)? {
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let priceStr = json["lastPrice"] as? String,
                  let changeStr = json["priceChangePercent"] as? String,
                  let price = Double(priceStr),
                  let change = Double(changeStr) else { return nil }
            return (symbol, price, change)
        } catch { return nil }
    }

    /// "HYPEUSDT" → "HYPE-USDT" (for KuCoin, OKX, Coinbase)
    private static func tvPairToHyphenated(_ pair: String) -> String {
        let clean = pair.replacingOccurrences(of: ".P", with: "")
        for quote in ["USDT", "USDC", "BTC", "ETH", "USD", "BUSD"] {
            if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                let base = String(clean.dropLast(quote.count))
                return "\(base)-\(quote)"
            }
        }
        return clean
    }

    /// "HYPEUSDT" → "HYPE_USDT" (for Gate.io)
    private static func tvPairToUnderscore(_ pair: String) -> String {
        let clean = pair.replacingOccurrences(of: ".P", with: "")
        for quote in ["USDT", "USDC", "BTC", "ETH", "BUSD"] {
            if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                let base = String(clean.dropLast(quote.count))
                return "\(base)_\(quote)"
            }
        }
        return clean
    }

    /// Fetch price + 24h change for an expression like "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P"
    private static func fetchExpressionPrice(_ symbol: String) async -> (String, Double, Double)? {
        let sides = symbol.split(separator: "/", maxSplits: 1)
        guard sides.count == 2 else { return nil }

        let numStr = String(sides[0])
        let denStr = String(sides[1])

        // Fetch current prices for both sides in parallel
        async let numData = fetchPriceAndDailyOpen(numStr)
        async let denData = fetchPriceAndDailyOpen(denStr)

        guard let num = await numData, let den = await denData,
              den.price > 0, den.open > 0 else { return nil }

        let currentRatio = num.price / den.price
        let openRatio = num.open / den.open
        let change = ((currentRatio - openRatio) / openRatio) * 100

        return (symbol, currentRatio, change)
    }

    /// Fetch current price and daily open for a single side (e.g., "BINANCE:LITUSDT.P", "KUCOIN:HYPEUSDT")
    /// Uses the exchange-specific fetchSingleChartPrice which returns (symbol, price, change24h).
    /// We derive the open from: open = price / (1 + change/100).
    private static func fetchPriceAndDailyOpen(_ side: String) async -> (price: Double, open: Double)? {
        // Re-use fetchSingleChartPrice which already handles all exchanges
        guard let (_, price, change) = await fetchSingleChartPrice(side) else { return nil }
        // Derive daily open from price and 24h change percentage
        let open = change != 0 ? price / (1 + change / 100) : price
        return (price, open)
    }

    /// Fetch HL mid price + 24h change
    private static func fetchHLPriceAndChange(coin: String) async -> (price: Double, change: Double)? {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "allMids"])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let mids = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let priceStr = mids[coin], let price = Double(priceStr) else { return nil }

            // For 24h change, fetch daily candle
            let endMs = Int64(Date().timeIntervalSince1970 * 1000)
            let startMs = endMs - 86_400_000 * 2
            let candleBody: [String: Any] = ["type": "candleSnapshot", "req": [
                "coin": coin, "interval": "1d", "startTime": startMs, "endTime": endMs
            ]]
            var candleReq = URLRequest(url: url)
            candleReq.httpMethod = "POST"
            candleReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            candleReq.httpBody = try? JSONSerialization.data(withJSONObject: candleBody)
            let (candleData, _) = try await URLSession.shared.data(for: candleReq)
            if let candles = try? JSONSerialization.jsonObject(with: candleData) as? [[String: Any]],
               let last = candles.last,
               let o = (last["o"] as? String).flatMap(Double.init), o > 0 {
                let change = ((price - o) / o) * 100
                return (price, change)
            }
            return (price, 0)
        } catch { return nil }
    }

    /// Strip USDT/USDC/etc suffix: "HYPEUSDT" → "HYPE"
    private static func stripQuoteSuffix(_ pair: String) -> String {
        let upper = pair.uppercased()
        for suffix in ["USDT", "USDC", "BUSD", "USD", "PERP"] {
            if upper.hasSuffix(suffix) && upper.count > suffix.count {
                return String(upper.dropLast(suffix.count))
            }
        }
        return pair
    }

    // MARK: - Category chips (2-level)

    private var categoryChips: some View {
        VStack(spacing: 0) {
            // Row 1 — Main categories
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MainCategory.topRow) { cat in
                        mainChip(cat)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 40)

            // Row 2 — Sub-categories (contextual)
            if vm.selectedMain == .all {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { strictToggle }
                    .padding(.horizontal, 14)
                }
                .frame(height: 36)

            } else if vm.selectedMain == .perps {
                // Perps → sub-row: All | Crypto | Tradfi | HIP-3 | Pre-launch
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PerpSubCategory.allCases) { sub in
                                subChip(sub.rawValue, isActive: vm.selectedPerpSub == sub) {
                                    vm.selectedPerpSub = sub
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 36)

                    // Third level: Crypto → DeFi/AI/Memes... | Tradfi → Stocks/Forex... | HIP-3 → DEXes
                    if vm.selectedPerpSub == .crypto {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(CryptoSubCategory.allCases) { sub in
                                    subChip(sub.rawValue, isActive: vm.selectedCryptoSub == sub) {
                                        vm.selectedCryptoSub = sub
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                        .frame(height: 32)
                    } else if vm.selectedPerpSub == .tradfi {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(TradfiSubCategory.allCases) { sub in
                                    subChip(sub.rawValue, isActive: vm.selectedTradfiSub == sub) {
                                        vm.selectedTradfiSub = sub
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                        .frame(height: 32)
                    } else if vm.selectedPerpSub == .hip3 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                subChip("All", isActive: vm.selectedHIP3Dex == "All") {
                                    vm.selectedHIP3Dex = "All"
                                }
                                ForEach(vm.availableHIP3Dexes, id: \.self) { dex in
                                    subChip(dex, isActive: vm.selectedHIP3Dex == dex) {
                                        vm.selectedHIP3Dex = dex
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                        .frame(height: 32)
                    }
                }

            } else if vm.selectedMain == .spot {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        strictToggle
                        Divider().frame(height: 20).background(Color(white: 0.25))
                        ForEach(SpotQuoteCategory.allCases) { sub in
                            subChip(sub.rawValue, isActive: vm.selectedSpotSub == sub) {
                                vm.selectedSpotSub = sub
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 36)

            } else if vm.selectedMain == .predictions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        TestnetBadge()
                        Text("HIP-4 Outcome Trading")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 36)

            } else if vm.selectedMain == .options {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TestnetBadge()
                        Divider().frame(height: 20).background(Color(white: 0.25))
                        ForEach(OptionsUnderlying.allCases) { sub in
                            subChip(sub.rawValue, isActive: vm.selectedOptionsUnderlying == sub) {
                                vm.selectedOptionsUnderlying = sub
                            }
                        }
                        Divider().frame(height: 20).background(Color(white: 0.25))
                        ForEach(OptionsPeriod.allCases) { sub in
                            subChip(sub.displayName, isActive: vm.selectedOptionsPeriod == sub) {
                                vm.selectedOptionsPeriod = sub
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 36)
            }
        }
    }

    private func mainChip(_ cat: MainCategory) -> some View {
        let isActive = vm.selectedMain == cat
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.selectedMain = cat
            }
        } label: {
            Text(cat.rawValue)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color.hlButtonBg)
                .cornerRadius(20)
        }
    }

    /// Strict / All segmented toggle for spot markets
    private var strictToggle: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { vm.spotStrictMode = true }
            } label: {
                Text("Strict")
                    .font(.system(size: 11, weight: vm.spotStrictMode ? .semibold : .regular))
                    .foregroundColor(vm.spotStrictMode ? .black : Color(white: 0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(vm.spotStrictMode ? Color.hlGreen : Color.clear)
                    .cornerRadius(5)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { vm.spotStrictMode = false }
            } label: {
                Text("All")
                    .font(.system(size: 11, weight: !vm.spotStrictMode ? .semibold : .regular))
                    .foregroundColor(!vm.spotStrictMode ? .black : Color(white: 0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(!vm.spotStrictMode ? Color.hlGreen : Color.clear)
                    .cornerRadius(5)
            }
        }
        .background(Color.hlSurface)
        .cornerRadius(6)
    }

    private func subChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .hlGreen : Color(white: 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.hlGreen.opacity(0.12) : Color.clear)
                .cornerRadius(7)
        }
    }

    // MARK: - Sort strip

    private var sortStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if vm.selectedMain == .trending {
                    // Trending: only Chg% toggle
                    sortChip(.change)
                } else {
                    ForEach(SortOption.allCases) { opt in
                        sortChip(opt)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 36)
    }

    private func sortChip(_ opt: SortOption) -> some View {
        let isActive = vm.sortOption == opt
        return Button {
            vm.customSymbolOrder = nil
            if isActive { vm.sortAscending.toggle() }
            else        { vm.sortOption = opt; vm.sortAscending = false }
        } label: {
            HStack(spacing: 3) {
                Text(opt.rawValue).font(.system(size: 12, weight: isActive ? .semibold : .regular))
                if isActive {
                    Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundColor(isActive ? .hlGreen : Color(white: 0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.hlGreen.opacity(0.12) : Color.clear)
            .cornerRadius(7)
        }
    }

    // MARK: - Column headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Symbol")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 36)
            Text("Price")
                .frame(width: 90, alignment: .trailing)
            Text("24h Chg")
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(Color(white: 0.4))
        .padding(.leading, 18)
        .padding(.trailing, 58)   // 18 base + ~40 drag handle offset
        .padding(.vertical, 4)
    }

    // MARK: - Unified list item

    private enum ListItem: Identifiable {
        case custom(CustomChart)
        case market(Market)

        var id: String {
            switch self {
            case .custom(let c): return "TV:\(c.symbol)"
            case .market(let m): return m.id
            }
        }

        var orderKey: String {
            switch self {
            case .custom(let c): return "TV:\(c.symbol)"
            case .market(let m): return m.symbol
            }
        }
    }

    // MARK: - List

    private var marketsList: some View {
        let displayed = vm.filteredMarkets(watched: Set(watchVM.symbols))
        let customCharts = customChartStore.charts

        // Build unified list: favorites first, then custom charts, then the rest
        var unified: [ListItem] = []
        let watchedSet = Set(watchVM.symbols)
        if vm.searchQuery.isEmpty {
            // Split HL markets into favorites and non-favorites
            let favMarkets = displayed.filter { watchedSet.contains($0.symbol) }
            let nonFavMarkets = displayed.filter { !watchedSet.contains($0.symbol) }
            unified += favMarkets.map { .market($0) }
            unified += customCharts.map { .custom($0) }
            unified += nonFavMarkets.map { .market($0) }
        } else {
            unified += displayed.map { .market($0) }
        }

        // Apply saved order if available
        if let order = vm.customSymbolOrder {
            let orderMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            unified.sort { a, b in
                let ia = orderMap[a.orderKey] ?? Int.max
                let ib = orderMap[b.orderKey] ?? Int.max
                if ia == ib { return false }
                return ia < ib
            }
        }

        // Pre-compute row data so ForEach body returns a single, uniform view type
        let rowData: [RowData] = unified.map { item in
            switch item {
            case .custom(let chart):
                let watchKey = "TV:\(chart.symbol)"
                let ticker = customPrices[chart.symbol]
                let price = ticker?.price ?? 0
                let change = ticker?.change ?? 0
                let isPositive = change >= 0
                let pairName = Self.cleanDisplayName(chart.symbol)
                return RowData(
                    id: item.id,
                    watchKey: watchKey,
                    isWatched: watchVM.isWatched(watchKey),
                    iconSymbol: chart.iconBase,
                    iconHLName: chart.iconBase,
                    iconQuote: chart.iconQuote,
                    title: pairName,
                    subtitle: Self.abbreviatedSource(chart.tvSymbol),
                    badge: "TV",
                    price: price > 0 ? formatCustomPrice(price) : "—",
                    changeText: price > 0 ? String(format: "%@%.2f%%", isPositive ? "+" : "", change) : "—",
                    changeColor: price > 0 ? (isPositive ? .hlGreen : .white) : Color(white: 0.4),
                    changeBg: price > 0 ? (isPositive ? Color.hlButtonBg : Color.tradingRed) : Color.hlButtonBg,
                    isCustom: true,
                    customSymbol: chart.tvSymbol,
                    customDisplayName: pairName,
                    marketSymbol: nil,
                    marketDisplaySymbol: nil,
                    perpEquivalent: nil
                )
            case .market(let market):
                let lp = vm.livePrices[market.symbol] ?? market.price
                let lpFmt = market.format(lp)
                let liveChange: Double = {
                    if let open = market.dailyOpenPrice, open > 0 {
                        return ((lp - open) / open) * 100
                    }
                    return market.change24h
                }()
                let isPositive = liveChange >= 0
                let subtitle: String = {
                    var parts: [String] = ["Vol \(market.formattedVolume)"]
                    if !market.isSpot && market.openInterest > 0 {
                        parts.append("OI \(market.formattedOI)")
                    }
                    return parts.joined(separator: "  ")
                }()
                return RowData(
                    id: item.id,
                    watchKey: market.symbol,
                    isWatched: watchVM.isWatched(market.symbol),
                    iconSymbol: market.spotDisplayBaseName,
                    iconHLName: market.hlCoinIconName,
                    iconQuote: nil,
                    title: market.isSpot ? "\(market.spotDisplayPairName)  SPOT" : market.displaySymbol,
                    subtitle: subtitle,
                    badge: nil,
                    price: lpFmt,
                    changeText: String(format: "%@%.2f%%", isPositive ? "+" : "", liveChange),
                    changeColor: isPositive ? .hlGreen : .white,
                    changeBg: isPositive ? Color.hlButtonBg : Color.tradingRed,
                    isCustom: false,
                    customSymbol: nil,
                    customDisplayName: nil,
                    marketSymbol: market.symbol,
                    marketDisplaySymbol: market.displaySymbol,
                    perpEquivalent: market.perpEquivalent
                )
            }
        }

        return ScrollViewReader { proxy in
            List {
                ForEach(rowData) { row in
                    UnifiedMarketRow(
                        watchKey: row.watchKey,
                        isWatched: row.isWatched,
                        iconSymbol: row.iconSymbol,
                        iconHLName: row.iconHLName,
                        iconQuote: row.iconQuote,
                        title: row.title,
                        subtitle: row.subtitle,
                        badge: row.badge,
                        price: row.price,
                        changeText: row.changeText,
                        changeColor: row.changeColor,
                        changeBg: row.changeBg,
                        onStarTap: { watchVM.toggle(row.watchKey) },
                        onRowTap: {
                            if row.isCustom {
                                AppState.shared.openChart(
                                    symbol: row.customSymbol ?? "",
                                    displayName: row.customDisplayName,
                                    chartVM: chartVM,
                                    isCustomTV: true
                                )
                            } else {
                                AppState.shared.openChart(
                                    symbol: row.marketSymbol ?? "",
                                    displayName: row.marketDisplaySymbol,
                                    perpEquivalent: row.perpEquivalent,
                                    chartVM: chartVM
                                )
                            }
                        },
                        onDelete: row.isCustom ? {
                            if let chart = customChartStore.charts.first(where: { "TV:\($0.symbol)" == row.id }) {
                                customChartStore.remove(chart)
                            }
                        } : nil
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Color.hlSurface)
                    .id(row.id)
                }
                .onMove { source, destination in
                    var arr = unified
                    arr.move(fromOffsets: source, toOffset: destination)
                    let orderKeys = arr.map(\.orderKey)
                    vm.customSymbolOrder = orderKeys
                    let newCustomOrder = arr.compactMap { item -> CustomChart? in
                        if case .custom(let c) = item { return c }
                        return nil
                    }
                    customChartStore.reorder(newCustomOrder)
                    vm.forceWidgetReload(unifiedOrder: orderKeys)
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
            .refreshable { vm.refresh() }
            .onChange(of: appState.marketsReselect) { _, _ in
                if let first = unified.first {
                    withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private func formatCustomPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.1f", p) }
        if p >= 1_000  { return String(format: "%.2f", p) }
        if p >= 1      { return String(format: "%.4f", p) }
        if p >= 0.01   { return String(format: "%.5f", p) }
        return String(format: "%.8f", p)
    }

    // MARK: - Outcome markets list (predictions + options)

    private var outcomeList: some View {
        Group {
            if vm.isLoadingOutcomes && vm.outcomeQuestions.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading from testnet...")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let displayed = vm.filteredOutcomeQuestions()
                if displayed.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: vm.selectedMain == .predictions
                              ? "chart.pie" : "option")
                            .font(.system(size: 28))
                            .foregroundColor(Color(white: 0.25))
                        Text("No \(vm.selectedMain == .predictions ? "prediction" : "options") markets")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.4))
                        Text("HIP-4 is live on testnet")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(displayed) { question in
                            Group {
                                if question.isOption {
                                    OptionQuestionRowView(question: question)
                                } else {
                                    QuestionRowView(question: question)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedQuestion = question }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .listRowSeparator(.visible)
                            .listRowSeparatorTint(Color.hlSurface)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .onAppear {
            if vm.outcomeQuestions.isEmpty && !vm.isLoadingOutcomes {
                Task { await vm.loadOutcomeMarkets() }
            }
        }
    }

    // MARK: - Error

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(msg).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Retry") { vm.refresh() }
                .buttonStyle(.bordered)
                .tint(.hlGreen)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row data (plain value type — no view branching)

/// All data needed to render a single market row, pre-computed so the ForEach
/// body never branches on view type.
private struct RowData: Identifiable {
    let id: String
    let watchKey: String
    let isWatched: Bool
    let iconSymbol: String
    let iconHLName: String
    let iconQuote: String?     // non-nil → dual coin icon (pair chart)
    let title: String
    let subtitle: String
    let badge: String?
    let price: String
    let changeText: String
    let changeColor: Color
    let changeBg: Color
    // Tap routing
    let isCustom: Bool
    let customSymbol: String?
    let customDisplayName: String?
    let marketSymbol: String?
    let marketDisplaySymbol: String?
    let perpEquivalent: String?
}

// MARK: - Unified Market Row (single view type for ALL list items — guarantees alignment)

/// A single, concrete view struct used by BOTH custom-chart rows and Hyperliquid market rows.
/// Because every row in the `ForEach` returns the **exact same View type**, SwiftUI's List
/// edit-mode (drag handles, indentation) treats them identically — no more alignment offset.
private struct UnifiedMarketRow: View {
    let watchKey: String
    let isWatched: Bool
    let iconSymbol: String
    let iconHLName: String
    var iconQuote: String? = nil   // non-nil → use DualCoinIconView
    let title: String
    let subtitle: String
    let badge: String?          // e.g. "TV" for custom charts, nil for HL markets
    let price: String
    let changeText: String
    let changeColor: Color
    let changeBg: Color
    let onStarTap: () -> Void
    let onRowTap: () -> Void
    var onDelete: (() -> Void)?   // nil for HL markets, set for custom charts

    var body: some View {
        HStack(spacing: 0) {
            // Star
            Button(action: onStarTap) {
                Image(systemName: isWatched ? "star.fill" : "star")
                    .foregroundColor(isWatched ? .hlGreen : Color(white: 0.35))
                    .font(.system(size: 13))
                    .frame(width: 32)
            }
            .buttonStyle(.plain)

            // Icon + title + subtitle
            HStack(spacing: 8) {
                if let quote = iconQuote {
                    DualCoinIconView(
                        baseSymbol: iconSymbol,
                        quoteSymbol: quote,
                        baseHLName: iconHLName,
                        quoteHLName: quote
                    )
                } else {
                    CoinIconView(symbol: iconSymbol, hlIconName: iconHLName)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Price
            Text(price)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 90, alignment: .trailing)

            // Change badge
            Text(changeText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(changeColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(changeBg)
                .cornerRadius(5)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onRowTap)
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

