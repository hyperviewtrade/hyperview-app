import SwiftUI
import Combine

// MARK: - AppState — drives programmatic tab switching

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var selectedTab: Int = 0
    /// Pending deep link URL (stored while app is locked, processed after unlock).
    var pendingDeepLink: URL?
    /// Wallet address to open when a liquidation notification is tapped.
    @Published var pendingWalletAddress: String?

    /// When true, navigate to the Liquidations section on Home tab
    @Published var pendingLiquidationOpen: Bool = false

    /// Position coin to open from widget deep link
    @Published var pendingPositionCoin: String?

    /// Incremented each time the user taps the already-selected Home tab.
    @Published var homeReselect: Int = 0
    /// Incremented each time the user taps the already-selected Markets tab.
    @Published var marketsReselect: Int = 0

    /// Category to select when navigating to Markets tab (nil = keep current).
    @Published var pendingMarketCategory: MainCategory?
    /// Optional perps sub-category (for HIP-3 deep link from Home).
    @Published var pendingPerpSub: PerpSubCategory?

    private init() {}

    func openChart(symbol: String, displayName: String? = nil, perpEquivalent: String? = nil,
                   chartVM: ChartViewModel, isCustomTV: Bool = false) {
        chartVM.isCustomTVChart = isCustomTV
        if isCustomTV {
            // For custom TV symbols, prefix with "TV:" so the JS side uses the UDF datafeed
            let tvSymbol = "TV:\(symbol)"
            chartVM.selectedSymbol = tvSymbol
            chartVM.selectedDisplayName = displayName ?? symbol
            chartVM.livePrice = 0
            chartVM.candles = []
            chartVM.orderBook = nil
        } else {
            // Set symbol immediately so TradingView switches at once (loadChart has a 150ms debounce)
            chartVM.selectedSymbol = symbol
            if let dn = displayName { chartVM.selectedDisplayName = dn }
            // Always reload — bypasses changeSymbol's guard so we don't get stuck
            // showing the previous chart (e.g. after viewing a custom TradingView chart)
            Task { await chartVM.loadChart(symbol: symbol, interval: chartVM.selectedInterval,
                                           displayName: displayName, perpEquivalent: perpEquivalent) }
        }
        selectedTab = 2
    }

    func openTrack() {
        selectedTab = 3
    }

    func openMarkets(category: MainCategory? = nil) {
        pendingMarketCategory = category
        selectedTab = 1
    }

    /// Handle a deep link URL from a widget tap.
    func handleDeepLink(_ url: URL, chartVM: ChartViewModel) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        if components.host == "markets" {
            openMarkets()
            return
        }

        if components.host == "position",
           let coin = components.queryItems?.first(where: { $0.name == "coin" })?.value {
            selectedTab = 0
            pendingPositionCoin = coin
            return
        }

        if components.host == "wallet",
           let address = components.queryItems?.first(where: { $0.name == "address" })?.value {
            print("[DEEPLINK] Opening wallet: \(address)")
            selectedTab = 0
            pendingWalletAddress = address
            return
        }

        guard components.host == "chart",
              let symbol = components.queryItems?.first(where: { $0.name == "s" })?.value
        else { return }
        let displayName = components.queryItems?.first(where: { $0.name == "n" })?.value
        let isCustomTV = symbol.hasPrefix("TV:")
        let cleanSymbol = isCustomTV ? String(symbol.dropFirst(3)) : symbol
        openChart(symbol: cleanSymbol, displayName: displayName, chartVM: chartVM, isCustomTV: isCustomTV)
    }
}

// MARK: - ContentView
// 5 tabs matching the spec:
//   0 Home (smart money feed)
//   1 Markets
//   2 Chart
//   3 Track
//   4 Settings

struct ContentView: View {
    @StateObject private var marketsVM  = MarketsViewModel()
    @StateObject private var chartVM    = ChartViewModel()
    @StateObject private var tradingVM  = TradingViewModel()
    @StateObject private var watchVM    = WatchlistViewModel()
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var wallet = WalletManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true

    var body: some View {
        ZStack {
        TabView(selection: $appState.selectedTab) {

            // ── 0: Home ─────────────────────────────────────────────
            NavigationStack {
                HomeView()
                    .background(
                        TabBarReselectionHelper { tab in
                            switch tab {
                            case 0: appState.homeReselect += 1
                            case 1: appState.marketsReselect += 1
                            default: break
                            }
                        }
                    )
            }
            .environmentObject(marketsVM)
            .environmentObject(chartVM)
            .environmentObject(watchVM)
            .tag(0)
            .tabItem { Label("Home", systemImage: "bolt.fill") }

            // ── 1: Markets ──────────────────────────────────────────
            NavigationStack {
                MarketsView()
            }
            .environmentObject(marketsVM)
            .environmentObject(chartVM)
            .environmentObject(watchVM)
            .tag(1)
            .tabItem { Label("Markets", systemImage: "chart.bar.xaxis") }

            // ── 2: Chart + Trade ────────────────────────────────────
            NavigationStack {
                ChartContainerView()
            }
            .environmentObject(chartVM)
            .environmentObject(tradingVM)
            .environmentObject(marketsVM)
            .environmentObject(watchVM)
            .tag(2)
            .tabItem { Label("Trade", systemImage: "arrow.left.arrow.right") }

            // ── 3: Track ──────────────────────────────────────────────
            NavigationStack {
                TrackView()
            }
            .environmentObject(marketsVM)
            .environmentObject(chartVM)
            .tag(3)
            .tabItem { Label("Track", systemImage: "magnifyingglass") }

            // ── 4: Settings ─────────────────────────────────────────
            NavigationStack {
                SettingsView()
            }
            .tag(4)
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.hlGreen)
        .preferredColorScheme(.dark)
        // Load markets from the root view — ContentView never disappears,
        // so this Task is never cancelled by tab switching.
        .task { await marketsVM.loadMarkets() }
        // Early candle prefetch — warms cache for the most likely first chart open.
        // Deferred 1s so critical startup requests (markets, positions) get a head start.
        .task {
            try? await Task.sleep(for: .seconds(1))
            let interval = chartVM.selectedInterval
            TradingViewChartView.Coordinator.earlyPrefetch(symbol: "BTC", interval: interval)
        }
        // Non-critical prefetches — deferred to reduce startup request storm
        .task {
            try? await Task.sleep(for: .seconds(5))
            UnstakingViewModel.shared.prefetch()
            async let _ = RelativePerformanceViewModel.shared.load()
        }

            // Onboarding overlay — blocks entire UI on first launch
            if !wallet.hasCompletedOnboarding {
                OnboardingWalletView()
                    .transition(.opacity)
            }

            // Lock screen — Face ID / Password gate
            if wallet.hasCompletedOnboarding && (wallet.biometricEnabled || wallet.hasPassword) && !wallet.isUnlocked {
                LockScreenView()
                    .transition(.opacity)
            }

            // Transaction password prompt overlay
            if wallet.pendingPasswordAuth {
                TransactionPasswordOverlay()
                    .transition(.opacity)
                    .zIndex(5)
            }

            // Splash screen — shows logo while app loads in background
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: wallet.hasCompletedOnboarding)
        .animation(.easeInOut(duration: 0.25), value: wallet.isUnlocked)
        .animation(.easeOut(duration: 0.5), value: showSplash)
        .onOpenURL { url in
            if wallet.isUnlocked || (!wallet.biometricEnabled && !wallet.hasPassword) {
                appState.handleDeepLink(url, chartVM: chartVM)
            } else {
                appState.pendingDeepLink = url
            }
        }
        .onChange(of: wallet.isUnlocked) { _, unlocked in
            if unlocked, let url = appState.pendingDeepLink {
                appState.pendingDeepLink = nil
                appState.handleDeepLink(url, chartVM: chartVM)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // Build the unified display order (same logic as MarketsView.marketsList)
                // so the widget shows custom charts at their correct positions.
                let watchedSet = Set(watchVM.symbols)
                let displayed = marketsVM.cachedFilteredMarkets
                let customCharts = CustomChartStore.shared.charts

                let favMarkets    = displayed.filter { watchedSet.contains($0.symbol) }
                let nonFavMarkets = displayed.filter { !watchedSet.contains($0.symbol) }
                let favCustom     = customCharts.filter { watchedSet.contains("TV:\($0.symbol)") }
                let nonFavCustom  = customCharts.filter { !watchedSet.contains("TV:\($0.symbol)") }

                var orderKeys: [String] = []
                orderKeys += favMarkets.map(\.symbol)
                orderKeys += favCustom.map { "TV:\($0.symbol)" }
                orderKeys += nonFavCustom.map { "TV:\($0.symbol)" }
                orderKeys += nonFavMarkets.map(\.symbol)

                // Apply custom symbol order if user has manually reordered
                if let savedOrder = marketsVM.customSymbolOrder {
                    let orderMap = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
                    orderKeys.sort { a, b in
                        let ia = orderMap[a] ?? Int.max
                        let ib = orderMap[b] ?? Int.max
                        return ia < ib
                    }
                }

                marketsVM.forceWidgetReload(unifiedOrder: orderKeys)
                wallet.lockApp()
            } else if phase == .active && !wallet.isUnlocked && (wallet.biometricEnabled || wallet.hasPassword) {
                Task { await wallet.authenticateAppLaunch() }
            }
        }
        .task {
            // Authenticate on first launch
            if (wallet.biometricEnabled || wallet.hasPassword) && !wallet.isUnlocked {
                await wallet.authenticateAppLaunch()
            }
        }
        .task {
            // Dismiss splash after 5s — logo animation fills the full duration
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            showSplash = false
        }
    }
}

// MARK: - Tab Bar Reselection Helper (UIKit bridge)

/// Detects when the user taps an already-selected tab bar item.
/// Preserves the original SwiftUI delegate by forwarding all calls.
struct TabBarReselectionHelper: UIViewControllerRepresentable {
    let onReselect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReselect: onReselect)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.frame = .zero
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let tabBarController = vc.tabBarController else { return }
            if tabBarController.delegate !== context.coordinator {
                // Save the original SwiftUI delegate so we can forward calls
                context.coordinator.originalDelegate = tabBarController.delegate
                tabBarController.delegate = context.coordinator
            }
        }
    }

    class Coordinator: NSObject, UITabBarControllerDelegate {
        let onReselect: (Int) -> Void
        weak var originalDelegate: UITabBarControllerDelegate?

        init(onReselect: @escaping (Int) -> Void) {
            self.onReselect = onReselect
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              shouldSelect viewController: UIViewController) -> Bool {
            if let index = tabBarController.viewControllers?.firstIndex(of: viewController),
               index == tabBarController.selectedIndex {
                onReselect(index)
            }
            // Forward to original SwiftUI delegate
            return originalDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              didSelect viewController: UIViewController) {
            originalDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }
    }
}
