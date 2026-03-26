import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Model

struct WidgetMarket: Identifiable {
    var id: String { symbol + name }
    let name: String
    let symbol: String       // API symbol (e.g. "BTC", "@105", "TV:BINANCE:ETHUSDT")
    let price: Double
    let change24h: Double
    let volume24h: Double
    let iconData: Data?
    var iconName: String = ""
    var iconQuote: String? = nil   // non-nil → dual icon (pair chart)
    var iconQuoteData: Data? = nil
    var isCustomTV: Bool = false
    var priceDecimals: Int? = nil  // from szDecimals — nil falls back to magnitude-based

    var isPositive: Bool { change24h >= 0 }

    /// Deep link URL to open chart in the main app.
    var chartURL: URL {
        var c = URLComponents()
        c.scheme = "hyperview"
        c.host = "chart"
        c.queryItems = [
            URLQueryItem(name: "s", value: symbol),
            URLQueryItem(name: "n", value: name)
        ]
        return c.url ?? URL(string: "hyperview://chart")!
    }

    var formattedPrice: String {
        if let dec = priceDecimals {
            return "$" + String(format: "%.\(dec)f", price)
        }
        // Fallback for custom TV charts (no szDecimals available)
        if price >= 10_000 { return String(format: "$%.0f", price) }
        if price >= 1_000  { return String(format: "$%.1f", price) }
        if price >= 1      { return String(format: "$%.2f", price) }
        if price >= 0.01   { return String(format: "$%.4f", price) }
        return String(format: "$%.6f", price)
    }

    var formattedChange: String {
        String(format: "%@%.2f%%", isPositive ? "+" : "", change24h)
    }

    var formattedVolume: String {
        if volume24h >= 1_000_000_000 { return String(format: "%.1fB", volume24h / 1_000_000_000) }
        if volume24h >= 1_000_000     { return String(format: "%.1fM", volume24h / 1_000_000) }
        if volume24h >= 1_000         { return String(format: "%.1fK", volume24h / 1_000) }
        return String(format: "%.0f", volume24h)
    }
}

// MARK: - Timeline Entry

struct MarketEntry: TimelineEntry {
    let date: Date
    let markets: [WidgetMarket]

    static let placeholder = MarketEntry(
        date: .now,
        markets: [
            WidgetMarket(name: "BTC",  symbol: "BTC",  price: 104523, change24h: 2.34,  volume24h: 2_100_000_000, iconData: nil),
            WidgetMarket(name: "ETH",  symbol: "ETH",  price: 3845,   change24h: -1.23, volume24h: 987_000_000,   iconData: nil),
            WidgetMarket(name: "SOL",  symbol: "SOL",  price: 178,    change24h: 5.67,  volume24h: 432_000_000,   iconData: nil),
            WidgetMarket(name: "DOGE", symbol: "DOGE", price: 0.145,  change24h: 8.92,  volume24h: 356_000_000,   iconData: nil),
            WidgetMarket(name: "HYPE", symbol: "HYPE", price: 24.5,   change24h: -3.45, volume24h: 289_000_000,   iconData: nil),
            WidgetMarket(name: "XRP",  symbol: "XRP",  price: 2.35,   change24h: 1.12,  volume24h: 245_000_000,   iconData: nil),
            WidgetMarket(name: "SUI",  symbol: "SUI",  price: 3.87,   change24h: -0.89, volume24h: 198_000_000,   iconData: nil),
            WidgetMarket(name: "LINK", symbol: "LINK", price: 18.45,  change24h: 3.21,  volume24h: 176_000_000,   iconData: nil),
            WidgetMarket(name: "AVAX", symbol: "AVAX", price: 42.30,  change24h: -2.15, volume24h: 154_000_000,   iconData: nil),
            WidgetMarket(name: "PEPE", symbol: "PEPE", price: 0.0000123, change24h: 12.5, volume24h: 132_000_000, iconData: nil),
        ]
    )
}

// MARK: - Cache (offline fallback)

private enum WidgetCache {
    static let key = "widget_market_cache"

    static func save(_ markets: [WidgetMarket]) {
        let data = markets.map { m -> [String: Any] in
            var dict: [String: Any] = [
                "n": m.name, "s": m.symbol, "p": m.price, "c": m.change24h, "v": m.volume24h,
                "i": m.iconData?.base64EncodedString() ?? "",
                "ic": m.iconName,
                "tv": m.isCustomTV
            ]
            if let dec = m.priceDecimals { dict["dec"] = dec }
            return dict
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [WidgetMarket] {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let name = dict["n"] as? String,
                  let price = dict["p"] as? Double,
                  let change = dict["c"] as? Double,
                  let volume = dict["v"] as? Double else { return nil }
            let symbol = dict["s"] as? String ?? name
            let iconB64 = dict["i"] as? String ?? ""
            let iconData = iconB64.isEmpty ? nil : Data(base64Encoded: iconB64)
            let iconName = dict["ic"] as? String ?? name
            let isCustomTV = dict["tv"] as? Bool ?? false
            let dec = dict["dec"] as? Int
            return WidgetMarket(name: name, symbol: symbol, price: price, change24h: change, volume24h: volume, iconData: iconData, iconName: iconName, isCustomTV: isCustomTV, priceDecimals: dec)
        }
    }
}

// MARK: - CoreSVG bridge (same approach as CoinIconView in main app)

private let _svgHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_NOW)

private let _svgCreate: (@convention(c) (CFData, CFDictionary?) -> UnsafeRawPointer?)? = {
    guard let sym = dlsym(_svgHandle, "CGSVGDocumentCreateFromData") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CFData, CFDictionary?) -> UnsafeRawPointer?).self)
}()

private let _svgGetSize: (@convention(c) (UnsafeRawPointer) -> CGSize)? = {
    guard let sym = dlsym(_svgHandle, "CGSVGDocumentGetCanvasSize") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeRawPointer) -> CGSize).self)
}()

private let _svgDraw: (@convention(c) (CGContext, UnsafeRawPointer) -> Void)? = {
    guard let sym = dlsym(_svgHandle, "CGContextDrawSVGDocument") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGContext, UnsafeRawPointer) -> Void).self)
}()

private let _svgRelease: (@convention(c) (UnsafeRawPointer) -> Void)? = {
    guard let sym = dlsym(_svgHandle, "CGSVGDocumentRelease") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeRawPointer) -> Void).self)
}()

// MARK: - Icon Fetcher

private enum IconFetcher {
    static func fetchIcons(for names: [String]) async -> [String: Data] {
        var result: [String: Data] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            for name in names {
                group.addTask {
                    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                    let urlStr = "https://app.hyperliquid.xyz/coins/\(encoded).svg"
                    guard let url = URL(string: urlStr) else { return (name, nil) }
                    do {
                        var request = URLRequest(url: url, timeoutInterval: 8)
                        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                        let (svgData, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return (name, nil) }
                        // Skip HTML error pages
                        if svgData.starts(with: [0x3C, 0x21]) { return (name, nil) }
                        if let pngData = renderSVGtoPNG(svgData, size: 64, symbol: name) {
                            return (name, pngData)
                        }
                        return (name, nil)
                    } catch {
                        return (name, nil)
                    }
                }
            }
            for await (name, data) in group {
                if let data { result[name] = data }
            }
        }
        return result
    }

    private static let knownDarkLogos: Set<String> = ["MEGA", "MegaETH"]

    private static func renderSVGtoPNG(_ svgData: Data, size: Int, symbol: String = "") -> Data? {
        guard let create = _svgCreate,
              let getSize = _svgGetSize,
              let draw = _svgDraw else { return nil }

        guard let docPtr = create(svgData as CFData, nil) else { return nil }
        defer { _svgRelease?(docPtr) }

        let canvas = getSize(docPtr)
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let s = CGFloat(size)
        let scale = min(s / canvas.width, s / canvas.height)
        let targetSize = CGSize(width: s, height: s)

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2.0

        // Render plain icon first
        let plain = UIGraphicsImageRenderer(size: targetSize, format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: s)
            cg.scaleBy(x: 1, y: -1)
            cg.scaleBy(x: scale, y: scale)
            draw(cg, docPtr)
        }

        // Check if icon needs white circle background (dark logos)
        let needsWhiteBg = knownDarkLogos.contains(symbol) || iconIsDark(plain)
        if needsWhiteBg {
            let withBg = UIGraphicsImageRenderer(size: targetSize, format: fmt).image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: CGRect(origin: .zero, size: targetSize))
                cg.translateBy(x: 0, y: s)
                cg.scaleBy(x: 1, y: -1)
                cg.scaleBy(x: scale, y: scale)
                draw(cg, docPtr)
            }
            let data = withBg.pngData()
            return (data?.count ?? 0) > 200 ? data : nil
        }

        let pngData = plain.pngData()
        return (pngData?.count ?? 0) > 200 ? pngData : nil
    }

    /// Quick brightness check for widget icons
    private static func iconIsDark(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }
        let bpr = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var totalBright: Double = 0
        var opaqueCount = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                let a = pixels[i + 3]
                guard a > 128 else { continue }
                let r = Double(pixels[i]), g = Double(pixels[i+1]), b = Double(pixels[i+2])
                totalBright += (r + g + b) / 3.0
                opaqueCount += 1
            }
        }
        guard opaqueCount > 10 else { return false }
        return totalBright / Double(opaqueCount) < 110
    }
}

// MARK: - Shared Data (from main app via App Group)

private let sharedDefaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview")

private enum SharedMarketReader {
    /// Read custom TradingView charts from App Group
    static func loadCustomCharts() -> [WidgetMarket] {
        guard let defaults = sharedDefaults,
              let arr = defaults.array(forKey: "widget_custom_charts") as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict -> WidgetMarket? in
            guard let symbol = dict["symbol"] as? String,
                  let displayName = dict["displayName"] as? String else { return nil }
            let iconBase = dict["iconBase"] as? String ?? displayName
            let iconQuote = dict["iconQuote"] as? String
            // Strip exchange prefixes: "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P" → "HYPE/LITUSDT.P"
            let cleanName = stripAllExchangePrefixes(displayName)
            let price = dict["price"] as? Double ?? 0
            let change = dict["change"] as? Double ?? 0
            return WidgetMarket(name: cleanName, symbol: "TV:\(symbol)",
                                price: price, change24h: change, volume24h: 0,
                                iconData: nil, iconName: iconBase,
                                iconQuote: iconQuote, isCustomTV: true)
        }
    }

    /// Fetch fresh prices for custom TradingView charts.
    /// Handles Binance spot, Binance futures (.P), Hyperliquid, and expression (ratio) charts.
    static func fetchCustomChartPrices(_ charts: [WidgetMarket]) async -> [String: (price: Double, change: Double)] {
        var result: [String: (price: Double, change: Double)] = [:]

        // Separate into bulk-fetchable Binance spot vs individual fetches
        var binanceSpot: [(name: String, pair: String)] = []
        var others: [(name: String, raw: String)] = []

        for chart in charts where chart.isCustomTV {
            let raw = chart.symbol.hasPrefix("TV:") ? String(chart.symbol.dropFirst(3)) : chart.symbol
            if isExpression(raw) {
                others.append((chart.name, raw))
            } else {
                let (exchange, pair) = parseExchangePair(raw)
                let upper = exchange.uppercased()
                if (upper == "BINANCE" || upper.isEmpty) && !pair.hasSuffix(".P") {
                    binanceSpot.append((chart.name, pair.replacingOccurrences(of: "/", with: "")))
                } else {
                    others.append((chart.name, raw))
                }
            }
        }

        // Bulk fetch Binance spot
        if !binanceSpot.isEmpty {
            let pairs = binanceSpot.map { "\"\($0.pair)\"" }.joined(separator: ",")
            if let url = URL(string: "https://api.binance.com/api/v3/ticker/24hr?symbols=[\(pairs)]") {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let reverseMap = Dictionary(uniqueKeysWithValues: binanceSpot.map { ($0.pair, $0.name) })
                        for item in arr {
                            guard let binPair = item["symbol"] as? String,
                                  let priceStr = item["lastPrice"] as? String,
                                  let changeStr = item["priceChangePercent"] as? String,
                                  let price = Double(priceStr),
                                  let change = Double(changeStr),
                                  let name = reverseMap[binPair] else { continue }
                            result[name] = (price, change)
                        }
                    }
                } catch {}
            }
        }

        // Individual fetches for expressions, futures, and HL
        await withTaskGroup(of: (String, Double, Double)?.self) { group in
            for item in others {
                group.addTask { await fetchSinglePrice(name: item.name, raw: item.raw) }
            }
            for await res in group {
                if let (name, price, change) = res { result[name] = (price, change) }
            }
        }
        return result
    }

    /// Fetch price + 24h change for a single chart (expression, futures, or HL)
    private static func fetchSinglePrice(name: String, raw: String) async -> (String, Double, Double)? {
        if isExpression(raw) {
            return await fetchExpressionPrice(name: name, raw: raw)
        }
        let (exchange, pair) = parseExchangePair(raw)
        if let (price, change) = await fetchExchangeTicker(exchange: exchange, pair: pair) {
            return (name, price, change)
        }
        return nil
    }

    /// Unified exchange ticker: returns (price, change24h%) for any supported exchange.
    /// Falls back to Binance if the exchange-specific API fails.
    private static func fetchExchangeTicker(exchange: String, pair: String) async -> (Double, Double)? {
        let ex = exchange.uppercased()

        switch ex {
        case "HYPERLIQUID", "HL":
            let coin = stripQuoteSuffix(pair)
            return await fetchHL24hr(coin: coin)

        case "KUCOIN":
            let kcSymbol = tvPairToHyphenated(pair)
            if let url = URL(string: "https://api.kucoin.com/api/v1/market/stats?symbol=\(kcSymbol)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let innerData = json["data"] as? [String: Any],
               let priceStr = innerData["last"] as? String,
               let changeStr = innerData["changeRate"] as? String,
               let price = Double(priceStr), let changeRate = Double(changeStr) {
                return (price, changeRate * 100)
            }

        case "OKX", "OKEX":
            let instId = tvPairToHyphenated(pair)
            if let url = URL(string: "https://www.okx.com/api/v5/market/ticker?instId=\(instId)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["data"] as? [[String: Any]], let first = arr.first,
               let priceStr = first["last"] as? String, let openStr = first["open24h"] as? String,
               let price = Double(priceStr), let open = Double(openStr), open > 0 {
                return (price, ((price - open) / open) * 100)
            }

        case "BYBIT":
            let clean = pair.replacingOccurrences(of: ".P", with: "")
            if let url = URL(string: "https://api.bybit.com/v5/market/tickers?category=spot&symbol=\(clean)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let list = result["list"] as? [[String: Any]], let first = list.first,
               let priceStr = first["lastPrice"] as? String,
               let pctStr = first["price24hPcnt"] as? String,
               let price = Double(priceStr), let pct = Double(pctStr) {
                return (price, pct * 100)
            }

        case "COINBASE", "COINBASEPRO":
            let product = tvPairToHyphenated(pair)
            if let url = URL(string: "https://api.exchange.coinbase.com/products/\(product)/stats"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lastStr = json["last"] as? String, let openStr = json["open"] as? String,
               let price = Double(lastStr), let open = Double(openStr), open > 0 {
                return (price, ((price - open) / open) * 100)
            }

        case "GATEIO", "GATE":
            let gateSymbol = tvPairToUnderscore(pair)
            if let url = URL(string: "https://api.gateio.ws/api/v4/spot/tickers?currency_pair=\(gateSymbol)"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first,
               let priceStr = first["last"] as? String, let pctStr = first["change_percentage"] as? String,
               let price = Double(priceStr), let pct = Double(pctStr) {
                return (price, pct)
            }

        default:
            break
        }

        // Fallback: try Binance spot, then Binance futures
        let isFutures = pair.hasSuffix(".P")
        let cleanPair = isFutures ? String(pair.dropLast(2)) : pair.replacingOccurrences(of: "/", with: "")

        // Try Binance spot
        if let url = URL(string: "https://api.binance.com/api/v3/ticker/24hr?symbol=\(cleanPair)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = (json["lastPrice"] as? String).flatMap(Double.init),
           let c = (json["priceChangePercent"] as? String).flatMap(Double.init) {
            return (p, c)
        }
        // Try Binance futures
        if let url = URL(string: "https://fapi.binance.com/fapi/v1/ticker/24hr?symbol=\(cleanPair)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = (json["lastPrice"] as? String).flatMap(Double.init),
           let c = (json["priceChangePercent"] as? String).flatMap(Double.init) {
            return (p, c)
        }
        return nil
    }

    /// "HYPEUSDT" → "HYPE-USDT" (KuCoin, OKX, Coinbase format)
    private static func tvPairToHyphenated(_ pair: String) -> String {
        let clean = pair.replacingOccurrences(of: ".P", with: "")
        for quote in ["USDT", "USDC", "BTC", "ETH", "USD", "BUSD"] {
            if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                return "\(String(clean.dropLast(quote.count)))-\(quote)"
            }
        }
        return clean
    }

    /// "HYPEUSDT" → "HYPE_USDT" (Gate.io format)
    private static func tvPairToUnderscore(_ pair: String) -> String {
        let clean = pair.replacingOccurrences(of: ".P", with: "")
        for quote in ["USDT", "USDC", "BTC", "ETH", "BUSD"] {
            if clean.uppercased().hasSuffix(quote) && clean.count > quote.count {
                return "\(String(clean.dropLast(quote.count)))_\(quote)"
            }
        }
        return clean
    }

    /// Fetch expression ratio price and 24h change
    private static func fetchExpressionPrice(name: String, raw: String) async -> (String, Double, Double)? {
        let sides = raw.split(separator: "/", maxSplits: 1)
        guard sides.count == 2 else { return nil }
        async let numData = fetchSide24hr(String(sides[0]))
        async let denData = fetchSide24hr(String(sides[1]))
        guard let num = await numData, let den = await denData,
              den.price > 0, den.open > 0 else { return nil }
        let ratio = num.price / den.price
        let openRatio = num.open / den.open
        let change = ((ratio - openRatio) / openRatio) * 100
        return (name, ratio, change)
    }

    /// Fetch price + daily open for one side of an expression.
    /// Uses fetchExchangeTicker for (price, change) then derives open from change.
    private static func fetchSide24hr(_ side: String) async -> (price: Double, open: Double)? {
        let (exchange, pair) = parseExchangePair(side)
        let ex = exchange.uppercased()

        // HL: fetch price from allMids + daily open from candle snapshot
        if ex == "HYPERLIQUID" || ex == "HL" {
            let coin = stripQuoteSuffix(pair)
            guard let (price, _) = await fetchHL24hr(coin: coin) else { return nil }
            let endMs = Int64(Date().timeIntervalSince1970 * 1000)
            let body: [String: Any] = ["type": "candleSnapshot", "req": [
                "coin": coin, "interval": "1d", "startTime": endMs - 172_800_000, "endTime": endMs
            ]]
            guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return (price, price) }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let candles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let last = candles.last,
               let o = (last["o"] as? String).flatMap(Double.init) {
                return (price, o)
            }
            return (price, price)
        }

        // All other exchanges: use unified ticker then derive open from change
        guard let (price, change) = await fetchExchangeTicker(exchange: exchange, pair: pair) else { return nil }
        let open = change != 0 ? price / (1 + change / 100) : price
        return (price, open)
    }

    /// Fetch HL mid price + 24h change
    private static func fetchHL24hr(coin: String) async -> (Double, Double)? {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "allMids"])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let price = mids[coin].flatMap(Double.init) else { return nil }
        // Daily candle for open
        let endMs = Int64(Date().timeIntervalSince1970 * 1000)
        let candleBody: [String: Any] = ["type": "candleSnapshot", "req": [
            "coin": coin, "interval": "1d", "startTime": endMs - 172_800_000, "endTime": endMs
        ]]
        var cReq = URLRequest(url: url)
        cReq.httpMethod = "POST"
        cReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        cReq.httpBody = try? JSONSerialization.data(withJSONObject: candleBody)
        if let (cData, _) = try? await URLSession.shared.data(for: cReq),
           let candles = try? JSONSerialization.jsonObject(with: cData) as? [[String: Any]],
           let last = candles.last,
           let o = (last["o"] as? String).flatMap(Double.init), o > 0 {
            return (price, ((price - o) / o) * 100)
        }
        return (price, 0)
    }

    private static func isExpression(_ s: String) -> Bool {
        let sides = s.split(separator: "/", maxSplits: 1)
        return sides.count == 2 && !sides[0].isEmpty && !sides[1].isEmpty
            && (sides[0].contains(":") || sides[1].contains(":"))
    }

    private static func parseExchangePair(_ s: String) -> (String, String) {
        let parts = s.split(separator: ":", maxSplits: 1)
        if parts.count > 1 { return (String(parts[0]), String(parts[1])) }
        return ("", s)
    }

    private static func stripQuoteSuffix(_ pair: String) -> String {
        let upper = pair.uppercased()
        for suffix in ["USDT", "USDC", "BUSD", "USD", "PERP"] {
            if upper.hasSuffix(suffix) && upper.count > suffix.count {
                return String(upper.dropLast(suffix.count))
            }
        }
        return pair
    }

    /// Read markets written by the main app, then fetch only the icons that aren't already cached.
    /// Previously cached icons (saved by WidgetCache) are reused to avoid redundant network calls.
    /// Order matches Markets view: the app writes markets already sorted (favorites first),
    /// so we just insert custom charts after the last favorite.
    static func loadFromApp() async -> [WidgetMarket] {
        guard let defaults = sharedDefaults,
              let arr = defaults.array(forKey: "widget_shared_markets") as? [[String: Any]]
        else { return [] }

        // Read watchlist to know where favorites end in the shared list
        let watchSet = Set(defaults.stringArray(forKey: "widget_watchlist") ?? [])
        let customCharts = loadCustomCharts()

        // --- Temporary debug log ---
        let readSymbols = arr.prefix(10).compactMap { ($0["s"] as? String) }
        print("WIDGET APP GROUP READ TOP10: \(readSymbols)")

        let hlMarkets = arr.compactMap { dict -> WidgetMarket? in
            guard let name = dict["n"] as? String,
                  let price = dict["p"] as? Double,
                  let change = dict["c"] as? Double,
                  let volume = dict["v"] as? Double else { return nil }
            let symbol = dict["s"] as? String ?? name
            let iconName = dict["icon"] as? String ?? name
            let dec = dict["dec"] as? Int
            return WidgetMarket(name: name, symbol: symbol, price: price, change24h: change,
                                volume24h: volume, iconData: nil, iconName: iconName,
                                priceDecimals: dec)
        }

        // If the user has manually reordered, respect that unified order
        let unifiedOrder = defaults.stringArray(forKey: "widget_unified_order")

        var markets: [WidgetMarket]
        if let order = unifiedOrder, !order.isEmpty {
            // Build lookup maps keyed by orderKey
            var hlMap: [String: WidgetMarket] = [:]
            for m in hlMarkets { hlMap[m.symbol] = m }
            var customMap: [String: WidgetMarket] = [:]
            // c.symbol is already "TV:BINANCE:ETHUSDT" from loadCustomCharts
            for c in customCharts { customMap[c.symbol] = c }

            // Place items in saved order
            var ordered: [WidgetMarket] = []
            var usedHL = Set<String>()
            var usedCustom = Set<String>()
            for key in order {
                if let m = hlMap[key] {
                    ordered.append(m)
                    usedHL.insert(key)
                } else if let c = customMap[key] {
                    ordered.append(c)
                    usedCustom.insert(key)
                }
            }
            // Append any remaining items not in the saved order
            for c in customCharts where !usedCustom.contains(c.symbol) {
                ordered.append(c)
            }
            for m in hlMarkets where !usedHL.contains(m.symbol) {
                ordered.append(m)
            }
            markets = ordered
        } else {
            // The app writes widget_shared_markets in exact display order
            // (favorites first, then the rest). Preserve that order as-is
            // and just append any custom TradingView charts at the end.
            markets = hlMarkets + customCharts
        }

        // --- Temporary debug logs ---
        print("WIDGET POST-PROCESS TOP10: \(markets.prefix(10).map(\.symbol))")
        print("WIDGET FINAL DISPLAY TOP10: \(markets.prefix(10).map(\.symbol))")

        // Build icon map from WidgetCache — reuse already-fetched icons, only download new ones.
        let cachedIcons: [String: Data] = Dictionary(
            WidgetCache.load().compactMap { m -> (String, Data)? in
                guard let data = m.iconData else { return nil }
                return (m.iconName, data)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Collect all icon names needed (base + quote for dual icons)
        var allNeeded: Set<String> = []
        for m in markets {
            allNeeded.insert(m.iconName)
            if let q = m.iconQuote { allNeeded.insert(q) }
        }
        let missingNames = allNeeded.filter { cachedIcons[$0] == nil }
        let fetched = missingNames.isEmpty ? [:] : await IconFetcher.fetchIcons(for: Array(missingNames))
        let allIcons = cachedIcons.merging(fetched) { _, new in new }

        for i in markets.indices {
            markets[i] = WidgetMarket(
                name: markets[i].name, symbol: markets[i].symbol, price: markets[i].price,
                change24h: markets[i].change24h, volume24h: markets[i].volume24h,
                iconData: allIcons[markets[i].iconName], iconName: markets[i].iconName,
                iconQuote: markets[i].iconQuote,
                iconQuoteData: markets[i].iconQuote.flatMap { allIcons[$0] },
                isCustomTV: markets[i].isCustomTV,
                priceDecimals: markets[i].priceDecimals
            )
        }
        return markets
    }

    /// Read daily open prices from App Group (written by main app from backend).
    private static func loadDailyOpens() -> [String: Double] {
        guard let defaults = sharedDefaults,
              let dict = defaults.dictionary(forKey: "widget_daily_opens")
        else { return [:] }
        var opens: [String: Double] = [:]
        for (key, val) in dict {
            if let d = val as? Double { opens[key] = d }
            else if let n = val as? NSNumber { opens[key] = n.doubleValue }
        }
        return opens
    }

    /// Compute change% using daily candle open (TradingView style) when available.
    private static func computeChange(price: Double, prevDayPx: Double, dailyOpen: Double?) -> Double {
        let ref = (dailyOpen != nil && dailyOpen! > 0) ? dailyOpen! : prevDayPx
        guard ref > 0 else { return 0 }
        return ((price - ref) / ref) * 100
    }

    /// Fallback: fetch directly from Hyperliquid API (top by volume).
    static func fetchFromAPI(count: Int = 10) async -> [WidgetMarket] {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs"])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2 else { return [] }

            let metaData = try JSONSerialization.data(withJSONObject: json[0])
            let meta = try JSONDecoder().decode(MetaResponse.self, from: metaData)

            let ctxsData = try JSONSerialization.data(withJSONObject: json[1])
            let ctxs = try JSONDecoder().decode([ContextInfo].self, from: ctxsData)

            let dailyOpens = loadDailyOpens()

            var markets: [WidgetMarket] = []
            for (i, asset) in meta.universe.enumerated() where i < ctxs.count {
                let ctx = ctxs[i]
                let price  = Double(ctx.markPx     ?? "0") ?? 0
                let prev   = Double(ctx.prevDayPx  ?? "0") ?? 0
                let volume = Double(ctx.dayNtlVlm  ?? "0") ?? 0
                guard volume > 0 else { continue }
                let change = computeChange(price: price, prevDayPx: prev, dailyOpen: dailyOpens[asset.name])
                markets.append(WidgetMarket(name: asset.name, symbol: asset.name, price: price,
                                            change24h: change, volume24h: volume,
                                            iconData: nil, iconName: asset.name))
            }
            markets.sort { $0.volume24h > $1.volume24h }
            var top = Array(markets.prefix(count))

            let icons = await IconFetcher.fetchIcons(for: top.map(\.iconName))
            for i in top.indices {
                top[i] = WidgetMarket(
                    name: top[i].name, symbol: top[i].symbol, price: top[i].price,
                    change24h: top[i].change24h, volume24h: top[i].volume24h,
                    iconData: icons[top[i].iconName], iconName: top[i].iconName
                )
            }
            return top
        } catch {
            return []
        }
    }

    /// Fetch fresh prices from API (no icons). Returns [coinName: (price, change, volume)].
    /// Uses daily candle opens (TradingView-style) when available.
    /// Fetches from App Group first, then from backend if empty.
    static func fetchFreshPrices() async -> [String: (price: Double, change: Double, volume: Double)] {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "metaAndAssetCtxs"])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2 else { return [:] }

            let metaData = try JSONSerialization.data(withJSONObject: json[0])
            let meta = try JSONDecoder().decode(MetaResponse.self, from: metaData)
            let ctxsData = try JSONSerialization.data(withJSONObject: json[1])
            let ctxs = try JSONDecoder().decode([ContextInfo].self, from: ctxsData)

            // Try App Group daily opens first, then fetch from backend
            var dailyOpens = loadDailyOpens()
            if dailyOpens.isEmpty {
                dailyOpens = await fetchDailyOpensFromBackend()
            }

            var result: [String: (price: Double, change: Double, volume: Double)] = [:]
            for (i, asset) in meta.universe.enumerated() where i < ctxs.count {
                let ctx = ctxs[i]
                let price  = Double(ctx.markPx    ?? "0") ?? 0
                let prev   = Double(ctx.prevDayPx ?? "0") ?? 0
                let volume = Double(ctx.dayNtlVlm ?? "0") ?? 0
                let change = computeChange(price: price, prevDayPx: prev, dailyOpen: dailyOpens[asset.name])
                result[asset.name] = (price, change, volume)
            }
            return result
        } catch {
            return [:]
        }
    }

    /// Lightweight fallback: fetch only allMids (much smaller payload than metaAndAssetCtxs)
    static func fetchAllMidsFallback(markets: [WidgetMarket], fresh: Bool = false) async -> [String: (price: Double, change: Double, volume: Double)] {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Daily opens change once per day — always use cached values for fast refresh.
        // They're kept up-to-date by the timeline provider and main app.
        let dailyOpens = loadDailyOpens()

        let hip3Markets = markets.filter { $0.symbol.contains(":") }
        let hasHIP3 = !hip3Markets.isEmpty

        // Extract unique DEX prefixes from HIP-3 symbols (e.g. "xyz" from "xyz:GOLD")
        let neededDexes: Set<String> = Set(hip3Markets.compactMap { m in
            let sym = m.symbol
            guard let colon = sym.firstIndex(of: ":") else { return nil }
            let dex = String(sym[sym.startIndex..<colon])
            return dex.isEmpty ? nil : dex
        })

        if hasHIP3 {
            print("[WIDGET HAS HIP3] YES — dexes: \(neededDexes.sorted()) symbols: \(hip3Markets.map(\.symbol))")
        }

        // Launch ALL fetches in parallel — allMids (normal) + HIP-3 direct from HL
        // When fresh (refresh tap): fetch HIP-3 directly from HL API (fast, no backend dependency)
        // When not fresh (timeline): try backend cache first (lighter on HL rate limits)
        async let midsTask = fetchAllMids()
        async let hip3Task: [String: Double] = hasHIP3
            ? (fresh ? fetchHIP3Direct(dexes: neededDexes) : fetchHIP3FromBackend(dexes: neededDexes))
            : [:]

        let mids = await midsTask
        let hip3Prices = await hip3Task

        let t1 = CFAbsoluteTimeGetCurrent()
        print("[WIDGET FETCH DONE] \(String(format: "%.0f", (t1 - t0) * 1000))ms — mids=\(mids.count) hip3=\(hip3Prices.count)")

        // Debug: log HIP-3 keys
        if hasHIP3 {
            let hip3Keys = hip3Prices.keys.sorted()
            print("[HIP3 RESPONSE KEYS] \(hip3Keys.count) keys: \(hip3Keys.prefix(20).joined(separator: ", "))")
        }

        var result: [String: (price: Double, change: Double, volume: Double)] = [:]

        for m in markets {
            var price: Double? = nil

            // Main DEX: from allMids
            if let priceStr = mids[m.symbol] ?? mids[m.name] {
                price = Double(priceStr)
            }

            // HIP-3: from direct HL fetch
            if price == nil, let hip3 = hip3Prices[m.symbol] ?? hip3Prices[m.name], hip3 > 0 {
                price = hip3
            }

            // Debug: log HIP-3 lookup
            if m.symbol.contains(":") {
                let found = hip3Prices[m.symbol] ?? hip3Prices[m.name]
                print("[HIP3 LOOKUP] symbol=\(m.symbol) name=\(m.name) → hip3Price=\(found.map { String($0) } ?? "MISS") finalPrice=\(price.map { String($0) } ?? "nil")")
            }

            if let price, price > 0 {
                var change = m.change24h
                if let open = dailyOpens[m.symbol] ?? dailyOpens[m.name], open > 0 {
                    change = ((price - open) / open) * 100
                }
                result[m.name] = (price, change, m.volume24h)
            }
        }

        return result
    }

    /// Fetch allMids from Hyperliquid (main DEX perps + spot pairs)
    private static func fetchAllMids() async -> [String: String] {
        guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "allMids"])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
        } catch {
            return [:]
        }
    }

    // MARK: - HIP-3 prices

    /// Fetch HIP-3 prices directly from Hyperliquid API for specific DEXes — in parallel.
    /// Used by widget refresh (fresh=true) for speed and reliability (no backend dependency).
    private static func fetchHIP3Direct(dexes: Set<String>) async -> [String: Double] {
        let dexList = dexes.isEmpty ? ["xyz", "cash", "km"] : Array(dexes)
        let t0 = CFAbsoluteTimeGetCurrent()
        print("[HIP3 DIRECT START] fetching \(dexList.count) DEXes: \(dexList)")

        var combined: [String: Double] = [:]
        await withTaskGroup(of: (String, [String: Double]).self) { group in
            for dex in dexList {
                group.addTask {
                    guard let url = URL(string: "https://api.hyperliquid.xyz/info") else { return (dex, [:]) }
                    var request = URLRequest(url: url, timeoutInterval: 6)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "type": "metaAndAssetCtxs",
                        "dex": dex
                    ])
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          arr.count >= 2,
                          let meta = (arr[0] as? [String: Any])?["universe"] as? [[String: Any]],
                          let ctxs = arr[1] as? [[String: Any]] else {
                        print("[HIP3 DIRECT FAIL] dex=\(dex) — bad response")
                        return (dex, [:])
                    }
                    var prices: [String: Double] = [:]
                    for (i, asset) in meta.enumerated() where i < ctxs.count {
                        if let rawName = asset["name"] as? String,
                           let markPx = ctxs[i]["markPx"] as? String,
                           let price = Double(markPx), price > 0 {
                            // Normalize: HL API may return unprefixed names for some DEXes.
                            // Must prefix with "dex:" to match widget symbol keys (e.g. "xyz:WTIOIL").
                            let name = rawName.contains(":") ? rawName : "\(dex):\(rawName)"
                            prices[name] = price
                        }
                    }
                    print("[HIP3 DIRECT OK] dex=\(dex) — \(prices.count) prices (raw first: \(meta.first?["name"] as? String ?? "?") → normalized: \(prices.keys.first ?? "?"))")
                    return (dex, prices)
                }
            }
            for await (_, prices) in group {
                combined.merge(prices) { _, new in new }
            }
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        print("[HIP3 DIRECT DONE] \(String(format: "%.0f", (t1 - t0) * 1000))ms — \(combined.count) total prices")
        return combined
    }

    /// Fetch HIP-3 prices from backend cache (used for non-fresh timeline updates).
    /// Falls back to direct HL fetch if backend fails.
    private static func fetchHIP3FromBackend(dexes: Set<String>) async -> [String: Double] {
        if let url = URL(string: "https://hyperview-backend-production-075c.up.railway.app/all-prices") {
            var request = URLRequest(url: url, timeoutInterval: 8)
            if let (data, resp) = try? await URLSession.shared.data(for: request),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let prices = json["prices"] as? [String: Any] {
                var result: [String: Double] = [:]
                for (key, val) in prices {
                    guard key.contains(":") else { continue }
                    if let d = val as? Double { result[key] = d }
                    else if let n = val as? NSNumber { result[key] = n.doubleValue }
                }
                if !result.isEmpty { return result }
            }
        }
        // Backend failed — fetch directly from HL
        return await fetchHIP3Direct(dexes: dexes)
    }

    /// Fetch daily opens directly from backend when App Group is empty.
    /// - Parameter fresh: When true, appends ?fresh=1 to bypass backend cache.
    static func fetchDailyOpensFromBackend(fresh: Bool = false) async -> [String: Double] {
        let suffix = fresh ? "?fresh=1" : ""
        guard let url = URL(string: "https://hyperview-backend-production-075c.up.railway.app/daily-opens\(suffix)") else { return [:] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let opens = json["opens"] as? [String: Any] else { return [:] }
            var result: [String: Double] = [:]
            for (key, val) in opens {
                if let d = val as? Double { result[key] = d }
                else if let n = val as? NSNumber { result[key] = n.doubleValue }
            }
            // Save to App Group for next time
            if !result.isEmpty,
               let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview") {
                defaults.set(result, forKey: "widget_daily_opens")
            }
            return result
        } catch {
            return [:]
        }
    }

    private struct MetaResponse: Decodable {
        let universe: [AssetInfo]
    }
    private struct AssetInfo: Decodable {
        let name: String
    }
    private struct ContextInfo: Decodable {
        let markPx: String?
        let prevDayPx: String?
        let dayNtlVlm: String?
    }
}

// MARK: - Refresh Intent

struct RefreshMarketsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Markets"

    func perform() async throws -> some IntentResult {
        let tStart = CFAbsoluteTimeGetCurrent()
        print("[WIDGET REFRESH TAPPED] \(Date())")

        guard let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview"),
              var arr = defaults.array(forKey: "widget_shared_markets") as? [[String: Any]]
        else {
            WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
            return .result()
        }

        // Build a lightweight market list (no icons needed — we only want fresh prices).
        let markets = arr.compactMap { dict -> WidgetMarket? in
            guard let name = dict["n"] as? String,
                  let price = dict["p"] as? Double,
                  let change = dict["c"] as? Double,
                  let volume = dict["v"] as? Double else { return nil }
            let symbol = dict["s"] as? String ?? name
            let iconName = dict["icon"] as? String ?? name
            let dec = dict["dec"] as? Int
            return WidgetMarket(name: name, symbol: symbol, price: price, change24h: change,
                                volume24h: volume, iconData: nil, iconName: iconName,
                                priceDecimals: dec)
        }

        let hip3Symbols = markets.filter { $0.symbol.contains(":") }.map { "[\($0.symbol) n=\($0.name)]" }
        let normalSymbols = markets.filter { !$0.symbol.contains(":") }.map(\.symbol)
        print("[WIDGET MARKETS] \(markets.count) total — normal: \(normalSymbols) hip3: \(hip3Symbols)")

        // Fetch HL prices + custom chart prices ALL in parallel — NO backend dependency for fresh
        let customCharts = SharedMarketReader.loadCustomCharts()
        let tFetch = CFAbsoluteTimeGetCurrent()
        async let hlTask = SharedMarketReader.fetchAllMidsFallback(markets: markets, fresh: true)
        async let customTask = SharedMarketReader.fetchCustomChartPrices(customCharts)

        let freshPrices = await hlTask
        let customPrices = await customTask
        let tFetched = CFAbsoluteTimeGetCurrent()
        print("[RESPONSE RECEIVED] \(String(format: "%.0f", (tFetched - tFetch) * 1000))ms — \(freshPrices.count) prices")

        if !freshPrices.isEmpty {
            var normalUpdated = 0, hip3Updated = 0, hip3Missed = 0
            for i in arr.indices {
                if let name = arr[i]["n"] as? String, let fresh = freshPrices[name] {
                    let sym = arr[i]["s"] as? String ?? ""
                    if sym.contains(":") {
                        let oldPrice = arr[i]["p"] as? Double ?? 0
                        print("[HIP3 FINAL WRITTEN] \(sym) old=\(oldPrice) → new=\(fresh.price)")
                        hip3Updated += 1
                    } else {
                        normalUpdated += 1
                    }
                    arr[i]["p"] = fresh.price
                    arr[i]["c"] = fresh.change
                    arr[i]["v"] = fresh.volume
                } else if let name = arr[i]["n"] as? String, let sym = arr[i]["s"] as? String, sym.contains(":") {
                    print("[HIP3 FINAL MISS] name=\(name) symbol=\(sym) — freshPrices has \(freshPrices.keys.filter { $0.contains(":") }.count) HIP-3 keys")
                    hip3Missed += 1
                }
            }
            defaults.set(arr, forKey: "widget_shared_markets")
            defaults.set(Date().timeIntervalSince1970, forKey: "widget_last_update")
            let tWritten = CFAbsoluteTimeGetCurrent()
            print("[FINAL WRITEBACK] \(String(format: "%.0f", (tWritten - tStart) * 1000))ms total — normal=\(normalUpdated) hip3=\(hip3Updated) hip3missed=\(hip3Missed)")
        }

        // Update custom charts with fresh Binance prices
        if !customPrices.isEmpty,
           var customArr = defaults.array(forKey: "widget_custom_charts") as? [[String: Any]] {
            for i in customArr.indices {
                let displayName = customArr[i]["displayName"] as? String ?? ""
                let cleanName = stripAllExchangePrefixes(displayName)
                if let fresh = customPrices[cleanName] {
                    customArr[i]["price"] = fresh.price
                    customArr[i]["change"] = fresh.change
                }
            }
            defaults.set(customArr, forKey: "widget_custom_charts")
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
        let tEnd = CFAbsoluteTimeGetCurrent()
        print("[TIMELINE RELOAD] \(String(format: "%.0f", (tEnd - tStart) * 1000))ms total end-to-end")
        return .result()
    }
}

// MARK: - Provider

struct MarketWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MarketEntry {
        .placeholder
    }

    /// Load markets: shared selection + fresh API prices, then fallbacks.
    /// If the data was refreshed within the last 30s (e.g. by RefreshMarketsIntent),
    /// skip the redundant price re-fetch to avoid doubling the network work.
    private func loadMarkets() async -> [WidgetMarket] {
        let shared = await SharedMarketReader.loadFromApp()
        if !shared.isEmpty {
            // Skip price re-fetch if data is already fresh (intent just updated it).
            let lastUpdate = sharedDefaults?.double(forKey: "widget_last_update") ?? 0
            let dataAge = Date().timeIntervalSince1970 - lastUpdate
            if dataAge < 30 {
                WidgetCache.save(shared)
                return shared
            }

            // Fetch HL prices + custom chart prices in parallel
            let customCharts = shared.filter { $0.isCustomTV }
            async let hlTask = SharedMarketReader.fetchAllMidsFallback(markets: shared)
            async let customTask = SharedMarketReader.fetchCustomChartPrices(customCharts)

            let freshPrices = await hlTask
            let customPrices = await customTask

            if !freshPrices.isEmpty || !customPrices.isEmpty {
                let updated = shared.map { m -> WidgetMarket in
                    if m.isCustomTV, let fresh = customPrices[m.name] {
                        return WidgetMarket(name: m.name, symbol: m.symbol, price: fresh.price,
                                            change24h: fresh.change, volume24h: 0,
                                            iconData: m.iconData, iconName: m.iconName,
                                            iconQuote: m.iconQuote, iconQuoteData: m.iconQuoteData,
                                            isCustomTV: true, priceDecimals: m.priceDecimals)
                    }
                    if let fresh = freshPrices[m.name] {
                        return WidgetMarket(name: m.name, symbol: m.symbol, price: fresh.price,
                                            change24h: fresh.change, volume24h: fresh.volume,
                                            iconData: m.iconData, iconName: m.iconName,
                                            iconQuote: m.iconQuote, iconQuoteData: m.iconQuoteData,
                                            isCustomTV: m.isCustomTV, priceDecimals: m.priceDecimals)
                    }
                    return m
                }
                WidgetCache.save(updated)
                return updated
            }
            return shared
        }
        let api = await SharedMarketReader.fetchFromAPI()
        if !api.isEmpty { return api }
        let cached = WidgetCache.load()
        return cached.isEmpty ? MarketEntry.placeholder.markets : cached
    }

    func getSnapshot(in context: Context, completion: @escaping (MarketEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task {
            let markets = await loadMarkets()
            completion(MarketEntry(date: .now, markets: markets))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MarketEntry>) -> Void) {
        Task {
            let markets = await loadMarkets()
            if !markets.isEmpty { WidgetCache.save(markets) }
            let entry = MarketEntry(date: .now, markets: markets)
            let next = Calendar.current.date(byAdding: .minute, value: 10, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Widget Definition

struct MarketWidget: Widget {
    let kind = "MarketWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MarketWidgetProvider()) { entry in
            MarketWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.055, green: 0.055, blue: 0.055)
                }
        }
        .configurationDisplayName("Markets")
        .description("Top Hyperliquid markets by volume")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry View

struct MarketWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: MarketEntry

    var body: some View {
        switch family {
        case .systemSmall:
            let market = entry.markets.first ?? MarketEntry.placeholder.markets[0]
            SmallWidgetView(market: market)
                .widgetURL(marketsURL)
        case .systemMedium:
            MediumWidgetView(markets: Array(entry.markets.prefix(3)), date: entry.date)
        default:
            LargeWidgetView(markets: Array(entry.markets.prefix(10)), date: entry.date)
        }
    }
}

// MARK: - Colors

private let hlGreen = Color(red: 0.145, green: 0.839, blue: 0.584)
private let hlRed   = Color(red: 0.929, green: 0.251, blue: 0.329)
private let marketsURL = URL(string: "hyperview://markets")!

/// Strip exchange prefixes from both sides of an expression.
/// "HYPERLIQUID:HYPE/BINANCE:LITUSDT.P" → "HYPE/LITUSDT.P"
/// "BINANCE:ETHBTC" → "ETHBTC"
private func stripAllExchangePrefixes(_ name: String) -> String {
    if name.contains("/") {
        let sides = name.split(separator: "/", maxSplits: 1)
        let a = stripOnePrefix(String(sides[0]))
        let b = sides.count > 1 ? stripOnePrefix(String(sides[1])) : ""
        return b.isEmpty ? a : "\(a)/\(b)"
    }
    return stripOnePrefix(name)
}

private func stripOnePrefix(_ s: String) -> String {
    if let idx = s.firstIndex(of: ":") { return String(s[s.index(after: idx)...]) }
    return s
}

// MARK: - Coin Icon View

private struct CoinIcon: View {
    let market: WidgetMarket
    let size: CGFloat

    var body: some View {
        if market.iconQuote != nil {
            // Dual icon for pair charts
            DualCoinIcon(market: market, size: size)
        } else if let data = market.iconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            // Fallback: colored circle with initials
            ZStack {
                Circle()
                    .fill(Color(white: 0.2))
                Text(String(market.name.prefix(2)))
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

/// Two overlapping coin icons for expression/pair charts
private struct DualCoinIcon: View {
    let market: WidgetMarket
    let size: CGFloat

    var body: some View {
        let small = size * 0.75
        let offset = size * 0.4
        ZStack {
            singleIcon(data: market.iconData, name: market.iconName, size: small)
                .offset(x: -offset / 2)
            singleIcon(data: market.iconQuoteData, name: market.iconQuote ?? "?", size: small)
                .offset(x: offset / 2)
        }
        .frame(width: size + offset * 0.3, height: size)
    }

    @ViewBuilder
    private func singleIcon(data: Data?, name: String, size: CGFloat) -> some View {
        if let data, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(red: 0.055, green: 0.055, blue: 0.055), lineWidth: 1.5))
        } else {
            ZStack {
                Circle().fill(Color(white: 0.2))
                Text(String(name.prefix(2)))
                    .font(.system(size: size * 0.35, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(red: 0.055, green: 0.055, blue: 0.055), lineWidth: 1.5))
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let market: WidgetMarket

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HYPERVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hlGreen)
                Spacer()
                CoinIcon(market: market, size: 20)
            }

            Spacer()

            Text(market.formattedPrice)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)

            HStack(spacing: 4) {
                Image(systemName: market.isPositive ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                Text(market.formattedChange)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(market.isPositive ? hlGreen : hlRed)

            Text(market.name + " · Vol " + market.formattedVolume)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.gray)
        }
    }
}

// MARK: - Medium Widget (3 markets)

struct MediumWidgetView: View {
    let markets: [WidgetMarket]
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Link(destination: marketsURL) {
                    Text("HYPERVIEW")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hlGreen)
                }
                Spacer()
                Text("Updated \(date, style: .relative) ago")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.35))
                Button(intent: RefreshMarketsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            ForEach(Array(markets.enumerated()), id: \.element.id) { index, market in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.06))
                }
                Link(destination: market.chartURL) {
                    HStack(spacing: 6) {
                        CoinIcon(market: market, size: 20)

                        HStack(spacing: 4) {
                            Text(market.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if market.isCustomTV {
                                Text("TV")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.blue)
                            }
                        }

                        Spacer(minLength: 4)

                        if market.isCustomTV && market.price == 0 {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(white: 0.4))
                        } else {
                            Text(market.formattedPrice)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .layoutPriority(1)

                            Text(market.formattedChange)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(market.isPositive ? hlGreen : hlRed)
                                .frame(width: 74, alignment: .trailing)
                                .layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

// MARK: - Large Widget (10 markets)

struct LargeWidgetView: View {
    let markets: [WidgetMarket]
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Link(destination: marketsURL) {
                    Text("HYPERVIEW")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hlGreen)
                }
                Spacer()
                Text("Updated \(date, style: .relative) ago")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.35))
                Button(intent: RefreshMarketsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)

            // Market rows
            ForEach(Array(markets.enumerated()), id: \.element.id) { index, market in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.06))
                }
                Link(destination: market.chartURL) {
                    HStack(spacing: 6) {
                        CoinIcon(market: market, size: 24)

                        HStack(spacing: 4) {
                            Text(market.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if market.isCustomTV {
                                Text("TV")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.blue)
                            }
                        }

                        Spacer(minLength: 4)

                        if market.isCustomTV && market.price == 0 {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(white: 0.4))
                        } else {
                            Text(market.formattedPrice)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .layoutPriority(1)

                            Text(market.formattedChange)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(market.isPositive ? hlGreen : hlRed)
                                .frame(width: 66, alignment: .trailing)
                                .layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

