import SwiftUI
import Combine

// MARK: - Order enums

enum TradingOrderType: String, CaseIterable, Identifiable {
    case market = "Market"
    case limit  = "Limit"
    case twap   = "TWAP"
    var id: String { rawValue }
}

enum TradingOrderSide: String, CaseIterable {
    case buy  = "Buy"
    case sell = "Sell"
}

// MARK: - TradingViewModel

@MainActor
final class TradingViewModel: ObservableObject {

    // MARK: - Form state
    @Published var orderType: TradingOrderType = .market
    @Published var side:      TradingOrderSide = .buy

    @Published var sizeUSD:     String = ""
    @Published var limitPrice:  String = ""
    @Published var leverage:    Double = 10
    @Published var isCross:     Bool   = true   // true = cross margin (HL default)

    @Published var tpEnabled  = false
    @Published var slEnabled  = false
    @Published var tpPrice:   String = ""
    @Published var slPrice:   String = ""
    @Published var reduceOnly = false

    // MARK: - Status
    @Published var isSubmitting      = false
    @Published var statusMessage:   String?
    @Published var lastOrderResult: String?
    @Published var showSuccess      = false

    @Published var errorMessage: String? {
        didSet {
            if errorMessage != nil {
                errorDismissTask?.cancel()
                errorDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled { errorMessage = nil }
                }
            }
        }
    }
    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Market context (set by parent view)
    var selectedSymbol: String = "BTC" {
        didSet { updateLimitPricePlaceholder() }
    }
    var currentPrice: Double = 0 {
        didSet { updateLimitPricePlaceholder() }
    }
    var availableMargin: Double = 0

    // MARK: - Market context (set by TradeTabView)
    var displayCoinName: String = ""   // Human-readable coin name (e.g. "HYPE", "SOL", "BTC")
    var isSpotMarket: Bool = false
    var assetIndex: Int = 0           // index in HL universe for order signing
    var szDecimals: Int = 4           // size decimal precision for order wire format
    var sizeIsToken: Bool = false     // true = sizeUSD contains token amount, not USD
    /// Exact token amount for spot sells (set by % buttons to avoid USD→token round-trip precision loss)
    var spotSellTokenOverride: Double?

    // MARK: - TWAP settings
    @Published var twapDuration: Int = 0        // minutes (5-1440), 0 = not set yet
    @Published var twapRandomize: Bool = false    // disabled on mobile for simplicity

    // MARK: - Slippage (synced from Settings)
    @AppStorage("hl_slippage") var slippagePct: Double = 0.1

    // MARK: - Computed

    var sizeUSDValue:    Double { Double(stripCommas(sizeUSD))    ?? 0 }
    var limitPriceValue: Double {
        // Handle both "." and "," decimal separators (French locale keyboards use comma)
        let cleaned = limitPrice.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned) ?? currentPrice
    }
    var tpPriceValue:    Double { Double(tpPrice)    ?? 0 }
    var slPriceValue:    Double { Double(slPrice)    ?? 0 }

    var entryPrice: Double {
        orderType == .market ? currentPrice : limitPriceValue
    }

    var positionSize: Double {
        // Use exact token override for spot sells (avoids USD→token round-trip precision loss)
        if let override = spotSellTokenOverride, isSpotMarket, side == .sell {
            return override
        }
        guard entryPrice > 0 else { return 0 }
        if sizeIsToken {
            return sizeUSDValue  // Already in token units
        }
        // Size USD = notional value directly. Leverage only affects margin required, not trade size.
        return sizeUSDValue / entryPrice
    }

    var notionalValue:  Double { positionSize * entryPrice }
    var builderFeeAmt:  Double { notionalValue * 0.00005 }  // 0.005%
    var takerFeeRate:   Double { 0.00035 }    // 0.035%
    var makerFeeRate:   Double { -0.0001  }   // rebate –0.010%

    var feeAmt: Double {
        let rate = orderType == .market ? takerFeeRate : makerFeeRate
        return notionalValue * abs(rate)
    }

    var totalFee: Double { feeAmt + builderFeeAmt }

    var feeLabel: String {
        orderType == .market
            ? "Fee (taker 0.035% + builder 0.005%)"
            : "Fee (maker –0.010% + builder 0.005%)"
    }

    /// Warn if limit order would cross the spread (i.e., instant fill = taker)
    var limitCrossesSpread: Bool {
        guard orderType == .limit, currentPrice > 0 else { return false }
        let p = limitPriceValue
        return (side == .buy && p >= currentPrice) || (side == .sell && p <= currentPrice)
    }

    var canSubmit: Bool {
        sizeUSDValue > 0
            && (orderType == .market || limitPriceValue > 0)
            && WalletManager.shared.connectedWallet != nil
            && !isSubmitting
    }

    var submitLabel: String {
        if WalletManager.shared.connectedWallet == nil { return "Connect Wallet" }
        return "\(side.rawValue) \(selectedSymbol)"
    }

    // MARK: - Actions

    func setMaxSize() {
        sizeUSD = formatDecimalWithCommas(String(format: "%.2f", availableMargin))
    }

    func updateCurrentPrice(_ price: Double) {
        currentPrice = price
    }

    func updateAvailableMargin(_ margin: Double) {
        availableMargin = margin
    }

    /// Sync the trading symbol with the currently displayed chart
    func syncSymbol(from chartVM: ChartViewModel) {
        // The TradingView already reads chartVM.selectedSymbol,
        // so this just ensures the form is ready
    }

    /// Send updateLeverage to Hyperliquid (changes leverage + margin mode per asset).
    /// Called when user confirms leverage/margin changes in the picker.
    func updateLeverage() async -> Bool {
        do {
            let vault = WalletManager.shared.activeVaultAddress
            #if DEBUG
            print("[LEVERAGE] Sending: asset=\(assetIndex) isCross=\(isCross) leverage=\(Int(leverage)) vault=\(vault ?? "none")")
            #endif
            let payload = try await TransactionSigner.signUpdateLeverage(
                asset: assetIndex,
                isCross: isCross,
                leverage: Int(leverage)
            )
            let result = try await TransactionSigner.postAction(payload)
            #if DEBUG
            print("[LEVERAGE] Result: \(result)")
            #endif
            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                await MainActor.run { errorMessage = "Leverage: \(errMsg)" }
                return false
            }
            #if DEBUG
            print("[LEVERAGE] Updated asset=\(assetIndex) isCross=\(isCross) leverage=\(Int(leverage))")
            #endif
            return true
        } catch {
            #if DEBUG
            print("[LEVERAGE] Error: \(error)")
            #endif
            await MainActor.run { errorMessage = "Leverage: \(error.localizedDescription)" }
            return false
        }
    }

    /// Sign and submit an order to Hyperliquid via local private key + Face ID.
    func submitOrder() async {
        guard canSubmit else {
            if WalletManager.shared.connectedWallet == nil {
                errorMessage = "Connect a wallet to trade"
            }
            return
        }

        isSubmitting = true
        errorMessage = nil

        // Sync leverage + margin mode with HL before placing the order (perps only)
        if !isSpotMarket {
            statusMessage = "Syncing leverage…"
            do {
                let levPayload = try await TransactionSigner.signUpdateLeverage(
                    asset: assetIndex,
                    isCross: isCross,
                    leverage: Int(leverage)
                )
                let levResult = try await TransactionSigner.postAction(levPayload)
                if let status = levResult["status"] as? String, status == "err",
                   let errMsg = levResult["response"] as? String {
                    errorMessage = "Leverage sync failed: \(errMsg)"
                    isSubmitting = false
                    return
                }
            } catch {
                errorMessage = "Leverage sync failed: \(error.localizedDescription)"
                isSubmitting = false
                return
            }
        }

        statusMessage = "Signing order…"

        do {
            let isBuy = side == .buy
            // Round size to szDecimals to match exchange requirements
            let rawSz = positionSize
            let factor = pow(10.0, Double(szDecimals))
            let sz = floor(rawSz * factor) / factor
            guard sz > 0 else {
                errorMessage = "Invalid size"
                isSubmitting = false
                return
            }

            // TWAP orders use a different signing path
            if orderType == .twap {
                let payload = try await TransactionSigner.signTwapOrder(
                    assetIndex: assetIndex,
                    isBuy: isBuy,
                    size: sz,
                    reduceOnly: reduceOnly,
                    durationMinutes: twapDuration,
                    randomize: twapRandomize,
                    szDecimals: szDecimals
                )
                let result = try await TransactionSigner.postAction(payload)
                parseTwapResponse(result)
                isSubmitting = false
                return
            }

            // Determine limit price with slippage for market orders
            let effectivePrice: Double
            if orderType == .market {
                let slip = slippagePct / 100.0
                effectivePrice = isBuy
                    ? currentPrice * (1 + slip)
                    : currentPrice * (1 - slip)
            } else {
                effectivePrice = limitPriceValue
            }

            #if DEBUG
            print("[ORDER] type=\(orderType) price=\(effectivePrice) size=\(sz) asset=\(assetIndex) szDec=\(szDecimals) isSpot=\(isSpotMarket)")
            #endif

            // Order type wire format
            let orderTypeWire: [String: Any]
            if orderType == .market {
                orderTypeWire = ["limit": ["tif": "Ioc"]]
            } else {
                orderTypeWire = ["limit": ["tif": "Gtc"]]
            }

            let payload = try await TransactionSigner.signOrder(
                assetIndex: assetIndex,
                isBuy: isBuy,
                limitPrice: effectivePrice,
                size: sz,
                reduceOnly: reduceOnly,
                orderType: orderTypeWire,
                szDecimals: szDecimals
            )

            let result = try await TransactionSigner.postAction(payload)

            // Parse response — HL returns {"status":"ok/err", "response": ...}
            // IMPORTANT: status "ok" means the REQUEST was accepted, NOT that the order filled.
            // The actual per-order result is in response.data.statuses[]
            let coinName = displayCoinName.isEmpty
                ? (selectedSymbol.components(separatedBy: "/").first ?? selectedSymbol)
                : displayCoinName

            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                // Top-level error (bad signature, user doesn't exist, etc.)
                errorMessage = errMsg
                HapticsManager.notification(.error)
            } else if let response = result["response"] as? [String: Any] {
                // Try to extract per-order statuses
                let data = (response["data"] ?? response["payload"]) as? [String: Any]
                let statuses = data?["statuses"] as? [Any]
                let first = statuses?.first

                #if DEBUG
                print("[ORDER] response type=\(response["type"] ?? "nil") statuses=\(String(describing: statuses))")
                #endif

                if let firstDict = first as? [String: Any], let filled = firstDict["filled"] as? [String: Any] {
                    let fillPx = filled["avgPx"] as? String ?? ""
                    let totalSz = filled["totalSz"] as? String ?? ""
                    lastOrderResult = "\(side.rawValue.uppercased()) \(totalSz) \(coinName) @ $\(fillPx)"
                    showSuccess = true
                    sizeUSD = ""
                    HapticsManager.notification(.success)
                } else if let firstDict = first as? [String: Any], let resting = firstDict["resting"] as? [String: Any] {
                    let restPx = resting["px"] as? String ?? limitPrice
                    let restSz = resting["sz"] as? String ?? String(format: "%.6f", positionSize)
                    lastOrderResult = "Limit \(side.rawValue.uppercased()) \(restSz) \(coinName) @ $\(restPx)"
                    showSuccess = true
                    sizeUSD = ""
                    HapticsManager.notification(.success)
                } else if let firstDict = first as? [String: Any], let error = firstDict["error"] as? String {
                    errorMessage = error
                    HapticsManager.notification(.error)
                } else if let firstStr = first as? String {
                    // HL sometimes returns status as a plain string like "success"
                    if firstStr.lowercased().contains("success") {
                        lastOrderResult = "Order placed \(coinName)"
                        showSuccess = true
                        sizeUSD = ""
                        HapticsManager.notification(.success)
                    } else {
                        errorMessage = firstStr
                        HapticsManager.notification(.error)
                    }
                } else {
                    // Unknown status format — show raw for debugging
                    let raw = String(describing: first ?? "nil")
                    #if DEBUG
                    print("[ORDER] Unknown order status: \(raw)")
                    #endif
                    errorMessage = "Order status: \(raw.prefix(200))"
                    HapticsManager.notification(.error)
                }
                statusMessage = nil
            } else if let status = result["status"] as? String, status == "ok" {
                // status ok but no statuses — shouldn't happen, but handle gracefully
                let desc = "\(side.rawValue.uppercased()) \(String(format: "%.4f", sz)) \(coinName)"
                lastOrderResult = desc
                statusMessage = nil
                showSuccess = true
                sizeUSD = ""
                HapticsManager.notification(.success)
            } else if let error = result["error"] as? String {
                errorMessage = error
                HapticsManager.notification(.error)
            } else {
                // Completely unknown response — show raw for debugging
                let raw = result.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                #if DEBUG
                print("[ORDER] Unexpected response: \(raw)")
                #endif
                errorMessage = "Unexpected: \(raw.prefix(200))"
                HapticsManager.notification(.error)
            }
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            HapticsManager.notification(.error)
        }

        // Force immediate position refresh after successful order
        if showSuccess {
            if assetIndex >= 100000 {
                WalletManager.shared.refreshHIP3PositionsNow()
            } else {
                WalletManager.shared.refreshMainPositionsNow()
            }
        }

        isSubmitting = false
    }

    private func parseTwapResponse(_ result: [String: Any]) {
        let coinName = selectedSymbol.components(separatedBy: "/").first ?? selectedSymbol

        if let status = result["status"] as? String, status == "err",
           let errMsg = result["response"] as? String {
            errorMessage = errMsg
            HapticsManager.notification(.error)
        } else if let response = result["response"] as? [String: Any],
                  let data = response["data"] as? [String: Any],
                  let statusDict = data["status"] as? [String: Any] {
            if let running = statusDict["running"] as? [String: Any],
               let twapId = running["twapId"] {
                lastOrderResult = "TWAP \(side.rawValue) \(coinName) started (#\(twapId))"
                showSuccess = true
                sizeUSD = ""
                HapticsManager.notification(.success)
            } else if let error = statusDict["error"] as? String {
                errorMessage = error
                HapticsManager.notification(.error)
            } else {
                lastOrderResult = "TWAP \(coinName) submitted"
                showSuccess = true
                sizeUSD = ""
                HapticsManager.notification(.success)
            }
        } else {
            let raw = result.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            errorMessage = "Unexpected: \(raw.prefix(200))"
            HapticsManager.notification(.error)
        }
        statusMessage = nil
    }

    private func updateLimitPricePlaceholder() {
        if limitPrice.isEmpty && currentPrice > 0 {
            // Don't auto-fill, just ensure the placeholder shows current price
        }
    }

    // MARK: - Bottom tabs data

    enum BottomTab: String, CaseIterable {
        case balances       = "Balances"
        case positions      = "Positions"
        case predictions    = "Predictions"
        case openOrders     = "Open Orders"
        case options        = "Options"
        case twap           = "TWAP"
        case tradeHistory   = "Trade History"
        case fundingHistory = "Funding"
        case orderHistory   = "Order History"
    }

    @Published var bottomTab: BottomTab = .balances
    @Published var openOrders: [HLOpenOrder] = []
    @Published var orderHistory: [[String: Any]] = []
    @Published var tradeHistory: [HLFill] = []
    @Published var fundingHistory: [HLFunding] = []
    @Published var activeTwaps: [HLTwapOrder] = []
    @Published var predictionPositions: [OutcomePosition] = []
    @Published var optionPositions: [OutcomePosition] = []
    @Published var isLoadingBottom = false
    @Published var isCancelling: Int64? = nil  // oid being cancelled
    @Published var isCancellingTwap: Int64? = nil

    /// Throttle: minimum 2s between bottom tab fetches to avoid API spam
    private var lastBottomTabFetch: Date = .distantPast

    func fetchBottomTabData() async {
        let now = Date()
        guard now.timeIntervalSince(lastBottomTabFetch) > 2.0 else { return }
        lastBottomTabFetch = now
        guard let addr = WalletManager.shared.connectedWallet?.address else { return }
        isLoadingBottom = true
        defer { isLoadingBottom = false }

        switch bottomTab {
        case .openOrders:
            await fetchOpenOrders(addr)
        case .predictions:
            await fetchOutcomePositions(addr, mode: .predictions)
        case .options:
            await fetchOutcomePositions(addr, mode: .options)
        case .twap:
            await fetchActiveTwaps(addr)
        case .tradeHistory:
            await fetchTradeHistory(addr)
        case .orderHistory:
            await fetchOrderHistory(addr)
        case .fundingHistory:
            await fetchFundingHistory(addr)
        default:
            break
        }
    }

    enum OutcomeMode { case predictions, options }

    private func fetchOutcomePositions(_ addr: String, mode: OutcomeMode) async {
        let api = HyperliquidAPI.shared
        do {
            // 1. Get user's clearinghouse state from testnet
            let state = try await api.fetchOutcomeUserState(address: addr)
            guard let assetPositions = state["assetPositions"] as? [[String: Any]] else { return }

            // 2. Get outcome metadata for name resolution
            let meta = try await api.fetchOutcomeMeta()

            // 3. Get current prices
            let prices = try await api.fetchOutcomePrices()

            // Build lookup: outcomeId -> (name, description, sideSpecs)
            var outcomeLookup: [Int: (name: String, desc: String, sides: [(name: String, index: Int)])] = [:]
            for o in meta.outcomes {
                outcomeLookup[o.outcomeId] = (o.name, o.description, o.sideSpecs)
            }

            // Build lookup: outcomeId -> questionName
            var questionLookup: [Int: String] = [:]
            for q in meta.questions {
                for oId in q.namedOutcomes {
                    questionLookup[oId] = q.name
                }
            }

            var predictions: [OutcomePosition] = []
            var options: [OutcomePosition] = []

            for ap in assetPositions {
                guard let posDict = ap["position"] as? [String: Any],
                      let coin = posDict["coin"] as? String,
                      coin.hasPrefix("#"),
                      let sziStr = posDict["szi"] as? String,
                      let sz = Double(sziStr), sz != 0,
                      let entryStr = posDict["entryPx"] as? String,
                      let entry = Double(entryStr)
                else { continue }

                let encodingStr = String(coin.dropFirst())
                guard let encoding = Int(encodingStr) else { continue }
                let outcomeId = encoding / 10
                let sideIndex = encoding % 10

                // Resolve name and type
                let info = outcomeLookup[outcomeId]
                let sideName: String
                if let sides = info?.sides, let side = sides.first(where: { $0.index == sideIndex }) {
                    sideName = side.name
                } else {
                    sideName = sideIndex == 0 ? "Yes" : "No"
                }

                let isOption = info?.desc.lowercased().contains("pricebinary") == true
                    || info?.desc.lowercased().contains("option") == true
                let displayName = questionLookup[outcomeId] ?? info?.name ?? "#\(outcomeId)"

                let markPrice = prices[coin] ?? entry
                let pnl = sz * (markPrice - entry)

                let position = OutcomePosition(
                    id: coin,
                    coin: coin,
                    outcomeId: outcomeId,
                    sideIndex: sideIndex,
                    displayName: displayName,
                    sideName: sideName,
                    size: sz,
                    entryPrice: entry,
                    markPrice: markPrice,
                    unrealizedPnl: pnl,
                    isLong: sz > 0
                )

                if isOption {
                    options.append(position)
                } else {
                    predictions.append(position)
                }
            }

            await MainActor.run {
                predictionPositions = predictions
                optionPositions = options
            }
        } catch {
            print("Failed to fetch outcome positions: \(error)")
        }
    }

    private func fetchOrderHistory(_ addr: String) async {
        do {
            let body: [String: Any] = ["type": "historicalOrders", "user": addr]
            let data = try await HyperliquidAPI.shared.post(
                url: URL(string: "https://api.hyperliquid.xyz/info")!,
                body: body
            )
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                await MainActor.run { orderHistory = arr }
            }
        } catch {
            print("[TRADE] fetchOrderHistory error: \(error)")
        }
    }

    /// Refresh open orders without changing the active bottom tab
    func refreshOpenOrdersBackground() async {
        guard let addr = WalletManager.shared.connectedWallet?.address else { return }
        await fetchOpenOrders(addr)
    }

    private func fetchOpenOrders(_ addr: String) async {
        do {
            let body: [String: Any] = ["type": "frontendOpenOrders", "user": addr]
            let data = try await HyperliquidAPI.shared.post(
                url: URL(string: "https://api.hyperliquid.xyz/info")!,
                body: body
            )
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                openOrders = arr.compactMap { HLOpenOrder(dict: $0) }
            }
        } catch {
            print("[TRADE] fetchOpenOrders error: \(error)")
        }
    }

    private func fetchTradeHistory(_ addr: String) async {
        do {
            let body: [String: Any] = ["type": "userFills", "user": addr]
            let data = try await HyperliquidAPI.shared.post(
                url: URL(string: "https://api.hyperliquid.xyz/info")!,
                body: body
            )
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                tradeHistory = arr.prefix(50).compactMap { HLFill(dict: $0) }
            }
        } catch {
            print("[TRADE] fetchTradeHistory error: \(error)")
        }
    }

    private func fetchActiveTwaps(_ addr: String) async {
        do {
            let body: [String: Any] = ["type": "twapHistory", "user": addr]
            let data = try await HyperliquidAPI.shared.post(
                url: URL(string: "https://api.hyperliquid.xyz/info")!,
                body: body
            )
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                activeTwaps = arr.compactMap { HLTwapOrder(dict: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
            }
        } catch {
            print("[TRADE] fetchActiveTwaps error: \(error)")
        }
    }

    /// Cancel an active TWAP order
    func cancelTwap(_ twap: HLTwapOrder, markets: [Market]) async {
        isCancellingTwap = twap.twapId
        defer { isCancellingTwap = nil }

        let assetIdx = resolveAssetIndex(coin: twap.coin, markets: markets)

        do {
            let payload = try await TransactionSigner.signCancelTwap(
                assetIndex: assetIdx,
                twapId: twap.twapId
            )
            let result = try await TransactionSigner.postAction(payload)
            print("[TWAP CANCEL] result: \(result)")

            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                errorMessage = errMsg
                HapticsManager.notification(.error)
            } else {
                activeTwaps.removeAll { $0.twapId == twap.twapId }
                HapticsManager.notification(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticsManager.notification(.error)
        }
    }

    private func fetchFundingHistory(_ addr: String) async {
        do {
            let body: [String: Any] = ["type": "userFunding", "user": addr, "startTime": 0]
            let data = try await HyperliquidAPI.shared.post(
                url: URL(string: "https://api.hyperliquid.xyz/info")!,
                body: body
            )
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                fundingHistory = arr.suffix(50).reversed().compactMap { HLFunding(dict: $0) }
            }
        } catch {
            print("[TRADE] fetchFundingHistory error: \(error)")
        }
    }

    /// Resolve coin name to asset index using MarketsViewModel
    private func resolveAssetIndex(coin: String, markets: [Market]) -> Int {
        // Try exact match first
        if let m = markets.first(where: { $0.asset.name == coin }) { return m.index }
        // Try base name match (e.g. "HYPE/USDC" → market with baseName "HYPE")
        if let m = markets.first(where: { $0.baseName == coin }) { return m.index }
        // Try matching the first part of symbol
        if let m = markets.first(where: { $0.symbol.hasPrefix(coin) }) { return m.index }
        return 0
    }

    /// Cancel an open order by oid
    func cancelOrder(_ order: HLOpenOrder, markets: [Market]) async {
        isCancelling = order.oid
        defer { isCancelling = nil }

        let assetIdx = resolveAssetIndex(coin: order.coin, markets: markets)

        do {
            let payload = try await TransactionSigner.signCancelOrder(
                assetIndex: assetIdx,
                oid: order.oid
            )
            let result = try await TransactionSigner.postAction(payload)
            print("[CANCEL] result: \(result)")

            if let status = result["status"] as? String, status == "err",
               let errMsg = result["response"] as? String {
                errorMessage = errMsg
                HapticsManager.notification(.error)
            } else {
                // Refresh open orders
                openOrders.removeAll { $0.oid == order.oid }
                HapticsManager.notification(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            HapticsManager.notification(.error)
        }
    }
}

// MARK: - HL Data Models for bottom tabs

struct HLOpenOrder: Identifiable {
    let id: Int64
    let oid: Int64
    let coin: String
    let side: String       // "A" or "B"
    let limitPx: String
    let sz: String
    let origSz: String
    let timestamp: Int64
    let orderType: String  // "Limit", "Stop Market", etc.
    let reduceOnly: Bool
    let isTrigger: Bool
    let assetIndex: Int    // derived from coin

    var isBuy: Bool { side == "B" }
    var sideLabel: String { isBuy ? "Buy" : "Sell" }
    var sideColor: String { isBuy ? "green" : "red" }
    var timeStr: String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    init?(dict: [String: Any]) {
        guard let coin = dict["coin"] as? String,
              let side = dict["side"] as? String,
              let limitPx = dict["limitPx"] as? String,
              let sz = dict["sz"] as? String else { return nil }

        self.coin = coin
        self.side = side
        self.limitPx = limitPx
        self.sz = sz
        self.origSz = dict["origSz"] as? String ?? sz
        self.orderType = dict["orderType"] as? String ?? "Limit"
        self.reduceOnly = dict["reduceOnly"] as? Bool ?? false
        self.isTrigger = dict["isTrigger"] as? Bool ?? false

        // oid can be Int or Int64
        if let o = dict["oid"] as? Int64 { self.oid = o }
        else if let o = dict["oid"] as? Int { self.oid = Int64(o) }
        else { return nil }
        self.id = self.oid

        if let t = dict["timestamp"] as? Int64 { self.timestamp = t }
        else if let t = dict["timestamp"] as? Int { self.timestamp = Int64(t) }
        else { self.timestamp = 0 }

        // We don't know the exact asset index from this response — store 0
        // Cancel uses coin name, not index
        self.assetIndex = 0
    }
}

struct HLFill: Identifiable {
    let id: Int64
    let coin: String
    let px: String
    let sz: String
    let side: String
    let time: Int64
    let dir: String
    let closedPnl: String
    let fee: String
    let crossed: Bool

    var isBuy: Bool { side == "B" }
    var timeStr: String {
        let date = Date(timeIntervalSince1970: Double(time) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    init?(dict: [String: Any]) {
        guard let coin = dict["coin"] as? String,
              let px = dict["px"] as? String,
              let sz = dict["sz"] as? String,
              let side = dict["side"] as? String else { return nil }

        self.coin = coin
        self.px = px
        self.sz = sz
        self.side = side
        self.dir = dict["dir"] as? String ?? ""
        self.closedPnl = dict["closedPnl"] as? String ?? "0"
        self.fee = dict["fee"] as? String ?? "0"
        self.crossed = dict["crossed"] as? Bool ?? true

        if let t = dict["time"] as? Int64 { self.time = t }
        else if let t = dict["time"] as? Int { self.time = Int64(t) }
        else { self.time = 0 }

        if let t = dict["tid"] as? Int64 { self.id = t }
        else if let t = dict["tid"] as? Int { self.id = Int64(t) }
        else { self.id = self.time }
    }
}

struct HLTwapOrder: Identifiable {
    let id: Int64
    let twapId: Int64
    let coin: String
    let side: String       // "B" or "A"
    let sz: String
    let filledSz: String
    let status: String     // "running", "completed", "cancelled"
    let timestamp: Int64
    let durationMinutes: Int

    var isBuy: Bool { side == "B" }
    var sideLabel: String { isBuy ? "Buy" : "Sell" }
    var isRunning: Bool { status == "running" }
    var timeStr: String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }
    var progress: String {
        let filled = Double(filledSz) ?? 0
        let total = Double(sz) ?? 1
        guard total > 0 else { return "0%" }
        return String(format: "%.0f%%", (filled / total) * 100)
    }

    init?(dict: [String: Any]) {
        guard let coin = dict["coin"] as? String else { return nil }
        self.coin = coin
        self.side = dict["side"] as? String ?? "B"
        self.sz = dict["sz"] as? String ?? "0"
        self.filledSz = dict["filledSz"] as? String ?? "0"
        self.status = dict["state"] as? String ?? dict["status"] as? String ?? "unknown"
        self.durationMinutes = dict["minutes"] as? Int ?? 0

        if let t = dict["twapId"] as? Int64 { self.twapId = t }
        else if let t = dict["twapId"] as? Int { self.twapId = Int64(t) }
        else { return nil }
        self.id = self.twapId

        if let t = dict["time"] as? Int64 { self.timestamp = t }
        else if let t = dict["time"] as? Int { self.timestamp = Int64(t) }
        else if let t = dict["timestamp"] as? Int64 { self.timestamp = t }
        else if let t = dict["timestamp"] as? Int { self.timestamp = Int64(t) }
        else { self.timestamp = 0 }
    }
}

struct HLFunding: Identifiable {
    let id: Int64
    let time: Int64
    let coin: String
    let usdc: String
    let szi: String
    let fundingRate: String

    var timeStr: String {
        let date = Date(timeIntervalSince1970: Double(time) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: date)
    }

    init?(dict: [String: Any]) {
        guard let delta = dict["delta"] as? [String: Any],
              let coin = delta["coin"] as? String else { return nil }

        self.coin = coin
        self.usdc = delta["usdc"] as? String ?? "0"
        self.szi = delta["szi"] as? String ?? "0"
        self.fundingRate = delta["fundingRate"] as? String ?? "0"

        if let t = dict["time"] as? Int64 { self.time = t }
        else if let t = dict["time"] as? Int { self.time = Int64(t) }
        else { self.time = 0 }

        self.id = self.time
    }
}

// MARK: - Simple haptics helper

enum HapticsManager {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard UserDefaults.standard.bool(forKey: "hl_haptics") else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard UserDefaults.standard.bool(forKey: "hl_haptics") else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
