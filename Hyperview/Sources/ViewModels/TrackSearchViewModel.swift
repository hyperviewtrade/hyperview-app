import SwiftUI
import Combine

// MARK: - Search result model

struct TrackedPosition: Identifiable {
    let id = UUID()
    let address: String
    let coin: String
    let size: Double
    let entryPrice: Double
    let markPrice: Double          // from backend (fallback)
    let unrealizedPnl: Double      // from backend (fallback)
    let leverage: Int
    let isLong: Bool
    let notionalUSD: Double

    /// Real-time mark price from static cache (falls back to stored markPrice)
    var liveMarkPrice: Double {
        let live = MarketsViewModel.markPrice(for: coin)
        return live > 0 ? live : markPrice
    }

    /// Real-time PnL calculated from live mark price
    var livePnl: Double {
        let mp = liveMarkPrice
        let direction: Double = isLong ? 1 : -1
        return (mp - entryPrice) * abs(size) * direction
    }

    var shortAddress: String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    var formattedSize: String {
        let sign = isLong ? "+" : "-"
        let sz = abs(size)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = sz >= 1 ? 2 : 4
        f.maximumFractionDigits = sz >= 1000 ? 2 : (sz >= 1 ? 4 : 6)
        let formatted = f.string(from: NSNumber(value: sz)) ?? String(format: "%.4f", sz)
        return "\(sign)\(formatted) \(coin)"
    }

    var formattedNotional: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formatted = formatter.string(from: NSNumber(value: notionalUSD)) ?? String(format: "%.2f", notionalUSD)
        return "$\(formatted)"
    }

    var formattedEntry: String { formatPx(entryPrice) }
    var formattedMark:  String { formatPx(liveMarkPrice) }

    var formattedPnl: String {
        let pnl = livePnl
        let sign = pnl >= 0 ? "+" : "-"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        let formatted = formatter.string(from: NSNumber(value: abs(pnl))) ?? String(format: "%.2f", abs(pnl))
        return "PNL : \(sign)$\(formatted)"
    }

    private func formatPx(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "$%.1f", p) }
        if p >= 1      { return String(format: "$%.2f", p) }
        return String(format: "$%.4f", p)
    }
}

// MARK: - ViewModel

enum PositionSide { case long, short }

/// LARP threshold — positions below this notional are considered LARPs.
let kLarpThreshold: Double = 1_000

@MainActor
final class TrackSearchViewModel: ObservableObject {
    @Published var results: [TrackedPosition] = []
    @Published var isLoading = true
    @Published var isLoadingMore = false
    @Published var progress  = "Searching…"
    @Published var errorMsg: String?
    @Published var totalCount = 0
    @Published var totalCountAll = 0   // total positions for coin (unfiltered)
    @Published var hasMore = false

    private var currentOffset = 0
    private static let pageSize = 100

    private static let backendBaseURL = "https://hyperview-backend-production-075c.up.railway.app"

    // ─── Primary search with pagination ──────────────────────────────

    func search(
        coin: String,
        side: PositionSide? = nil,
        minAmount: Double?,
        maxAmount: Double?,
        minEntry: Double?,
        maxEntry: Double?,
        reset: Bool = true
    ) async {
        if reset {
            isLoading = true
            errorMsg  = nil
            results   = []
            progress  = "Searching…"
            currentOffset = 0
        } else {
            isLoadingMore = true
        }

        do {
            var components = URLComponents(string: "\(Self.backendBaseURL)/search")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "coin", value: coin)
            ]

            if let s = side {
                queryItems.append(URLQueryItem(name: "side", value: s == .long ? "long" : "short"))
            }
            if let mn = minEntry {
                queryItems.append(URLQueryItem(name: "minEntry", value: String(mn)))
            }
            if let mx = maxEntry {
                queryItems.append(URLQueryItem(name: "maxEntry", value: String(mx)))
            }
            if let mn = minAmount {
                queryItems.append(URLQueryItem(name: "minNotional", value: String(mn)))
            }
            if let mx = maxAmount {
                queryItems.append(URLQueryItem(name: "maxNotional", value: String(mx)))
            }

            // Pagination
            queryItems.append(URLQueryItem(name: "limit", value: String(Self.pageSize)))
            queryItems.append(URLQueryItem(name: "offset", value: String(currentOffset)))

            components.queryItems = queryItems
            guard let url = components.url else {
                errorMsg = "Invalid URL"
                isLoading = false
                isLoadingMore = false
                return
            }

            print("🔍 [LARP] Fetching: \(url.absoluteString)")

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("🔍 [LARP] HTTP error: \(code)")
                errorMsg = "Server error"
                isLoading = false
                isLoadingMore = false
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let positions = json["positions"] as? [[String: Any]] else {
                print("🔍 [LARP] JSON parse failed")
                errorMsg = "Invalid response"
                isLoading = false
                isLoadingMore = false
                return
            }

            let newPositions = positions.compactMap { pos -> TrackedPosition? in
                guard let address = pos["address"] as? String,
                      let coin = pos["coin"] as? String,
                      let size = pos["size"] as? Double,
                      let entryPrice = pos["entryPrice"] as? Double,
                      let markPrice = pos["markPrice"] as? Double,
                      let unrealizedPnl = pos["unrealizedPnl"] as? Double,
                      let leverage = pos["leverage"] as? Int,
                      let sideStr = pos["side"] as? String,
                      let notionalUSD = pos["notionalUSD"] as? Double
                else { return nil }

                return TrackedPosition(
                    address: address,
                    coin: coin,
                    size: size,
                    entryPrice: entryPrice,
                    markPrice: markPrice,
                    unrealizedPnl: unrealizedPnl,
                    leverage: leverage,
                    isLong: sideStr == "LONG",
                    notionalUSD: notionalUSD
                )
            }

            totalCount = (json["totalCount"] as? Int) ?? newPositions.count
            totalCountAll = (json["totalCountAll"] as? Int) ?? totalCount
            hasMore = (json["hasMore"] as? Bool) ?? false
            currentOffset += newPositions.count

            if reset {
                results = newPositions
            } else {
                results.append(contentsOf: newPositions)
            }

            progress = "\(results.count) of \(totalCount) positions"

        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
        isLoadingMore = false
    }

    // ─── Entry-price specific search (larp detection) ────────────────

    func searchByEntry(
        coin: String,
        targetPrice: Double,
        range: Double = 0.05,
        side: PositionSide? = nil,
        minNotional: Double? = nil,
        maxNotional: Double? = nil,
        reset: Bool = true
    ) async {
        if reset {
            isLoading = true
            errorMsg  = nil
            results   = []
            progress  = "Searching…"
            currentOffset = 0
        } else {
            isLoadingMore = true
        }

        do {
            var components = URLComponents(string: "\(Self.backendBaseURL)/search-entry")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "asset", value: coin),
                URLQueryItem(name: "price", value: String(targetPrice)),
                URLQueryItem(name: "range", value: String(range)),
            ]
            if let s = side {
                queryItems.append(URLQueryItem(name: "side", value: s == .long ? "long" : "short"))
            }
            if let mn = minNotional {
                queryItems.append(URLQueryItem(name: "minNotional", value: String(mn)))
            }
            if let mx = maxNotional {
                queryItems.append(URLQueryItem(name: "maxNotional", value: String(mx)))
            }

            // Pagination
            queryItems.append(URLQueryItem(name: "limit", value: String(Self.pageSize)))
            queryItems.append(URLQueryItem(name: "offset", value: String(currentOffset)))

            components.queryItems = queryItems

            guard let url = components.url else {
                errorMsg = "Invalid URL"
                isLoading = false
                isLoadingMore = false
                return
            }

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                errorMsg = "Server error"
                isLoading = false
                isLoadingMore = false
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let positions = json["positions"] as? [[String: Any]] else {
                errorMsg = "Invalid response"
                isLoading = false
                isLoadingMore = false
                return
            }

            let newPositions = positions.compactMap { pos -> TrackedPosition? in
                guard let address = pos["address"] as? String,
                      let coin = pos["coin"] as? String,
                      let size = pos["size"] as? Double,
                      let entryPrice = pos["entryPrice"] as? Double,
                      let markPrice = pos["markPrice"] as? Double,
                      let unrealizedPnl = pos["unrealizedPnl"] as? Double,
                      let leverage = pos["leverage"] as? Int,
                      let sideStr = pos["side"] as? String,
                      let notionalUSD = pos["notionalUSD"] as? Double
                else { return nil }

                return TrackedPosition(
                    address: address,
                    coin: coin,
                    size: size,
                    entryPrice: entryPrice,
                    markPrice: markPrice,
                    unrealizedPnl: unrealizedPnl,
                    leverage: leverage,
                    isLong: sideStr == "LONG",
                    notionalUSD: notionalUSD
                )
            }

            totalCount = (json["totalCount"] as? Int) ?? newPositions.count
            totalCountAll = (json["totalCountAll"] as? Int) ?? totalCount
            hasMore = (json["hasMore"] as? Bool) ?? false
            currentOffset += newPositions.count

            if reset {
                results = newPositions
            } else {
                results.append(contentsOf: newPositions)
            }

            progress = "\(results.count) of \(totalCount) positions"

        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
        isLoadingMore = false
    }
}
