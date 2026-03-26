import SwiftUI

struct HomeUnstakingCard: View {
    @Binding var showFullUnstaking: Bool
    @StateObject private var vm = UnstakingViewModel()

    enum SortField { case time, amount }
    @State private var sortField: SortField = .amount
    @State private var sortAscending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Upcoming Unstaking")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    showFullUnstaking = true
                } label: {
                    Text("View All")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.hlGreen)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hlGreen)
                }
            }

            // Content
            let entries = topEntries
            if entries.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 20))
                            .foregroundColor(Color(white: 0.3))
                        Text("No upcoming unstaking")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                // Column header — tappable for sorting
                HStack(spacing: 0) {
                    Button {
                        if sortField == .time { sortAscending.toggle() }
                        else { sortField = .time; sortAscending = true }
                    } label: {
                        HStack(spacing: 2) {
                            Text("Time")
                            if sortField == .time {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                        }
                        .frame(width: 70, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Text("Address")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        if sortField == .amount { sortAscending.toggle() }
                        else { sortField = .amount; sortAscending = false }
                    } label: {
                        HStack(spacing: 2) {
                            Text("Amount")
                            if sortField == .amount {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                            }
                        }
                        .frame(width: 80, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: 0.4))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().background(Color(white: 0.15))
                            }
                            unstakingRow(entry)
                        }
                    }
                }
                .frame(height: 215)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
        .task { await vm.loadAll() }
    }

    // MARK: - Unstaking row

    private func unstakingRow(_ entry: UnstakingQueueEntry) -> some View {
        HStack(spacing: 0) {
            // Countdown
            Text(countdown(to: entry.time))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 70, alignment: .leading)

            // Address
            NavigationLink {
                WalletDetailView(address: entry.userAddress)
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                Text(shortAddr(entry.userAddress))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.hlGreen)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Amount
            Text(formatHYPE(entry.amountHYPE))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    // MARK: - Data

    private var topEntries: [UnstakingQueueEntry] {
        let now = Date()
        let weekFromNow = now.addingTimeInterval(7 * 24 * 3600)
        let filtered = vm.queueEntries
            .filter { $0.time > now && $0.time < weekFromNow && $0.amountHYPE >= 100_000 }

        switch sortField {
        case .time:
            return filtered.sorted { sortAscending ? $0.time < $1.time : $0.time > $1.time }
        case .amount:
            return filtered.sorted { sortAscending ? $0.amountHYPE < $1.amountHYPE : $0.amountHYPE > $1.amountHYPE }
        }
    }

    // MARK: - Helpers

    private func countdown(to date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        if diff <= 0 { return "Done" }
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 24 {
            let d = h / 24
            return "\(d)d \(h % 24)h"
        }
        return "\(h)h \(m)m"
    }

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private func formatHYPE(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM HYPE", value / 1_000_000) }
        if value >= 1_000     { return String(format: "%.1fK HYPE", value / 1_000) }
        return String(format: "%.0f HYPE", value)
    }
}
