import Foundation
import SwiftUI
import Combine

// MARK: - Model

struct LargestPosition: Identifiable {
    let id = UUID()
    let coin: String
    let isLong: Bool
    let notionalUSD: Double
    let leverage: String       // "50x", "Cross", etc.
    let entryPx: Double
    let markPx: Double
    let unrealizedPnl: Double
    let userAddress: String
    let dexName: String?       // non-nil for HIP-3 positions

    var shortAddress: String {
        guard userAddress.count > 10 else { return userAddress }
        return "\(userAddress.prefix(6))...\(userAddress.suffix(4))"
    }

    var displayLabel: String {
        AliasCache.shared.alias(for: userAddress) ?? shortAddress
    }

    var formattedNotional: String {
        if notionalUSD >= 1_000_000_000 { return String(format: "$%.1fB", notionalUSD / 1_000_000_000) }
        if notionalUSD >= 1_000_000     { return String(format: "$%.1fM", notionalUSD / 1_000_000) }
        if notionalUSD >= 1_000         { return String(format: "$%.0fK", notionalUSD / 1_000) }
        return String(format: "$%.0f", notionalUSD)
    }

    var formattedPnl: String {
        let abs = Swift.abs(unrealizedPnl)
        let sign = unrealizedPnl >= 0 ? "+" : "-"
        if abs >= 1_000_000 { return "\(sign)$\(String(format: "%.1fM", abs / 1_000_000))" }
        if abs >= 1_000     { return "\(sign)$\(String(format: "%.1fK", abs / 1_000))" }
        return "\(sign)$\(String(format: "%.0f", abs))"
    }

    var formattedEntryPx: String { Self.formatPrice(entryPx) }
    var formattedMarkPx: String  { Self.formatPrice(markPx) }

    private static func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "$%.1f", p) }
        if p >= 1_000  { return String(format: "$%.2f", p) }
        if p >= 1      { return String(format: "$%.4f", p) }
        if p >= 0.01   { return String(format: "$%.5f", p) }
        return String(format: "$%.8f", p)
    }
}

// MARK: - ViewModel

@MainActor
final class LargestPositionsViewModel: ObservableObject {
    static let shared = LargestPositionsViewModel()

    @Published var positions: [LargestPosition] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var progressText: String?

    private static let backendBase = "https://hyperview-backend-production-075c.up.railway.app"

    // MARK: - Load

    func load() async {
        guard !isLoading else { return }
        if !positions.isEmpty { return }
        isLoading = true
        errorMsg = nil
        progressText = "Loading largest positions..."

        let urlStr = "\(Self.backendBase)/largest-positions?limit=50"

        do {
            guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
            let (data, _) = try await URLSession.shared.data(from: url)

            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parseResponse(data)
            }.value

            positions = parsed
            progressText = nil
            isLoading = false
        } catch {
            errorMsg = error.localizedDescription
            progressText = nil
            isLoading = false
        }
    }

    /// Force reload (for pull-to-refresh)
    func refresh() async {
        positions = []
        await load()
    }

    // MARK: - Parsing

    nonisolated private static func parseResponse(_ data: Data) -> [LargestPosition] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let positionsArr = json["positions"] as? [[String: Any]] else {
            return []
        }

        return positionsArr.compactMap { pos -> LargestPosition? in
            guard let address = pos["address"] as? String,
                  let coin = pos["coin"] as? String,
                  let side = pos["side"] as? String else { return nil }

            let isLong = side == "LONG"
            let notionalUSD = (pos["notionalUSD"] as? Double) ?? 0
            let entryPrice = (pos["entryPrice"] as? Double) ?? 0
            let markPrice = (pos["markPrice"] as? Double) ?? 0
            let unrealizedPnl = (pos["unrealizedPnl"] as? Double) ?? 0
            let leverage = pos["leverage"] as? NSNumber

            let leverageStr: String
            if let lev = leverage, lev.doubleValue > 0 {
                leverageStr = "\(lev.intValue)x"
            } else {
                leverageStr = "—"
            }

            // Detect HIP-3: coin contains ":"
            let dexName: String?
            if coin.contains(":") {
                dexName = String(coin.split(separator: ":").first ?? "")
            } else {
                dexName = nil
            }

            return LargestPosition(
                coin: coin, isLong: isLong, notionalUSD: notionalUSD,
                leverage: leverageStr, entryPx: entryPrice, markPx: markPrice,
                unrealizedPnl: unrealizedPnl, userAddress: address, dexName: dexName
            )
        }
    }
}
