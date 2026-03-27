import Foundation
import SwiftUI
import Combine

// MARK: - Model

struct TWAPOrder: Identifiable {
    var id: String { hash.isEmpty ? "\(user)-\(coin)-\(timestamp.timeIntervalSince1970)" : hash }
    let coin: String
    let user: String
    let isBuy: Bool
    let size: Double
    let durationMinutes: Int
    let randomize: Bool
    let reduceOnly: Bool
    let timestamp: Date
    let status: TWAPStatus
    let hash: String
    let isSpot: Bool
    let markPrice: Double?

    enum TWAPStatus {
        case active
        case ended(String)
    }

    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    var shortAddress: String {
        guard user.count > 10 else { return user }
        return "\(user.prefix(6))...\(user.suffix(4))"
    }

    var formattedSize: String {
        if size >= 1_000_000 { return String(format: "%.1fM", size / 1_000_000) }
        if size >= 1_000 { return String(format: "%.0fK", size / 1_000) }
        return String(format: "%.2f", size)
    }

    var formattedDuration: String {
        if durationMinutes >= 1440 {
            let days = durationMinutes / 1440
            let hours = (durationMinutes % 1440) / 60
            if hours == 0 { return "\(days)d" }
            return "\(days)d \(hours)h"
        }
        if durationMinutes >= 60 {
            let hours = durationMinutes / 60
            let mins = durationMinutes % 60
            if mins == 0 { return "\(hours)h" }
            return "\(hours)h \(mins)m"
        }
        return "\(durationMinutes)m"
    }

    /// Progress from 0.0 to 1.0 (elapsed / total duration)
    var progress: Double {
        guard durationMinutes > 0 else { return 1.0 }
        let elapsed = Date().timeIntervalSince(timestamp)
        let total = Double(durationMinutes) * 60
        return min(max(elapsed / total, 0), 1.0)
    }

    /// Remaining time as formatted string
    var remainingTime: String {
        let elapsed = Date().timeIntervalSince(timestamp)
        let total = Double(durationMinutes) * 60
        let remaining = max(total - elapsed, 0)
        if remaining <= 0 { return "Done" }
        let mins = Int(remaining / 60)
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
        }
        return "\(mins)m left"
    }

    /// Remaining size in coins (decreases in real-time)
    var remainingSize: Double {
        return size * (1.0 - progress)
    }

    /// Remaining value in USD (if markPrice available)
    var remainingValueUSD: Double? {
        guard let px = markPrice, px > 0 else { return nil }
        return remainingSize * px
    }

    /// Formatted remaining value (live — updates every second)
    var formattedRemainingValue: String? {
        guard let usd = remainingValueUSD else { return nil }
        if usd >= 10_000_000 { return String(format: "$%.2fM", usd / 1_000_000) }
        if usd >= 1_000_000 { return String(format: "$%.2fM", usd / 1_000_000) }
        if usd >= 10_000 { return String(format: "$%.2fK", usd / 1_000) }
        if usd >= 1_000 { return String(format: "$%.2fK", usd / 1_000) }
        return String(format: "$%.0f", usd)
    }

    /// Total value in USD
    var totalValueUSD: Double? {
        guard let px = markPrice, px > 0 else { return nil }
        return size * px
    }

    var formattedTotalValue: String? {
        guard let usd = totalValueUSD else { return nil }
        if usd >= 1_000_000 { return String(format: "$%.1fM", usd / 1_000_000) }
        if usd >= 1_000 { return String(format: "$%.0fK", usd / 1_000) }
        return String(format: "$%.0f", usd)
    }

    var timeAgo: String {
        let seconds = Int(Date().timeIntervalSince(timestamp))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

enum TWAPSortOption: String, CaseIterable {
    case newest          = "Newest"
    case valueDesc       = "Value ↓"
    case valueAsc        = "Value ↑"
    case progressDesc    = "Progress ↓"
    case progressAsc     = "Progress ↑"
}

// MARK: - ViewModel

enum TWAPMarketFilter: String, CaseIterable {
    case all = "All"
    case perp = "Perp"
    case spot = "Spot"
}

enum TWAPPerpSubFilter: String, CaseIterable {
    case all = "All"
    case crypto = "Crypto"
    case hip3 = "HIP-3"
}

@MainActor
final class TWAPViewModel: ObservableObject {
    static let shared = TWAPViewModel()

    @Published var orders: [TWAPOrder] = []
    @Published var isLoading = false
    /// True once the first successful fetch has completed (distinguishes "not loaded" from "truly empty").
    @Published var hasLoaded = false
    @Published var errorMsg: String?
    @Published var progressText: String?
    @Published var showActiveOnly = true
    @Published var marketFilter: TWAPMarketFilter = .all
    @Published var perpSubFilter: TWAPPerpSubFilter = .all
    @Published var selectedCoin: String = "All"
    @Published var sortOption: TWAPSortOption = .valueDesc
    @Published var availableCoins: [String] = []

    // Buy pressure card (USD values)
    @Published var hypePressure1hUSD: Double = 0
    @Published var hypePressure24hUSD: Double = 0

    private static let backendBase = "https://hyperview-backend-production-075c.up.railway.app"
    private var pollTimer: AnyCancellable?

    var filteredOrders: [TWAPOrder] {
        // Exclude unresolved Asset# entries
        var filtered = orders.filter { !$0.coin.hasPrefix("Asset#") }

        if showActiveOnly {
            filtered = filtered.filter { $0.isActive }
        }

        switch marketFilter {
        case .all: break
        case .perp:
            filtered = filtered.filter { !$0.isSpot }
            switch perpSubFilter {
            case .all: break
            case .crypto: filtered = filtered.filter { !$0.coin.contains(":") }
            case .hip3: filtered = filtered.filter { $0.coin.contains(":") }
            }
        case .spot: filtered = filtered.filter { $0.isSpot }
        }

        if selectedCoin != "All" {
            filtered = filtered.filter { $0.coin == selectedCoin }
        }

        switch sortOption {
        case .newest:
            return filtered.sorted { $0.timestamp > $1.timestamp }
        case .valueDesc:
            return filtered.sorted { ($0.remainingValueUSD ?? 0) > ($1.remainingValueUSD ?? 0) }
        case .valueAsc:
            return filtered.sorted { ($0.remainingValueUSD ?? 0) < ($1.remainingValueUSD ?? 0) }
        case .progressDesc:
            return filtered.sorted { $0.progress > $1.progress }
        case .progressAsc:
            return filtered.sorted { $0.progress < $1.progress }
        }
    }

    var activeBuyCount: Int {
        orders.filter { $0.isActive && $0.isBuy && (selectedCoin == "All" || $0.coin == selectedCoin) }.count
    }
    var activeSellCount: Int {
        orders.filter { $0.isActive && !$0.isBuy && (selectedCoin == "All" || $0.coin == selectedCoin) }.count
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTimer == nil else { return }
        // Don't fetch here — load() already fetched. Just start the timer.
        pollTimer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard UIApplication.shared.applicationState == .active else { return }
                Task { await self?.fetch() }
            }
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    func fetch() async {
        let urlStr = "\(Self.backendBase)/twaps?activeOnly=true&limit=1000"
        let t0 = CFAbsoluteTimeGetCurrent()
        print("[TWAP] FETCH START  hasLoaded=\(hasLoaded) orders=\(orders.count)")

        do {
            guard let url = URL(string: urlStr) else { return }

            // Fetch TWAP list and buy pressure CONCURRENTLY (saves ~1.5s)
            async let twapData = URLSession.shared.data(from: url)
            async let pressureTask: Void = fetchBuyPressure()

            let (data, response) = try await twapData

            // If backend returns 503 (tracker not ready), keep loading state
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 503 {
                print("[TWAP] BACKEND NOT READY (503) — will retry")
                _ = await pressureTask
                return
            }

            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parseResponse(data)
            }.value

            // Update orders (never clear to empty on success — server returns current state)
            orders = parsed.orders
            hasLoaded = true
            errorMsg = nil
            let activeCount = orders.filter { $0.isActive }.count
            let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[TWAP] FETCH SUCCESS  count=\(orders.count) active=\(activeCount) filteredOrders=\(filteredOrders.count) elapsed=\(elapsed)ms")

            // Only update coin list if it actually changed (prevents Menu reset during scroll)
            let filteredCoins = parsed.coins.filter { !$0.hasPrefix("Asset#") }
            if filteredCoins != availableCoins {
                availableCoins = filteredCoins
            }

            if isLoading {
                progressText = nil
                isLoading = false
            }

            // Wait for concurrent pressure fetch to complete
            _ = await pressureTask
        } catch {
            print("[TWAP] FETCH FAILURE  error=\(error.localizedDescription) staleOrders=\(orders.count)")
            // Only set errorMsg if we have NO stale data to show
            if orders.isEmpty {
                errorMsg = error.localizedDescription
            }
            if isLoading {
                progressText = nil
                isLoading = false
            }
        }
    }

    func fetchBuyPressure() async {
        guard let url = URL(string: "\(Self.backendBase)/twap-pressure?coin=HYPE") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Handle both Int and Double from JSON (JSONSerialization may return Int for whole numbers)
                hypePressure1hUSD = (json["next1hUSD"] as? NSNumber)?.doubleValue ?? 0
                hypePressure24hUSD = (json["next24hUSD"] as? NSNumber)?.doubleValue ?? 0
                print("[TWAP] BUY PRESSURE: 1h=$\(hypePressure1hUSD) 24h=$\(hypePressure24hUSD)")
            }
        } catch {
            print("[TWAP] BUY PRESSURE FETCH FAILURE: \(error.localizedDescription)")
        }
    }

    func load() async {
        guard !isLoading else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        print("[TWAP] LOAD START  hasLoaded=\(hasLoaded) orders=\(orders.count)")
        if orders.isEmpty {
            isLoading = true
            errorMsg = nil
            progressText = "Loading TWAPs..."
        }
        await fetch()

        // If backend wasn't ready (503 or empty), retry a few times quickly
        if orders.isEmpty && !hasLoaded {
            for retry in 1...3 {
                print("[TWAP] LOAD RETRY \(retry)/3 — backend may still be warming up")
                try? await Task.sleep(for: .seconds(3))
                await fetch()
                if !orders.isEmpty { break }
            }
        }

        let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[TWAP] LOAD COMPLETE  orders=\(orders.count) hasLoaded=\(hasLoaded) elapsed=\(elapsed)ms")
        startPolling()
    }

    func refresh() async {
        // Reset filters but keep stale orders visible during refresh.
        // Orders are replaced atomically when fetch() succeeds.
        selectedCoin = "All"
        if orders.isEmpty {
            isLoading = true
            progressText = "Loading TWAPs..."
        }
        print("[TWAP] REFRESH START  staleOrders=\(orders.count)")
        await fetch()
    }

    // MARK: - Parsing

    private struct ParseResult {
        let orders: [TWAPOrder]
        let coins: [String]
    }

    nonisolated private static func parseResponse(_ data: Data) -> ParseResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let twapsArr = json["twaps"] as? [[String: Any]] else {
            return ParseResult(orders: [], coins: [])
        }

        let coins: [String]
        if let coinsArr = json["availableCoins"] as? [String] {
            coins = ["All"] + coinsArr
        } else {
            coins = ["All"]
        }

        let orders = twapsArr.compactMap { dict -> TWAPOrder? in
            guard let user = dict["user"] as? String,
                  let coin = dict["coin"] as? String,
                  let isBuy = dict["isBuy"] as? Bool else {
                return nil
            }

            // Skip unresolved asset IDs and token refs
            if coin.hasPrefix("Asset#") || coin.hasPrefix("@") { return nil }

            let size = (dict["size"] as? Double) ?? (dict["size"] as? Int).map(Double.init) ?? 0
            let minutes = dict["durationMinutes"] as? Int ?? 0
            let reduceOnly = dict["reduceOnly"] as? Bool ?? false
            let randomize = dict["randomize"] as? Bool ?? false
            let isSpot = dict["isSpot"] as? Bool ?? false
            let hash = dict["hash"] as? String ?? ""

            let timeMs: Double
            if let t = dict["timestamp"] as? Int64 {
                timeMs = Double(t)
            } else if let t = dict["timestamp"] as? Int {
                timeMs = Double(t)
            } else if let t = dict["timestamp"] as? Double {
                timeMs = t
            } else {
                return nil
            }

            let statusStr = dict["status"] as? String ?? "active"
            let status: TWAPOrder.TWAPStatus
            if statusStr == "active" {
                status = .active
            } else {
                let reason = dict["endedReason"] as? String ?? statusStr
                status = .ended(reason)
            }

            let markPx = dict["markPrice"] as? Double

            return TWAPOrder(
                coin: coin,
                user: user,
                isBuy: isBuy,
                size: size,
                durationMinutes: minutes,
                randomize: randomize,
                reduceOnly: reduceOnly,
                timestamp: Date(timeIntervalSince1970: timeMs / 1000),
                status: status,
                hash: hash,
                isSpot: isSpot,
                markPrice: markPx
            )
        }

        return ParseResult(orders: orders, coins: coins)
    }
}
