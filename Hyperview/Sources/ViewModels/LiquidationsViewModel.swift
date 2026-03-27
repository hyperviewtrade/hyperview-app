import SwiftUI
import Combine
import UserNotifications

// MARK: - Notification Rule

enum LiqDirection: String, Codable, CaseIterable {
    case both  = "Both"
    case long  = "Long"
    case short = "Short"

    var label: String { rawValue }
    var icon: String {
        switch self {
        case .both:  return "arrow.up.arrow.down"
        case .long:  return "arrow.up.right"
        case .short: return "arrow.down.right"
        }
    }
}

struct NotificationRule: Identifiable, Codable, Equatable {
    let id: String
    let coin: String
    let minSize: Double
    let direction: LiqDirection

    init(coin: String, minSize: Double, direction: LiqDirection = .both) {
        self.id = UUID().uuidString
        self.coin = coin
        self.minSize = minSize
        self.direction = direction
    }

    var formattedMinSize: String {
        if minSize >= 1_000_000 { return String(format: "$%.1fM", minSize / 1_000_000) }
        if minSize >= 1_000 {
            let k = minSize / 1_000
            return k == k.rounded() ? String(format: "$%.0fK", k) : String(format: "$%.1fK", k)
        }
        return String(format: "$%.0f", minSize)
    }
}

// MARK: - ViewModel

@MainActor
final class LiquidationsViewModel: ObservableObject {
    static let shared = LiquidationsViewModel()
    @Published var liquidations: [LiquidationItem] = []
    @Published var availableCoins: [String] = []
    @Published var allPerps: [String] = []
    @Published var perpVolumes: [String: Double] = [:]
    @Published var selectedCoins: Set<String> = []   // empty = All markets
    @Published var selectedSide: String = "All"
    @Published var minSize: String = "1,000"
    @Published var maxSize: String = ""
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var totalFiltered = 0               // total matching items in backend history
    @Published var notificationRules: [NotificationRule] = []
    @Published var showNotificationSettings = false
    @Published var showMarketPicker = false

    /// True when there are more items in history to load
    var hasMore: Bool { totalFiltered > liquidations.count }

    private static let backendBaseURL = Configuration.backendBaseURL
    private var pollTimer: AnyCancellable?
    private var backgroundPollTimer: AnyCancellable?
    private var notifiedIds: Set<String> = []
    private var isViewVisible = false
    /// Timestamp of newest liquidation — used for delta polling (since=)
    private var newestTimestamp: Double = 0

    init() {
        loadNotificationRules()
        notifiedIds = LiquidationNotificationService.shared.loadPersistedNotifiedIds()
        // Start background polling for notifications (if rules exist)
        startBackgroundPollingIfNeeded()
    }

    // MARK: - Polling

    /// Fast polling when the Liquidations view is visible (every 15s)
    func startPolling() {
        isViewVisible = true
        stopBackgroundPolling()
        guard pollTimer == nil else { return }
        Task { await fetch() }
        Task { await fetchAllPerps() }

        pollTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.fetch() }
            }
    }

    /// Stop fast polling when leaving the view, resume background polling for notifs
    func stopPolling() {
        isViewVisible = false
        pollTimer?.cancel()
        pollTimer = nil
        startBackgroundPollingIfNeeded()
    }

    /// Background polling (every 30s) for notification checks — battery-friendly
    private func startBackgroundPollingIfNeeded() {
        guard backgroundPollTimer == nil, !notificationRules.isEmpty else { return }
        backgroundPollTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isViewVisible else { return }
                Task { await self.fetch() }
            }
    }

    private func stopBackgroundPolling() {
        backgroundPollTimer?.cancel()
        backgroundPollTimer = nil
    }

    /// Call when notification rules change to start/stop background polling
    func onNotificationRulesChanged() {
        if notificationRules.isEmpty {
            stopBackgroundPolling()
        } else if !isViewVisible && backgroundPollTimer == nil {
            startBackgroundPollingIfNeeded()
        }
    }

    /// Label shown on the market picker button
    var selectedCoinsLabel: String {
        if selectedCoins.isEmpty { return "All" }
        if selectedCoins.count == 1 { return selectedCoins.first! }
        return "\(selectedCoins.count) Markets"
    }

    func toggleCoin(_ coin: String) {
        if selectedCoins.contains(coin) {
            selectedCoins.remove(coin)
        } else {
            selectedCoins.insert(coin)
        }
        Task { await fetchFirstPage() }
    }

    func selectAllMarkets() {
        selectedCoins.removeAll()
        Task { await fetchFirstPage() }
    }

    // MARK: - Fetch (3 modes: first page, delta poll, load more)

    /// Build common query items for current filter state.
    private func filterQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !selectedCoins.isEmpty {
            for coin in selectedCoins.sorted() {
                items.append(URLQueryItem(name: "coin", value: coin))
            }
        }
        if selectedSide != "All" {
            items.append(URLQueryItem(name: "side", value: selectedSide.lowercased()))
        }
        if let min = Double(stripCommas(minSize)), min > 0 {
            items.append(URLQueryItem(name: "minSize", value: String(min)))
        }
        if let max = Double(stripCommas(maxSize)), max > 0 {
            items.append(URLQueryItem(name: "maxSize", value: String(max)))
        }
        return items
    }

    /// First page load — replaces the list, resets pagination state.
    private func fetchFirstPage() async {
        newestTimestamp = 0
        var components = URLComponents(string: "\(Self.backendBaseURL)/liquidations")!
        var queryItems = filterQueryItems()
        queryItems.append(URLQueryItem(name: "limit", value: "30"))
        components.queryItems = queryItems
        guard let url = components.url else { return }

        print("[LIQ] FIRST PAGE REQUEST: \(url.absoluteString)")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LiquidationsResponse.self, from: data)

            checkNotifications(response.liquidations)
            liquidations = response.liquidations
            totalFiltered = response.total ?? response.liquidations.count

            if let newest = liquidations.first?.timestamp {
                newestTimestamp = newest
            }
            if let coins = response.availableCoins, !coins.isEmpty {
                availableCoins = ["All"] + coins
            }

            let minUSD = liquidations.map(\.sizeUSD).min() ?? 0
            let maxUSD = liquidations.map(\.sizeUSD).max() ?? 0
            print("[LIQ] FIRST PAGE: count=\(liquidations.count) total=\(totalFiltered) hasMore=\(hasMore) minUSD=\(minUSD) maxUSD=\(maxUSD)")
        } catch {
            print("[LIQ] FIRST PAGE DECODE ERROR: \(error)")
        }
    }

    /// Delta poll — only fetches items newer than what we have.
    /// Called by the 15s/30s timer. Small payload, no pagination.
    func fetch() async {
        // If no data yet, do a first page load instead
        guard newestTimestamp > 0 else {
            await fetchFirstPage()
            return
        }

        var components = URLComponents(string: "\(Self.backendBaseURL)/liquidations")!
        var queryItems = filterQueryItems()
        queryItems.append(URLQueryItem(name: "since", value: String(Int64(newestTimestamp))))
        queryItems.append(URLQueryItem(name: "limit", value: "50"))
        components.queryItems = queryItems
        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LiquidationsResponse.self, from: data)

            checkNotifications(response.liquidations)

            if !response.liquidations.isEmpty {
                // Prepend new items at the top, dedup by id
                let existingIds = Set(liquidations.map(\.id))
                let fresh = response.liquidations.filter { !existingIds.contains($0.id) }
                if !fresh.isEmpty {
                    liquidations = fresh + liquidations
                    totalFiltered += fresh.count
                }
            }

            if let newest = liquidations.first?.timestamp, newest > newestTimestamp {
                newestTimestamp = newest
            }
        } catch {
            // Silently fail — will retry on next poll
        }
    }

    /// Load more — fetches older items using before= cursor.
    func loadMore() async {
        print("[LIQ] LOAD MORE: hasMore=\(hasMore) isLoadingMore=\(isLoadingMore) count=\(liquidations.count) totalFiltered=\(totalFiltered)")
        guard !isLoadingMore, hasMore else {
            print("[LIQ] LOAD MORE GUARD FAILED: isLoadingMore=\(isLoadingMore) hasMore=\(hasMore)")
            return
        }
        guard let oldestTs = liquidations.last?.timestamp else {
            print("[LIQ] LOAD MORE: no oldest timestamp")
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        var components = URLComponents(string: "\(Self.backendBaseURL)/liquidations")!
        var queryItems = filterQueryItems()
        queryItems.append(URLQueryItem(name: "before", value: String(Int64(oldestTs))))
        queryItems.append(URLQueryItem(name: "limit", value: "30"))
        components.queryItems = queryItems
        guard let url = components.url else { return }

        print("[LIQ] LOAD MORE REQUEST: before=\(Int64(oldestTs)) url=\(url.absoluteString)")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(LiquidationsResponse.self, from: data)

            print("[LIQ] LOAD MORE RESPONSE: count=\(response.liquidations.count) total=\(response.total ?? -1)")
            if !response.liquidations.isEmpty {
                let existingIds = Set(liquidations.map(\.id))
                let older = response.liquidations.filter { !existingIds.contains($0.id) }
                liquidations.append(contentsOf: older)
                print("[LIQ] LOAD MORE APPENDED: \(older.count) new items, total=\(liquidations.count)")
            }
            // Stop pagination if server returned fewer items than requested (end of data)
            if response.liquidations.count < 30 {
                totalFiltered = liquidations.count
                print("[LIQ] LOAD MORE: reached end of data, totalFiltered=\(totalFiltered)")
            }
        } catch {
            print("[LIQ] LOAD MORE DECODE ERROR: \(error)")
        }
    }

    private func checkNotifications(_ items: [LiquidationItem]) {
        guard !notificationRules.isEmpty else { return }
        let newOnes = items.filter { !notifiedIds.contains($0.id) }
        for liq in newOnes {
            notifiedIds.insert(liq.id)
            if matchesAnyRule(liq) {
                sendLocalNotification(liq)
            }
        }
        if notifiedIds.count > 500 {
            let currentIds = Set(items.map(\.id))
            notifiedIds = notifiedIds.intersection(currentIds)
        }
        LiquidationNotificationService.shared.persistNotifiedIds(notifiedIds)
    }

    // MARK: - All Perp Markets (main DEX + HIP-3)

    func fetchAllPerps() async {
        var volumes: [String: Double] = [:]
        var coins: [String] = []

        // Main DEX
        if let (mainCoins, mainVols) = await self.fetchDexMarkets(dex: nil) {
            coins.append(contentsOf: mainCoins)
            volumes.merge(mainVols) { _, new in new }
        }

        // HIP-3 markets
        let hip3Dexes = await self.fetchHIP3Dexes()
        for dex in hip3Dexes {
            if let (dexCoins, dexVols) = await self.fetchDexMarkets(dex: dex) {
                for coin in dexCoins where !coins.contains(coin) {
                    coins.append(coin)
                }
                volumes.merge(dexVols) { _, new in new }
            }
        }

        // Sort by 24h volume descending
        coins.sort { (volumes[$0] ?? 0) > (volumes[$1] ?? 0) }
        allPerps = coins
        perpVolumes = volumes
    }

    /// Fetch markets for a specific DEX (nil = main DEX)
    private nonisolated func fetchDexMarkets(dex: String?) async -> ([String], [String: Double])? {
        let apiURL = URL(string: "https://api.hyperliquid.xyz/info")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["type": "metaAndAssetCtxs"]
        if let dex = dex { body["dex"] = dex }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 2,
                  let meta = arr[0] as? [String: Any],
                  let universe = meta["universe"] as? [[String: Any]],
                  let assetCtxs = arr[1] as? [[String: Any]] else { return nil }

            var coins: [String] = []
            var volumes: [String: Double] = [:]

            for (i, asset) in universe.enumerated() {
                guard let name = asset["name"] as? String else { continue }
                let displayName = name
                coins.append(displayName)
                if i < assetCtxs.count,
                   let volStr = assetCtxs[i]["dayNtlVlm"] as? String,
                   let vol = Double(volStr) {
                    volumes[displayName] = vol
                }
            }
            return (coins, volumes)
        } catch {
            return nil
        }
    }

    /// Fetch list of HIP-3 DEX names via HyperliquidAPI
    private func fetchHIP3Dexes() async -> [String] {
        await HyperliquidAPI.shared.fetchPerpDexNames()
    }

    // MARK: - Notification Rules

    private func matchesAnyRule(_ liq: LiquidationItem) -> Bool {
        for rule in notificationRules {
            guard rule.coin == liq.coin && liq.sizeUSD >= rule.minSize else { continue }
            switch rule.direction {
            case .both:  return true
            case .long:  if liq.isLong { return true }
            case .short: if !liq.isLong { return true }
            }
        }
        return false
    }

    func addRule(coin: String, minSize: Double, direction: LiqDirection = .both) {
        // Remove existing rule for same coin
        notificationRules.removeAll { $0.coin == coin }
        let rule = NotificationRule(coin: coin, minSize: minSize, direction: direction)
        notificationRules.append(rule)
        saveNotificationRules()

        // Request notification permission if first rule
        if notificationRules.count == 1 {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        onNotificationRulesChanged()
    }

    func removeRule(_ rule: NotificationRule) {
        notificationRules.removeAll { $0.id == rule.id }
        saveNotificationRules()
        onNotificationRulesChanged()
    }

    private func sendLocalNotification(_ liq: LiquidationItem) {
        let content = UNMutableNotificationContent()
        content.title = "💥 \(liq.coin) \(liq.side) Liquidation"
        content.body = "\(liq.formattedSize) liquidated @ $\(String(format: "%.2f", liq.price))"
        content.sound = .default
        content.userInfo = ["walletAddress": liq.address, "type": "liquidation"]

        let request = UNNotificationRequest(
            identifier: liq.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func saveNotificationRules() {
        if let data = try? JSONEncoder().encode(notificationRules) {
            UserDefaults.standard.set(data, forKey: "liq_notification_rules")
        }
        // Sync rules to backend for real-time push notifications
        Task { await PushRegistrationService.shared.syncRulesToBackend() }
    }

    private func loadNotificationRules() {
        guard let data = UserDefaults.standard.data(forKey: "liq_notification_rules"),
              let rules = try? JSONDecoder().decode([NotificationRule].self, from: data) else { return }
        notificationRules = rules
    }
}

// MARK: - Models

struct LiquidationsResponse: Decodable {
    let count: Int
    let total: Int?                // total matching items in history (for hasMore)
    let liquidations: [LiquidationItem]
    let availableCoins: [String]?  // nil on delta/pagination fetches
}

struct LiquidationItem: Identifiable, Decodable {
    let id: String
    let coin: String
    let address: String
    let side: String           // "LONG" / "SHORT"
    let sizeUSD: Double
    let price: Double
    let entryPrice: Double?
    let leverage: Int?
    let timestamp: Double

    /// Decode both legacy (full field names) and slim (short keys) formats.
    enum CodingKeys: String, CodingKey {
        // Slim keys (new backend)
        case id, c, a, s, usd, px, ep, lev, ts
        // Legacy keys (backward compat)
        case coin, address, side, sizeUSD, price, entryPrice, leverage, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Slim → legacy fallback for each field
        if let v = try? container.decode(String.self, forKey: .c) { coin = v }
        else { coin = try container.decode(String.self, forKey: .coin) }
        if let v = try? container.decode(String.self, forKey: .a) { address = v }
        else { address = try container.decode(String.self, forKey: .address) }
        if let v = try? container.decode(Double.self, forKey: .usd) { sizeUSD = v }
        else { sizeUSD = try container.decode(Double.self, forKey: .sizeUSD) }
        if let v = try? container.decode(Double.self, forKey: .px) { price = v }
        else { price = try container.decode(Double.self, forKey: .price) }
        entryPrice = (try? container.decode(Double.self, forKey: .ep)) ?? (try? container.decode(Double.self, forKey: .entryPrice))
        leverage = (try? container.decode(Int.self, forKey: .lev)) ?? (try? container.decode(Int.self, forKey: .leverage))
        if let v = try? container.decode(Double.self, forKey: .ts) { timestamp = v }
        else { timestamp = try container.decode(Double.self, forKey: .timestamp) }
        // Side: slim uses "L"/"S", legacy uses "LONG"/"SHORT"
        if let slim = try? container.decode(String.self, forKey: .s) {
            side = slim == "L" ? "LONG" : "SHORT"
        } else {
            side = try container.decode(String.self, forKey: .side)
        }
    }

    var shortAddress: String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    var formattedSize: String {
        if sizeUSD >= 1_000_000 { return String(format: "$%.1fM", sizeUSD / 1_000_000) }
        if sizeUSD >= 1_000     { return String(format: "$%.0fK", sizeUSD / 1_000) }
        return String(format: "$%.0f", sizeUSD)
    }

    var formattedPrice: String {
        if price >= 10_000 { return String(format: "$%.1f", price) }
        if price >= 1_000  { return String(format: "$%.2f", price) }
        if price >= 1      { return String(format: "$%.4f", price) }
        if price >= 0.01   { return String(format: "$%.5f", price) }
        return String(format: "$%.8f", price)
    }

    var formattedEntryPrice: String? {
        guard let ep = entryPrice, ep > 0 else { return nil }
        if ep >= 10_000 { return String(format: "$%.1f", ep) }
        if ep >= 1_000  { return String(format: "$%.2f", ep) }
        if ep >= 1      { return String(format: "$%.4f", ep) }
        if ep >= 0.01   { return String(format: "$%.5f", ep) }
        return String(format: "$%.8f", ep)
    }

    var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince1970 - timestamp / 1000)
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var isLong: Bool { side == "LONG" }
}
