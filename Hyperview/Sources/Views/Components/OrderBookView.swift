import SwiftUI

// MARK: - OrderBookView
// Hyperliquid-style orderbook with:
//   • Semi-transparent depth bars (green bids, red asks) scaling with order size
//   • Price column: right-aligned, bold, larger font
//   • Size column: smaller font, lighter color
//   • Aggregation + depth controls

struct OrderBookView: View {
    let orderBook: OrderBook
    var onPriceTap: ((Double) -> Void)? = nil
    @EnvironmentObject private var chartVM: ChartViewModel
    @EnvironmentObject private var marketsVM: MarketsViewModel

    @State private var depth:    Int = 20
    @State private var aggIndex: Int = 0
    @State private var showTotalUSD: Bool = false
    /// Throttles scroll-to-mid calls to reduce re-renders that interfere with Menu taps
    @State private var lastMidScrollTime: Date = .distantPast

    /// Label for the total column: "Total (BTC)" or "Total (USD)"
    private var totalLabel: String {
        showTotalUSD ? "Total (USD)" : "Total (\(chartVM.displayBaseName))"
    }

    /// Current funding rate for the displayed market (nil for spot)
    private var fundingRate: Double? {
        marketsVM.markets
            .first { $0.symbol == chartVM.selectedSymbol }
            .map { $0.funding }
    }

    // MARK: - Aggregation steps (Hyperliquid nSigFigs system)

    /// Returns aggregation ticks matching Hyperliquid's significant-figures system.
    ///
    /// Hyperliquid computes tick sizes from `nSigFigs` (2–5) and `mantissa` (1,2,5
    /// when nSigFigs=5).  The effective base tick for nSigFigs=5 is:
    ///
    ///   baseTick = 10^(floor(log10(price)) − 4)
    ///
    /// Then the ladder is [1, 2, 5, 10, 100, 1000] × baseTick, which maps to:
    ///   nSigFigs=5 m=1 → ×1,  m=2 → ×2,  m=5 → ×5
    ///   nSigFigs=4 → ×10,  nSigFigs=3 → ×100,  nSigFigs=2 → ×1000
    ///
    /// Examples (price-derived, independent of book liquidity):
    ///   BTC ~85 000  → mag=4  → 1, 2, 5, 10, 100, 1 000
    ///   ETH ~2 000   → mag=3  → 0.1, 0.2, 0.5, 1, 10, 100
    ///   CL  ~85      → mag=1  → 0.001, 0.002, 0.005, 0.01, 0.1, 1
    ///   SOL ~130     → mag=2  → 0.01, 0.02, 0.05, 0.1, 1, 10
    private func allowedTicks(for symbol: String) -> [Double] {
        let price = max(orderBook.midPrice, 0.0001)
        let mag = floor(log10(price))
        let baseTick = pow(10.0, mag - 4)       // nSigFigs=5, mantissa=1
        return [1, 2, 5, 10, 100, 1_000].map { $0 * baseTick }
    }

    private var aggSteps: [Double] { allowedTicks(for: orderBook.coin) }

    private var aggStep: Double {
        let steps = aggSteps
        return steps[min(aggIndex, steps.count - 1)]
    }

    // Aggregate `levels` into a price grid of up to visibleDepth rows.
    //
    // Root cause of size=0 rows: floating-point precision.
    //   85.087 / 0.001 → 85086.9999… in IEEE 754 → floor() gives 85086, not 85087.
    //   The bucket key doesn't match the grid slot key → size=0 everywhere.
    //
    // Fix: use Int bucket keys + epsilon correction before truncation.
    //   floor(x / step + eps) → corrects systematic under-shoot for exact tick prices.
    //   ceil (x / step - eps) → corrects systematic over-shoot for exact tick prices.
    //   eps = 1e-9 is large enough to absorb float bias but far smaller than any
    //   real price gap, so non-exact prices are still bucketed correctly.
    private func aggregate(_ levels: [OrderBookLevel], isBid: Bool) -> [OrderBookLevel] {
        guard aggStep > 0, !levels.isEmpty else { return [] }

        let eps = 1e-9

        // Phase 1 — integer anchor key (bid: floor of bestBid; ask: ceil of bestAsk).
        let anchorKey: Int = isBid
            ? Int(floor(orderBook.bestBid / aggStep + eps))
            :  Int(ceil(orderBook.bestAsk / aggStep - eps))
        let visibleDepth = max(depth / 2, 1)

        // Phase 2 — bucket levels using integer keys.
        var bucketSizes: [Int: Double] = [:]
        for level in levels {
            let key: Int = isBid
                ? Int(floor(level.price / aggStep + eps))
                :  Int(ceil(level.price / aggStep - eps))
            bucketSizes[key, default: 0.0] += level.size
        }

        // Phase 3 — build grid; scan outward until visibleDepth non-empty
        // buckets are collected. For thin markets (HIP-3) many ticks are
        // empty, so the scan may need to go well past visibleDepth ticks.
        let maxScan = visibleDepth * 200   // safety cap
        var grid: [OrderBookLevel] = []
        var cumulativeSize: Double = 0
        var i = 0
        while grid.count < visibleDepth, i < maxScan {
            let key        = isBid ? anchorKey - i : anchorKey + i
            let bucketSize = bucketSizes[key] ?? 0.0
            if bucketSize > 0 {
                let price = Double(key) * aggStep
                cumulativeSize += bucketSize
                grid.append(OrderBookLevel(px:    String(format: "%.8f", price),
                                           sz:    String(format: "%.8f", bucketSize),
                                           n:     1,
                                           total: cumulativeSize))
            }
            i += 1
        }

        // Bids descending (closest to spread first); asks ascending.
        return grid.sorted { isBid ? $0.price > $1.price : $0.price < $1.price }
    }

    // Aggregate the full merged order book for each side.
    // No pre-windowing — the entire REST+WS merged book is passed to aggregate()
    // so that all available depth contributes to bucket sizes and cumulative totals.
    // aggregate() naturally confines output to visibleDepth rows anchored at the
    // spread; levels whose bucket falls outside that range are never looked up in
    // Phase 3 and have no effect on the grid.
    //   aggBids: descending (highest bid first)
    //   aggAsks: ascending  (lowest ask  first)
    var aggBids: [OrderBookLevel] { aggregate(orderBook.bids, isBid: true)  }
    var aggAsks: [OrderBookLevel] { aggregate(orderBook.asks, isBid: false) }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerControls
            columnHeaders
            Divider().background(Color.hlSurface)
            bookScroll
        }
        .background(Color.hlBackground)
    }

    // MARK: - Header controls

    private var headerControls: some View {
        HStack(spacing: 10) {
            // Funding rate — only shown for perps (spot has no funding)
            if !chartVM.isSpotMarket {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Funding Rate")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.38))
                    if let rate = fundingRate {
                        let pct = rate * 100
                        Text(String(format: "%.4f%%", pct))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(rate >= 0 ? .hlGreen : .tradingRed)
                    } else {
                        Text("—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.55))
                    }
                }
            }

            Spacer()

            // Aggregation selector
            Menu {
                ForEach(Array(aggSteps.enumerated()), id: \.offset) { idx, step in
                    Button {
                        aggIndex = idx
                    } label: {
                        HStack {
                            Text(formatAgg(step))
                            if idx == aggIndex { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(formatAgg(aggStep))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.hlGreen)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.hlGreen)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.hlGreen.opacity(0.12))
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.hlCardBackground)
    }

    // MARK: - Column headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Price")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Total column — tap to toggle Token / USD
            Menu {
                Button {
                    showTotalUSD = false
                } label: {
                    HStack {
                        Text("Total (\(chartVM.displayBaseName))")
                        if !showTotalUSD { Image(systemName: "checkmark") }
                    }
                }
                Button {
                    showTotalUSD = true
                } label: {
                    HStack {
                        Text("Total (USD)")
                        if showTotalUSD { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(totalLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7))
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
                .contentShape(Rectangle())
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(Color(white: 0.35))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    // MARK: - Scrollable book

    private var bookScroll: some View {
        // Snapshot visible slices once so both ForEach blocks read the same data.
        // visibleAsks is pre-reversed: highest ask at index 0, lowest ask last
        // (closest to mid), matching a standard exchange ladder.
        // visibleBids is already descending from aggBids (highest bid first).
        //
        // Capture aggregated arrays once — each is a computed property that runs
        // aggregate(), so snapshotting here avoids running it twice and guarantees
        // the spread and filter thresholds come from the same data set used for
        // rendering (as opposed to orderBook.bestBid/bestAsk which come from the
        // raw WS L2 snapshot and may differ from the aggregated book).
        let bids         = aggBids    // descending (highest bid first)
        let asks         = aggAsks    // ascending  (lowest ask  first)
        let bestBid      = bids.first?.price ?? 0
        let bestAsk      = asks.first?.price ?? 0
        let visibleDepth = depth / 2
        let filteredAsks = asks.filter { $0.price >= bestAsk }
        let filteredBids = bids.filter { $0.price <= bestBid }
        let visibleAsks  = Array(filteredAsks.prefix(visibleDepth)).reversed()
        let visibleBids  = Array(filteredBids.prefix(visibleDepth))
        let maxAsk = visibleAsks.map(\.total).max() ?? 1
        let maxBid = visibleBids.map(\.total).max() ?? 1

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Asks — already reversed above; render top-to-bottom as-is.
                    // Offset is prefixed with "a" to guarantee IDs are unique within the
                    // LazyVStack and never collide with the bids section below.
                    ForEach(Array(visibleAsks.enumerated()), id: \.offset) { idx, level in
                        bookRow(level: level, isBid: false, maxSize: maxAsk)
                            .id("a\(idx)")
                    }

                    // Mid-price separator — tagged for auto-centering scroll target.
                    midPriceRow
                        .id("mid")

                    // Bids — highest bid at top (closest to mid price first).
                    // Offset is prefixed with "b" to avoid ID collisions with asks.
                    ForEach(Array(visibleBids.enumerated()), id: \.offset) { idx, level in
                        bookRow(level: level, isBid: true, maxSize: maxBid)
                            .id("b\(idx)")
                    }
                }
                // LazyVStack reuses row views for stable IDs, so changing aggStep
                // would leave stale prices on screen even though aggBids/aggAsks
                // have already been recomputed.  A new identity forces SwiftUI to
                // discard all row views and rebuild them from the fresh aggregation.
                .id(aggStep)
            }
            // On first appearance, scroll so the mid-price row is centred in the viewport.
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("mid", anchor: .center)
                }
            }
            // Re-centre whenever the best bid or ask changes (live WS updates).
            // Throttled to max once per second to prevent frequent re-renders
            // that interfere with Menu gesture recognition (tap swallowing).
            .onChange(of: orderBook.bestBid) { _, _ in
                let now = Date()
                guard now.timeIntervalSince(lastMidScrollTime) >= 1.0 else { return }
                lastMidScrollTime = now
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("mid", anchor: .center)
                }
            }
            .onChange(of: orderBook.bestAsk) { _, _ in
                let now = Date()
                guard now.timeIntervalSince(lastMidScrollTime) >= 1.0 else { return }
                lastMidScrollTime = now
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("mid", anchor: .center)
                }
            }
            // Re-centre after a tick-size change so the rebuilt ladder is
            // immediately visible at the spread rather than wherever the
            // scroll position happened to be before the rebuild.
            // Also update REST+WS precision so all visible buckets have data.
            .onChange(of: aggIndex) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("mid", anchor: .center)
                }
                chartVM.updateOrderBookNSigFigs(nSigFigsForAggStep(aggStep))
            }
        }
    }

    // MARK: - Book row with depth bar

    private func bookRow(level: OrderBookLevel,
                         isBid: Bool,
                         maxSize: Double) -> some View {
        let accent  = isBid ? Color.hlGreen : Color.tradingRed
        let barFrac = CGFloat(level.total / max(maxSize, 0.001))

        return HStack(spacing: 0) {
            // Price — bold, larger, colored
            Text(formatPrice(level.price))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Size — smaller, dimmer
            Text(formatSize(level.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.55))
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Total — cumulative depth (token or USD)
            Text(formatSize(showTotalUSD ? level.total * level.price : level.total))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.35))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        // Depth bar drawn in background so it doesn't affect layout
        .background(
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Spacer()
                    accent.opacity(0.14)
                        .frame(width: geo.size.width * barFrac)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPriceTap?(level.price)
        }
    }

    // MARK: - Mid price separator

    private var midPriceRow: some View {
        HStack(spacing: 8) {
            Text("Spread")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.45))
            Text(formatSpread(orderBook.spread))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(String(format: "%.3f%%", orderBook.spreadPct))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.hlCardBackground)
    }

    // MARK: - Formatters

    /// Spread value — strips trailing zeros (e.g. "0.003" instead of "0.003000")
    private func formatSpread(_ s: Double) -> String {
        if s == 0 { return "0" }
        // Use enough decimals to capture the value, then drop trailing zeros
        let raw = String(format: "%.8f", s)
        var trimmed = raw
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// Price decimals derived from aggregation step (matches Hyperliquid web).
    /// aggStep=0.001 → 3 decimals, aggStep=1 → 0, aggStep=0.01 → 2
    private func formatPrice(_ p: Double) -> String {
        let decimals = max(0, Int(-floor(log10(max(aggStep, 1e-10)))))
        return String(format: "%.\(decimals)f", p)
    }

    private func formatSize(_ s: Double) -> String {
        if s >= 1_000_000 { return String(format: "%.1fM", s / 1_000_000) }
        if s >= 1_000     { return String(format: "%.1fK", s / 1_000) }
        if s >= 1         { return String(format: "%.2f",  s) }
        return              String(format: "%.4f", s)
    }

    private func formatAgg(_ step: Double) -> String {
        if step >= 1      { return String(format: "%.0f",  step) }
        if step >= 0.1    { return String(format: "%.1f",  step) }
        if step >= 0.01   { return String(format: "%.2f",  step) }
        if step >= 0.001  { return String(format: "%.3f",  step) }
        if step >= 0.0001 { return String(format: "%.4f",  step) }
        return              String(format: "%.5f",  step)
    }

    /// Computes the nSigFigs needed for REST+WS l2Book so every visible bucket
    /// at `step` tick size has price levels to show.
    /// Formula: floor(log10(price / step)) + 1, clamped to [1, 5].
    ///   BTC ~83 000, step=1    → 5   (1-unit resolution)
    ///   BTC ~83 000, step=10   → 4   (10-unit resolution)
    ///   BTC ~83 000, step=100  → 3   (100-unit resolution)
    ///   BTC ~83 000, step=1000 → 2   (1000-unit resolution)
    private func nSigFigsForAggStep(_ step: Double) -> Int {
        let price = max(orderBook.midPrice, 1)
        guard step > 0 else { return 5 }
        let n = Int(floor(log10(price / step))) + 1
        return max(1, min(5, n))
    }
}
