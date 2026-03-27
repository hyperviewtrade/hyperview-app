import Foundation
import SwiftUI
import Combine

@MainActor
final class LeaderboardViewModel: ObservableObject {
    static let shared = LeaderboardViewModel()

    // Published state
    @Published var entries: [LeaderboardEntry] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var progressText: String?
    @Published var selectedTimeframe: Timeframe = .allTime
    @Published var sortBy: SortBy = .pnl
    @Published var displayCount: Int = 30

    enum Timeframe: String, CaseIterable {
        case day = "1D"
        case week = "7D"
        case month = "1M"
        case allTime = "All"

        var apiKey: String {
            switch self {
            case .day: return "day"
            case .week: return "week"
            case .month: return "month"
            case .allTime: return "allTime"
            }
        }
    }

    enum SortBy: String, CaseIterable {
        case pnl = "PnL"
        case volume = "Volume"
    }

    private let pageSize = 30
    private let maxEntries = 200
    private static let backendBase = Configuration.backendBaseURL

    // Data is already sorted by the backend — just show prefix(displayCount)
    var sortedEntries: [LeaderboardEntry] {
        Array(entries.prefix(displayCount))
    }

    var hasMore: Bool {
        displayCount < entries.count
    }

    /// Reveal next 30 entries (instant — data already loaded)
    func loadMore() {
        displayCount = min(displayCount + pageSize, entries.count)
    }

    /// Force reload (for pull-to-refresh)
    func refresh() async {
        entries = []
        displayCount = 30
        await load()
    }

    /// Re-fetch when user changes timeframe or sort
    func reloadForFilters() {
        entries = []
        displayCount = 30
        Task { await load() }
    }

    func load() async {
        guard !isLoading else { return }
        if !entries.isEmpty { return }
        isLoading = true
        errorMsg = nil
        progressText = "Loading leaderboard..."

        let sortParam = sortBy == .volume ? "volume" : "pnl"
        let tf = selectedTimeframe.apiKey
        let urlStr = "\(Self.backendBase)/leaderboard?sortBy=\(sortParam)&timeframe=\(tf)&limit=\(maxEntries)"

        do {
            guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
            let (data, _) = try await URLSession.shared.data(from: url)

            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parseResponse(data)
            }.value

            entries = parsed
            displayCount = min(pageSize, parsed.count)
            progressText = nil
            isLoading = false
        } catch {
            errorMsg = error.localizedDescription
            progressText = nil
            isLoading = false
        }
    }

    // MARK: - Parsing

    nonisolated private static func parseResponse(_ data: Data) -> [LeaderboardEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["leaderboardRows"] as? [[String: Any]] else {
            return []
        }
        return parseEntries(rows)
    }

    nonisolated private static func parseEntries(_ arr: [[String: Any]]) -> [LeaderboardEntry] {
        var seen = Set<String>()
        return arr.compactMap { dict -> LeaderboardEntry? in
            guard let ethAddress = dict["ethAddress"] as? String else { return nil }
            guard seen.insert(ethAddress).inserted else { return nil }
            // accountValue can be String (legacy) or Number (new slim format)
            let accountValue: Double
            if let n = dict["accountValue"] as? Double { accountValue = n }
            else { accountValue = Double(dict["accountValue"] as? String ?? "0") ?? 0 }
            let displayName = dict["displayName"] as? String

            var performances: [String: WindowPerformance] = [:]

            // New slim format: flat pnl/vlm/roi fields (single timeframe)
            if let pnl = dict["pnl"] as? Double {
                let vlm = dict["vlm"] as? Double ?? 0
                let roi = dict["roi"] as? Double ?? 0
                // Store under a generic key — backend already sorted by requested timeframe
                performances["_current"] = WindowPerformance(pnl: pnl, roi: roi, vlm: vlm)
            }

            // Legacy format: nested windowPerformances array
            if let windows = dict["windowPerformances"] as? [[Any]] {
                for window in windows {
                    guard window.count >= 2,
                          let key = window[0] as? String,
                          let metrics = window[1] as? [String: Any] else { continue }
                    let pnl = Double(metrics["pnl"] as? String ?? "0") ?? 0
                    let roi = Double(metrics["roi"] as? String ?? "0") ?? 0
                    let vlm = Double(metrics["vlm"] as? String ?? "0") ?? 0
                    performances[key] = WindowPerformance(pnl: pnl, roi: roi, vlm: vlm)
                }
            }

            guard !performances.isEmpty else { return nil }

            return LeaderboardEntry(
                ethAddress: ethAddress,
                displayName: displayName,
                accountValue: accountValue,
                performances: performances
            )
        }
    }
}

// MARK: - Models

struct LeaderboardEntry: Identifiable {
    let id = UUID()
    let ethAddress: String
    let displayName: String?
    let accountValue: Double
    let performances: [String: WindowPerformance]

    func performanceFor(_ timeframe: String) -> WindowPerformance? {
        // New slim format stores under "_current" (already sorted by backend)
        performances[timeframe] ?? performances["_current"]
    }

    var shortAddress: String {
        guard ethAddress.count > 10 else { return ethAddress }
        return "\(ethAddress.prefix(6))...\(ethAddress.suffix(4))"
    }

    var displayLabel: String {
        // Priority: HL displayName > Hypurrscan alias > short address
        if let dn = displayName { return dn }
        if let alias = AliasCache.shared.alias(for: ethAddress) { return alias }
        return shortAddress
    }
}

struct WindowPerformance {
    let pnl: Double
    let roi: Double
    let vlm: Double
}
