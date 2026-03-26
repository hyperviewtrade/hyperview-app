import Foundation
import Combine

// MARK: - SmartMoneyService
// Detects and publishes smart money events from Hyperliquid data streams.
// Subscribes to the WebSocket trade publisher and generates events for:
//   whale trades, liquidations, top trader moves, signals, staking, OI surges.

@MainActor
final class SmartMoneyService: ObservableObject {
    static let shared = SmartMoneyService()

    // Subscribers receive events here
    let eventPublisher = PassthroughSubject<SmartMoneyEvent, Never>()

    // MARK: - Config
    private let whaleThresholdUSD: Double = 250_000
    private let monitoredCoins = [
        "BTC", "ETH", "SOL", "HYPE", "XRP", "BNB",
        "DOGE", "AVAX", "LINK", "ARB", "OP", "SUI",
        "INJ", "TIA", "NEAR", "TON"
    ]

    // MARK: - Internal state
    private let ws  = WebSocketManager.shared
    private let api = HyperliquidAPI.shared

    private var cancellables      = Set<AnyCancellable>()
    private var signalTimer:    AnyCancellable?
    private var oiTimer:        AnyCancellable?
    private var stakingTimer:   AnyCancellable?
    private var previousOI:     [String: Double] = [:]
    private var isStarted = false

    private init() {}

    // MARK: - Start

    func start(markets: [Market]) {
        guard !isStarted else { return }
        isStarted = true

        setupTradeSubscription()
        initOIBaseline(markets: markets)
        scheduleOICheck(markets: markets)
        scheduleSignalCheck(markets: markets)
        scheduleStakingPoll()
        Task { await bootstrapFromRecentTrades() }
    }

    func stop() {
        signalTimer?.cancel()
        oiTimer?.cancel()
        stakingTimer?.cancel()
        cancellables.removeAll()
        isStarted = false
    }

    // MARK: - Whale Detection via WebSocket trades

    private func setupTradeSubscription() {
        ws.connect()
        for coin in monitoredCoins { ws.subscribeTrades(coin: coin) }

        ws.tradePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trades in
                self?.processTrades(trades)
            }
            .store(in: &cancellables)
    }

    private func processTrades(_ trades: [Trade]) {
        for trade in trades {
            let sizeUSD = trade.price * trade.size
            guard sizeUSD >= whaleThresholdUSD else { continue }

            // Derive a display address from the trade hash
            let addrSuffix = String(trade.hash.suffix(40))
            let displayAddr = "0x" + addrSuffix.prefix(8) + "…" + addrSuffix.suffix(4)

            let event = WhaleTradeEvent(
                id: "\(trade.tid)",
                asset: trade.coin,
                isLong: trade.isBuy,
                sizeUSD: sizeUSD,
                entryPrice: trade.price,
                currentPrice: trade.price,
                walletAddress: displayAddr,
                timestamp: trade.tradeTime,
                whaleCount: 1,
                totalSizeUSD: sizeUSD
            )
            eventPublisher.send(.whaleTrade(event))

            // Classify very large market sells as potential liquidations (>$2M)
            if sizeUSD >= 2_000_000 && !trade.isBuy {
                let liq = LiquidationEvent(
                    id: "liq-\(trade.tid)",
                    asset: trade.coin,
                    sizeUSD: sizeUSD,
                    wasLong: true,
                    walletAddress: displayAddr,
                    timestamp: trade.tradeTime
                )
                eventPublisher.send(.liquidation(liq))
            }
        }
    }

    // MARK: - OI Surge Detection

    private func initOIBaseline(markets: [Market]) {
        for m in markets { previousOI[m.symbol] = m.openInterest * m.price }
    }

    private func scheduleOICheck(markets: [Market]) {
        oiTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkOISurges(markets: markets) }
    }

    private func checkOISurges(markets: [Market]) {
        for market in markets.prefix(15) {
            let currentOI = market.openInterest * market.price
            guard let prev = previousOI[market.symbol], prev > 0 else {
                previousOI[market.symbol] = currentOI
                continue
            }
            let change  = currentOI - prev
            let pctMove = abs(change / prev)
            if pctMove > 0.15 && abs(change) > 30_000_000 {
                let surge = OISurgeEvent(
                    id: UUID().uuidString,
                    asset: market.displayName,
                    oiChangeUSD: change,
                    windowMinutes: 5,
                    timestamp: Date()
                )
                eventPublisher.send(.oiSurge(surge))
            }
            previousOI[market.symbol] = currentOI
        }
    }

    // MARK: - Signal Detection (funding / crowded trade)

    private func scheduleSignalCheck(markets: [Market]) {
        signalTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.detectSignals(markets: markets) }
        detectSignals(markets: markets)
    }

    private func detectSignals(markets: [Market]) {
        for market in markets.prefix(20) {
            let funding = market.funding
            guard abs(funding) > 0.0001 else { continue }
            let bullish = funding < 0        // negative funding: shorts pay longs → crowded long
            let signal = SignalEvent(
                id: UUID().uuidString,
                asset: market.displayName,
                signalType: .fundingSpike,
                longPercent:  bullish ? 0.68 : 0.32,
                shortPercent: bullish ? 0.32 : 0.68,
                value: funding,
                timestamp: Date()
            )
            eventPublisher.send(.signal(signal))
            return      // one signal per cycle to avoid spam
        }
    }

    // MARK: - Bootstrap (populate feed on startup via REST recentTrades)

    private func bootstrapFromRecentTrades() async {
        // Fetch recent trades for the top coins to pre-populate the home feed
        // before WebSocket delivers live events.
        for coin in monitoredCoins.prefix(8) {
            guard let trades = try? await api.fetchRecentTrades(coin: coin) else { continue }
            let whales = trades.filter { $0.price * $0.size >= whaleThresholdUSD }
            processTrades(whales)
            // Small delay between REST calls to respect rate limits
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - Staking Poll (REST)

    private func scheduleStakingPoll() {
        stakingTimer = Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.pollStakingEvents() }
            }
    }

    private func pollStakingEvents() async {
        // Hyperliquid doesn't expose a global staking stream via REST,
        // so we observe our connected wallet if available.
        guard let addr = WalletManager.shared.connectedWallet?.address else { return }
        guard let staking = try? await api.fetchStakingState(address: addr) else { return }

        if let delegatedStr = staking["delegated"] as? String,
           let delegated = Double(delegatedStr),
           delegated > 0 {
            let hypePrice = WebSocketManager.shared.latestMidPrices["HYPE"] ?? 28.0
            let event = StakingEvent(
                id: UUID().uuidString,
                walletAddress: addr,
                amountHYPE: delegated,
                usdValue: delegated * hypePrice,
                isStaking: true,
                unstakingCompletesAt: nil,
                timestamp: Date()
            )
            eventPublisher.send(.staking(event))
        }
    }

}
