import SwiftUI

struct WalletIdentifier: Identifiable {
    let id = UUID()
    let address: String
}

struct TrackSearchResultsView: View {
    let market: Market
    let sideFilter: SideFilterOption?   // nil = both
    let minAmount: Double?
    let maxAmount: Double?
    let minEntry: Double?
    let maxEntry: Double?

    enum SideFilterOption { case long, short }

    @StateObject private var vm = TrackSearchViewModel()
    @EnvironmentObject var chartVM: ChartViewModel

    @State private var walletToShow: WalletIdentifier?
    @State private var displayFilter: DisplayFilter = .all
    @State private var aliases: [String: String] = [:]
    @State private var positionToShare: TrackedPosition? = nil
    @State private var positionToCopy: TrackedPosition? = nil

    enum DisplayFilter: String, CaseIterable {
        case larps    = "LARPS"
        case notLarps = "NOT LARPS"
        case all      = "ALL"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header summary
            headerBar

            Divider().background(Color.hlSurface)

            // ── Display filter ───────────────────────────
            if !vm.results.isEmpty {
                displayFilterBar
            }

            // Content
            if vm.isLoading && vm.results.isEmpty {
                loadingView
            } else if let err = vm.errorMsg {
                errorView(err)
            } else if vm.results.isEmpty && !vm.isLoading {
                emptyView
            } else {
                resultsList
            }
        }
        .background(Color.hlBackground)
        .navigationTitle(market.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $positionToShare) { pos in
            ShareCardView(position: pos, market: market, alias: aliases[pos.address.lowercased()])
        }
        .sheet(item: $positionToCopy) { pos in
            CopyTradeSheet(position: pos, market: market, alias: aliases[pos.address.lowercased()])
        }
        .task {
            await loadAliases()
            // Only search on first load — keep results cached when returning from wallet detail
            guard vm.results.isEmpty else { return }
            await vm.search(
                coin: market.apiCoin,
                side: sideFilter == .long ? .long : sideFilter == .short ? .short : nil,
                minAmount: minAmount,
                maxAmount: maxAmount,
                minEntry: minEntry,
                maxEntry: maxEntry
            )
        }
        .navigationDestination(isPresented: Binding(
            get: { walletToShow != nil },
            set: { if !$0 { walletToShow = nil } }
        )) {
            if let wallet = walletToShow {
                WalletDetailView(address: wallet.address)
                    .navigationTitle("Wallet")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(market.displayName)-PERP")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("\(vm.results.count) results")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }

            // Active filters
            HStack(spacing: 6) {
                if let side = sideFilter {
                    filterTag(side == .long ? "Long" : "Short")
                }
                if let mn = minAmount { filterTag("Size ≥ \(formatFull(mn))") }
                if let mx = maxAmount { filterTag("Size ≤ \(formatFull(mx))") }
                if let mn = minEntry  { filterTag("Entry ≥ \(formatFull(mn))") }
                if let mx = maxEntry  { filterTag("Entry ≤ \(formatFull(mx))") }
            }

            if !vm.progress.isEmpty {
                Text(vm.progress)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hlCardBackground)
    }

    private func filterTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.hlGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.hlGreen.opacity(0.12))
            .cornerRadius(6)
    }

    // MARK: - Computed splits

    private var larps: [TrackedPosition] {
        vm.results.filter { $0.notionalUSD < 1_000 }.sorted { $0.notionalUSD > $1.notionalUSD }
    }

    private var otherPositions: [TrackedPosition] {
        vm.results.filter { $0.notionalUSD >= 1_000 }.sorted { $0.notionalUSD > $1.notionalUSD }
    }

    // MARK: - Results list

    // MARK: - Display filter bar

    private var displayFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(DisplayFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { displayFilter = filter }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(displayFilter == filter ? .black : Color(white: 0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(displayFilter == filter ? Color.hlGreen : Color(white: 0.12))
                        .cornerRadius(8)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.hlCardBackground)
    }

    private var resultsList: some View {
        List {
            // ── LARPS section ────────────────────────────
            if !larps.isEmpty && displayFilter != .notLarps {
                Section {
                    ForEach(larps) { pos in
                        Button {
                            walletToShow = WalletIdentifier(address: pos.address)
                        } label: {
                            positionRow(pos)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                copyTrade(pos)
                            } label: {
                                Label("CopyTrade", systemImage: "doc.on.doc")
                            }
                            .tint(.hlGreen)

                            Button {
                                positionToShare = pos
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color(white: 0.18))
                    }
                } header: {
                    Text(larps.count == 1
                         ? "LARP DETECTED ❗️"
                         : "LARPS DETECTED ❗️")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                }
            }

            // ── Other positions section ──────────────────
            if !otherPositions.isEmpty && displayFilter != .larps {
                Section {
                    ForEach(otherPositions) { pos in
                        Button {
                            walletToShow = WalletIdentifier(address: pos.address)
                        } label: {
                            positionRow(pos)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                copyTrade(pos)
                            } label: {
                                Label("CopyTrade", systemImage: "doc.on.doc")
                            }
                            .tint(.hlGreen)

                            Button {
                                positionToShare = pos
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        .listRowBackground(Color(white: 0.11))
                        .listRowSeparatorTint(Color(white: 0.18))
                    }
                } header: {
                    Text(otherPositions.count == 1
                         ? "NOT LARP :"
                         : "NOT LARPS :")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func positionRow(_ pos: TrackedPosition) -> some View {
        let alias = aliases[pos.address.lowercased()]
        return VStack(spacing: 8) {
            HStack {
                if let alias {
                    Text(alias)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    Text(pos.shortAddress)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }

                DirectionBadge(isLong: pos.isLong)

                Text("\(pos.leverage)×")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))

                Spacer()

                Text(pos.formattedPnl)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(pos.livePnl >= 0 ? .hlGreen : .tradingRed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack {
                labelValue("Size", pos.formattedNotional)
                Spacer()
                labelValue("Entry", pos.formattedEntry)
                Spacer()
                labelValue("Mark", pos.formattedMark)
            }
        }
        .padding(.vertical, 6)
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - States

    private var loadingView: some View {
        WalletLoadingView(message: vm.progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(Color(white: 0.3))
            Text("No matching positions found")
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.5))
            Text("Try adjusting your filters or searching another market.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.35))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(msg)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await vm.search(
                        coin: market.apiCoin,
                        side: sideFilter == .long ? .long : sideFilter == .short ? .short : nil,
                        minAmount: minAmount, maxAmount: maxAmount,
                        minEntry: minEntry, maxEntry: maxEntry
                    )
                }
            }
            .buttonStyle(.bordered).tint(.hlGreen)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Copy Trade

    private func copyTrade(_ pos: TrackedPosition) {
        positionToCopy = pos
    }

    // MARK: - Aliases

    private func loadAliases() async {
        var merged = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        if let url = URL(string: "https://api.hypurrscan.io/globalAliases"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in dict {
                let key = k.lowercased()
                if merged[key] == nil { merged[key] = v }
            }
        }
        aliases = merged
    }

    // MARK: - Helpers

    private static let fullNumberFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = 2
        return fmt
    }()

    private func formatFull(_ v: Double) -> String {
        "$\(Self.fullNumberFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))"
    }
}
