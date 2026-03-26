import Foundation
import Combine

// MARK: - Message types

private struct WSOutbound: Encodable {
    let method: String
    let subscription: [String: String]
}

// MARK: - Manager

@MainActor
final class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()

    /// Posted after WebSocket reconnects and all subscriptions are restored.
    /// Listeners should use this to reconcile stale data (refetch order book snapshot, fill candle gaps, etc.)
    static let didReconnect = Notification.Name("WebSocketManager.didReconnect")

    /// Throttle balance persistence to disk (every 30s max)
    private static var lastBalancePersist: Date = .distantPast

    /// Cached JSON encoder to avoid repeated allocation (HIGH-02)
    private static let jsonEncoder = JSONEncoder()

    @Published private(set) var isConnected = false

    /// Timestamp of last l2Book WebSocket message (used for health-check fallback)
    private(set) var lastL2BookMessageTime: Date = .distantPast

    /// Cached latest allMids prices — updated every ~2s via WebSocket
    private(set) var latestMidPrices: [String: Double] = [:]

    // Public callbacks
    var onAllMids:    (([String: String]) -> Void)?
    var onCandle:     ((Candle) -> Void)?
    var onTrades:     (([Trade]) -> Void)?
    var onOrderBook:  ((OrderBook, String) -> Void)?
    var onSpotBalance: (([[String: Any]]) -> Void)?  // spot clearinghouse balances via webData2

    // Combine publishers — multiple subscribers can observe without overwriting each other
    let tradePublisher   = PassthroughSubject<[Trade], Never>()
    let allMidsPublisher = PassthroughSubject<[String: String], Never>()
    let candlePublisher  = PassthroughSubject<Candle, Never>()

    private var task: URLSessionWebSocketTask?
    private var pingTimer: AnyCancellable?
    private var activeSubs: Set<String> = []
    private let wsURL = URL(string: "wss://api.hyperliquid.xyz/ws")!

    private init() {}

    // MARK: - Connect / disconnect

    func connect() {
        guard task == nil else { return }
        let t = URLSession.shared.webSocketTask(with: wsURL)
        task = t
        t.resume()
        isConnected = true
        resetBackoff()
        receive(task: t)
        startPing()
    }

    func disconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        activeSubs.removeAll()
    }

    // MARK: - Subscriptions

    func subscribeAllMids() {
        let key = "allMids"
        guard !activeSubs.contains(key) else { return }
        activeSubs.insert(key)
        send(method: "subscribe", sub: ["type": "allMids"], subKey: key)
    }

    func subscribeCandles(coin: String, interval: ChartInterval) {
        let key = "candle:\(coin):\(interval.rawValue)"
        guard !activeSubs.contains(key) else { return }
        activeSubs.insert(key)
        send(method: "subscribe", sub: ["type": "candle", "coin": coin, "interval": interval.rawValue], subKey: key)
    }

    func unsubscribeCandles(coin: String, interval: ChartInterval) {
        let key = "candle:\(coin):\(interval.rawValue)"
        activeSubs.remove(key)
        send(method: "unsubscribe", sub: ["type": "candle", "coin": coin, "interval": interval.rawValue])
    }

    func subscribeTrades(coin: String) {
        let key = "trades:\(coin)"
        guard !activeSubs.contains(key) else { return }
        activeSubs.insert(key)
        send(method: "subscribe", sub: ["type": "trades", "coin": coin], subKey: key)
    }

    func subscribeWebData2(address: String) {
        let key = "webData2:\(address)"
        guard !activeSubs.contains(key) else { return }
        activeSubs.insert(key)
        print("[WS] Subscribing to webData2 for \(String(address.prefix(10)))...")
        sendDict(method: "subscribe", sub: ["type": "webData2", "user": address], subKey: key)
    }

    func unsubscribeWebData2(address: String) {
        let key = "webData2:\(address)"
        activeSubs.remove(key)
        sendDict(method: "unsubscribe", sub: ["type": "webData2", "user": address])
    }

    func subscribeOrderBook(coin: String, nSigFigs: Int = 5) {
        // coin includes dex prefix for HIP-3 (e.g. "xyz:SP500"), so key is unique
        let key = "l2Book:\(coin):\(nSigFigs)"
        guard !activeSubs.contains(key) else { return }
        activeSubs.insert(key)
        var sub: [String: Any] = ["type": "l2Book", "coin": coin]
        if nSigFigs != 5 { sub["nSigFigs"] = nSigFigs }
        sendDict(method: "subscribe", sub: sub, subKey: key)
    }

    func unsubscribeOrderBook(coin: String, nSigFigs: Int = 5) {
        let key = "l2Book:\(coin):\(nSigFigs)"
        activeSubs.remove(key)
        var sub: [String: Any] = ["type": "l2Book", "coin": coin]
        if nSigFigs != 5 { sub["nSigFigs"] = nSigFigs }
        sendDict(method: "unsubscribe", sub: sub)
    }

    // MARK: - Private

    private func send(method: String, sub: [String: String], subKey: String? = nil) {
        guard let task else { return }
        guard let data = try? Self.jsonEncoder.encode(WSOutbound(method: method, subscription: sub)),
              let str  = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] error in
            if let error = error {
                print("[WS] Send failed for \(sub): \(error.localizedDescription)")
                if let subKey = subKey {
                    Task { @MainActor [weak self] in
                        self?.activeSubs.remove(subKey)
                    }
                }
            }
        }
    }

    // Sends a subscription message whose fields may include non-string values (e.g. nSigFigs: Int).
    private func sendDict(method: String, sub: [String: Any], subKey: String? = nil) {
        guard let task else { return }
        let msg: [String: Any] = ["method": method, "subscription": sub]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str  = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] error in
            if let error = error {
                print("[WS] Send failed for \(sub): \(error.localizedDescription)")
                if let subKey = subKey {
                    Task { @MainActor [weak self] in
                        self?.activeSubs.remove(subKey)
                    }
                }
            }
        }
    }

    private nonisolated func receive(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(let msg):
                // handleMessage dispatches to main internally
                self?.handleMessage(msg)
                self?.receive(task: task)
            case .failure:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isConnected = false
                    self.pingTimer?.cancel()
                    self.pingTimer = nil
                    let subsToRestore = self.activeSubs
                    self.activeSubs.removeAll()
                    self.task = nil
                    self.scheduleReconnect(restoring: subsToRestore)
                }
            }
        }
    }

    private nonisolated func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        var str: String?
        switch msg {
        case .string(let s): str = s
        case .data(let d):   str = String(data: d, encoding: .utf8)
        @unknown default: return
        }

        guard let str,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = json["channel"] as? String
        else { return }

        let msgData = json["data"]

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch channel {

            case "allMids":
                if let inner = (msgData as? [String: Any])?["mids"] as? [String: String] {
                    // Cache prices for use by WalletManager (no extra REST call needed)
                    var prices: [String: Double] = [:]
                    for (coin, priceStr) in inner {
                        if let p = Double(priceStr) { prices[coin] = p }
                    }
                    self.latestMidPrices = prices
                    self.onAllMids?(inner)
                    self.allMidsPublisher.send(inner)
                }

            case "webData2":
                if let dataDict = msgData as? [String: Any] {
                    var perpVal: Double?
                    var spotVal: Double?
                    var withdrawable: Double?

                    // 1. Parse perp accountValue + withdrawable + positions
                    if let chState = dataDict["clearinghouseState"] as? [String: Any] {
                        if let margin = chState["marginSummary"] as? [String: Any],
                           let avStr = margin["accountValue"] as? String,
                           let av = Double(avStr) {
                            perpVal = av
                        }
                        if let wStr = chState["withdrawable"] as? String,
                           let w = Double(wStr) {
                            withdrawable = w
                        }
                        // Parse active positions
                        if let assetPositions = chState["assetPositions"] as? [[String: Any]] {
                            let parsed: [PerpPosition] = assetPositions.compactMap { wrapper in
                                guard let pos = wrapper["position"] as? [String: Any],
                                      let coin = pos["coin"] as? String,
                                      let sziStr = pos["szi"] as? String,
                                      let szi = Double(sziStr), szi != 0,
                                      let entryStr = pos["entryPx"] as? String,
                                      let entry = Double(entryStr)
                                else { return nil }
                                let posValue = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
                                let pnl = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
                                let liqPx = (pos["liquidationPx"] as? String).flatMap(Double.init)
                                let levVal = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
                                let isCross = ((pos["leverage"] as? [String: Any])?["type"] as? String ?? "cross") == "cross"
                                let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0
                                let funding = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String
                                let cumulFunding = funding.flatMap(Double.init) ?? 0
                                return PerpPosition(
                                    coin: coin, size: szi, entryPrice: entry,
                                    markPrice: posValue / max(abs(szi), 0.000001),
                                    unrealizedPnl: pnl, leverage: levVal, isCross: isCross,
                                    marginUsed: marginUsed,
                                    liquidationPx: liqPx, cumulativeFunding: cumulFunding,
                                    szDecimals: MarketsViewModel.szDecimals(for: coin)
                                )
                            }
                            WalletManager.shared.mainDexPositions = parsed
                            WalletManager.shared.mergePositions()
                        }
                    }

                    // 2. Parse spot balances (user holdings with entryNtl)
                    if let spotState = dataDict["spotState"] as? [String: Any],
                       let balances = spotState["balances"] as? [[String: Any]] {
                        var total: Double = 0
                        for b in balances {
                            if let entryNtlStr = b["entryNtl"] as? String,
                               let entryNtl = Double(entryNtlStr), entryNtl > 0 {
                                total += entryNtl
                            }
                        }
                        spotVal = total
                        if !balances.isEmpty {
                            self.onSpotBalance?(balances)
                        }
                    }

                    // 3. Update WalletManager in real-time
                    if perpVal != nil || spotVal != nil || withdrawable != nil {
                        let wallet = WalletManager.shared
                        if let pv = perpVal { wallet.perpValue = pv }
                        if let sv = spotVal { wallet.spotValue = sv }
                        if let w = withdrawable { wallet.perpWithdrawable = w }
                        wallet.accountValue = wallet.perpValue + wallet.spotValue
                        // Throttle disk writes: only persist every 30s (not every 2s WebSocket tick)
                        let now = Date()
                        if now.timeIntervalSince(Self.lastBalancePersist) > 30 {
                            Self.lastBalancePersist = now
                            let perpValue = wallet.perpValue
                            let spotValue = wallet.spotValue
                            let accountValue = wallet.accountValue
                            DispatchQueue.global(qos: .utility).async {
                                UserDefaults.standard.set(perpValue, forKey: "cached_perpValue")
                                UserDefaults.standard.set(spotValue, forKey: "cached_spotValue")
                                UserDefaults.standard.set(accountValue, forKey: "cached_accountValue")
                            }
                        }
                    }
                }

            case "candle":
                if let candleDict = msgData as? [String: Any],
                   let candleData = try? JSONSerialization.data(withJSONObject: candleDict),
                   let candle = try? JSONDecoder().decode(Candle.self, from: candleData) {
                    #if DEBUG
                    print("🕯 WS candle → s=\(candle.s) i=\(candle.i) c=\(candle.c)")
                    #endif
                    self.onCandle?(candle)
                    self.candlePublisher.send(candle)
                } else {
                    #if DEBUG
                    print("⚠️ WS candle → failed to decode: \(String(describing: msgData))")
                    #endif
                }

            case "trades":
                if let arr = msgData as? [[String: Any]],
                   let tData = try? JSONSerialization.data(withJSONObject: arr),
                   let trades = try? JSONDecoder().decode([Trade].self, from: tData) {
                    self.onTrades?(trades)
                    self.tradePublisher.send(trades)
                }

            case "l2Book":
                if let bookDict = msgData as? [String: Any],
                   let coinRaw = bookDict["coin"] as? String,
                   let levels = bookDict["levels"] as? [[[String: Any]]],
                   levels.count >= 2,
                   let bData = try? JSONSerialization.data(withJSONObject: levels[0]),
                   let aData = try? JSONSerialization.data(withJSONObject: levels[1]),
                   let bids  = try? JSONDecoder().decode([OrderBookLevel].self, from: bData),
                   let asks  = try? JSONDecoder().decode([OrderBookLevel].self, from: aData) {
                    // Normalize: strip "@dex" suffix from HIP-3 responses (e.g. "CL@xyz" → "CL")
                    // but keep "@" prefix for spot coins (e.g. "@107" stays "@107").
                    let coin: String
                    if let atIdx = coinRaw.firstIndex(of: "@"), atIdx != coinRaw.startIndex {
                        coin = String(coinRaw[..<atIdx])
                    } else {
                        coin = coinRaw
                    }
                    self.lastL2BookMessageTime = Date()
                    self.onOrderBook?(OrderBook(coin: coin, bids: bids, asks: asks), coin)
                } else {
                    #if DEBUG
                    print("⚠️ WS l2Book → failed to decode")
                    #endif
                }

            default:
                break // subscriptionResponse, etc. — ignore silently
            }
        }
    }

    private func startPing() {
        pingTimer = Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
    }

    /// Reconnect attempt counter for exponential backoff
    private var reconnectAttempt = 0

    private func scheduleReconnect(restoring subs: Set<String> = []) {
        reconnectAttempt += 1
        // Exponential backoff: 2s, 4s, 8s, 16s max
        let delay = min(UInt64(pow(2.0, Double(reconnectAttempt))) * 1_000_000_000, 16_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            self.connect()
            if !subs.isEmpty {
                // Wait 1s for connection to stabilize, then batch-restore all subscriptions
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for key in subs {
                    self.restoreSubscription(key)
                }
                // Notify listeners so they can reconcile stale data
                NotificationCenter.default.post(name: Self.didReconnect, object: nil)
            }
        }
    }

    /// Reset backoff counter on successful connection
    private func resetBackoff() {
        reconnectAttempt = 0
    }

    /// Re-sends a subscription from its stored key string (e.g. "candle:BTC:1h", "trades:ETH").
    private func restoreSubscription(_ key: String) {
        let parts = key.split(separator: ":").map(String.init)
        guard let type = parts.first else { return }
        switch type {
        case "candle" where parts.count == 3:
            let sub = ["type": "candle", "coin": parts[1], "interval": parts[2]]
            activeSubs.insert(key)
            send(method: "subscribe", sub: sub, subKey: key)
        case "trades" where parts.count == 2:
            let sub = ["type": "trades", "coin": parts[1]]
            activeSubs.insert(key)
            send(method: "subscribe", sub: sub, subKey: key)
        case "l2Book" where parts.count >= 2:
            // parts[1] may be "BTC" (main DEX), "SILVER@dex" (HIP-3), or "@107" (spot).
            let coinPart = parts[1]
            let coin: String
            var dex: String? = nil
            if let atIdx = coinPart.firstIndex(of: "@"), atIdx != coinPart.startIndex {
                // HIP-3: "SILVER@dex" → coin="SILVER", dex="dex"
                coin = String(coinPart[..<atIdx])
                dex  = String(coinPart[coinPart.index(after: atIdx)...])
            } else {
                // Main DEX ("BTC") or spot ("@107")
                coin = coinPart
            }
            let nSigFigs = parts.count >= 3 ? Int(parts[2]) ?? 5 : 5
            var sub: [String: Any] = ["type": "l2Book", "coin": coin]
            if let dex { sub["dex"] = dex }
            if nSigFigs != 5 { sub["nSigFigs"] = nSigFigs }
            activeSubs.insert(key)
            sendDict(method: "subscribe", sub: sub, subKey: key)
        case "allMids":
            activeSubs.insert(key)
            send(method: "subscribe", sub: ["type": "allMids"], subKey: key)
        default:
            break
        }
    }
}
