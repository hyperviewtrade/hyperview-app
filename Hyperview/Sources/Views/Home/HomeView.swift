import SwiftUI
import SafariServices
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @EnvironmentObject var marketsVM: MarketsViewModel
    @ObservedObject private var wallet = WalletManager.shared
    @ObservedObject private var twapVM = TWAPViewModel.shared
    @ObservedObject private var sentimentVM = SentimentViewModel.shared
    @StateObject private var earnVM = EarnViewModel()

    @State private var showDepositMenu  = false
    @State private var showWithdrawMenu = false
    @State private var showDepositCrypto  = false
    @State private var showDepositUSDC    = false
    @State private var showBuyCrypto      = false
    @State private var showWithdrawCrypto = false
    @State private var showSellFiat       = false
    @State private var showTransfer       = false
    @State private var showSendAsset      = false
    @State private var showWalletDetail   = false
    @State private var showDappBrowser    = false
    @State private var showCopied         = false
    @State private var showStaking        = false
    @State private var showUnstaking      = false
    @State private var showHomeSettings   = false
    @ObservedObject private var cardOrder = HomeCardOrder.shared

    // Position detail from Home
    @State private var homeSelectedPosition: PerpPosition?
    // showHomePositionDetail removed — using .fullScreenCover(item:) instead

    // Notification deep-link → wallet
    @ObservedObject private var appState = AppState.shared
    @State private var notifWalletAddress = ""
    @State private var showNotifWallet    = false

    // Phantom wallet
    @AppStorage("hl_phantomAddress") private var phantomAddress = ""
    @State private var phantomBalance: Double = 0
    @State private var phantomPnl: Double = 0
    @State private var globalAliases: [String: String] = [:]

    // Filter reorder
    @AppStorage("hl_filterOrder") private var filterOrderRaw = ""
    @State private var draggedFilter: FeedFilter?

    // Scroll-to-top on tab reselection
    @State private var lastReselectTime: Date = .distantPast
    @State private var homeScrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {

            // ── Filter bar ──────────────────────────────────────────
            filterBar

            Divider().background(Color.hlSurface)

            // ── Content ─────────────────────────────────────────────
            contentForSelectedFilter
        }
        .background(Color.hlBackground)
        .copyToast(show: $showCopied)
        .navigationTitle("Hyperview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { logoItem; settingsItem }
        .sheet(isPresented: $showHomeSettings) {
            HomeSettingsSheet()
        }
        .task {
            print("[STARTUP] HOME APPEAR t=\(Int(Date().timeIntervalSince1970 * 1000))")
            // Start feed immediately — don't block on markets loading
            if !marketsVM.markets.isEmpty {
                vm.start(markets: marketsVM.markets)
            }
            // Defer non-critical background fetches to reduce startup request storm
            Task {
                try? await Task.sleep(for: .seconds(3))
                print("[STARTUP] ALIASES LOAD START (deferred 3s)")
                await loadGlobalAliases()
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(4))
                print("[STARTUP] LEADERBOARD+WHALES LOAD START (deferred 4s)")
                await LeaderboardViewModel.shared.load()
                await LargestPositionsViewModel.shared.load()
            }
        }
        .onChange(of: marketsVM.markets.count) { _, count in
            // Start feed as soon as markets become available (reactive, no polling)
            if count > 0 && !vm.isLive {
                vm.start(markets: marketsVM.markets)
            }
        }
        // ── Sheets ──────────────────────────────────────────────
        .sheet(isPresented: $showDepositMenu)  { depositMenuSheet }
        .sheet(isPresented: $showWithdrawMenu) { withdrawMenuSheet }
        .sheet(isPresented: $showDepositCrypto) {
            NavigationStack { DepositCryptoView() }
        }
        .sheet(isPresented: $showDepositUSDC) {
            NavigationStack {
                DepositAddressView(asset: .init(name: "USDC", network: "Arbitrum",
                                                minDeposit: "5", estimatedTime: "~2 min",
                                                estimatedFee: "~$0.10",
                                                fixedAddress: "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7"))
            }
        }
        .sheet(isPresented: $showBuyCrypto) {
            NavigationStack { BuyCryptoView() }
        }
        .sheet(isPresented: $showWithdrawCrypto) {
            NavigationStack { WithdrawCryptoView() }
        }
        .sheet(isPresented: $showSellFiat) {
            if let url = moonPaySellURL {
                SafariSheet(url: url)
            }
        }
        .sheet(isPresented: $showTransfer) {
            TransferView()
        }
        .sheet(isPresented: $showSendAsset) {
            SendAssetView()
        }
        .navigationDestination(isPresented: $showWalletDetail) {
            if isPhantomActive {
                WalletDetailView(address: phantomAddress)
                    .navigationTitle("Phantom Wallet")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .tabBar)
            } else {
                WalletTabView()
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .navigationDestination(isPresented: $showStaking) {
            StakingView()
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showUnstaking) {
            UnstakingView()
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showNotifWallet) {
            WalletDetailView(address: notifWalletAddress)
                .toolbar(.hidden, for: .tabBar)
        }
        .onChange(of: appState.pendingWalletAddress) { _, address in
            if let address = address {
                notifWalletAddress = address
                showNotifWallet = true
                appState.pendingWalletAddress = nil
            }
        }
        .onChange(of: appState.pendingLiquidationOpen) { _, open in
            if open {
                vm.selectedFilter = .liquidations
                appState.pendingLiquidationOpen = false
            }
        }
        .onAppear {
            // Handle notification tap on cold start (onChange won't fire if already set)
            if appState.pendingLiquidationOpen {
                vm.selectedFilter = .liquidations
                appState.pendingLiquidationOpen = false
            }
        }
        .onChange(of: appState.pendingPositionCoin) { _, coin in
            if let coin = coin,
               let pos = wallet.activePositions.first(where: { $0.coin == coin }) {
                homeSelectedPosition = pos
                appState.pendingPositionCoin = nil
            }
        }
        .onChange(of: appState.homeReselect) { _, _ in
            let now = Date()
            let elapsed = now.timeIntervalSince(lastReselectTime)

            if vm.selectedFilter == .home {
                // Already on home — scroll to top
                withAnimation { homeScrollProxy?.scrollTo("homeTop", anchor: .top) }
            } else if elapsed < 0.7 {
                // Quick double-tap — switch to home (Total Balance)
                withAnimation(.easeInOut(duration: 0.15)) { vm.selectedFilter = .home }
            }
            // else: first tap while on a sub-tab — sub-views handle their own scroll-to-top

            lastReselectTime = now
        }
        .fullScreenCover(isPresented: $showDappBrowser) {
            DappBrowserView()
        }
    }

    // MARK: - Staking content (from filter bar)

    private var stakingContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Color.clear.frame(height: 0).id("stakingTop")
                // Staking button
                Button { showStaking = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.hlGreen)
                            .frame(width: 40, height: 40)
                            .background(Color.hlGreen.opacity(0.12))
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Staking")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("Stake HYPE, view validators & rewards")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.5))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(white: 0.09))
                    )
                }

                // Unstaking button
                Button { showUnstaking = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                            .frame(width: 40, height: 40)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unstaking")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("Queue, stats & upcoming unstaking")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.5))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(white: 0.09))
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
        } // ScrollViewReader
    }

    // MARK: - Home content (balance card + recent activity)

    private var isPhantomActive: Bool {
        !phantomAddress.isEmpty && phantomAddress.hasPrefix("0x") && phantomAddress.count == 42
    }

    @ViewBuilder
    private var contentForSelectedFilter: some View {
        switch vm.selectedFilter {
        case .home:         homeContent
        case .liquidations: LiquidationsView()
        case .heatmap:      LiquidationHeatmapView()
        case .staking:      stakingContent
        case .topTraders:   LeaderboardView()
        case .whales:       WhalesContainerView()
        case .twap:         TWAPView()
        case .signals:      AnalyticsView()
        case .earn:         EarnTabView(earnVM: earnVM)
        default:
            ZStack {
                if vm.filteredEvents.isEmpty { emptyState }
                else { feedList }
            }
        }
    }

    private var homeContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 20) {
                Color.clear.frame(height: 0).id("homeTop")

                ForEach(cardOrder.cards.filter(\.isVisible)) { card in
                    homeCard(for: card.id)
                }
            }
            .padding(.bottom, 20)
        }
        .onAppear { homeScrollProxy = proxy }
        .refreshable {
            if isPhantomActive {
                await loadPhantomBalance()
            } else {
                await wallet.refreshAccountState()
            }
            await twapVM.refresh()
        }
        .task(id: phantomAddress) {
            if isPhantomActive {
                await loadPhantomBalance()
            }
        }
        .task(id: wallet.connectedWallet?.address) {
            await earnVM.load()
        }
        .task {
            print("[STARTUP] TWAP LOAD START t=\(Int(Date().timeIntervalSince1970 * 1000))")
            if !twapVM.hasLoaded {
                await twapVM.load()
            }
            print("[STARTUP] TWAP LOAD END t=\(Int(Date().timeIntervalSince1970 * 1000))")
        }
        .task {
            // Defer sentiment — not above-the-fold, let critical data load first
            try? await Task.sleep(for: .seconds(2))
            print("[STARTUP] SENTIMENT LOAD START (deferred 2s)")
            await sentimentVM.load()
            print("[STARTUP] SENTIMENT LOAD END")
        }
        .onAppear {
            twapVM.startHomePressurePolling()
        }
        .onDisappear {
            twapVM.stopHomePressurePolling()
        }
        } // ScrollViewReader
    }

    // MARK: - Balance card

    private func phantomAlias() -> String? {
        let key = phantomAddress.lowercased()
        let custom = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        if let c = custom[key] { return c }
        return globalAliases[key]
    }

    private var balanceCard: some View {
        let displayAddress: String = isPhantomActive ? phantomAddress : (wallet.connectedWallet?.address ?? "")
        let shortAddr: String = {
            guard displayAddress.count > 10 else { return displayAddress }
            return "\(displayAddress.prefix(6))…\(displayAddress.suffix(4))"
        }()
        let balance: Double = {
            if isPhantomActive { return phantomBalance }
            if earnVM.portfolioMarginEnabled {
                return earnVM.spotAccountValue
            }
            return wallet.accountValue
        }()
        let pnl     = isPhantomActive ? phantomPnl : wallet.dailyPnl
        let denom   = balance - pnl
        let pnlPct  = denom != 0 ? (pnl / denom) * 100 : 0

        return VStack(alignment: .leading, spacing: 10) {
            // Wallet address
            if !displayAddress.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(isPhantomActive ? Color.orange : Color.hlGreen).frame(width: 5, height: 5)
                    if isPhantomActive {
                        Text("👻")
                            .font(.system(size: 9))
                    }
                    if isPhantomActive, let alias = phantomAlias() {
                        Text(alias)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text(shortAddr)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(white: 0.35))
                    } else {
                        Text(shortAddr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                    }
                    Button {
                        copyWithToast(displayAddress, show: $showCopied)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
            }

            // Total balance
            VStack(alignment: .leading, spacing: 4) {
                Text(isPhantomActive ? "Phantom Balance" : "Total Balance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.5))

                Text(formatUSD(balance))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                // Daily PnL
                HStack(spacing: 4) {
                    Text("PNL (24h) :")
                    Text(pnl >= 0 ? "+\(formatUSD(pnl))" : formatUSD(pnl))
                    Text("(\(String(format: "%+.2f%%", pnlPct)))")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(pnl >= 0 ? .hlGreen : .red)
            }

            // Action buttons
            if isPhantomActive {
                Button {
                    showWalletDetail = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.fill")
                        Text("View Wallet")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.hlGreen)
                    .cornerRadius(10)
                }
            } else {
                // Row 1: Deposit + Withdraw
                HStack(spacing: 8) {
                    Button {
                        showDepositMenu = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11))
                            Text("Deposit")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                    }

                    Button {
                        showWithdrawMenu = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 11))
                            Text("Withdraw")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                    }

                    Button {
                        showTransfer = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 11))
                            Text("Transfer")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                    }

                    Button {
                        showSendAsset = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11))
                            Text("Send")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.hlGreen)
                        .cornerRadius(10)
                    }
                }

            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { showWalletDetail = true }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Home Positions Card

    @ViewBuilder
    private var homePositionsCard: some View {
        if wallet.activePositions.isEmpty {
            EmptyView()
        } else {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Positions")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(wallet.activePositions.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().background(Color(white: 0.15))

            // Position rows
            ForEach(wallet.activePositions) { pos in
                Button {
                    homeSelectedPosition = pos
                } label: {
                    homePositionRow(pos)
                }
                .buttonStyle(.plain)

                if pos.id != wallet.activePositions.last?.id {
                    Divider().background(Color(white: 0.1)).padding(.horizontal, 12)
                }
            }
        }
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
        .sheet(item: $homeSelectedPosition) { pos in
            PositionDetailSheet(
                position: pos,
                marketsVM: marketsVM,
                onDismiss: { homeSelectedPosition = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        } // else (has positions)
    }

    private func homePositionRow(_ pos: PerpPosition) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(pos.coin)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(pos.isLong ? "LONG" : "SHORT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(pos.isLong ? .hlGreen : .tradingRed)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((pos.isLong ? Color.hlGreen : Color.tradingRed).opacity(0.15))
                    .cornerRadius(4)
                Text("\(pos.isCross ? "Cross" : "Iso") \(pos.leverage)× - \(pos.formattedMargin) \(wallet.isPortfolioMargin ? (pos.isCross ? "(PM)" : "(Isolated)") : "")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                let pnlPct = pos.entryPrice != 0
                    ? (pos.unrealizedPnl / (pos.sizeAbs * pos.entryPrice)) * 100 : 0
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%+.2f USDC", pos.unrealizedPnl))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                    Text(String(format: "%+.2f%%", pnlPct))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(pos.unrealizedPnl >= 0 ? .hlGreen : .tradingRed)
                }
            }
            // Row 1: Size (with token), Entry, Mark
            HStack {
                Text("Size")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text("\(String(format: "%.4f", pos.sizeAbs)) \(pos.coin)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Entry")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedEntry)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text("Mark")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedMark)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            }
            // Row 2: Position Value, Liq
            HStack {
                Text("Position Value")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.4))
                Text(pos.formattedSizeUSD.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                if let liq = pos.liquidationPx {
                    Text("Liq")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                    Text(pos.formattedLiqPx)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Deposit menu sheet

    private var depositMenuSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            Text("Deposit")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)
                .padding(.bottom, 20)

            VStack(spacing: 1) {
                menuRow(icon: "arrow.down.to.line", title: "Deposit Crypto",
                        subtitle: "BTC, ETH, SOL, USDC and more") {
                    showDepositMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showDepositCrypto = true
                    }
                }

                menuRow(icon: "dollarsign.circle", title: "Deposit USDC",
                        subtitle: "Direct deposit on Arbitrum") {
                    showDepositMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showDepositUSDC = true
                    }
                }

                menuRow(icon: "creditcard", title: "Buy with Card",
                        subtitle: "Visa, Mastercard, Apple Pay") {
                    showDepositMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showBuyCrypto = true
                    }
                }
            }

            Spacer()
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    // MARK: - Withdraw menu sheet

    private var withdrawMenuSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            Text("Withdraw")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 16)
                .padding(.bottom, 20)

            VStack(spacing: 1) {
                menuRow(icon: "arrow.up.forward", title: "Withdraw Crypto",
                        subtitle: "USDC, BTC, ETH, SOL") {
                    showWithdrawMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showWithdrawCrypto = true
                    }
                }

                menuRow(icon: "banknote", title: "Sell to Fiat",
                        subtitle: "Off-ramp via MoonPay") {
                    showWithdrawMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showSellFiat = true
                    }
                }
            }

            Spacer()
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    // MARK: - Menu row helper

    private func menuRow(icon: String, title: String, subtitle: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.hlGreen)
                    .frame(width: 36, height: 36)
                    .background(Color.hlGreen.opacity(0.12))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.5))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(white: 0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.hlCardBackground)
        }
    }

    // MARK: - Filter bar

    private var orderedFilters: [FeedFilter] {
        guard !filterOrderRaw.isEmpty else { return FeedFilter.allCases.map { $0 } }
        let saved = filterOrderRaw.components(separatedBy: ",")
        let mapped = saved.compactMap { raw in FeedFilter(rawValue: raw) }
        // Append any new filters not in saved order
        let missing = FeedFilter.allCases.filter { f in !mapped.contains(f) }
        return mapped + missing
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(orderedFilters) { filter in
                    filterChip(filter)
                        .onDrag {
                            draggedFilter = filter
                            return NSItemProvider(object: filter.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: FilterDropDelegate(
                            target: filter,
                            current: $draggedFilter,
                            filters: orderedFilters,
                            onReorder: { newOrder in
                                filterOrderRaw = newOrder.map(\.rawValue).joined(separator: ",")
                            }
                        ))
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 46)
    }

    private func filterChip(_ filter: FeedFilter) -> some View {
        let isActive = vm.selectedFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                vm.selectedFilter = filter
            }
        } label: {
            Text(filter.displayLabel)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : Color(white: 0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.hlGreen : Color.hlButtonBg)
                .cornerRadius(20)
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 10) {
                Color.clear.frame(height: 0).id("feedTop")
                ForEach(vm.filteredEvents) { event in
                    eventCard(event)
                        .padding(.horizontal, 14)
                        .transition(.asymmetric(
                            insertion: .push(from: .top).combined(with: .opacity),
                            removal:   .opacity
                        ))
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
            .animation(.easeInOut(duration: 0.3), value: vm.filteredEvents.count)
        }
        .refreshable {
            vm.start(markets: marketsVM.markets)
        }
        // homeReselect handled in main onChange (line 154)
        }
    }

    // MARK: - Card router

    @ViewBuilder
    private func eventCard(_ event: SmartMoneyEvent) -> some View {
        switch event {
        case .whaleTrade(let e):    WhaleTradeCard(event: e)
        case .liquidation(let e):   LiquidationCard(event: e)
        case .topTraderMove(let e): TopTraderCard(event: e)
        case .signal(let e):        SignalCard(event: e)
        case .staking(let e):       StakingCard(event: e)
        case .oiSurge(let e):       OISurgeCard(event: e)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("⚡️")
                .font(.system(size: 52))
            Text("Connecting to Hyperliquid…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text("Smart money activity will appear here in real time.")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Dynamic Card Router

    @ViewBuilder
    private func homeCard(for id: String) -> some View {
        switch id {
        case "balance":
            balanceCard
                .padding(.horizontal, 14)
                .padding(.top, 14)
        case "positions":
            homePositionsCard
                .padding(.horizontal, 14)
        case "earn":
            homeEarnCard
                .padding(.horizontal, 14)
        case "twap":
            homeBuyPressureCard
                .padding(.horizontal, 14)
                .task {
                    if !twapVM.hasLoaded {
                        await twapVM.load()
                    }
                }
        case "buyback":
            FeesBuybackCard()
                .padding(.horizontal, 14)
        case "markets":
            HomeMarketsCard()
                .padding(.horizontal, 14)
        case "heatmap":
            if !sentimentVM.heatmapTiles.isEmpty {
                SentimentHeatmapView(
                    tiles: sentimentVM.heatmapTiles,
                    maxTiles: 10
                )
                .padding(.horizontal, 14)
            }
        case "unstaking":
            HomeUnstakingCard(showFullUnstaking: $showUnstaking)
                .padding(.horizontal, 14)
        case "staking":
            HomeRelativePerformanceCard()
                .padding(.horizontal, 14)
        // stables removed
        default:
            EmptyView()
        }
    }

    // MARK: - Toolbar Items

    private var logoItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 6) {
                Image("HyperviewLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var settingsItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showHomeSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .foregroundColor(.hlGreen)
            }
        }
    }

    // MARK: - Helpers

    private static let usdFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.locale = Locale(identifier: "en_US")
        fmt.maximumFractionDigits = 2
        return fmt
    }()

    private func loadPhantomBalance() async {
        guard isPhantomActive else { return }
        do {
            // Fetch comprehensive data from portfolio API (includes perps + spot)
            var balanceSet = false
            let portfolio = try await HyperliquidAPI.shared.fetchPortfolio(address: phantomAddress)
            for entry in portfolio {
                guard let period = entry["period"] as? String, period == "day" else { continue }

                // Account value from portfolio history (comprehensive)
                if let avhRaw = entry["accountValueHistory"] as? [Any],
                   let lastPair = avhRaw.last as? [Any],
                   lastPair.count >= 2 {
                    if let val = lastPair[1] as? Double {
                        phantomBalance = val
                        balanceSet = true
                    } else if let valStr = lastPair[1] as? String, let val = Double(valStr) {
                        phantomBalance = val
                        balanceSet = true
                    }
                }

                // 24h PnL
                if let pnlRaw = entry["pnlHistory"] as? [Any],
                   let lastPair = pnlRaw.last as? [Any],
                   lastPair.count >= 2 {
                    if let pnlVal = lastPair[1] as? Double {
                        phantomPnl = pnlVal
                    } else if let pnlStr = lastPair[1] as? String, let pnlVal = Double(pnlStr) {
                        phantomPnl = pnlVal
                    }
                }
                break
            }

            // Fallback: clearinghouseState if portfolio didn't provide balance
            if !balanceSet {
                let state = try await HyperliquidAPI.shared.fetchUserState(address: phantomAddress)
                if let marginSummary = state["marginSummary"] as? [String: Any],
                   let valStr = marginSummary["accountValue"] as? String,
                   let val = Double(valStr) {
                    phantomBalance = val
                }
            }
        } catch {
            print("⚠️ Phantom balance fetch failed: \(error)")
        }
    }

    private func formatUSD(_ value: Double) -> String {
        Self.usdFormatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private func loadGlobalAliases() async {
        guard let url = URL(string: "https://api.hypurrscan.io/globalAliases"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        globalAliases = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.lowercased(), $0.value) })
    }

    private var moonPaySellURL: URL? {
        guard let addr = wallet.connectedWallet?.address else { return nil }
        guard var comps = URLComponents(string: "https://sell.moonpay.com/") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "apiKey", value: "pk_live_YOUR_KEY"),
            URLQueryItem(name: "baseCurrencyCode", value: "usdc_arbitrum"),
            URLQueryItem(name: "refundWalletAddress", value: addr),
            URLQueryItem(name: "theme", value: "dark"),
        ]
        return comps.url
    }

    // MARK: - Earn Card

    @ViewBuilder
    private var homeEarnCard: some View {
        if earnVM.supplyAssets.contains(where: { $0.userSupplied > 0 }) ||
           earnVM.borrowAssets.contains(where: { $0.userBorrowed > 0 }) {
            VStack(alignment: .leading, spacing: 10) {
                // Title
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundColor(.hlGreen)
                    Text("Earn")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        vm.selectedFilter = .earn
                    } label: {
                        Text("View all")
                            .font(.system(size: 12))
                            .foregroundColor(.hlGreen)
                    }
                }

                // Stats row
                HStack(spacing: 8) {
                    earnStat("Supplied", formatCompact(earnVM.totalSuppliedUSD), color: .white)
                    earnStat("Borrowed", formatCompact(earnVM.totalBorrowedUSD), color: .white)
                    earnStat("Health Factor",
                             earnVM.totalBorrowedUSD > 0
                                ? String(format: "%.2f%%", earnVM.healthFactor)
                                : "--",
                             color: .white)
                }

                // Supply positions
                let activeSupply = earnVM.supplyAssets.filter { $0.userSupplied > 0 }
                if !activeSupply.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(activeSupply) { asset in
                            HStack(spacing: 6) {
                                CoinIconView(symbol: earnDisplayCoin(asset.coin), hlIconName: earnIconName(asset.coin), iconSize: 16)
                                Text(earnDisplayCoin(asset.coin))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Supplied")
                                    .font(.system(size: 10))
                                    .foregroundColor(.hlGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.hlGreen.opacity(0.15))
                                    .cornerRadius(4)
                                Spacer()
                                Text(earnFormatToken(asset.userSupplied, coin: asset.coin))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }

                // Borrow positions
                let activeBorrow = earnVM.borrowAssets.filter { $0.userBorrowed > 0 }
                if !activeBorrow.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(activeBorrow) { asset in
                            HStack(spacing: 6) {
                                CoinIconView(symbol: asset.coin, hlIconName: asset.coin, iconSize: 16)
                                Text(asset.coin)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Borrowed")
                                    .font(.system(size: 10))
                                    .foregroundColor(.tradingRed)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.tradingRed.opacity(0.15))
                                    .cornerRadius(4)
                                Spacer()
                                Text(earnFormatToken(asset.userBorrowed, coin: asset.coin))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.11))
            )
        }
    }

    private func earnStat(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.08))
        )
    }

    private func formatCompact(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value >= 1000 {
            return String(format: "$%.1fK", value / 1000)
        }
        return String(format: "$%.2f", value)
    }

    private func earnDisplayCoin(_ coin: String) -> String {
        coin == "UBTC" ? "BTC" : coin
    }

    private func earnIconName(_ coin: String) -> String {
        coin == "UBTC" ? "BTC" : coin
    }

    private func earnFormatToken(_ amount: Double, coin: String) -> String {
        let dc = coin == "UBTC" ? "BTC" : coin
        let stables = ["USDC", "USDH", "USDT", "USDE"]
        if stables.contains(coin) {
            return String(format: "%.2f %@", amount, dc)
        }
        if coin == "UBTC" {
            return String(format: "%.5f %@", amount, dc)
        }
        return String(format: "%.4f %@", amount, dc)
    }

    // MARK: - TWAP HYPE Buy Pressure Card

    private func hypeBuyPressure(windowSeconds: Double) -> Double {
        // Use live HYPE price from markets, never stale order.markPrice
        let livePrice = marketsVM.markets.first(where: { $0.asset.name == "HYPE" && !$0.isSpot })?.price ?? 0
        guard livePrice > 0 else { return 0 }

        let now = Date()
        var net: Double = 0
        for order in twapVM.orders where order.isActive && order.coin == "HYPE" {
            guard order.durationMinutes > 0 else { continue }
            let totalSec = Double(order.durationMinutes) * 60
            let elapsed = now.timeIntervalSince(order.timestamp)
            let remaining = max(totalSec - elapsed, 0)
            guard remaining > 0 else { continue }
            let ratePerSec = order.size / totalSec
            let inWindow = min(remaining, windowSeconds)
            let sizeInWindow = ratePerSec * inWindow
            let usd = sizeInWindow * livePrice
            net += (order.isBuy ? 1 : -1) * usd
        }
        return net
    }

    private var homeBuyPressureCard: some View {
        let p1h = twapVM.hypePressure1hUSD
        let p24h = twapVM.hypePressure24hUSD

        return VStack(spacing: 10) {
            HStack {
                Text("TWAPs HYPE Buy Pressure")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    vm.selectedFilter = .twap
                } label: {
                    HStack(spacing: 3) {
                        Text("View All")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.hlGreen)
                }
            }

            HStack {
                Text("Next 1h:")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text(pressureFormatted(p1h))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(p1h >= 0 ? .hlGreen : .tradingRed)
            }

            HStack {
                Text("Next 24h:")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                Spacer()
                Text(pressureFormatted(p24h))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(p24h >= 0 ? .hlGreen : .tradingRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }

    private func pressureFormatted(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let num = formatter.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
        return "\(sign)\(num)$"
    }
}

// MARK: - Filter drag-and-drop delegate

struct FilterDropDelegate: DropDelegate {
    let target: FeedFilter
    @Binding var current: FeedFilter?
    let filters: [FeedFilter]
    let onReorder: ([FeedFilter]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = current, dragged != target else { return }
        var arr = filters
        guard let fromIdx = arr.firstIndex(of: dragged),
              let toIdx   = arr.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            arr.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
        onReorder(arr)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        current = nil
        return true
    }
}

// MARK: - SFSafariViewController wrapper

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Color.hlGreen)
        vc.preferredBarTintColor = UIColor(white: 0.08, alpha: 1)
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
