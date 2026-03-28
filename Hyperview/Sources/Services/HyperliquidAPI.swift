import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int)
    case rateLimited
    case decodingError(Error)
    case parseError(String)
    case walletNotConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL:            return "Invalid URL"
        case .serverError(let c):   return "Server error (\(c))"
        case .rateLimited:          return "Rate limited — please try again"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        case .parseError(let m):    return "Parse error: \(m)"
        case .walletNotConnected:   return "Wallet not connected"
        }
    }
}

// MARK: - Trading types

struct OrderRequest {
    let coin:      String
    let dex:       String
    let isBuy:     Bool
    let price:     Double      // 0 = market order
    let size:      Double
    let orderType: OrderType
    let reduceOnly: Bool
    let tpPrice:   Double?
    let slPrice:   Double?

    enum OrderType { case market, limit, stopMarket, takeProfit }
}

struct OrderResponse: Codable {
    let status:   String
    let response: Inner?

    struct Inner: Codable {
        let type: String?
        let data: Data?
        struct Data: Codable {
            let statuses: [Status]?
            struct Status: Codable {
                let resting: Resting?
                let filled:  Filled?
                let error:   String?
                struct Resting: Codable { let oid: Int }
                struct Filled:  Codable { let totalSz: String; let avgPx: String }
            }
        }
    }
}

// MARK: - Service

final class HyperliquidAPI {
    static let shared = HyperliquidAPI()

    // Builder code — app earns fees on every trade
    static let builderAddress = "0x4100ffCcfF56D8D0d3161Ab13187936C688AFF27"
    static let builderFeeBps  = 5     // 0.005% per trade

    // Referral code — set automatically on first wallet connect
    static let referralCode = "HYPERVIEW"

    private let infoURL     = URL(string: "https://api.hyperliquid.xyz/info")!
    private let exchangeURL = URL(string: "https://api.hyperliquid.xyz/exchange")!
    private let session: URLSession
    private let pinningDelegate = CertificatePinningDelegate()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg, delegate: pinningDelegate, delegateQueue: nil)
    }

    /// Certificate pinning delegate for Hyperliquid API + backend
    private class CertificatePinningDelegate: NSObject, URLSessionDelegate {
        // Public key hashes for pinned domains (SHA256 of SubjectPublicKeyInfo)
        // These should be updated when certificates rotate
        private let pinnedDomains: Set<String> = [
            "api.hyperliquid.xyz",
            "hyperview-backend-production-075c.up.railway.app"
        ]

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust,
                  pinnedDomains.contains(challenge.protectionSpace.host) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // Validate the certificate chain
            let policies = [SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)]
            SecTrustSetPolicies(serverTrust, policies as CFArray)

            var error: CFError?
            guard SecTrustEvaluateWithError(serverTrust, &error) else {
                print("⚠️ Certificate validation failed for \(challenge.protectionSpace.host)")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // Accept valid certificates from pinned domains
            // In production, pin the specific public key hash for maximum security
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }

    // MARK: - Generic POST

    func post(url: URL? = nil, body: [String: Any], maxRetries: Int = 3) async throws -> Data {
        let target = url ?? infoURL
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff with jitter: ~300ms, ~900ms, ~2.7s
                let baseDelay = UInt64(300_000_000) * UInt64(pow(3.0, Double(attempt - 1)))
                let jitter = UInt64.random(in: 0...200_000_000)
                try? await Task.sleep(nanoseconds: baseDelay + jitter)
            }
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return data }
                if http.statusCode == 429, attempt < maxRetries {
                    lastError = APIError.rateLimited
                    continue   // retry on rate-limit
                }
                if http.statusCode == 429 {
                    throw APIError.rateLimited
                }
                throw APIError.serverError(http.statusCode)
            }
            return data
        }
        throw lastError ?? APIError.rateLimited
    }

    // MARK: - Backend URL
    private static let backendBaseURL = Configuration.backendBaseURL

    // MARK: - HIP-3 markets from backend (1 request instead of 30+)

    /// Fetches all HIP-3 DEX markets from the backend cache.
    /// The backend fetches from all DEXes every 2 min, so we get everything in 1 request.
    func fetchHIP3MarketsFromBackend() async -> [Market] {
        guard let url = URL(string: "\(Self.backendBaseURL)/hip3-markets") else { return [] }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalCacheData  // Never use cached empty response
            let (data, resp) = try await session.data(for: req)
            let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            print("[HIP3-DEBUG] Response: \(data.count) bytes, status \(httpStatus)")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let marketsArr = json["markets"] as? [[String: Any]]
            else {
                print("[HIP3-DEBUG] JSON parse failed. First 200 chars: \(String(data: data.prefix(200), encoding: .utf8) ?? "nil")")
                return []
            }
            print("[HIP3-DEBUG] Parsed \(marketsArr.count) market entries")

            var markets: [Market] = []
            for (_, m) in marketsArr.enumerated() {
                guard let name = m["name"] as? String,
                      let dex = m["dex"] as? String
                else { continue }

                // Use absolute asset index from backend (100000 + perpDexIdx * 10000 + posInUniverse)
                // Fall back to 0 if not present (shouldn't happen with updated backend)
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

            print("⚡ Backend HIP-3: \(markets.count) markets from 1 request")
            return markets
        } catch {
            print("⚠️ Backend HIP-3 failed, falling back: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Daily candle open prices from backend

    /// Fetches daily candle open prices from backend (1 request for all markets).
    /// Returns { "BTC": 67500.0, "ETH": 3200.0, "cash:INTC": 22.5, ... }
    func fetchDailyOpens() async -> [String: Double] {
        guard let url = URL(string: "\(Self.backendBaseURL)/daily-opens") else { return [:] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            let (data, _) = try await session.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let opens = json["opens"] as? [String: Any]
            else { return [:] }

            var result: [String: Double] = [:]
            for (coin, val) in opens {
                if let d = val as? Double {
                    result[coin] = d
                } else if let n = val as? NSNumber {
                    result[coin] = n.doubleValue
                }
            }
            print("📊 Backend daily opens: \(result.count) markets")
            return result
        } catch {
            print("⚠️ Daily opens fetch failed: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Perp markets (main + HIP-3)

    func fetchMarkets() async throws -> [Market] {
        async let mainTask = fetchMarketsForDex("")
        async let dexInfo = fetchPerpDexNamesWithIndices()
        let (mainMarkets, hip3Dexes) = try await (mainTask, dexInfo)
        print("✅ \(mainMarkets.count) main DEX markets")
        print("📋 \(hip3Dexes.count) DEX HIP-3: \(hip3Dexes.map(\.name))")

        var hip3Markets: [Market] = []
        for dex in hip3Dexes {
            if let m = try? await self.fetchMarketsForDex(dex.name, perpDexIdx: dex.perpDexIdx) {
                hip3Markets.append(contentsOf: m)
            }
        }
        let all = mainMarkets + hip3Markets
        print("✅ Total perp: \(all.count)")
        return all
    }

    // MARK: - Spot markets

    func fetchSpotMarkets() async throws -> [Market] {
        let data = try await post(body: ["type": "spotMetaAndAssetCtxs"])
        guard let root        = try JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let metaDict    = root[0] as? [String: Any],
              let universeRaw = metaDict["universe"] as? [[String: Any]],
              let contextsRaw = root[1] as? [[String: Any]]
        else { return [] }

        print("🔍 SPOT API: universe=\(universeRaw.count) contexts=\(contextsRaw.count)")

        // Build token name map keyed by array position.
        // pair.tokens references the position in this array, NOT the "index" field.
        var tokenNames: [Int: String] = [:]
        if let tokensRaw = metaDict["tokens"] as? [[String: Any]] {
            for (pos, t) in tokensRaw.enumerated() {
                guard let name = t["name"] as? String else { continue }
                tokenNames[pos] = name
            }
        }

        var markets: [Market] = []
        for i in 0..<universeRaw.count {
            let pairRaw = universeRaw[i]
            guard let toks = pairRaw["tokens"] as? [Int], toks.count >= 2 else { continue }

            // Resolve base/quote names from token indices
            guard let baseName  = tokenNames[toks[0]],
                  let quoteName = tokenNames[toks[1]] else { continue }

            // The pair's real index (from universe[i]["index"]) is the key
            // into the contexts array. universe position ≠ context position
            // because deleted/skipped pairs create gaps in the context array.
            let pairIndex: Int
            if let idx = pairRaw["index"] as? Int {
                pairIndex = idx
            } else if let n = pairRaw["index"] as? NSNumber {
                pairIndex = n.intValue
            } else {
                print("⚠️ SPOT[\(i)] missing index field, falling back to \(i)")
                pairIndex = i
            }

            // Decode context using the pair's actual index, NOT the universe position
            let ctx: AssetContext
            if pairIndex < contextsRaw.count,
               let cData = try? JSONSerialization.data(withJSONObject: contextsRaw[pairIndex]),
               let decoded = try? JSONDecoder().decode(AssetContext.self, from: cData) {
                ctx = decoded
            } else {
                ctx = AssetContext(funding: nil, openInterest: nil, prevDayPx: nil,
                                  dayNtlVlm: nil, premium: nil, oraclePx: nil,
                                  markPx: nil, midPx: nil, impactPxs: nil)
            }

            // API coin identifier: from context.coin field, fallback to @{pairIndex}
            let spotCoin: String
            if pairIndex < contextsRaw.count, let coin = contextsRaw[pairIndex]["coin"] as? String {
                spotCoin = coin
            } else {
                spotCoin = "@\(pairIndex)"
            }

            let pairName = "\(baseName)/\(quoteName)"
            let asset = Asset(name: pairName, szDecimals: 2, maxLeverage: nil, onlyIsolated: nil)
            markets.append(Market(asset: asset, context: ctx, index: 10_000 + pairIndex,
                                  marketType: .spot, dexName: "", spotCoin: spotCoin))

            // Debug: verify correct pairing
            let markPx = ctx.markPrice
            if ["UBTC", "UETH", "USOL", "HYPE", "VORTX", "WOW"].contains(baseName) {
                print("PAIR: \(baseName) / \(quoteName) price: \(markPx) coin: \(spotCoin) pairIdx: \(pairIndex)")
            }
        }
        print("✅ \(markets.count) spot markets")
        return markets
    }

    // MARK: - Helpers

    /// Returns (name, perpDexsIndex) pairs for all HIP-3 DEXes.
    /// The perpDexsIndex is the position in the `perpDexs` response array — needed
    /// to compute absolute asset indices: `100000 + perpDexsIndex * 10000 + posInUniverse`.
    func fetchPerpDexNamesWithIndices() async -> [(name: String, perpDexIdx: Int)] {
        guard let data = try? await post(body: ["type": "perpDexs"]) else { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var result: [(name: String, perpDexIdx: Int)] = []
        for (i, item) in arr.enumerated() {
            if let dict = item as? [String: Any], let name = dict["name"] as? String, !name.isEmpty {
                result.append((name: name, perpDexIdx: i))
            }
        }
        return result
    }

    /// Convenience: just the names (for callers that don't need indices)
    func fetchPerpDexNames() async -> [String] {
        return await fetchPerpDexNamesWithIndices().map(\.name)
    }

    // MARK: - Cached DEX names (1-hour TTL)

    private var cachedDexNames: [String] = []
    private var dexNamesFetchTime: Date = .distantPast

    /// Returns DEX names with 1-hour cache to avoid refetching on every HIP-3 poll cycle.
    func fetchPerpDexNamesCached() async -> [String] {
        if Date().timeIntervalSince(dexNamesFetchTime) < 3600 && !cachedDexNames.isEmpty {
            return cachedDexNames
        }
        let names = await fetchPerpDexNames()
        cachedDexNames = names
        dexNamesFetchTime = Date()
        return names
    }

    /// Fetch markets for a specific DEX.
    /// - Parameters:
    ///   - dex: DEX name ("" for main, "xyz" for HIP-3)
    ///   - perpDexIdx: Position in `perpDexs` array (0 for main DEX). Used to compute absolute asset indices for HIP-3.
    func fetchMarketsForDex(_ dex: String, perpDexIdx: Int = 0) async throws -> [Market] {
        var body: [String: Any] = ["type": "metaAndAssetCtxs"]
        if !dex.isEmpty { body["dex"] = dex }

        let data = try await post(body: body)
        guard let root        = try JSONSerialization.jsonObject(with: data) as? [Any],
              root.count >= 2,
              let metaDict    = root[0] as? [String: Any],
              let universeRaw = metaDict["universe"] as? [[String: Any]],
              let contextsRaw = root[1] as? [[String: Any]]
        else { throw APIError.parseError("metaAndAssetCtxs dex=\(dex)") }

        // For main DEX (dex=""), asset index = position in universe (0, 1, 2...)
        // For HIP-3 DEXes, absolute index = 100000 + perpDexIdx * 10000 + posInUniverse
        let baseIndex = dex.isEmpty ? 0 : (100000 + perpDexIdx * 10000)

        var markets: [Market] = []
        for idx in 0..<universeRaw.count {
            guard idx < contextsRaw.count else { continue }
            let assetRaw = universeRaw[idx]
            let ctxRaw   = contextsRaw[idx]
            guard let aData = try? JSONSerialization.data(withJSONObject: assetRaw),
                  let cData = try? JSONSerialization.data(withJSONObject: ctxRaw),
                  let asset = try? JSONDecoder().decode(Asset.self, from: aData),
                  let ctx   = try? JSONDecoder().decode(AssetContext.self, from: cData)
            else { continue }
            markets.append(Market(asset: asset, context: ctx, index: baseIndex + idx,
                                  marketType: .perp, dexName: dex, spotCoin: ""))
        }
        return markets
    }

    // MARK: - Candles (HIP-3 aware)

    func fetchCandles(coin: String, interval: ChartInterval, limit: Int? = nil) async throws -> [Candle] {
        let count   = limit ?? interval.defaultCount
        let endMs   = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = endMs - Int64(interval.durationSeconds) * Int64(count) * 1000

        // HIP-3 markets: pass full coin name with dex prefix (e.g. "xyz:SP500")
        // The HL candle API expects the coin field to include the dex prefix,
        // NOT a separate "dex" parameter.
        let req: [String: Any] = [
            "coin":      coin,
            "interval":  interval.rawValue,
            "startTime": startMs,
            "endTime":   endMs
        ]

        let data = try await post(body: ["type": "candleSnapshot", "req": req])
        return try JSONDecoder().decode([Candle].self, from: data)
    }

    /// Fetch candles for a custom time range (used for loading older history).
    func fetchCandlesRange(coin: String, interval: ChartInterval,
                           startMs: Int64, endMs: Int64) async throws -> [Candle] {
        let req: [String: Any] = [
            "coin":      coin,
            "interval":  interval.rawValue,
            "startTime": startMs,
            "endTime":   endMs
        ]

        let data = try await post(body: ["type": "candleSnapshot", "req": req])
        return try JSONDecoder().decode([Candle].self, from: data)
    }

    // MARK: - Order Book (HIP-3 aware)

    // No pre-aggregation limit: decode ALL levels the API returns.
    // The display cap (depth selector 10/20/50) is applied inside OrderBookView.aggregate()
    // AFTER aggregation, so large tick sizes always have enough raw levels to fill the view.
    func fetchOrderBook(coin: String, nSigFigs: Int = 5) async throws -> OrderBook {
        // Pass full coin name with dex prefix (e.g. "xyz:SP500") — same as candles
        var body: [String: Any] = ["type": "l2Book", "coin": coin]
        if nSigFigs != 5 { body["nSigFigs"] = nSigFigs }

        let data = try await post(body: body)
        // Cast to [Any] so the guard succeeds for both response formats:
        //   array format  → [["price", "size"], ...]
        //   object format → [{"px": "...", "sz": "...", "n": ...}, ...]
        guard let json      = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLevels = json["levels"] as? [Any],
              rawLevels.count >= 2
        else { throw APIError.parseError("l2Book") }

        // Step 2 — parse each side, handling both response formats.
        func parseSide(_ raw: Any) -> [OrderBookLevel] {
            // Array format: [["69866", "0.12"], ...]
            if let rows = raw as? [[Any]] {
                return rows.compactMap { row -> OrderBookLevel? in
                    guard row.count >= 2 else { return nil }
                    let px: String
                    let sz: String
                    if let p = row[0] as? String, let s = row[1] as? String {
                        px = p; sz = s
                    } else if let p = row[0] as? Double, let s = row[1] as? Double {
                        px = String(p); sz = String(s)
                    } else { return nil }
                    let n = row.count > 2 ? (row[2] as? Int ?? 1) : 1
                    return OrderBookLevel(px: px, sz: sz, n: n)
                }
            }
            // Object format: [{"px": "...", "sz": "...", "n": ...}, ...]
            if let dicts    = raw as? [[String: Any]],
               let sideData = try? JSONSerialization.data(withJSONObject: dicts) {
                return (try? JSONDecoder().decode([OrderBookLevel].self, from: sideData)) ?? []
            }
            return []
        }

        let bids = parseSide(rawLevels[0])
        let asks = parseSide(rawLevels[1])

        let book = OrderBook(coin: coin, bids: bids, asks: asks)
        return book
    }

    // MARK: - Trading

    func submitOrder(signedPayload: [String: Any]) async throws -> OrderResponse {
        let data = try await post(url: exchangeURL, body: signedPayload)
        return try JSONDecoder().decode(OrderResponse.self, from: data)
    }

    func buildOrderAction(assetIndex: Int, request: OrderRequest, nonce: Int64) -> [String: Any] {
        var orderDict: [String: Any] = [
            "a": assetIndex,
            "b": request.isBuy,
            "s": String(format: "%.6f", request.size),
            "r": request.reduceOnly
        ]
        switch request.orderType {
        case .market:
            orderDict["p"] = "0"
            orderDict["t"] = ["trigger": ["isMarket": true, "triggerPx": "0", "tpsl": "na"]]
        case .limit:
            orderDict["p"] = String(format: "%.6f", request.price)
            orderDict["t"] = ["limit": ["tif": "Gtc"]]
        case .takeProfit:
            orderDict["p"] = String(format: "%.6f", request.price)
            orderDict["t"] = ["trigger": ["isMarket": false,
                                          "triggerPx": String(format: "%.6f", request.price),
                                          "tpsl": "tp"]]
        case .stopMarket:
            orderDict["p"] = String(format: "%.6f", request.price)
            orderDict["t"] = ["trigger": ["isMarket": true,
                                          "triggerPx": String(format: "%.6f", request.price),
                                          "tpsl": "sl"]]
        }
        return [
            "action": [
                "type": "order",
                "orders": [orderDict],
                "grouping": "na",
                "builder": ["b": HyperliquidAPI.builderAddress,
                            "f": HyperliquidAPI.builderFeeBps] as [String: Any]
            ] as [String: Any],
            "nonce": nonce
        ]
    }

    // MARK: - User state

    func fetchUserState(address: String) async throws -> [String: Any] {
        let data = try await post(body: ["type": "clearinghouseState", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Fetch HIP-3 perp positions across all permissionless DEXes.
    /// Returns a dict of dexName → clearinghouseState for DEXes where the user has positions.
    func fetchHIP3States(address: String) async -> [String: [String: Any]] {
        let dexNames = await fetchPerpDexNamesCached()
        guard !dexNames.isEmpty else { return [:] }

        // Fetch sequentially to avoid saturating connection pool
        var result: [String: [String: Any]] = [:]
        for dex in dexNames {
            guard let data = try? await post(body: [
                "type": "clearinghouseState",
                "user": address,
                "dex": dex
            ]) else { continue }
            let state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let positions = state["assetPositions"] as? [[String: Any]],
                  !positions.isEmpty else { continue }
            result[dex] = state
        }
        return result
    }

    func fetchStakingState(address: String) async throws -> [String: Any] {
        let data = try await post(body: ["type": "delegatorSummary", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Fetch all validator summaries from Hyperliquid L1.
    func fetchValidatorSummaries() async throws -> [[String: Any]] {
        let data = try await post(body: ["type": "validatorSummaries"])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Recent trades for a coin — used to bootstrap the home feed on startup
    func fetchRecentTrades(coin: String) async throws -> [Trade] {
        let data = try await post(body: ["type": "recentTrades", "coin": coin])
        return (try? JSONDecoder().decode([Trade].self, from: data)) ?? []
    }

    // MARK: - UNIT Bridge API (deposit / withdraw address generation)

    private let unitBaseURL = "https://api.hyperunit.xyz"

    /// Generates a deposit address on `srcChain` that bridges to the user's HL address.
    /// Example: `generateDepositAddress(srcChain: "bitcoin", asset: "btc", hlAddress: "0x...")`
    func generateDepositAddress(srcChain: String, asset: String, hlAddress: String) async throws -> String {
        let urlStr = "\(unitBaseURL)/gen/\(srcChain)/hyperliquid/\(asset)/\(hlAddress)"
        guard let url = URL(string: urlStr) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode)
        }
        // Response is a JSON with "address" field or plain text
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let addr = json["address"] as? String {
            return addr
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        throw APIError.parseError("UNIT deposit address")
    }

    /// Generates an intermediate HL address for withdrawing to `dstChain`.
    /// The user sends tokens to this address on HL; UNIT guardians release on the destination chain.
    func generateWithdrawAddress(dstChain: String, asset: String, dstAddress: String) async throws -> String {
        let urlStr = "\(unitBaseURL)/gen/hyperliquid/\(dstChain)/\(asset)/\(dstAddress)"
        guard let url = URL(string: urlStr) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let addr = json["address"] as? String {
            return addr
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        throw APIError.parseError("UNIT withdraw address")
    }

    // MARK: - Portfolio history

    /// Fetches portfolio history (account value, PnL, volume) for all timeframes.
    /// Returns raw array of [period, data] tuples.
    func fetchPortfolio(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: ["type": "portfolio", "user": address])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw APIError.parseError("portfolio")
        }
        // API returns [ ["day", { accountValueHistory, pnlHistory, vlm }], ["week", ...], ... ]
        var result: [[String: Any]] = []
        for item in root {
            guard let tuple = item as? [Any],
                  tuple.count >= 2,
                  let period = tuple[0] as? String,
                  let body = tuple[1] as? [String: Any]
            else { continue }
            var entry = body
            entry["period"] = period
            result.append(entry)
        }
        return result
    }

    // MARK: - Coin / dex name helpers

    func coinName(from symbol: String) -> String {
        if let idx = symbol.firstIndex(of: ":") {
            return String(symbol[symbol.index(after: idx)...])
        }
        return symbol
    }

    func dexName(from symbol: String) -> String? {
        guard let idx = symbol.firstIndex(of: ":") else { return nil }
        return String(symbol[..<idx])
    }

    // MARK: - HIP-4 Outcome Markets (testnet)

    private let testnetInfoURL = URL(string: "https://api.hyperliquid-testnet.xyz/info")!

    /// Fetches outcome metadata (predictions + options) from testnet.
    /// Returns parsed OutcomeMetaResponse with all outcomes and questions.
    func fetchOutcomeMeta() async throws -> OutcomeMetaResponse {
        let data = try await post(url: testnetInfoURL, body: ["type": "outcomeMeta"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError("outcomeMeta")
        }

        // Parse outcomes
        var outcomes: [OutcomeMetaResponse.OutcomeEntry] = []
        if let outcomesArr = json["outcomes"] as? [[String: Any]] {
            for o in outcomesArr {
                guard let outcomeId = o["outcome"] as? Int,
                      let name = o["name"] as? String
                else { continue }
                let desc = o["description"] as? String ?? ""
                var sideSpecs: [(name: String, index: Int)] = []
                if let sides = o["sideSpecs"] as? [[String: Any]] {
                    for (i, side) in sides.enumerated() {
                        let sideName = side["name"] as? String ?? (i == 0 ? "Yes" : "No")
                        sideSpecs.append((name: sideName, index: i))
                    }
                }
                outcomes.append(.init(outcomeId: outcomeId, name: name,
                                      description: desc, sideSpecs: sideSpecs))
            }
        }

        // Parse questions
        var questions: [OutcomeMetaResponse.QuestionEntry] = []
        if let questionsArr = json["questions"] as? [[String: Any]] {
            for q in questionsArr {
                guard let qId = q["question"] as? Int,
                      let name = q["name"] as? String
                else { continue }
                questions.append(.init(
                    questionId: qId,
                    name: name,
                    description: q["description"] as? String ?? "",
                    fallbackOutcome: q["fallbackOutcome"] as? Int,
                    namedOutcomes: q["namedOutcomes"] as? [Int] ?? [],
                    settledNamedOutcomes: q["settledNamedOutcomes"] as? [Int] ?? []
                ))
            }
        }

        print("📊 HIP-4: \(outcomes.count) outcomes, \(questions.count) questions")
        return OutcomeMetaResponse(outcomes: outcomes, questions: questions)
    }

    /// Fetch user's outcome positions from testnet clearinghouse.
    func fetchOutcomeUserState(address: String) async throws -> [String: Any] {
        let data = try await post(url: testnetInfoURL, body: ["type": "clearinghouseState", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Fetch candles for an outcome coin from testnet.
    func fetchOutcomeCandles(coin: String, interval: ChartInterval, limit: Int? = nil) async throws -> [Candle] {
        let count   = limit ?? interval.defaultCount
        let endMs   = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = endMs - Int64(interval.durationSeconds) * Int64(count) * 1000
        let req: [String: Any] = [
            "coin":      coin,
            "interval":  interval.rawValue,
            "startTime": startMs,
            "endTime":   endMs
        ]
        let data = try await post(url: testnetInfoURL, body: ["type": "candleSnapshot", "req": req])
        return (try? JSONDecoder().decode([Candle].self, from: data)) ?? []
    }

    /// Fetch recent trades for an outcome coin from testnet.
    /// Coin format: "#<encoding>" e.g. "#10" for outcomeId=1, sideIndex=0
    func fetchOutcomeRecentTrades(coin: String) async throws -> [Trade] {
        let data = try await post(url: testnetInfoURL, body: ["type": "recentTrades", "coin": coin])
        return (try? JSONDecoder().decode([Trade].self, from: data)) ?? []
    }

    /// Fetch L2 order book for an outcome coin from testnet.
    func fetchOutcomeOrderBook(coin: String) async throws -> OrderBook {
        let data = try await post(url: testnetInfoURL, body: ["type": "l2Book", "coin": coin])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLevels = json["levels"] as? [Any],
              rawLevels.count >= 2
        else { throw APIError.parseError("l2Book testnet") }

        func parseSide(_ raw: Any) -> [OrderBookLevel] {
            if let rows = raw as? [[Any]] {
                return rows.compactMap { row -> OrderBookLevel? in
                    guard row.count >= 2 else { return nil }
                    let px: String, sz: String
                    if let p = row[0] as? String, let s = row[1] as? String { px = p; sz = s }
                    else if let p = row[0] as? Double, let s = row[1] as? Double { px = String(p); sz = String(s) }
                    else { return nil }
                    let n = row.count > 2 ? (row[2] as? Int ?? 1) : 1
                    return OrderBookLevel(px: px, sz: sz, n: n)
                }
            }
            if let dicts = raw as? [[String: Any]],
               let sideData = try? JSONSerialization.data(withJSONObject: dicts) {
                return (try? JSONDecoder().decode([OrderBookLevel].self, from: sideData)) ?? []
            }
            return []
        }

        let bids = parseSide(rawLevels[0])
        let asks = parseSide(rawLevels[1])
        return OrderBook(coin: coin, bids: bids, asks: asks)
    }

    /// Fetches mid prices for outcome coins from testnet.
    /// Returns dict of "#<encoding>" → price (0–1).
    func fetchOutcomePrices() async throws -> [String: Double] {
        let data = try await post(url: testnetInfoURL, body: ["type": "allMids"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError("allMids testnet")
        }

        var prices: [String: Double] = [:]
        for (coin, val) in json {
            guard coin.hasPrefix("#") else { continue }
            if let str = val as? String, let price = Double(str) {
                prices[coin] = price
            } else if let price = val as? Double {
                prices[coin] = price
            }
        }
        print("📊 HIP-4 prices: \(prices.count) outcome coins")
        return prices
    }
}
