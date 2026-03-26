import Foundation
import SwiftUI
import Combine

@MainActor
final class UnstakingViewModel: ObservableObject {

    // MARK: - Published state

    @Published var queueEntries: [UnstakingQueueEntry] = []
    @Published var dailyBars: [DailyUnstakingBar] = []
    @Published var upcomingFiltered: [UnstakingQueueEntry] = []

    // Stats
    @Published var unstakingNext1h: Double = 0
    @Published var unstakingNext24h: Double = 0
    @Published var unstakingNext7d: Double = 0
    @Published var finishedPast1h: Double = 0
    @Published var finishedPast24h: Double = 0
    @Published var finishedPast7d: Double = 0

    // Sort & filter
    enum SortField: String { case time, amount }
    enum SortDirection { case asc, desc }
    @Published var sortField: SortField = .time
    @Published var sortDirection: SortDirection = .asc
    @Published var minAmountFilter: String = ""
    @Published var maxAmountFilter: String = ""

    // Loading
    @Published var isLoading = false
    @Published var errorMsg: String?

    private let session = URLSession.shared

    // MARK: - Load all

    func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        errorMsg = nil

        do {
            let entries = try await fetchUnstakingQueue()
            queueEntries = entries
            computeStats()
            aggregateDailyBars()
            applySortAndFilter()
        } catch {
            errorMsg = error.localizedDescription
        }

        isLoading = false
    }

    func refresh() async {
        isLoading = false
        await loadAll()
    }

    // MARK: - Sort & Filter

    func toggleSort(field: SortField) {
        if sortField == field {
            sortDirection = sortDirection == .asc ? .desc : .asc
        } else {
            sortField = field
            sortDirection = .asc
        }
        applySortAndFilter()
    }

    func applySortAndFilter() {
        let now = Date()
        var filtered = queueEntries.filter { $0.time > now }    // only upcoming

        // Amount filters (strip commas before parsing)
        if let min = Double(stripCommas(minAmountFilter)), min > 0 {
            filtered = filtered.filter { $0.amountHYPE >= min }
        }
        if let max = Double(stripCommas(maxAmountFilter)), max > 0 {
            filtered = filtered.filter { $0.amountHYPE <= max }
        }

        // Sort
        switch (sortField, sortDirection) {
        case (.time, .asc):    filtered.sort { $0.time < $1.time }
        case (.time, .desc):   filtered.sort { $0.time > $1.time }
        case (.amount, .asc):  filtered.sort { $0.amountHYPE < $1.amountHYPE }
        case (.amount, .desc): filtered.sort { $0.amountHYPE > $1.amountHYPE }
        }

        upcomingFiltered = filtered
    }

    // MARK: - Stats computation

    private func computeStats() {
        let now = Date()
        let in1h = now.addingTimeInterval(3600)
        let in24h = now.addingTimeInterval(86400)
        let in7d = now.addingTimeInterval(7 * 86400)
        let ago1h = now.addingTimeInterval(-3600)
        let ago24h = now.addingTimeInterval(-86400)
        let ago7d = now.addingTimeInterval(-7 * 86400)

        unstakingNext1h = queueEntries.filter { $0.time > now && $0.time <= in1h }.reduce(0) { $0 + $1.amountHYPE }
        unstakingNext24h = queueEntries.filter { $0.time > now && $0.time <= in24h }.reduce(0) { $0 + $1.amountHYPE }
        unstakingNext7d = queueEntries.filter { $0.time > now && $0.time <= in7d }.reduce(0) { $0 + $1.amountHYPE }

        finishedPast1h = queueEntries.filter { $0.time <= now && $0.time >= ago1h }.reduce(0) { $0 + $1.amountHYPE }
        finishedPast24h = queueEntries.filter { $0.time <= now && $0.time >= ago24h }.reduce(0) { $0 + $1.amountHYPE }
        finishedPast7d = queueEntries.filter { $0.time <= now && $0.time >= ago7d }.reduce(0) { $0 + $1.amountHYPE }
    }

    // MARK: - Daily aggregation (7 days)

    private func aggregateDailyBars() {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        // Include 3 past days + today + 3 future days = 7 bars
        var bars: [DailyUnstakingBar] = []
        for dayOffset in -3...3 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }

            let total = queueEntries
                .filter { $0.time >= dayStart && $0.time < dayEnd }
                .reduce(0.0) { $0 + $1.amountHYPE }

            let fmt = DateFormatter()
            fmt.dateFormat = "MM/dd"
            let label = fmt.string(from: dayStart)

            bars.append(DailyUnstakingBar(id: label, date: dayStart, totalHYPE: total))
        }

        dailyBars = bars
    }

    // MARK: - Fetch unstaking queue from Hypurrscan

    private func fetchUnstakingQueue() async throws -> [UnstakingQueueEntry] {
        guard let url = URL(string: "https://api.hypurrscan.io/unstakingQueue") else {
            throw APIError.invalidURL
        }
        let (data, _) = try await session.data(from: url)

        // Parse on background thread to avoid blocking the main thread
        return await Task.detached(priority: .userInitiated) {
            Self.parseQueueData(data)
        }.value
    }

    /// Heavy JSON parsing — runs off the main actor to keep the UI responsive.
    nonisolated private static func parseQueueData(_ data: Data) -> [UnstakingQueueEntry] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        // Create the formatter ONCE and reuse
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return arr.compactMap { entry -> UnstakingQueueEntry? in
            let entryTime: Date?
            if let timeStr = entry["time"] as? String {
                entryTime = iso.date(from: timeStr) ?? {
                    if let ms = Double(timeStr) {
                        return Date(timeIntervalSince1970: ms / 1000)
                    }
                    return nil
                }()
            } else if let timeMs = entry["time"] as? Int64 {
                entryTime = Date(timeIntervalSince1970: Double(timeMs) / 1000)
            } else if let timeMs = (entry["time"] as? NSNumber)?.int64Value {
                entryTime = Date(timeIntervalSince1970: Double(timeMs) / 1000)
            } else {
                entryTime = nil
            }

            guard let time = entryTime else { return nil }

            let user = entry["user"] as? String ?? ""
            let wei = entry["wei"] ?? entry["amount"] ?? 0
            let amount: Double
            if let s = wei as? String, let d = Double(s) {
                amount = d / 100_000_000
            } else if let n = wei as? NSNumber {
                amount = n.doubleValue / 100_000_000
            } else if let d = wei as? Double {
                amount = d / 100_000_000
            } else if let i = wei as? Int {
                amount = Double(i) / 100_000_000
            } else {
                amount = 0
            }

            guard amount > 0 else { return nil }

            return UnstakingQueueEntry(time: time, userAddress: user, amountHYPE: amount)
        }
        .sorted { $0.time < $1.time }
    }
}
