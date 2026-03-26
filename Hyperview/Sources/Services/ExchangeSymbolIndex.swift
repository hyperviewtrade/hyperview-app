import Foundation

// MARK: - Exchange Symbol Index
// Replaces TradingView's symbol-search API with direct exchange API queries.
// Symbols are fetched once, cached in-memory + disk, and searched locally (< 1ms).

actor ExchangeSymbolIndex {
    static let shared = ExchangeSymbolIndex()

    // MARK: - Types

    struct IndexedSymbol: Codable {
        let symbol: String          // "ETHUSDT"
        let baseAsset: String       // "ETH"
        let quoteAsset: String      // "USDT"
        let exchange: String        // "BINANCE"
        let type: String            // "crypto"
        let description: String     // "Ethereum / TetherUS"
    }

    // MARK: - State

    private var symbols: [IndexedSymbol] = []
    private var isLoaded = false
    private var loadTask: Task<Void, Never>?
    private var lastRefresh: Date?

    private let cacheFile: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("exchange_symbol_index.json")
    }()

    private static let refreshInterval: TimeInterval = 6 * 3600 // 6h
    private static let staleInterval: TimeInterval = 24 * 3600   // 24h — force refresh

    // Hard-coded macro/index symbols not available from any exchange API
    private static let macroSymbols: [IndexedSymbol] = [
        IndexedSymbol(symbol: "BTC.D",  baseAsset: "BTC",  quoteAsset: "", exchange: "CRYPTOCAP", type: "index",   description: "Bitcoin Dominance"),
        IndexedSymbol(symbol: "ETH.D",  baseAsset: "ETH",  quoteAsset: "", exchange: "CRYPTOCAP", type: "index",   description: "Ethereum Dominance"),
        IndexedSymbol(symbol: "TOTAL",  baseAsset: "TOTAL", quoteAsset: "", exchange: "CRYPTOCAP", type: "index",  description: "Total Crypto Market Cap"),
        IndexedSymbol(symbol: "TOTAL2", baseAsset: "TOTAL2", quoteAsset: "", exchange: "CRYPTOCAP", type: "index", description: "Crypto Market Cap (ex BTC)"),
        IndexedSymbol(symbol: "TOTAL3", baseAsset: "TOTAL3", quoteAsset: "", exchange: "CRYPTOCAP", type: "index", description: "Crypto Market Cap (ex BTC/ETH)"),
        IndexedSymbol(symbol: "DXY",    baseAsset: "DXY",  quoteAsset: "", exchange: "TVC",       type: "index",   description: "US Dollar Index"),
        IndexedSymbol(symbol: "US10Y",  baseAsset: "US10Y", quoteAsset: "", exchange: "TVC",      type: "bond",    description: "US 10Y Treasury Yield"),
        IndexedSymbol(symbol: "US02Y",  baseAsset: "US02Y", quoteAsset: "", exchange: "TVC",      type: "bond",    description: "US 2Y Treasury Yield"),
        IndexedSymbol(symbol: "GOLD",   baseAsset: "GOLD",  quoteAsset: "USD", exchange: "TVC",   type: "cfd",     description: "Gold Spot / USD"),
        IndexedSymbol(symbol: "SILVER", baseAsset: "SILVER", quoteAsset: "USD", exchange: "TVC",  type: "cfd",     description: "Silver Spot / USD"),
        IndexedSymbol(symbol: "SPX",    baseAsset: "SPX",   quoteAsset: "", exchange: "SP",       type: "index",   description: "S&P 500 Index"),
        IndexedSymbol(symbol: "NDQ",    baseAsset: "NDQ",   quoteAsset: "", exchange: "NASDAQ",   type: "index",   description: "Nasdaq Composite"),
    ]

    // MARK: - Public API

    /// Ensure index is loaded. Call early (e.g. app launch).
    func warmUp() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadIndex() }
    }

    /// Search symbols — returns results matching the query, limited to `limit`.
    func search(query: String, limit: Int = 40) async -> [IndexedSymbol] {
        if !isLoaded { await loadIndex() }

        let q = query.uppercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        // Score and rank results
        var scored: [(symbol: IndexedSymbol, score: Int)] = []

        for sym in symbols {
            let score = matchScore(symbol: sym, query: q)
            if score > 0 {
                scored.append((sym, score))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit).map(\.symbol))
    }

    /// Find all exchanges that list a given symbol (e.g. "ETHUSDT" → [BINANCE, OKX, BYBIT, ...])
    func exchanges(for symbolQuery: String) async -> (symbol: String, description: String, type: String, exchanges: [String])? {
        if !isLoaded { await loadIndex() }

        let q = symbolQuery.uppercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }

        // Find exact match first
        let exactMatches = symbols.filter { $0.symbol.uppercased() == q }
        if !exactMatches.isEmpty {
            let first = exactMatches[0]
            var seen = Set<String>()
            let exchanges = exactMatches.compactMap { m -> String? in
                seen.insert(m.exchange).inserted ? m.exchange : nil
            }
            return (first.symbol, first.description, first.type, exchanges)
        }

        // Try matching by base asset (e.g. "ETH" → "ETHUSDT" on multiple exchanges)
        let baseMatches = symbols.filter { $0.baseAsset.uppercased() == q && $0.quoteAsset == "USDT" }
        if !baseMatches.isEmpty {
            let first = baseMatches[0]
            var seen = Set<String>()
            let exchanges = baseMatches.compactMap { m -> String? in
                seen.insert(m.exchange).inserted ? m.exchange : nil
            }
            return (first.symbol, first.description, first.type, exchanges)
        }

        // Fallback: best substring match
        let results = await search(query: q, limit: 20)
        guard let best = results.first else { return nil }
        let sameSymbol = results.filter { $0.symbol.uppercased() == best.symbol.uppercased() }
        var seen = Set<String>()
        let exchanges = sameSymbol.compactMap { m -> String? in
            seen.insert(m.exchange).inserted ? m.exchange : nil
        }
        return (best.symbol, best.description, best.type, exchanges)
    }

    /// Force refresh from exchange APIs
    func refresh() async {
        await fetchAllExchanges()
    }

    // MARK: - Loading

    private func loadIndex() async {
        // Try disk cache first
        if let cached = loadFromDisk() {
            symbols = cached.symbols
            lastRefresh = cached.date
            isLoaded = true

            // Background refresh if stale
            let age = Date().timeIntervalSince(cached.date)
            if age > Self.refreshInterval {
                Task { await fetchAllExchanges() }
            }
            return
        }

        // No cache — fetch from exchanges
        await fetchAllExchanges()
    }

    private func fetchAllExchanges() async {
        let fetchers: [() async -> [IndexedSymbol]] = [
            Self.fetchBinance,
            Self.fetchBybit,
            Self.fetchOKX,
            Self.fetchKuCoin,
            Self.fetchCoinbase,
            Self.fetchKraken,
            Self.fetchGateIO,
            Self.fetchMEXC,
            Self.fetchHTX,
            Self.fetchBitget,
            Self.fetchHyperliquid,
        ]

        // Fetch all exchanges in parallel
        let results = await withTaskGroup(of: [IndexedSymbol].self) { group in
            for fetcher in fetchers {
                group.addTask { await fetcher() }
            }
            var all: [[IndexedSymbol]] = []
            for await result in group {
                all.append(result)
            }
            return all
        }

        var allSymbols = results.flatMap { $0 }
        allSymbols.append(contentsOf: Self.macroSymbols)

        symbols = allSymbols
        lastRefresh = Date()
        isLoaded = true

        // Persist to disk
        saveToDisk(symbols: allSymbols, date: Date())

        #if DEBUG
        print("[ExchangeSymbolIndex] Loaded \(allSymbols.count) symbols from \(fetchers.count) exchanges + macros")
        #endif
    }

    // MARK: - Scoring

    private func matchScore(symbol: IndexedSymbol, query: String) -> Int {
        let sym = symbol.symbol.uppercased()
        let base = symbol.baseAsset.uppercased()
        let desc = symbol.description.uppercased()

        // Exact symbol match
        if sym == query { return 1000 }
        // Exact base match
        if base == query { return 900 }
        // Symbol starts with query
        if sym.hasPrefix(query) { return 800 }
        // Base starts with query
        if base.hasPrefix(query) { return 700 }
        // Symbol contains query
        if sym.contains(query) { return 500 }
        // Description contains query
        if desc.contains(query) { return 300 }

        return 0
    }

    // MARK: - Disk Cache

    private struct DiskCache: Codable {
        let symbols: [IndexedSymbol]
        let date: Date
    }

    private func saveToDisk(symbols: [IndexedSymbol], date: Date) {
        Task.detached(priority: .utility) { [cacheFile] in
            do {
                let cache = DiskCache(symbols: symbols, date: date)
                let data = try JSONEncoder().encode(cache)
                try data.write(to: cacheFile, options: .atomic)
            } catch {
                #if DEBUG
                print("[ExchangeSymbolIndex] Failed to save cache: \(error)")
                #endif
            }
        }
    }

    private func loadFromDisk() -> (symbols: [IndexedSymbol], date: Date)? {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            return nil
        }

        // Reject if older than stale interval
        if Date().timeIntervalSince(cache.date) > Self.staleInterval {
            return nil
        }

        return (cache.symbols, cache.date)
    }

    // MARK: - Exchange Fetchers

    private static func fetchBinance() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.binance.com/api/v3/exchangeInfo") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let syms = json["symbols"] as? [[String: Any]] else { return [] }

        return syms.compactMap { s -> IndexedSymbol? in
            guard let symbol = s["symbol"] as? String,
                  let base = s["baseAsset"] as? String,
                  let quote = s["quoteAsset"] as? String,
                  let status = s["status"] as? String,
                  status == "TRADING" else { return nil }
            return IndexedSymbol(
                symbol: symbol, baseAsset: base.uppercased(), quoteAsset: quote.uppercased(),
                exchange: "BINANCE", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchBybit() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.bybit.com/v5/market/instruments-info?category=spot&limit=1000") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let list = result["list"] as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let symbol = s["symbol"] as? String,
                  let base = s["baseCoin"] as? String,
                  let quote = s["quoteCoin"] as? String,
                  let status = s["status"] as? String,
                  status == "Trading" else { return nil }
            return IndexedSymbol(
                symbol: symbol, baseAsset: base, quoteAsset: quote,
                exchange: "BYBIT", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchOKX() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://www.okx.com/api/v5/public/instruments?instType=SPOT") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let instId = s["instId"] as? String,
                  let base = s["baseCcy"] as? String,
                  let quote = s["quoteCcy"] as? String,
                  let state = s["state"] as? String,
                  state == "live" else { return nil }
            let symbol = instId.replacingOccurrences(of: "-", with: "")
            return IndexedSymbol(
                symbol: symbol, baseAsset: base, quoteAsset: quote,
                exchange: "OKX", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchKuCoin() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.kucoin.com/api/v1/symbols") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let symbol = s["symbol"] as? String,
                  let base = s["baseCurrency"] as? String,
                  let quote = s["quoteCurrency"] as? String,
                  let enabled = s["enableTrading"] as? Bool,
                  enabled else { return nil }
            let clean = symbol.replacingOccurrences(of: "-", with: "")
            return IndexedSymbol(
                symbol: clean, baseAsset: base, quoteAsset: quote,
                exchange: "KUCOIN", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchCoinbase() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.exchange.coinbase.com/products") else { return [] }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let id = s["id"] as? String,
                  let base = s["base_currency"] as? String,
                  let quote = s["quote_currency"] as? String,
                  let status = s["status"] as? String,
                  status == "online" else { return nil }
            let symbol = id.replacingOccurrences(of: "-", with: "")
            return IndexedSymbol(
                symbol: symbol, baseAsset: base, quoteAsset: quote,
                exchange: "COINBASE", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchKraken() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.kraken.com/0/public/AssetPairs") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return [] }

        return result.compactMap { (key, value) -> IndexedSymbol? in
            guard let info = value as? [String: Any],
                  let base = info["base"] as? String,
                  let quote = info["quote"] as? String,
                  let wsName = info["wsname"] as? String,
                  let status = info["status"] as? String,
                  status == "online" else { return nil }

            // Kraken uses X/Z prefixes — strip them
            let cleanBase = cleanKrakenAsset(base)
            let cleanQuote = cleanKrakenAsset(quote)
            let symbol = "\(cleanBase)\(cleanQuote)"

            return IndexedSymbol(
                symbol: symbol, baseAsset: cleanBase, quoteAsset: cleanQuote,
                exchange: "KRAKEN", type: "crypto",
                description: "\(cleanBase) / \(cleanQuote)"
            )
        }
    }

    private static func cleanKrakenAsset(_ asset: String) -> String {
        var a = asset
        // Kraken prefixes: XXBT → BTC, XETH → ETH, ZUSD → USD, etc.
        if a == "XXBT" || a == "XBT" { return "BTC" }
        if a.count == 4 && (a.hasPrefix("X") || a.hasPrefix("Z")) {
            a = String(a.dropFirst())
        }
        return a
    }

    private static func fetchGateIO() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.gateio.ws/api/v4/spot/currency_pairs") else { return [] }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let id = s["id"] as? String,
                  let base = s["base"] as? String,
                  let quote = s["quote"] as? String,
                  let status = s["trade_status"] as? String,
                  status == "tradable" else { return nil }
            let symbol = id.replacingOccurrences(of: "_", with: "")
            return IndexedSymbol(
                symbol: symbol, baseAsset: base, quoteAsset: quote,
                exchange: "GATEIO", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchMEXC() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.mexc.com/api/v3/exchangeInfo") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let syms = json["symbols"] as? [[String: Any]] else { return [] }

        return syms.compactMap { s -> IndexedSymbol? in
            guard let symbol = s["symbol"] as? String,
                  let base = s["baseAsset"] as? String,
                  let quote = s["quoteAsset"] as? String,
                  let status = s["status"] as? String,
                  status == "1" else { return nil }
            return IndexedSymbol(
                symbol: symbol, baseAsset: base.uppercased(), quoteAsset: quote.uppercased(),
                exchange: "MEXC", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchHTX() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.huobi.pro/v1/common/symbols") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let base = s["base-currency"] as? String,
                  let quote = s["quote-currency"] as? String,
                  let state = s["state"] as? String,
                  state == "online" else { return nil }
            let symbol = "\(base.uppercased())\(quote.uppercased())"
            return IndexedSymbol(
                symbol: symbol, baseAsset: base.uppercased(), quoteAsset: quote.uppercased(),
                exchange: "HTX", type: "crypto",
                description: "\(base.uppercased()) / \(quote.uppercased())"
            )
        }
    }

    private static func fetchBitget() async -> [IndexedSymbol] {
        guard let data = await httpGet("https://api.bitget.com/api/v2/spot/public/symbols") else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }

        return list.compactMap { s -> IndexedSymbol? in
            guard let symbol = s["symbol"] as? String,
                  let base = s["baseCoin"] as? String,
                  let quote = s["quoteCoin"] as? String,
                  let status = s["status"] as? String,
                  status == "online" else { return nil }
            return IndexedSymbol(
                symbol: symbol, baseAsset: base, quoteAsset: quote,
                exchange: "BITGET", type: "crypto",
                description: "\(base) / \(quote)"
            )
        }
    }

    private static func fetchHyperliquid() async -> [IndexedSymbol] {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        guard let body = try? JSONSerialization.data(withJSONObject: ["type": "allMids"]) else { return [] }
        req.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let mids = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return mids.keys.map { coin in
                IndexedSymbol(
                    symbol: "\(coin)USDC",
                    baseAsset: coin,
                    quoteAsset: "USDC",
                    exchange: "HYPERLIQUID",
                    type: "crypto",
                    description: "\(coin) / USDC (Perp)"
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - HTTP Helper

    private static func httpGet(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            #if DEBUG
            print("[ExchangeSymbolIndex] Failed to fetch \(urlString): \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}
