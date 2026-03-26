import SwiftUI

struct LeaderboardView: View {
    @ObservedObject private var vm = LeaderboardViewModel.shared
    @ObservedObject private var appState = AppState.shared
    @State private var leaderPage = 1

    var body: some View {
        VStack(spacing: 0) {
            // ── Filter pills ──────────────────────────────────
            filterBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            // ── Content ───────────────────────────────────────
            if vm.isLoading && vm.entries.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.hlGreen)
                        .scaleEffect(1.2)
                    if let progress = vm.progressText {
                        Text(progress)
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
                Spacer()
            } else if let error = vm.errorMsg, vm.entries.isEmpty {
                Spacer()
                errorView(error)
                Spacer()
            } else if vm.sortedEntries.isEmpty {
                Spacer()
                Text("No leaderboard data")
                    .font(.system(size: 14))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
            } else {
                let pageSize = 50
                let allEntries = vm.entries
                let totalPages = max(1, Int(ceil(Double(allEntries.count) / Double(pageSize))))
                let start = (leaderPage - 1) * pageSize
                let end = min(start + pageSize, allEntries.count)
                let pagedEntries = start < allEntries.count
                    ? Array(allEntries[start..<end]) : []

                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("leaderTop")
                        ForEach(Array(pagedEntries.enumerated()), id: \.element.id) { index, entry in
                            NavigationLink {
                                WalletDetailView(address: entry.ethAddress)
                                    .toolbar(.hidden, for: .tabBar)
                            } label: {
                                leaderboardRow(rank: start + index + 1, entry: entry)
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                    // Pagination
                    if totalPages > 1 {
                        leaderPaginationBar(totalPages: totalPages, proxy: proxy)
                            .padding(.bottom, 20)
                    }
                }
                .refreshable {
                    await vm.refresh()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: appState.homeReselect) { _, _ in
                    withAnimation { proxy.scrollTo("leaderTop", anchor: .top) }
                }
                }
            }
        }
        .background(Color.hlBackground)
        .task { await vm.load() }
    }

    // MARK: - Filter Bar

    // MARK: - Pagination

    private func leaderPaginationBar(totalPages: Int, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Button {
                if leaderPage > 1 {
                    leaderPage -= 1
                    withAnimation { proxy.scrollTo("leaderTop", anchor: .top) }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(leaderPage > 1 ? .hlGreen : Color(white: 0.25))
            }
            .disabled(leaderPage <= 1)

            let pages = leaderVisiblePages(totalPages: totalPages)
            ForEach(pages, id: \.self) { page in
                if page == -1 {
                    Text("…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.3))
                        .frame(width: 24, height: 28)
                } else {
                    Button {
                        leaderPage = page
                        withAnimation { proxy.scrollTo("leaderTop", anchor: .top) }
                    } label: {
                        Text("\(page)")
                            .font(.system(size: 12, weight: page == leaderPage ? .bold : .regular))
                            .foregroundColor(page == leaderPage ? .black : .white)
                            .frame(width: 28, height: 28)
                            .background(page == leaderPage ? Color.hlGreen : Color(white: 0.15))
                            .cornerRadius(6)
                    }
                }
            }

            Button {
                if leaderPage < totalPages {
                    leaderPage += 1
                    withAnimation { proxy.scrollTo("leaderTop", anchor: .top) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(leaderPage < totalPages ? .hlGreen : Color(white: 0.25))
            }
            .disabled(leaderPage >= totalPages)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func leaderVisiblePages(totalPages: Int) -> [Int] {
        if totalPages <= 7 { return Array(1...totalPages) }
        var pages: [Int] = [1]
        if leaderPage > 3 { pages.append(-1) }
        for p in max(2, leaderPage - 1)...min(totalPages - 1, leaderPage + 1) {
            if !pages.contains(p) { pages.append(p) }
        }
        if leaderPage < totalPages - 2 { pages.append(-1) }
        if !pages.contains(totalPages) { pages.append(totalPages) }
        return pages
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            // Timeframe pills
            HStack(spacing: 6) {
                ForEach(LeaderboardViewModel.Timeframe.allCases, id: \.self) { tf in
                    pillButton(
                        title: tf.rawValue,
                        isActive: vm.selectedTimeframe == tf
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.selectedTimeframe = tf
                            vm.reloadForFilters()
                        }
                    }
                }

                Spacer()

                // Sort pills
                ForEach(LeaderboardViewModel.SortBy.allCases, id: \.self) { sort in
                    pillButton(
                        title: sort.rawValue,
                        isActive: vm.sortBy == sort
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.sortBy = sort
                            vm.reloadForFilters()
                        }
                    }
                }
            }
        }
    }

    private func pillButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .black : Color(white: 0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isActive ? Color.hlGreen : Color(white: 0.15))
                .cornerRadius(8)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await vm.load() }
            } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - Leaderboard Row

    private func leaderboardRow(rank: Int, entry: LeaderboardEntry) -> some View {
        let tf = vm.selectedTimeframe.apiKey
        let perf = entry.performanceFor(tf)
        let pnl = perf?.pnl ?? 0
        let roi = perf?.roi ?? 0
        let vlm = perf?.vlm ?? 0

        return HStack(spacing: 10) {
            // Rank
            Text("#\(rank)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(rankColor(rank))
                .frame(width: 38, alignment: .leading)

            // Name + account value
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(formatUSD(entry.accountValue))
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            // PnL / Volume + ROI
            VStack(alignment: .trailing, spacing: 2) {
                if vm.sortBy == .pnl {
                    Text(formatSignedUSD(pnl))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(pnl >= 0 ? .hlGreen : .tradingRed)
                } else {
                    Text(formatUSD(vlm))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(formatROI(roi))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(roi >= 0 ? .hlGreen : .tradingRed)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.11))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(white: 0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Rank Color

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1:  return Color(red: 1.0, green: 0.84, blue: 0.0)   // gold
        case 2:  return Color(white: 0.75)                          // silver
        case 3:  return Color(red: 0.80, green: 0.50, blue: 0.20)  // bronze
        default: return Color(white: 0.45)
        }
    }

    // MARK: - Formatting

    private func formatUSD(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 1_000_000_000 {
            return "$\(String(format: "%.1f", abs / 1_000_000_000))B"
        } else if abs >= 1_000_000 {
            return "$\(String(format: "%.1f", abs / 1_000_000))M"
        } else if abs >= 1_000 {
            return "$\(String(format: "%.1f", abs / 1_000))K"
        } else {
            return "$\(String(format: "%.0f", abs))"
        }
    }

    private func formatSignedUSD(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "-"
        let abs = Swift.abs(value)
        if abs >= 1_000_000_000 {
            return "\(sign)$\(String(format: "%.1f", abs / 1_000_000_000))B"
        } else if abs >= 1_000_000 {
            return "\(sign)$\(String(format: "%.1f", abs / 1_000_000))M"
        } else if abs >= 1_000 {
            return "\(sign)$\(String(format: "%.1f", abs / 1_000))K"
        } else {
            return "\(sign)$\(String(format: "%.0f", abs))"
        }
    }

    private func formatROI(_ value: Double) -> String {
        let pct = value * 100
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
}
