import SwiftUI

// MARK: - Wallet Tab Root

struct WalletTabView: View {
    @ObservedObject private var walletMgr = WalletManager.shared
    @State private var showConnect = false

    var body: some View {
        Group {
            if let wallet = walletMgr.connectedWallet {
                WalletDetailView(address: wallet.address)
            } else {
                walletEmptyState
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnect) {
            WalletConnectView()
        }
    }

    private var walletEmptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "wallet.pass")
                .font(.system(size: 56))
                .foregroundColor(Color(white: 0.3))

            Text("No Wallet Connected")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text("Connect a wallet to view positions,\nholdings and order history.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button {
                showConnect = true
            } label: {
                Label("Connect Wallet", systemImage: "link.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.hlGreen)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Wallet Detail (tabbed)

struct WalletDetailView: View {
    let address: String

    @StateObject private var vm = WalletDetailViewModel()
    @StateObject private var portfolioVM = PortfolioChartViewModel()
    @EnvironmentObject var chartVM: ChartViewModel
    @EnvironmentObject var marketsVM: MarketsViewModel
    @State private var tab: WalletTab = .overview
    @State private var showTxFilter = false
    @State private var sizeInUSD: Set<UUID> = []       // perp positions showing USD size
    @State private var txShowUSD = false               // transactions amount toggle
    @State private var showAliasAlert = false
    @State private var aliasInput = ""
    @State private var showCopied = false
    @State private var pnlShowPercent: Set<UUID> = []   // positions showing PnL as %
    @State private var positionToShare: PerpPosition? = nil
    @State private var positionToCopy: PerpPosition? = nil
    @Namespace private var tabIndicator

    enum WalletTab: String, CaseIterable {
        case overview     = "Overview"
        case transactions = "Transactions"
        case perps        = "Perps"
        case holdings     = "Holdings"
        case predictions  = "Predictions"
        case options      = "Options"
        case staking      = "Staking"
        case orders       = "Orders"
        case more         = "More"
    }

    var shortAddress: String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Address bar ─────────────────────────────────────────
            addressBar

            // ── Tab picker ──────────────────────────────────────────
            tabBar

            Divider().background(Color.hlSurface)

            // ── Content ─────────────────────────────────────────────
            ZStack {
                if vm.isLoading && !vm.hasData {
                    WalletLoadingView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { print("⏱ [VIEW] LOADING SPINNER VISIBLE") }
                } else if let err = vm.errorMsg, !vm.hasData {
                    errorView(err)
                } else {
                    tabContent
                        .onAppear { print("⏱ [VIEW] TAB CONTENT VISIBLE  tab=\(tab.rawValue)") }
                }
            }
            .contentShape(Rectangle())
        }
        .background(Color.hlBackground)
        .copyToast(show: $showCopied)
        .sheet(item: $positionToShare) { pos in
            if let tracked = trackedPosition(from: pos),
               let market = marketsVM.markets.first(where: { $0.symbol == pos.coin || $0.asset.name == pos.coin }) {
                ShareCardView(position: tracked, market: market, alias: nil)
            }
        }
        .sheet(item: $positionToCopy) { pos in
            if let tracked = trackedPosition(from: pos),
               let market = marketsVM.markets.first(where: { $0.symbol == pos.coin || $0.asset.name == pos.coin }) {
                CopyTradeSheet(position: tracked, market: market, alias: nil)
            }
        }
        .task(id: address) {
            guard address.hasPrefix("0x"), address.count == 42 else { return }
            // 1) Fire unstructured tasks that survive even if this .task is cancelled
            vm.startLoad(address: address)
            portfolioVM.displayAddress = address
            portfolioVM.startLoad(address: address)
            // 2) Also await directly — if the structured task survives, great
            await vm.loadIfNeeded(address: address)
            await portfolioVM.load(address: address)
        }
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.hlGreen.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundColor(.hlGreen)
                        .font(.system(size: 16))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(shortAddress)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    if vm.alias == nil {
                        Button {
                            aliasInput = ""
                            showAliasAlert = true
                        } label: {
                            Text("Add Alias")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.hlGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.hlGreen.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                }
                if let alias = vm.alias {
                    Text(alias)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.hlGreen)
                        .onTapGesture {
                            aliasInput = alias
                            showAliasAlert = true
                        }
                }
            }
            Spacer()
            Button {
                copyWithToast(address, show: $showCopied)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.gray)
                    .font(.system(size: 15))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hlCardBackground)
        .alert("Set Alias", isPresented: $showAliasAlert) {
            TextField("Alias", text: $aliasInput)
            Button("Save") {
                vm.setCustomAlias(aliasInput, for: address)
            }
            Button("Remove", role: .destructive) {
                vm.setCustomAlias("", for: address)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a custom name for this wallet")
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(WalletTab.allCases, id: \.self) { t in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                        } label: {
                            VStack(spacing: 4) {
                                Text(t.rawValue)
                                    .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                                    .foregroundColor(tab == t ? .white : Color(white: 0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                if tab == t {
                                    Rectangle()
                                        .fill(Color.hlGreen)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "tabIndicator", in: tabIndicator)
                                } else {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 2)
                                }
                            }
                        }
                        .id(t)
                    }
                }
            }
            .onChange(of: tab) { _, newTab in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newTab, anchor: .center)
                }
            }
        }
        .background(Color.hlBackground)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:     overviewTab
        case .transactions: transactionsTab
        case .perps:        perpsTab
        case .holdings:     holdingsTab
        case .predictions:  WalletOutcomeTab(address: address, mode: .predictions)
        case .options:      WalletOutcomeTab(address: address, mode: .options)
        case .staking:      stakingTab
        case .orders:       ordersTab
        case .more:         WalletMoreTab(address: address)
        }
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Portfolio chart
                PortfolioChartView(vm: portfolioVM)
                    .padding(.horizontal, 14)

                // Stats — Volume & PnL from portfolio API (accurate all-time)
                VStack(spacing: 1) {
                    overviewStat(
                        icon: "chart.line.uptrend.xyaxis",
                        label: "Total PnL",
                        value: formatPnl(portfolioVM.allTimePnl),
                        valueColor: portfolioVM.allTimePnl >= 0 ? .hlGreen : .tradingRed
                    )
                    overviewStat(
                        icon: "target",
                        label: "Winrate",
                        value: "\(Int(portfolioVM.perpWinRate * 100))%",
                        valueColor: portfolioVM.perpWinRate >= 0.5 ? .hlGreen : .tradingRed
                    )
                    overviewStat(
                        icon: "arrow.left.arrow.right",
                        label: "Total Volume",
                        value: formatUSD(portfolioVM.allTimeVolume),
                        valueColor: .white
                    )
                    overviewStat(
                        icon: "trophy.fill",
                        label: "Best Trade",
                        value: formatPnl(portfolioVM.perpBestPeriod),
                        valueColor: .hlGreen
                    )
                }
                .background(Color.hlCardBackground)
                .cornerRadius(12)
                .padding(.horizontal, 14)
            }
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .refreshable {
            await vm.refresh(address: address)
            await portfolioVM.refresh(address: address)
        }
    }

    private func overviewStat(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(.hlGreen)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.6))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.hlCardBackground)
        .overlay(Divider().background(Color.hlDivider), alignment: .bottom)
    }

    // MARK: - Transactions Tab

    private var transactionsTab: some View {
        VStack(spacing: 0) {
            // Filter bar + count
            HStack(spacing: 0) {
                Button { showTxFilter.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 14))
                        Text("Filter (\(vm.selectedTxTypes.count)/\(WalletTransaction.TxType.allCases.count))")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(Color(white: 0.6))
                }

                if vm.txTotalCount > 0 {
                    Text("\(vm.filteredTransactions.count) / \(vm.txTotalCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }

                Button { showTxFilter.toggle() } label: {
                    Image(systemName: showTxFilter ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.hlCardBackground)

            if showTxFilter {
                txFilterGrid
            }

            Divider().background(Color.hlDivider)

            if vm.isLoading && vm.transactions.isEmpty {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredTransactions.isEmpty {
                emptyTab(icon: "list.bullet.rectangle", message: "No transactions")
            } else {
                List {
                    ForEach(vm.filteredTransactions) { tx in
                        transactionRow(tx)
                            .listRowBackground(Color.hlCardBackground)
                            .listRowSeparatorTint(Color.hlDivider)
                    }

                    // Load More button (LARP-style)
                    if vm.txHasMore {
                        if vm.txIsLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView().tint(.white)
                                Text("Loading more…")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(white: 0.4))
                                Spacer()
                            }
                            .listRowBackground(Color.hlCardBackground)
                        } else {
                            Button {
                                Task { await vm.loadMoreTransactions() }
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Load More (\(min(vm.txDisplayLimit, vm.transactions.count)) of \(vm.txTotalCount))")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.hlGreen)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .listRowBackground(Color.hlCardBackground)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh(address: address) }
            }
        }
    }

    private var txFilterGrid: some View {
        let counts = Dictionary(grouping: vm.transactions, by: \.type).mapValues(\.count)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(WalletTransaction.TxType.allCases, id: \.self) { type in
                let count = counts[type] ?? 0
                Button {
                    if vm.selectedTxTypes.contains(type) {
                        vm.selectedTxTypes.remove(type)
                    } else {
                        vm.selectedTxTypes.insert(type)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: vm.selectedTxTypes.contains(type) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                        Text(type.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        if count > 0 {
                            Text(count >= 1000 ? String(format: "%.1fK", Double(count) / 1000) : "\(count)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(vm.selectedTxTypes.contains(type) ? type.color : Color(white: 0.35))
                        }
                    }
                    .foregroundColor(vm.selectedTxTypes.contains(type) ? .white : Color(white: 0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(vm.selectedTxTypes.contains(type) ? Color(white: 0.18) : Color(white: 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(vm.selectedTxTypes.contains(type) ? type.color.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.hlCardBackground)
    }

    private func transactionRow(_ tx: WalletTransaction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tx.type.icon)
                .font(.system(size: 14))
                .foregroundColor(tx.type.color)
                .frame(width: 32, height: 32)
                .background(tx.type.color.opacity(0.12))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(tx.type.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(tx.detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(txShowUSD ? (tx.amountUSD ?? tx.amount) : tx.amount)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(tx.type.color)
                Text(relativeTime(tx.time))
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }
            .onTapGesture {
                if tx.amountUSD != nil { txShowUSD.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Perps Tab

    private var perpsTab: some View {
        Group {
            if vm.isLoading && vm.positions.isEmpty {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.positions.isEmpty {
                emptyTab(icon: "chart.bar.xaxis", message: "No open positions")
            } else {
                List(vm.positions.sorted { $0.notional > $1.notional }) { pos in
                    perpRow(pos)
                        .listRowBackground(Color.hlCardBackground)
                        .listRowSeparatorTint(Color.hlDivider)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                positionToCopy = pos
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
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh(address: address) }
            }
        }
    }

    private func perpRow(_ pos: PerpPosition) -> some View {
        VStack(spacing: 8) {
            HStack {
                CoinIconView(symbol: pos.coin, hlIconName: pos.coin, iconSize: 24)
                Text(pos.coin)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.hlGreen)
                    .onTapGesture {
                        AppState.shared.openChart(
                            symbol: pos.coin,
                            displayName: pos.coin,
                            chartVM: chartVM
                        )
                    }
                Text("\(pos.leverage)×")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))
                DirectionBadge(isLong: pos.isLong)
                Spacer()
                Text(pnlShowPercent.contains(pos.id) ? "PNL: \(pos.formattedRoe)" : pos.formattedPnl)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                    .onTapGesture {
                        if pnlShowPercent.contains(pos.id) {
                            pnlShowPercent.remove(pos.id)
                        } else {
                            pnlShowPercent.insert(pos.id)
                        }
                    }
            }
            HStack {
                labelValue("Entry",  pos.formattedEntry)
                Spacer()
                labelValue("Mark",   pos.formattedMark)
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Size")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.45))
                    Text(sizeInUSD.contains(pos.id) ? pos.formattedSizeUSD : pos.formattedSize)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                }
                .onTapGesture {
                    if sizeInUSD.contains(pos.id) {
                        sizeInUSD.remove(pos.id)
                    } else {
                        sizeInUSD.insert(pos.id)
                    }
                }
            }
            HStack {
                labelValue("Funding", pos.formattedFunding,
                           color: pos.cumulativeFunding >= 0 ? .hlGreen : .tradingRed)
                Spacer()
                labelValue("Liq Price", pos.formattedLiqPx, color: .orange)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Holdings Tab

    private var holdingsTab: some View {
        Group {
            if vm.isLoading && vm.spotBalances.isEmpty {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.spotBalances.isEmpty {
                emptyTab(icon: "bitcoinsign.circle", message: "No spot holdings")
            } else {
                List(vm.spotBalances) { bal in
                    holdingRow(bal)
                        .listRowBackground(Color.hlCardBackground)
                        .listRowSeparatorTint(Color.hlDivider)
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh(address: address) }
            }
        }
    }

    private func holdingRow(_ bal: SpotBalance) -> some View {
        HStack(spacing: 12) {
            CoinIconView(symbol: bal.coin, hlIconName: bal.coin, iconSize: 36, isSpot: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(bal.coin)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(bal.formattedTotal) \(bal.coin)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(bal.formattedUSD)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                if bal.entryNtl > 0 {
                    let pnl = bal.spotPnl
                    let pct = bal.spotPnlPct
                    Text(String(format: "%@$%@ (%@%.2f%%)",
                                pnl >= 0 ? "+" : "",
                                formatCompact(abs(pnl)),
                                pnl >= 0 ? "+" : "",
                                pct))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(pnl >= 0 ? .hlGreen : .tradingRed)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func formatCompact(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(format: "%.2f", v)
    }

    // MARK: - Staking Tab

    private var stakingTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary card
                VStack(spacing: 1) {
                    stakingStat(label: "Total Delegated",
                                value: formatHYPE(vm.staking.delegated),
                                color: .hlGreen)
                    stakingStat(label: "Undelegated",
                                value: formatHYPE(vm.staking.undelegated),
                                color: .white)
                    stakingStat(label: "Pending Withdrawal",
                                value: formatHYPE(vm.staking.pendingWithdrawal),
                                color: vm.staking.pendingWithdrawal > 0 ? .orange : .white)
                    stakingStat(label: "Total Rewards",
                                value: formatHYPE(vm.staking.totalRewards),
                                color: .hlGreen)
                }
                .background(Color.hlCardBackground)
                .cornerRadius(12)

                // Active delegations
                if !vm.staking.delegations.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Delegations")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)

                        ForEach(vm.staking.delegations) { d in
                            HStack(spacing: 12) {
                                Image(systemName: "person.badge.shield.checkmark.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.hlGreen)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.validatorName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                    if let lock = d.lockedUntil {
                                        Text("Locked until \(shortDate(lock))")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(white: 0.4))
                                    }
                                }
                                Spacer()
                                Text(formatHYPE(d.amount))
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(12)
                            .background(Color.hlCardBackground)
                            .cornerRadius(10)
                        }
                    }
                }

                // Recent rewards
                if !vm.staking.rewards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Rewards")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)

                        ForEach(vm.staking.rewards.prefix(20)) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.source == "commission" ? "Commission" : "Delegation")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(shortDate(r.time))
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(white: 0.4))
                                }
                                Spacer()
                                Text("+\(formatHYPE(r.amount))")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.hlGreen)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.hlCardBackground)
                            .cornerRadius(8)
                        }
                    }
                }

                if vm.isLoading && vm.staking.delegated == 0 && vm.staking.rewards.isEmpty {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if vm.staking.delegated == 0 && vm.staking.rewards.isEmpty {
                    emptyTab(icon: "lock.fill", message: "No staking activity")
                }
            }
            .padding(14)
        }
        .refreshable { await vm.refresh(address: address) }
    }

    private func stakingStat(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.6))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.hlCardBackground)
        .overlay(Divider().background(Color.hlDivider), alignment: .bottom)
    }

    private static let hypeFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = 2
        return fmt
    }()

    private func formatHYPE(_ v: Double) -> String {
        if v == 0 { return "0 HYPE" }
        let formatted = Self.hypeFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
        return "\(formatted) HYPE"
    }

    private static let shortDateFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd MMM yyyy"
        return fmt
    }()

    private func shortDate(_ date: Date) -> String {
        Self.shortDateFmt.string(from: date)
    }

    // MARK: - Orders Tab

    private var ordersTab: some View {
        Group {
            if vm.isLoading && vm.openOrders.isEmpty {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.openOrders.isEmpty {
                emptyTab(icon: "list.bullet.clipboard", message: "No open orders")
            } else {
                List(vm.openOrders) { order in
                    orderRow(order)
                        .listRowBackground(Color.hlCardBackground)
                        .listRowSeparatorTint(Color.hlDivider)
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh(address: address) }
            }
        }
    }

    private func orderRow(_ order: OpenOrder) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(order.coin)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(order.orderType)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.5))
                    DirectionBadge(isLong: order.isBuy)
                }
                Text("Size: \(order.formattedSize)")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(order.formattedPrice)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(relativeTime(order.timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func labelValue(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
    }

    private func emptyTab(icon: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(Color(white: 0.3))
            Text(message)
                .foregroundColor(Color(white: 0.4))
        }
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
                Task { await vm.refresh(address: address) }
                Task { await portfolioVM.refresh(address: address) }
            }
                .buttonStyle(.bordered).tint(.hlGreen)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatPnl(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : "-"
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        let formatted = formatter.string(from: NSNumber(value: abs(v))) ?? String(format: "%.2f", abs(v))
        return "PNL : \(sign)$\(formatted)"
    }

    private func formatUSD(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "$%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000     { return String(format: "$%.2fM", v / 1_000_000) }
        if v >= 1_000         { return String(format: "$%.1fK", v / 1_000) }
        return String(format: "$%.2f", v)
    }

    /// Convert a PerpPosition (from WalletDetailVM) to TrackedPosition (for ShareCard/CopyTrade)
    private func trackedPosition(from pos: PerpPosition) -> TrackedPosition? {
        TrackedPosition(
            address: address,
            coin: pos.coin,
            size: pos.sizeAbs,
            entryPrice: pos.entryPrice,
            markPrice: pos.markPrice,
            unrealizedPnl: pos.unrealizedPnl,
            leverage: pos.leverage,
            isLong: pos.isLong,
            notionalUSD: pos.notional
        )
    }
}
