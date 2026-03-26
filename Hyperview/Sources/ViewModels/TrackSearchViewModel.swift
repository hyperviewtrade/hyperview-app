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

@MainActor
final class TrackSearchViewModel: ObservableObject {
    @Published var results: [TrackedPosition] = []
    @Published var isLoading = true   // Start as loading — first render shows hourglass, not "No positions"
    @Published var progress  = "Searching…"
    @Published var errorMsg: String?

    // TODO: Update this URL after deploying the backend
    private static let backendBaseURL = "https://hyperview-backend-production-075c.up.railway.app"

    func search(
        coin: String,
        side: PositionSide? = nil,
        minAmount: Double?,
        maxAmount: Double?,
        minEntry: Double?,
        maxEntry: Double?
    ) async {
        isLoading = true
        errorMsg  = nil
        results   = []
        progress  = "Searching…"

        do {
            // Build URL with query params
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

            components.queryItems = queryItems
            guard let url = components.url else {
                errorMsg = "Invalid URL"
                isLoading = false
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
                return
            }

            let rawString = String(data: data.prefix(500), encoding: .utf8) ?? "?"
            print("🔍 [LARP] Response (\(data.count) bytes): \(rawString)")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let positions = json["positions"] as? [[String: Any]] else {
                print("🔍 [LARP] JSON parse failed")
                errorMsg = "Invalid response"
                isLoading = false
                return
            }
            print("🔍 [LARP] Parsed \(positions.count) positions")

            results = positions.compactMap { pos in
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

            progress = "\(results.count) positions found"

        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }

    /// Entry-price specific search (larp detection)
    func searchByEntry(
        coin: String,
        targetPrice: Double,
        range: Double = 0.05,
        side: PositionSide? = nil
    ) async {
        isLoading = true
        errorMsg  = nil
        results   = []
        progress  = "Searching…"

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
            components.queryItems = queryItems

            guard let url = components.url else {
                errorMsg = "Invalid URL"
                isLoading = false
                return
            }

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                errorMsg = "Server error"
                isLoading = false
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let positions = json["positions"] as? [[String: Any]] else {
                errorMsg = "Invalid response"
                isLoading = false
                return
            }

            results = positions.compactMap { pos in
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

            progress = "\(results.count) positions found"

        } catch {
            errorMsg = error.localizedDescription
        }
        isLoading = false
    }
}
