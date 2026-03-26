import SwiftUI
import Combine

// MARK: - Domain models for wallet detail

struct PerpPosition: Identifiable {
    let id = UUID()
    let coin: String
    let size: Double           // positive = long, negative = short
    let entryPrice: Double
    let markPrice: Double
    let unrealizedPnl: Double
    let leverage: Int
    let isCross: Bool          // true = cross margin, false = isolated
    let marginUsed: Double     // margin allocated to this position
    let liquidationPx: Double?
    let cumulativeFunding: Double
    var szDecimals: Int = 4    // size decimals from market meta (BTC=5, ETH=4, etc.)

    var isLong: Bool { size >= 0 }
    var sizeAbs: Double { abs(size) }
    var notional: Double { sizeAbs * markPrice }

    var formattedMargin: String {
        "$\(Self.commaFormatted(marginUsed, decimals: 2))"
    }

    var formattedSize: String {
        let sign = isLong ? "+" : "-"
        let dec = MarketsViewModel.szDecimalsCache[coin] ?? szDecimals
        return "\(sign)\(Self.commaFormatted(sizeAbs, decimals: dec)) \(coin)"
    }

    var formattedSizeUSD: String {
        let sign = isLong ? "+" : "-"
        return "\(sign)$\(Self.commaFormatted(notional, decimals: 2))"
    }

    var formattedPnl: String {
        let sign = unrealizedPnl >= 0 ? "+" : "-"
        return "PNL : \(sign)$\(Self.commaFormatted(abs(unrealizedPnl), decimals: 2))"
    }

    var formattedRoe: String {
        guard entryPrice > 0 else { return "0.00%" }
        let pnlPct = ((markPrice - entryPrice) / entryPrice) * 100 * (isLong ? 1 : -1)
        let roe = pnlPct * Double(leverage)
        return String(format: "%@%.2f%%", roe >= 0 ? "+" : "", roe)
    }

    var formattedEntry: String { formatPrice(entryPrice) }
    var formattedMark:  String { formatPrice(markPrice) }

    var formattedLiqPx: String {
        guard let px = liquidationPx else { return "—" }
        return formatPrice(px)
    }

    var formattedFunding: String {
        let sign = cumulativeFunding >= 0 ? "+" : "-"
        return "\(sign)$\(Self.commaFormatted(abs(cumulativeFunding), decimals: 2))"
    }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return "$\(Self.commaFormatted(p, decimals: 1))" }
        if p >= 1      { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }

    private static func commaFormatted(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }
}

struct UserFill: Identifiable {
    let id = UUID()
    let coin: String
    let price: Double
    let size: Double
    let side: String        // "B" or "A"
    let time: Date
    let closedPnl: Double
    let fee: Double
    let dir: String         // "Open Long" / "Close Long" / "Open Short" / "Close Short"

    var isBuy: Bool { side == "B" }
    var isClose: Bool { dir.hasPrefix("Close") }
}

struct SpotBalance: Identifiable {
    let id = UUID()
    let coin: String
    let total: Double
    let usdValue: Double
    let entryNtl: Double  // cost basis in USD

    var spotPnl: Double { usdValue - entryNtl }
    var spotPnlPct: Double { entryNtl > 0 ? (spotPnl / entryNtl) * 100 : 0 }

    var formattedTotal: String {
        if total >= 1_000_000 { return String(format: "%.2fM", total / 1_000_000) }
        if total >= 1_000     { return String(format: "%.2fK", total / 1_000) }
        return String(format: "%.4f", total)
    }
    var formattedUSD: String {
        let v = abs(usdValue)
        let sign = usdValue < 0 ? "-" : ""
        if v >= 1_000_000_000 { return String(format: "%@$%.2fB", sign, v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "%@$%.2fM", sign, v / 1_000_000) }
        if v >= 1_000         { return String(format: "%@$%.2fK", sign, v / 1_000) }
        return String(format: "%@$%.2f", sign, v)
    }
}

struct OpenOrder: Identifiable {
    let id = UUID()
    let oid: Int
    let coin: String
    let side: String
    let price: Double
    let size: Double
    let timestamp: Date
    let orderType: String

    var isBuy: Bool { side == "B" }

    var formattedPrice: String {
        if price >= 10_000 { return String(format: "$%.1f", price) }
        if price >= 1      { return String(format: "$%.2f", price) }
        return String(format: "$%.4f", price)
    }
    var formattedSize: String { String(format: "%.4f", size) }
}

// MARK: - Transaction model

struct WalletTransaction: Identifiable {
    let id = UUID()
    let time: Date
    let type: TxType
    let amount: String       // e.g. "1,300.00 USDC" or "1,500 HYPE"
    let amountUSD: String?   // e.g. "$1,234.56" — nil for non-trade txs
    let detail: String       // secondary info (destination, vault, etc.)
    let hash: String

    enum TxType: String, CaseIterable {
        case openLong           = "Open Long"
        case closeLong          = "Close Long"
        case openShort          = "Open Short"
        case closeShort         = "Close Short"
        case buy                = "Buy"
        case sell               = "Sell"
        case deposit            = "Deposit"
        case withdraw           = "Withdraw"
        case internalTransfer   = "Transfer"
        case spotTransfer       = "Spot Transfer"
        case accountClassTransfer = "Spot ↔ Perp"
        case staking            = "Staking"
        case airdrop            = "Airdrop"

        var icon: String {
            switch self {
            case .openLong:             return "arrow.up.right"
            case .closeLong:            return "arrow.down.left"
            case .openShort:            return "arrow.down.right"
            case .closeShort:           return "arrow.up.left"
            case .buy:                  return "cart.fill"
            case .sell:                 return "cart.badge.minus"
            case .deposit:              return "arrow.down.to.line"
            case .withdraw:             return "arrow.up.forward"
            case .internalTransfer:     return "arrow.left.arrow.right"
            case .spotTransfer:         return "arrow.left.arrow.right"
            case .accountClassTransfer: return "arrow.triangle.swap"
            case .staking:              return "lock.fill"
            case .airdrop:              return "gift.fill"
            }
        }

        var color: Color {
            switch self {
            case .openLong, .closeLong, .buy, .deposit, .airdrop:
                return .hlGreen
            case .openShort, .closeShort, .sell, .withdraw:
                return .tradingRed
            default:
                return Color(white: 0.5)
            }
        }
    }
}

// MARK: - Staking models

struct StakingDelegation: Identifiable {
    let id = UUID()
    let validator: String
    let validatorName: String
    let amount: Double
    let lockedUntil: Date?
}

struct StakingReward: Identifiable {
    let id = UUID()
    let time: Date
    let source: String   // "delegation" or "commission"
    let amount: Double
}

struct StakingSummary {
    var delegated: Double = 0
    var undelegated: Double = 0
    var pendingWithdrawal: Double = 0
    var delegations: [StakingDelegation] = []
    var rewards: [StakingReward] = []
    var totalRewards: Double = 0
}

// MARK: - WalletDetailViewModel

@MainActor
final class WalletDetailViewModel: ObservableObject {
    @Published var positions:    [PerpPosition]      = []
    @Published var openOrders:   [OpenOrder]         = []
    @Published var spotBalances: [SpotBalance]       = []
    @Published var fills:        [UserFill]          = []
    @Published var transactions: [WalletTransaction] = []
    @Published var selectedTxTypes: Set<WalletTransaction.TxType> = Set(WalletTransaction.TxType.allCases)
    @Published var staking:      StakingSummary      = StakingSummary()
    @Published var alias:        String?             = nil

    // MARK: - Transaction pagination (LARP-style)
    //
    // Ledger events (deposits/withdrawals/transfers/staking) are always fully loaded.
    // Fills (trades) are paginated — backend returns first 50, iOS fetches more on demand.
    // The combined transactions array is sorted by time desc; txDisplayLimit controls
    // how many the view reveals.
    @Published var txDisplayLimit: Int = 50
    @Published var txTotalFills:  Int = 0          // from backend fillsTotal (may exceed fills.count)
    @Published var txIsLoadingMore: Bool = false
    private var txLoadAddress: String = ""         // address for load-more calls
    /// Number of ledger-sourced transactions (always fully loaded, set after parse).
    private var txParsedLedgerCount: Int = 0

    /// Total known transactions = parsed ledger tx + total fills from backend.
    /// Ledger is always fully loaded; fills may have more on the server.
    var txTotalCount: Int {
        txParsedLedgerCount + txTotalFills
    }

    /// True when the user can load more: either we have un-revealed parsed data,
    /// or the server has more fills than we've fetched so far.
    var txHasMore: Bool {
        transactions.count > txDisplayLimit || fills.count < txTotalFills
    }

    /// Paginated + filtered view of transactions.
    var filteredTransactions: [WalletTransaction] {
        let limited = Array(transactions.prefix(txDisplayLimit))
        return limited.filter { selectedTxTypes.contains($0.type) }
    }

    var hasData: Bool {
        !positions.isEmpty || !spotBalances.isEmpty || !fills.isEmpty || !transactions.isEmpty
    }

    // Overview stats
    @Published var totalPnl:    Double = 0
    @Published var winrate:     Double = 0
    @Published var totalVolume: Double = 0
    @Published var bestTrade:   Double = 0

    @Published var isLoading  = false
    @Published var errorMsg:  String?
    // Data caching — once loaded, tabs don't re-fetch
    private(set) var hasFetched = false

    // Global aliases cache (shared across instances)
    static var globalAliases: [String: String]?
    // Spot token index → name map (e.g. "@182" → "HYPE")
    private static var spotTokenNames: [String: String]?
    // Validator address → name cache (shared, refreshed from backend)
    private static var validatorNames: [String: String]?

    // In-memory wallet cache for instant back-navigation (60s TTL)
    private static var walletCache: [String: CachedWallet] = [:]
    private static let cacheTTL: TimeInterval = 60
    private static let maxCacheSize = 10

    private struct CachedWallet {
        let positions: [PerpPosition]
        let openOrders: [OpenOrder]
        let spotBalances: [SpotBalance]
        let fills: [UserFill]
        let transactions: [WalletTransaction]
        let staking: StakingSummary
        let totalPnl: Double
        let winrate: Double
        let totalVolume: Double
        let bestTrade: Double
        let alias: String?
        let date: Date
    }

    private let api = HyperliquidAPI.shared

    // MARK: - Load

    /// Fire-and-forget loader called from struct init (before SwiftUI lifecycle).
    /// Creates an unstructured Task so it can't be cancelled by fullScreenCover transitions.
    nonisolated func startLoad(address: String) {
        Task { @MainActor [weak self] in
            await self?.loadIfNeeded(address: address)
        }
    }

    func loadIfNeeded(address: String) async {
        if hasFetched {
            // If we fetched but spot/overview is empty while account has value, retry once
            let accountVal = WalletManager.shared.accountValue
            if spotBalances.isEmpty && accountVal > 1 && !isLoading {
                print("[WALLET-VM] Spot empty but account=\(accountVal), retrying...")
                await load(address: address, forceRefresh: true)
            }
            return
        }
        await load(address: address)
    }

    func refresh(address: String) async {
        hasFetched = false
        await load(address: address, forceRefresh: true)
    }

    private static let backendBaseURL = "https://hyperview-backend-production-075c.up.railway.app"

    /// Shared timing origin for the current load cycle.
    private var loadT0: CFAbsoluteTime = 0

    private func elapsed() -> String {
        String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
    }

    private func load(address: String, forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        loadT0 = CFAbsoluteTimeGetCurrent()
        print("⏱ [\(elapsed())] WALLET LOAD START  address=\(address.prefix(10))…")
        isLoading = true
        errorMsg  = nil
        txDisplayLimit = 50
        txTotalFills   = 0
        txParsedLedgerCount = 0

        let cacheKey = address.lowercased()

        // Check in-memory cache for instant display (skip on pull-to-refresh)
        if !forceRefresh,
           let cached = Self.walletCache[cacheKey],
           Date().timeIntervalSince(cached.date) < Self.cacheTTL {
            positions = cached.positions
            openOrders = cached.openOrders
            spotBalances = cached.spotBalances
            fills = cached.fills
            transactions = cached.transactions
            staking = cached.staking
            totalPnl = cached.totalPnl
            winrate = cached.winrate
            totalVolume = cached.totalVolume
            bestTrade = cached.bestTrade
            alias = cached.alias
            hasFetched = true
            isLoading = false
            print("⏱ [\(elapsed())] WALLET CACHE HIT — skipping network")
            return
        }

        // Resolve alias + token names in parallel with main load
        async let tokenNamesTask: () = loadSpotTokenNames()
        async let aliasTask: () = resolveAlias(for: address)

        do {
            // Try backend aggregate endpoint first (1 request instead of 7)
            print("⏱ [\(elapsed())] WALLET TRYING BACKEND")
            let didLoadFromBackend = await loadFromBackend(address: address)

            if !didLoadFromBackend {
                // Fallback: progressive HL API loading
                print("⏱ [\(elapsed())] WALLET BACKEND FAILED — falling back to HL API")
                await loadFromHLAPI(address: address)
            }
        } catch is CancellationError {
            // Dismiss or navigation — ignore
        } catch let urlError as URLError where urlError.code == .cancelled {
            // ignore
        } catch {
            errorMsg = error.localizedDescription
        }

        _ = await tokenNamesTask
        _ = await aliasTask
        isLoading = false
        print("⏱ [\(elapsed())] WALLET LOAD COMPLETE  isLoading=false")

        // Cache the loaded data (only if we got meaningful data)
        if !spotBalances.isEmpty || !positions.isEmpty || !fills.isEmpty {
            Self.walletCache[cacheKey] = CachedWallet(
                positions: positions, openOrders: openOrders,
                spotBalances: spotBalances, fills: fills,
                transactions: transactions, staking: staking,
                totalPnl: totalPnl, winrate: winrate,
                totalVolume: totalVolume, bestTrade: bestTrade,
                alias: alias, date: Date()
            )
            // Evict oldest entry if cache exceeds size limit (HIGH-07)
            if Self.walletCache.count > Self.maxCacheSize {
                if let oldest = Self.walletCache.min(by: { $0.value.date < $1.value.date }) {
                    Self.walletCache.removeValue(forKey: oldest.key)
                }
            }
        }

        // Auto-retry if spot is empty but account should have data
        if spotBalances.isEmpty && WalletManager.shared.accountValue > 1 && !forceRefresh {
            print("[WALLET-VM] Spot empty after load, scheduling retry in 3s...")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.load(address: address, forceRefresh: true)
            }
        }
    }

    /// Load all wallet data from backend aggregate endpoint.
    /// Returns true if successful.
    private func loadFromBackend(address: String) async -> Bool {
        guard let url = URL(string: "\(Self.backendBaseURL)/wallet/\(address)") else { return false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5 // fail fast, fallback to direct API

            print("⏱ [\(elapsed())] BACKEND REQUEST START")
            let (data, response) = try await URLSession.shared.data(for: request)
            print("⏱ [\(elapsed())] BACKEND RESPONSE RECEIVED  bytes=\(data.count)")

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⏱ [\(elapsed())] BACKEND BAD STATUS \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return false
            }

            print("⏱ [\(elapsed())] BACKEND JSON PARSE START")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            print("⏱ [\(elapsed())] BACKEND JSON PARSE END")

            // Backend returns null for state/fills/ledger when HL API is rate-limited
            guard let state = json["state"] as? [String: Any],
                  state["assetPositions"] != nil || state["marginSummary"] != nil
            else { return false }

            let rawFills = json["fills"] as? [[String: Any]] ?? []
            let spot     = json["spot"] as? [String: Any] ?? [:]
            let ledger   = json["ledger"] as? [[String: Any]] ?? []
            let staking  = json["staking"] as? [String: Any] ?? [:]

            // Transaction pagination: backend returns fillsTotal (fills may be sliced)
            // Ledger is always returned in full — txParsedLedgerCount is set by parseTransactions.
            txTotalFills  = (json["fillsTotal"] as? Int) ?? rawFills.count
            txLoadAddress = address

            let stakeSum = staking["summary"] as? [String: Any] ?? [:]
            let delegs   = staking["delegations"] as? [[String: Any]] ?? []
            let rewards  = staking["rewards"] as? [[String: Any]] ?? []

            // Cache validator names from backend response
            if let validatorMap = json["validators"] as? [String: String], !validatorMap.isEmpty {
                Self.validatorNames = validatorMap
            }

            // Alias from Hypurrscan (via backend)
            if let backendAlias = json["alias"] as? String, !backendAlias.isEmpty {
                self.alias = backendAlias
            } else {
                self.alias = AliasCache.shared.alias(for: address)
            }

            // ── Phase 1: above-the-fold (positions, orders) ──
            print("⏱ [\(elapsed())] MIDPRICES FETCH START (async)")
            async let midPriceTask: () = fetchMidPrices()

            print("⏱ [\(elapsed())] PARSE POSITIONS START")
            parsePositions(from: state)
            print("⏱ [\(elapsed())] PARSE POSITIONS END  count=\(positions.count)")

            if let hip3 = json["hip3States"] as? [String: [String: Any]] {
                print("⏱ [\(elapsed())] PARSE HIP3 START  keys=\(hip3.count)")
                for (_, dexState) in hip3 {
                    parseHIP3Positions(from: dexState)
                }
                print("⏱ [\(elapsed())] PARSE HIP3 END")
            }

            print("⏱ [\(elapsed())] PARSE ORDERS START")
            parseOrders(from: state)
            print("⏱ [\(elapsed())] PARSE ORDERS END  count=\(openOrders.count)")

            hasFetched = true  // UI renders NOW — positions + orders visible
            print("⏱ [\(elapsed())] ✅ hasFetched = true (UI can render)")

            // ── Phase 2a: transactions (pure CPU, no network dependency) ──
            // Parse fills + transactions immediately so the Transactions tab
            // is ready by the time the user taps it. No need to wait for midprices.
            print("⏱ [\(elapsed())] PARSE FILLS START  raw=\(rawFills.count)")
            parseFills(rawFills)
            print("⏱ [\(elapsed())] PARSE FILLS END  count=\(fills.count)")

            print("⏱ [\(elapsed())] PARSE TRANSACTIONS START  raw=\(ledger.count)")
            parseTransactions(ledger)
            print("⏱ [\(elapsed())] PARSE TRANSACTIONS END  count=\(transactions.count)")

            print("⏱ [\(elapsed())] MERGE FILLS INTO TX START")
            mergeFillsIntoTransactions()
            print("⏱ [\(elapsed())] MERGE FILLS INTO TX END  total=\(transactions.count)")

            print("⏱ [\(elapsed())] COMPUTE OVERVIEW START")
            computeOverview()
            print("⏱ [\(elapsed())] COMPUTE OVERVIEW END")

            // ── Phase 2b: spot (needs midprices network call) ──
            print("⏱ [\(elapsed())] MIDPRICES AWAIT START")
            await midPriceTask
            print("⏱ [\(elapsed())] MIDPRICES AWAIT END")

            print("⏱ [\(elapsed())] PARSE SPOT START")
            parseSpot(spot)
            print("⏱ [\(elapsed())] PARSE SPOT END  count=\(spotBalances.count)")

            print("⏱ [\(elapsed())] PARSE STAKING START")
            parseStaking(summary: stakeSum, delegations: delegs, rewards: rewards)
            print("⏱ [\(elapsed())] PARSE STAKING END")

            // Older fills are now loaded on demand via "Load More" button
            // (no automatic background pagination)
            print("⏱ [\(elapsed())] BACKEND PATH COMPLETE  txTotal=\(txTotalCount) displayed=\(txDisplayLimit)")
            return true
        } catch {
            print("⏱ [\(elapsed())] BACKEND ERROR: \(error)")
            return false
        }
    }

    /// Fallback: progressive HL API loading.
    /// Phase 1: positions + orders (instant display)
    /// Phase 2: spot + fills, staking, HIP-3 (background)
    private func loadFromHLAPI(address: String) async {
        do {
            // ── All network requests in parallel ──
            print("⏱ [\(elapsed())] HLAPI START (state + spot + midPrices + fills + ledger)")
            async let stateTask  = api.fetchUserState(address: address)
            async let spotTask   = api.fetchSpotState(address: address)
            async let midTask: () = fetchMidPrices()
            async let fillsTask  = api.fetchUserFills(address: address)
            async let ledgerTask = { try? await self.api.fetchLedgerUpdates(address: address) }()

            // ── Phase 1: positions + orders (first render) ──
            let state = try await stateTask
            print("⏱ [\(elapsed())] HLAPI STATE RECEIVED")

            parsePositions(from: state)
            print("⏱ [\(elapsed())] HLAPI PARSE POSITIONS END  count=\(positions.count)")
            parseOrders(from: state)
            print("⏱ [\(elapsed())] HLAPI PARSE ORDERS END  count=\(openOrders.count)")
            hasFetched = true
            print("⏱ [\(elapsed())] ✅ hasFetched = true (UI can render)")

            // ── Phase 2a: fills + transactions (may already be done, pure CPU after await) ──
            let rawFills = (try? await fillsTask) ?? []
            let ledger   = await ledgerTask ?? []
            print("⏱ [\(elapsed())] HLAPI FILLS+LEDGER RECEIVED  fills=\(rawFills.count) ledger=\(ledger.count)")

            parseFills(rawFills)
            parseTransactions(ledger)
            mergeFillsIntoTransactions()
            txTotalFills  = rawFills.count
            txLoadAddress = address
            computeOverview()
            print("⏱ [\(elapsed())] HLAPI TRANSACTIONS READY  total=\(transactions.count)")

            // ── Phase 2b: spot (needs midprices) ──
            let spot = (try? await spotTask) ?? [:]
            await midTask
            print("⏱ [\(elapsed())] HLAPI SPOT+MIDPRICES DONE")
            parseSpot(spot)

            // ── Phase 3: staking + HIP-3 (least critical) ──
            print("⏱ [\(elapsed())] HLAPI PHASE3 START (staking, HIP3)")
            await loadSecondaryData(address: address)
            print("⏱ [\(elapsed())] HLAPI PHASE3 COMPLETE")
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    /// Load staking + HIP-3 data (fills/ledger are now fetched earlier in loadFromHLAPI).
    private func loadSecondaryData(address: String) async {
        // Fetch validator names if not cached yet
        if Self.validatorNames == nil {
            Task { await Self.loadValidatorNames() }
        }

        // Staking data (3 calls)
        async let stakeSumTask = try? api.fetchDelegatorSummary(address: address)
        async let delegTask    = try? api.fetchDelegations(address: address)
        async let rewardsTask  = try? api.fetchDelegatorRewards(address: address)
        let stakeSum = await stakeSumTask ?? [:]
        let delegs   = await delegTask ?? []
        let rewards  = await rewardsTask ?? []

        // Small delay before HIP-3 (which itself makes multiple calls)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // HIP-3 positions (sequential inside)
        let hip3 = await api.fetchHIP3States(address: address)

        for (_, dexState) in hip3 {
            parseHIP3Positions(from: dexState)
        }
        parseStaking(summary: stakeSum, delegations: delegs, rewards: rewards)

        // Update cache with complete data
        let cacheKey = address.lowercased()
        Self.walletCache[cacheKey] = CachedWallet(
            positions: positions, openOrders: openOrders,
            spotBalances: spotBalances, fills: fills,
            transactions: transactions, staking: staking,
            totalPnl: totalPnl, winrate: winrate,
            totalVolume: totalVolume, bestTrade: bestTrade,
            alias: alias, date: Date()
        )
        // Evict oldest entry if cache exceeds size limit (HIGH-07)
        if Self.walletCache.count > Self.maxCacheSize {
            if let oldest = Self.walletCache.min(by: { $0.value.date < $1.value.date }) {
                Self.walletCache.removeValue(forKey: oldest.key)
            }
        }

        // Older fills are now loaded on demand via "Load More" button
    }

    // MARK: - Background fill scanning

    /// Scans for perp fills that may be buried beyond the initial 2000-fill load.
    /// Uses two strategies:
    /// 1. Targeted time probes: directly queries specific days going back 90d
    /// 2. Sequential backward pagination from the newest fills
    /// The API limits userFillsByTime to the 10,000 most recent fills per user,
    /// so for high-frequency bot wallets, targeted probes bypass the dense recent fills.
    private func paginateOlderFills(address: String, ledger: [[String: Any]]) async {
        var seenTids = Set<Int64>()
        // Seed with tids from initial fills
        for fill in fills {
            // We don't have tids stored in UserFill, so dedup by time+coin+size
        }

        let initialFillCount = fills.count
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        // --- Phase 1: Targeted time probes ---
        // Directly query 12h windows at days 1, 2, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90
        // This bypasses dense bot fills entirely — if perp fills exist at these dates, we find them
        let probeOffsetsDays: [Int] = [1, 2, 3, 4, 5, 6, 7, 10, 14, 21, 30, 45, 60, 90]
        let msPerDay: Int64 = 86400 * 1000

        for offsetDays in probeOffsetsDays {
            let probeCenter = nowMs - Int64(offsetDays) * msPerDay
            let probeStart = probeCenter - 12 * 3600 * 1000  // 12h before
            let probeEnd = probeCenter + 12 * 3600 * 1000    // 12h after

            guard let data = try? await api.post(body: [
                "type": "userFillsByTime",
                "user": address,
                "startTime": Int(probeStart),
                "endTime": Int(probeEnd),
                "aggregateByTime": false
            ] as [String: Any]) else { continue }

            let rawPage = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            guard !rawPage.isEmpty else { continue }

            let newFills = parseFillPage(rawPage, seenTids: &seenTids)
            if !newFills.isEmpty {
                fills.append(contentsOf: newFills)

                let hasPerpFills = newFills.contains { ["Open Long", "Close Long", "Open Short", "Close Short"].contains($0.dir) }
                if hasPerpFills {
                    // Found perp fills — expand search around this time period
                    await expandAroundTimestamp(address: address, centerMs: probeCenter, seenTids: &seenTids)
                }
            }
        }

        // --- Phase 2: Sequential backward pagination (for fills just beyond initial load) ---
        let oldestMs = fills.map { Int64($0.time.timeIntervalSince1970 * 1000) }.min() ?? 0
        if oldestMs > 0 {
            var endCursor = oldestMs
            let limitMs = max(nowMs - 90 * msPerDay, 0)

            for _ in 0..<30 {
                let windowMs: Int64 = 6 * 3600 * 1000  // 6h windows
                let startMs = max(endCursor - windowMs, limitMs)
                guard startMs < endCursor else { break }

                guard let data = try? await api.post(body: [
                    "type": "userFillsByTime",
                    "user": address,
                    "startTime": Int(startMs),
                    "endTime": Int(endCursor),
                    "aggregateByTime": false
                ] as [String: Any]) else {
                    endCursor = startMs
                    continue
                }

                let rawPage = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                if rawPage.isEmpty { break } // Hit end of available fills

                let newFills = parseFillPage(rawPage, seenTids: &seenTids)
                if !newFills.isEmpty {
                    fills.append(contentsOf: newFills)
                }

                let pageOldestMs = rawPage.compactMap { f -> Int64? in
                    f["time"] as? Int64 ?? (f["time"] as? NSNumber)?.int64Value
                }.min() ?? startMs
                endCursor = min(pageOldestMs, startMs)

                if endCursor <= limitMs { break }
            }
        }

        // Final UI update — only convert NEW fills into transactions
        // (don't re-parse ledger or re-merge all fills; avoids "No Data" flash)
        let newFillCount = fills.count - initialFillCount
        if newFillCount > 0 {
            computeOverview()
            let newFillSlice = fills.suffix(newFillCount)
            let newTxs: [WalletTransaction] = newFillSlice.map { fill in
                let txType: WalletTransaction.TxType
                switch fill.dir {
                case "Open Long":    txType = .openLong
                case "Close Long":   txType = .closeLong
                case "Open Short":   txType = .openShort
                case "Close Short":  txType = .closeShort
                default:             txType = fill.isBuy ? .buy : .sell
                }
                let coin = resolvedCoinName(fill.coin)
                let sizeStr = fill.size >= 1_000
                    ? String(format: "%.2f", fill.size)
                    : String(format: "%.4f", fill.size)
                let usdVal = fill.size * fill.price
                let amount = formatUSDValue(usdVal)
                let amountUSD = "\(sizeStr) \(coin)"
                var detail = "\(coin) @\(formatPrice(fill.price))"
                if fill.closedPnl != 0 {
                    let sign = fill.closedPnl >= 0 ? "+" : ""
                    detail += " · PnL \(sign)$\(String(format: "%.2f", fill.closedPnl))"
                }
                return WalletTransaction(
                    time: fill.time, type: txType,
                    amount: amount, amountUSD: amountUSD,
                    detail: detail, hash: ""
                )
            }
            transactions.append(contentsOf: newTxs)
            transactions.sort { $0.time > $1.time }
        }
    }

    /// Expand search around a timestamp where perp fills were found
    private func expandAroundTimestamp(address: String, centerMs: Int64, seenTids: inout Set<Int64>) async {
        let msPerDay: Int64 = 86400 * 1000
        // Search ±3 days around the center in 12h windows
        for dayOffset in stride(from: -3, through: 3, by: 1) {
            let windowCenter = centerMs + Int64(dayOffset) * msPerDay
            let startMs = windowCenter - 12 * 3600 * 1000
            let endMs = windowCenter + 12 * 3600 * 1000

            guard let data = try? await api.post(body: [
                "type": "userFillsByTime",
                "user": address,
                "startTime": Int(startMs),
                "endTime": Int(endMs),
                "aggregateByTime": false
            ] as [String: Any]) else { continue }

            let rawPage = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let newFills = parseFillPage(rawPage, seenTids: &seenTids)
            if !newFills.isEmpty {
                fills.append(contentsOf: newFills)
            }
        }

        computeOverview()
    }

    /// Parse a page of raw fill dicts into UserFill, deduplicating by tid
    private func parseFillPage(_ rawPage: [[String: Any]], seenTids: inout Set<Int64>) -> [UserFill] {
        rawPage.compactMap { f in
            if let tid = f["tid"] as? Int64 ?? (f["tid"] as? NSNumber)?.int64Value {
                guard seenTids.insert(tid).inserted else { return nil }
            }
            guard let coin  = f["coin"] as? String,
                  let pxStr = f["px"] as? String,   let px  = Double(pxStr),
                  let szStr = f["sz"] as? String,   let sz  = Double(szStr),
                  let side  = f["side"] as? String,
                  let timeMs = f["time"] as? Int64 ?? (f["time"] as? NSNumber)?.int64Value
            else { return nil }
            let dir = f["dir"] as? String ?? (side == "B" ? "Buy" : "Sell")
            let closedPnl = Self.parseDouble(f["closedPnl"])
            let fee       = Self.parseDouble(f["fee"])
            return UserFill(coin: coin, price: px, size: sz, side: side,
                            time: Date(timeIntervalSince1970: Double(timeMs) / 1000),
                            closedPnl: closedPnl, fee: fee, dir: dir)
        }
    }

    // MARK: - Parsers

    private func parsePositions(from state: [String: Any]) {
        guard let assetPositions = state["assetPositions"] as? [[String: Any]] else { return }
        positions = assetPositions.compactMap { wrapper in
            guard let pos = wrapper["position"] as? [String: Any],
                  let coin = pos["coin"] as? String,
                  let sziStr = pos["szi"] as? String,
                  let szi = Double(sziStr),
                  szi != 0,
                  let entryStr = pos["entryPx"] as? String,
                  let entry = Double(entryStr)
            else { return nil }

            let mark   = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
            let pnl    = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
            let liqPx  = (pos["liquidationPx"] as? String).flatMap(Double.init)
            let levVal = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
            let isCross = ((pos["leverage"] as? [String: Any])?["type"] as? String ?? "cross") == "cross"
            let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0

            let funding = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String
            let cumulFunding = funding.flatMap(Double.init) ?? 0

            return PerpPosition(
                coin: coin,
                size: szi,
                entryPrice: entry,
                markPrice: mark / max(abs(szi), 0.000001),
                unrealizedPnl: pnl,
                leverage: levVal,
                isCross: isCross,
                marginUsed: marginUsed,
                liquidationPx: liqPx,
                cumulativeFunding: cumulFunding,
                szDecimals: MarketsViewModel.szDecimals(for: coin)
            )
        }
    }

    /// Parse HIP-3 positions and APPEND to existing positions array.
    private func parseHIP3Positions(from state: [String: Any]) {
        guard let assetPositions = state["assetPositions"] as? [[String: Any]] else { return }
        let hip3Positions: [PerpPosition] = assetPositions.compactMap { wrapper in
            guard let pos = wrapper["position"] as? [String: Any],
                  let coin = pos["coin"] as? String,
                  let sziStr = pos["szi"] as? String,
                  let szi = Double(sziStr),
                  szi != 0,
                  let entryStr = pos["entryPx"] as? String,
                  let entry = Double(entryStr)
            else { return nil }

            let mark   = (pos["positionValue"] as? String).flatMap(Double.init) ?? 0
            let pnl    = (pos["unrealizedPnl"] as? String).flatMap(Double.init) ?? 0
            let liqPx  = (pos["liquidationPx"] as? String).flatMap(Double.init)
            let levVal = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
            let isCross = ((pos["leverage"] as? [String: Any])?["type"] as? String ?? "cross") == "cross"
            let marginUsed = (pos["marginUsed"] as? String).flatMap(Double.init) ?? 0

            let funding = (pos["cumFunding"] as? [String: Any])?["sinceOpen"] as? String
            let cumulFunding = funding.flatMap(Double.init) ?? 0

            // HIP-3 coins come as "dex:COIN" — strip the prefix for display
            let displayCoin = coin.contains(":") ? String(coin.split(separator: ":").last ?? Substring(coin)) : coin

            return PerpPosition(
                coin: displayCoin,
                size: szi,
                entryPrice: entry,
                markPrice: mark / max(abs(szi), 0.000001),
                unrealizedPnl: pnl,
                leverage: levVal,
                isCross: isCross,
                marginUsed: marginUsed,
                liquidationPx: liqPx,
                cumulativeFunding: cumulFunding,
                szDecimals: MarketsViewModel.szDecimals(for: coin)
            )
        }
        positions.append(contentsOf: hip3Positions)
    }

    private func parseOrders(from state: [String: Any]) {
        guard let raw = state["openOrders"] as? [[String: Any]] else { return }
        openOrders = raw.compactMap { o in
            guard let coin  = o["coin"] as? String,
                  let side  = o["side"] as? String,
                  let pxStr = o["limitPx"] as? String,
                  let px    = Double(pxStr),
                  let szStr = o["sz"] as? String,
                  let sz    = Double(szStr),
                  let oid   = o["oid"] as? Int,
                  let timeMs = o["timestamp"] as? Int64
            else { return nil }
            let orderT = (o["orderType"] as? String) ?? "Limit"
            return OpenOrder(oid: oid, coin: coin, side: side,
                             price: px, size: sz,
                             timestamp: Date(timeIntervalSince1970: Double(timeMs) / 1000),
                             orderType: orderT)
        }
    }

    private func parseFills(_ raw: [[String: Any]]) {
        fills = raw.compactMap { f in
            guard let coin  = f["coin"] as? String,
                  let pxStr = f["px"] as? String,   let px  = Double(pxStr),
                  let szStr = f["sz"] as? String,   let sz  = Double(szStr),
                  let side  = f["side"] as? String,
                  let timeMs = f["time"] as? Int64 ?? (f["time"] as? NSNumber)?.int64Value
            else { return nil }
            let dir = f["dir"] as? String ?? (side == "B" ? "Buy" : "Sell")
            let closedPnl = Self.parseDouble(f["closedPnl"])
            let fee       = Self.parseDouble(f["fee"])
            return UserFill(coin: coin, price: px, size: sz, side: side,
                            time: Date(timeIntervalSince1970: Double(timeMs) / 1000),
                            closedPnl: closedPnl, fee: fee, dir: dir)
        }
        .sorted { $0.time > $1.time }
    }

    /// Parse a value that may be a String, Double, or NSNumber.
    private static func parseDouble(_ value: Any?) -> Double {
        if let s = value as? String, let v = Double(s) { return v }
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        return 0
    }

    private func parseSpot(_ raw: [String: Any]) {
        guard let balances = raw["balances"] as? [[String: Any]] else { return }
        spotBalances = balances.compactMap { b in
            guard let coin  = b["coin"] as? String,
                  let totStr = b["total"] as? String,
                  let total  = Double(totStr),
                  total > 0
            else { return nil }
            // USD value estimation — real app would use live prices
            let usdEstimate = estimateUSD(coin: coin, amount: total)
            let entryNtl = Self.parseDouble(b["entryNtl"])
            return SpotBalance(coin: coin, total: total, usdValue: usdEstimate, entryNtl: entryNtl)
        }
        .sorted { $0.usdValue > $1.usdValue }
    }

    private func computeOverview() {
        let closedFills = fills.filter { $0.isClose }
        totalPnl    = closedFills.reduce(0) { $0 + $1.closedPnl }
        totalVolume = fills.reduce(0) { $0 + $1.price * $1.size }
        bestTrade   = closedFills.map(\.closedPnl).max() ?? 0

        let winners = closedFills.filter { $0.closedPnl > 0 }.count
        winrate     = closedFills.isEmpty ? 0 : Double(winners) / Double(closedFills.count)

        // Add unrealized PnL from open positions
        totalPnl   += positions.reduce(0) { $0 + $1.unrealizedPnl }
    }

    // MARK: - Transaction parsing

    private func parseTransactions(_ raw: [[String: Any]]) {
        transactions = raw.compactMap({ entry -> WalletTransaction? in
            guard let timeMs = entry["time"] as? Int64 ?? (entry["time"] as? NSNumber)?.int64Value,
                  let delta = entry["delta"] as? [String: Any],
                  let typeStr = delta["type"] as? String
            else { return nil }

            let hash = (entry["hash"] as? String) ?? ""
            let date = Date(timeIntervalSince1970: Double(timeMs) / 1000)

            switch typeStr {
            case "deposit":
                let usdc = delta["usdc"] as? String ?? "0"
                return WalletTransaction(time: date, type: .deposit,
                                         amount: "\(formatNum(usdc)) USDC", amountUSD: nil, detail: "Bridge deposit", hash: hash)

            case "withdraw":
                let usdc = delta["usdc"] as? String ?? "0"
                let fee = delta["fee"] as? String ?? "0"
                return WalletTransaction(time: date, type: .withdraw,
                                         amount: "\(formatNum(usdc)) USDC", amountUSD: nil, detail: "Fee: \(fee) USDC", hash: hash)

            case "internalTransfer":
                let usdc = delta["usdc"] as? String ?? "0"
                let dest = shortAddr(delta["destination"] as? String)
                return WalletTransaction(time: date, type: .internalTransfer,
                                         amount: "\(formatNum(usdc)) USDC", amountUSD: nil, detail: "To \(dest)", hash: hash)

            case "spotTransfer":
                let token = delta["token"] as? String ?? "?"
                let amt = delta["amount"] as? String ?? "0"
                let dest = shortAddr(delta["destination"] as? String)
                return WalletTransaction(time: date, type: .spotTransfer,
                                         amount: "\(formatNum(amt)) \(token)", amountUSD: nil, detail: "To \(dest)", hash: hash)

            case "accountClassTransfer":
                let usdc = delta["usdc"] as? String ?? "0"
                let toPerp = delta["toPerp"] as? Bool ?? true
                let dir = toPerp ? "Spot → Perp" : "Perp → Spot"
                return WalletTransaction(time: date, type: .accountClassTransfer,
                                         amount: "\(formatNum(usdc)) USDC", amountUSD: nil, detail: dir, hash: hash)

            case "cStakingTransfer":
                let token = delta["token"] as? String ?? "HYPE"
                let amt = delta["amount"] as? String ?? "0"
                let isDeposit = delta["isDeposit"] as? Bool ?? true
                let detail = isDeposit ? "Delegated" : "Undelegated"
                return WalletTransaction(time: date, type: .staking,
                                         amount: "\(formatNum(amt)) \(token)", amountUSD: nil, detail: detail, hash: hash)

            case "spotGenesis":
                let token = delta["token"] as? String ?? "?"
                let amt = delta["amount"] as? String ?? "0"
                return WalletTransaction(time: date, type: .airdrop,
                                         amount: "\(formatNum(amt)) \(token)", amountUSD: nil, detail: "Genesis airdrop", hash: hash)

            default:
                return nil
            }
        }).sorted { $0.time > $1.time }
        txParsedLedgerCount = transactions.count
    }

    private func mergeFillsIntoTransactions() {
        let fillTxs: [WalletTransaction] = fills.map { fill in
            let txType: WalletTransaction.TxType
            switch fill.dir {
            case "Open Long":    txType = .openLong
            case "Close Long":   txType = .closeLong
            case "Open Short":   txType = .openShort
            case "Close Short":  txType = .closeShort
            default:             txType = fill.isBuy ? .buy : .sell
            }

            let coin = resolvedCoinName(fill.coin)

            let sizeStr = fill.size >= 1_000
                ? String(format: "%.2f", fill.size)
                : String(format: "%.4f", fill.size)

            let usdVal = fill.size * fill.price
            let amount = formatUSDValue(usdVal)
            let amountUSD = "\(sizeStr) \(coin)"

            var detail = "\(coin) @\(formatPrice(fill.price))"
            if fill.closedPnl != 0 {
                let sign = fill.closedPnl >= 0 ? "+" : ""
                detail += " · PnL \(sign)$\(String(format: "%.2f", fill.closedPnl))"
            }

            return WalletTransaction(
                time: fill.time, type: txType,
                amount: amount, amountUSD: amountUSD,
                detail: detail, hash: ""
            )
        }

        transactions.append(contentsOf: fillTxs)
        transactions.sort { $0.time > $1.time }
    }

    // MARK: - Load More Transactions (explicit, LARP-style)

    /// Called by "Load More" button — fetches the next page of fills from HL API
    /// using a time cursor (oldest fill timestamp), then appends to transactions.
    func loadMoreTransactions() async {
        guard !txIsLoadingMore else { return }
        let address = txLoadAddress
        guard !address.isEmpty else { return }

        // Step 1: If we already have more parsed transactions than displayed, just reveal them
        if transactions.count > txDisplayLimit {
            txDisplayLimit += 50
            return
        }

        // Step 2: Fetch older fills from HL API using time-based cursor
        guard fills.count < txTotalFills else {
            // No more fills to fetch — just bump the display limit for any remaining ledger tx
            txDisplayLimit += 50
            return
        }

        txIsLoadingMore = true
        defer { txIsLoadingMore = false }

        let oldestFillMs = fills.map { Int64($0.time.timeIntervalSince1970 * 1000) }.min() ?? 0
        guard oldestFillMs > 0 else { return }

        // Fetch fills ending before our oldest
        let endMs = oldestFillMs - 1
        let startMs = endMs - 30 * 86400 * 1000  // 30 day window

        guard let data = try? await api.post(body: [
            "type": "userFillsByTime",
            "user": address,
            "startTime": Int(startMs),
            "endTime": Int(endMs),
            "aggregateByTime": false
        ] as [String: Any]) else { return }

        let rawPage = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []

        if rawPage.isEmpty {
            // No more fills — mark total as loaded
            txTotalFills = fills.count
            txDisplayLimit += 50
            return
        }

        // Parse new fills (dedup by time+coin+size)
        let existingKeys = Set(fills.map { "\($0.time.timeIntervalSince1970)-\($0.coin)-\($0.size)" })
        let newFills: [UserFill] = rawPage.compactMap { f in
            guard let coin  = f["coin"] as? String,
                  let pxStr = f["px"] as? String,   let px  = Double(pxStr),
                  let szStr = f["sz"] as? String,   let sz  = Double(szStr),
                  let side  = f["side"] as? String,
                  let timeMs = f["time"] as? Int64 ?? (f["time"] as? NSNumber)?.int64Value
            else { return nil }
            let t = Date(timeIntervalSince1970: Double(timeMs) / 1000)
            let key = "\(t.timeIntervalSince1970)-\(coin)-\(sz)"
            guard !existingKeys.contains(key) else { return nil }
            let dir = f["dir"] as? String ?? (side == "B" ? "Buy" : "Sell")
            let closedPnl = Self.parseDouble(f["closedPnl"])
            let fee       = Self.parseDouble(f["fee"])
            return UserFill(coin: coin, price: px, size: sz, side: side,
                            time: t, closedPnl: closedPnl, fee: fee, dir: dir)
        }

        if !newFills.isEmpty {
            fills.append(contentsOf: newFills)
            fills.sort { $0.time > $1.time }

            // Convert new fills to transactions and append
            let newTxs: [WalletTransaction] = newFills.map { fill in
                let txType: WalletTransaction.TxType
                switch fill.dir {
                case "Open Long":    txType = .openLong
                case "Close Long":   txType = .closeLong
                case "Open Short":   txType = .openShort
                case "Close Short":  txType = .closeShort
                default:             txType = fill.isBuy ? .buy : .sell
                }
                let coin = resolvedCoinName(fill.coin)
                let sizeStr = fill.size >= 1_000
                    ? String(format: "%.2f", fill.size)
                    : String(format: "%.4f", fill.size)
                let usdVal = fill.size * fill.price
                let amount = formatUSDValue(usdVal)
                let amountUSD = "\(sizeStr) \(coin)"
                var detail = "\(coin) @\(formatPrice(fill.price))"
                if fill.closedPnl != 0 {
                    let sign = fill.closedPnl >= 0 ? "+" : ""
                    detail += " · PnL \(sign)$\(String(format: "%.2f", fill.closedPnl))"
                }
                return WalletTransaction(
                    time: fill.time, type: txType,
                    amount: amount, amountUSD: amountUSD,
                    detail: detail, hash: ""
                )
            }
            transactions.append(contentsOf: newTxs)
            transactions.sort { $0.time > $1.time }
            computeOverview()
        }

        txDisplayLimit += 50
    }

    private func formatUSDValue(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "$%.1fK", v / 1_000) }
        return String(format: "$%.2f", v)
    }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "$%.1f", p) }
        if p >= 1      { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }

    // MARK: - Spot token name resolution

    private func loadSpotTokenNames() async {
        guard Self.spotTokenNames == nil else { return }
        do {
            let data = try await api.post(body: ["type": "spotMetaAndAssetCtxs"])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let metaDict = root.first as? [String: Any],
                  let tokensRaw = metaDict["tokens"] as? [[String: Any]],
                  let universeRaw = metaDict["universe"] as? [[String: Any]]
            else { return }

            // Step 1: token name by array position (used by pair.tokens references)
            var tokenNameByPos: [Int: String] = [:]
            for (pos, t) in tokensRaw.enumerated() {
                if let name = t["name"] as? String {
                    tokenNameByPos[pos] = name
                }
            }

            // Step 2: map @{pairIndex} → base token name
            // Fills use @{pairIndex} as coin, so we need pair index → base name
            var map: [String: String] = [:]
            for pair in universeRaw {
                guard let tokens = pair["tokens"] as? [Int],
                      tokens.count >= 2,
                      let baseName = tokenNameByPos[tokens[0]]
                else { continue }
                if let idx = pair["index"] as? Int {
                    map["@\(idx)"] = baseName
                } else if let idx = (pair["index"] as? NSNumber)?.intValue {
                    map["@\(idx)"] = baseName
                }
            }
            Self.spotTokenNames = map
        } catch {
            // Non-critical — coins will just show @index
        }
    }

    /// Resolves "@182" → "HYPE", passes through normal coin names unchanged
    private func resolvedCoinName(_ coin: String) -> String {
        if coin.hasPrefix("@"), let name = Self.spotTokenNames?[coin] {
            return name
        }
        return coin
    }

    // MARK: - Alias resolution (Hypurrscan)

    private static let customAliasesKey = "customWalletAliases"

    private func resolveAlias(for address: String) async {
        // Check custom alias first
        let key = address.lowercased()
        if let custom = Self.loadCustomAliases()[key] {
            alias = custom
            return
        }
        // Fetch global aliases once, then cache
        if Self.globalAliases == nil {
            Self.globalAliases = await fetchGlobalAliases()
        }
        alias = Self.globalAliases?[key]
    }

    func setCustomAlias(_ name: String, for address: String) {
        var aliases = Self.loadCustomAliases()
        let key = address.lowercased()
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aliases.removeValue(forKey: key)
        } else {
            aliases[key] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        UserDefaults.standard.set(aliases, forKey: Self.customAliasesKey)
        alias = aliases[key] ?? Self.globalAliases?[key]
    }

    private static func loadCustomAliases() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: customAliasesKey) as? [String: String] ?? [:]
    }

    private func fetchGlobalAliases() async -> [String: String] {
        guard let url = URL(string: "https://api.hypurrscan.io/globalAliases") else { return [:] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
            // Normalize keys to lowercase for case-insensitive lookup
            return Dictionary(uniqueKeysWithValues: dict.map { ($0.key.lowercased(), $0.value) })
        } catch {
            return [:]
        }
    }

    // MARK: - Staking parsing

    private func parseStaking(summary: [String: Any], delegations: [[String: Any]], rewards: [[String: Any]]) {
        var s = StakingSummary()

        s.delegated = Double(summary["delegated"] as? String ?? "0") ?? 0
        s.undelegated = Double(summary["undelegated"] as? String ?? "0") ?? 0
        s.pendingWithdrawal = Double(summary["totalPendingWithdrawal"] as? String ?? "0") ?? 0

        s.delegations = delegations.compactMap { d -> StakingDelegation? in
            guard let validator = d["validator"] as? String,
                  let amtStr = d["amount"] as? String,
                  let amt = Double(amtStr)
            else { return nil }
            let lockTs = d["lockedUntilTimestamp"] as? Int64 ?? (d["lockedUntilTimestamp"] as? NSNumber)?.int64Value
            let lockDate = lockTs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            // Use backend-enriched name first, then cached validator names, then short address
            let name = (d["validatorName"] as? String) ?? validatorName(for: validator)
            return StakingDelegation(validator: validator, validatorName: name, amount: amt, lockedUntil: lockDate)
        }

        s.rewards = rewards.compactMap { r -> StakingReward? in
            guard let timeMs = r["time"] as? Int64 ?? (r["time"] as? NSNumber)?.int64Value,
                  let source = r["source"] as? String,
                  let amtStr = r["totalAmount"] as? String,
                  let amt = Double(amtStr)
            else { return nil }
            return StakingReward(time: Date(timeIntervalSince1970: Double(timeMs) / 1000),
                                 source: source, amount: amt)
        }
        .sorted { $0.time > $1.time }

        s.totalRewards = s.rewards.reduce(0) { $0 + $1.amount }
        staking = s
    }

    // MARK: - Formatting helpers

    private func formatNum(_ s: String) -> String {
        guard let v = Double(s) else { return s }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = v >= 100 ? 2 : 4
        fmt.minimumFractionDigits = 2
        return fmt.string(from: NSNumber(value: v)) ?? s
    }

    private func shortAddr(_ addr: String?) -> String {
        guard let a = addr, a.count > 10 else { return addr ?? "?" }
        return "\(a.prefix(6))…\(a.suffix(4))"
    }

    private func validatorName(for address: String) -> String {
        if let name = Self.validatorNames?[address.lowercased()], !name.isEmpty {
            return name
        }
        return shortAddr(address)
    }

    /// Fetch validator names from backend /validators endpoint (or direct HL API).
    private static func loadValidatorNames() async {
        // Try backend first
        if let url = URL(string: "https://hyperview-backend-production-075c.up.railway.app/validators") {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let validators = json["validators"] as? [String: Any] {
                    var map: [String: String] = [:]
                    for (addr, info) in validators {
                        if let dict = info as? [String: Any], let name = dict["name"] as? String {
                            map[addr.lowercased()] = name
                        } else if let name = info as? String {
                            map[addr.lowercased()] = name
                        }
                    }
                    if !map.isEmpty {
                        await MainActor.run { validatorNames = map }
                        return
                    }
                }
            } catch { /* fall through to HL API */ }
        }

        // Fallback: direct HL API
        do {
            let body: [String: String] = ["type": "validatorSummaries"]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            var request = URLRequest(url: URL(string: "https://api.hyperliquid.xyz/info")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            let (data, _) = try await URLSession.shared.data(for: request)
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var map: [String: String] = [:]
                for v in arr {
                    if let addr = v["validator"] as? String, let name = v["name"] as? String {
                        map[addr.lowercased()] = name
                    }
                }
                if !map.isEmpty {
                    await MainActor.run { validatorNames = map }
                }
            }
        } catch { /* silent */ }
    }

    /// Spot coin name → perp/allMids name mapping (matches Market.spotNameMap)
    private static let spotToPerpName: [String: String] = [
        "UBTC": "BTC", "UETH": "ETH", "USOL": "SOL",
        "UFART": "FARTCOIN", "UPUMP": "PUMP", "HPENGU": "PENGU",
        "UBONK": "BONK", "UENA": "ENA", "UMON": "MON",
        "UZEC": "ZEC", "MMOVE": "MOVE", "UDZ": "DZ",
    ]

    /// Shared mid price cache — populated on each wallet load
    static var midPriceCache: [String: Double] = [:]

    /// USD value estimation using live mid prices from allMids.
    private func estimateUSD(coin: String, amount: Double) -> Double {
        if coin == "USDC" || coin == "USDH" || coin == "USDT" { return amount }
        let priceCoin = Self.spotToPerpName[coin] ?? coin
        if let price = Self.midPriceCache[priceCoin], price > 0 {
            return amount * price
        }
        return 0
    }

    /// Fetch all mid prices and cache them for USD valuation.
    func fetchMidPrices() async {
        let body: [String: Any] = ["type": "allMids"]
        guard let data = try? await HyperliquidAPI.shared.post(
            url: URL(string: "https://api.hyperliquid.xyz/info")!,
            body: body
        ),
              let mids = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        var prices: [String: Double] = [:]
        for (coin, priceStr) in mids {
            if let p = Double(priceStr) { prices[coin] = p }
        }
        Self.midPriceCache = prices
    }
}

// MARK: - HyperliquidAPI extensions for wallet detail

extension HyperliquidAPI {

    func fetchUserFills(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: [
            "type": "userFills",
            "user": address,
            "aggregateByTime": false
        ])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Fetches fills using time-based endpoint, falls back to userFills if empty
    func fetchUserFillsByTime(address: String) async throws -> [[String: Any]] {
        let startTime = Int(Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970 * 1000)
        let data = try await post(body: [
            "type": "userFillsByTime",
            "user": address,
            "startTime": startTime,
            "aggregateByTime": false
        ] as [String: Any])
        let fills = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        if !fills.isEmpty { return fills }

        // Fallback to regular userFills
        let fallbackData = try await post(body: [
            "type": "userFills",
            "user": address,
            "aggregateByTime": false
        ])
        return (try? JSONSerialization.jsonObject(with: fallbackData) as? [[String: Any]]) ?? []
    }

    func fetchSpotState(address: String) async throws -> [String: Any] {
        let data = try await post(body: [
            "type": "spotClearinghouseState",
            "user": address
        ])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Transactions (ledger updates)

    func fetchLedgerUpdates(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: [
            "type": "userNonFundingLedgerUpdates",
            "user": address,
            "startTime": 0
        ] as [String: Any])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    // MARK: - Staking

    func fetchDelegatorSummary(address: String) async throws -> [String: Any] {
        let data = try await post(body: ["type": "delegatorSummary", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func fetchDelegations(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: ["type": "delegations", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    func fetchDelegatorRewards(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: ["type": "delegatorRewards", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    func fetchDelegatorHistory(address: String) async throws -> [[String: Any]] {
        let data = try await post(body: ["type": "delegatorHistory", "user": address])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }
}
