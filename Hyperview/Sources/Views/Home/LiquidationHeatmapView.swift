import SwiftUI

struct LiquidationHeatmapView: View {
    @StateObject private var vm = LiquidationHeatmapViewModel()

    private let priceAxisW: CGFloat = 62
    private let timeAxisH: CGFloat = 28

    // Crosshair state
    @State private var crosshairLocation: CGPoint? = nil
    @State private var crosshairData: CrosshairInfo? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    struct CrosshairInfo {
        let price: Double
        let timestamp: Double
        let liqVolume: Double
        let markPrice: Double
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar: coin picker + legend ──────────────────────
            topBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            // ── Heatmap ───────────────────────────────────────────
            if vm.isLoading && vm.snapshots.isEmpty {
                loadingState
            } else if let err = vm.errorMessage, vm.snapshots.isEmpty {
                errorState(err)
            } else if vm.snapshots.isEmpty {
                emptyState
            } else {
                heatmapContent
            }
        }
        .sheet(isPresented: $vm.showCoinPicker) {
            coinPickerSheet
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Coin selector
            Button { vm.showCoinPicker = true } label: {
                HStack(spacing: 6) {
                    CoinIconView(symbol: vm.selectedCoin, hlIconName: vm.selectedCoin, iconSize: 18)
                    Text(vm.selectedCoin)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.13))
                .cornerRadius(8)
            }

            Spacer()

            // Legend
            HStack(spacing: 4) {
                Text("Low")
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.4))
                legendGradient
                    .frame(width: 60, height: 8)
                    .cornerRadius(2)
                Text("High")
                    .font(.system(size: 9))
                    .foregroundColor(Color(white: 0.4))
            }

            // Refresh
            Button {
                Task { await vm.fetch() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.5))
                    .padding(8)
                    .background(Color(white: 0.13))
                    .cornerRadius(8)
            }
        }
    }

    private var legendGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.18, green: 0.0, blue: 0.29),   // dark purple
                Color(red: 0.07, green: 0.27, blue: 0.50),   // dark blue
                Color(red: 0.0, green: 0.52, blue: 0.52),    // teal
                Color(red: 0.15, green: 0.72, blue: 0.34),   // green
                Color(red: 0.70, green: 0.87, blue: 0.17),   // yellow-green
                Color(red: 0.99, green: 0.91, blue: 0.14),   // yellow
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Heatmap Content

    private var heatmapContent: some View {
        GeometryReader { geo in
            let chartW = max(1, geo.size.width - priceAxisW)
            let chartH = max(1, geo.size.height - timeAxisH)

            ZStack(alignment: .topLeading) {
                Color.hlBackground

                // Main heatmap canvas
                Canvas { ctx, size in
                    drawHeatmap(ctx: ctx, chartW: chartW, chartH: chartH)
                }
                .frame(width: chartW, height: chartH)

                // Mark price line overlay
                Canvas { ctx, size in
                    drawMarkPriceLine(ctx: ctx, chartW: chartW, chartH: chartH)
                }
                .frame(width: chartW, height: chartH)
                .allowsHitTesting(false)

                // Crosshair overlay
                if let loc = crosshairLocation, loc.x >= 0, loc.x <= chartW, loc.y >= 0, loc.y <= chartH {
                    // Vertical line
                    Path { p in
                        p.move(to: CGPoint(x: loc.x, y: 0))
                        p.addLine(to: CGPoint(x: loc.x, y: chartH))
                    }
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .frame(width: chartW, height: chartH)
                    .allowsHitTesting(false)

                    // Horizontal line
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: loc.y))
                        p.addLine(to: CGPoint(x: chartW, y: loc.y))
                    }
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .frame(width: chartW, height: chartH)
                    .allowsHitTesting(false)

                    // Crosshair dot
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .position(x: loc.x, y: loc.y)
                        .allowsHitTesting(false)

                    // Tooltip
                    if let info = crosshairData {
                        crosshairTooltip(info: info, at: loc, chartW: chartW, chartH: chartH)
                            .allowsHitTesting(false)
                    }
                }

                // Gesture layer
                Color.clear
                    .frame(width: chartW, height: chartH)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let dist = abs(value.translation.width) + abs(value.translation.height)
                                if !isDragging && dist < 3 { return } // Wait to distinguish tap from drag
                                isDragging = true

                                if let anchor = crosshairLocation, dragOffset == .zero {
                                    // Starting a new drag from existing crosshair
                                    dragOffset = value.translation
                                }

                                if let anchor = crosshairLocation, dragOffset != .zero {
                                    let delta = CGSize(
                                        width: value.translation.width - dragOffset.width,
                                        height: value.translation.height - dragOffset.height
                                    )
                                    let newLoc = CGPoint(
                                        x: max(0, min(chartW, anchor.x + delta.width)),
                                        y: max(0, min(chartH, anchor.y + delta.height))
                                    )
                                    crosshairLocation = newLoc
                                    crosshairData = computeCrosshairInfo(at: newLoc, chartW: chartW, chartH: chartH)
                                    dragOffset = value.translation
                                } else {
                                    let loc = value.location
                                    let clamped = CGPoint(
                                        x: max(0, min(chartW, loc.x)),
                                        y: max(0, min(chartH, loc.y))
                                    )
                                    crosshairLocation = clamped
                                    crosshairData = computeCrosshairInfo(at: clamped, chartW: chartW, chartH: chartH)
                                    dragOffset = value.translation
                                }
                            }
                            .onEnded { value in
                                let dist = abs(value.translation.width) + abs(value.translation.height)
                                if !isDragging && dist < 3 && crosshairLocation != nil {
                                    // It was a tap (no drag movement) — dismiss crosshair
                                    crosshairLocation = nil
                                    crosshairData = nil
                                }
                                dragOffset = .zero
                                isDragging = false
                            }
                    )

                // Price axis (right)
                priceAxisView(chartW: chartW, chartH: chartH)

                // Time axis (bottom)
                timeAxisView(chartW: chartW, chartH: chartH, fullH: geo.size.height)
            }
        }
    }

    // MARK: - Drawing

    private func drawHeatmap(ctx: GraphicsContext, chartW: CGFloat, chartH: CGFloat) {
        let snaps = vm.snapshots
        guard !snaps.isEmpty, let range = vm.priceRange, range.max > range.min else { return }
        let maxI = max(vm.maxIntensity, 1)

        let colW = chartW / CGFloat(snaps.count)

        for (col, snap) in snaps.enumerated() {
            let buckets = snap.b
            guard !buckets.isEmpty else { continue }

            let x = CGFloat(col) * colW

            for bucket in buckets {
                guard bucket.count >= 2 else { continue }
                let priceMid = bucket[0]
                let intensity = bucket[1]
                guard intensity > 0 else { continue }

                // Y position (price axis — high prices at top)
                let priceFrac = (priceMid - range.min) / (range.max - range.min)
                let y = chartH * CGFloat(1 - priceFrac)

                // Bucket height = chartH / number of price buckets
                let bucketH = chartH / CGFloat(buckets.count)

                // Color from viridis-like palette
                let norm = min(intensity / maxI, 1.0)
                let color = viridisColor(norm)

                let rect = CGRect(x: x, y: y - bucketH / 2, width: colW + 0.5, height: bucketH + 0.5)
                ctx.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func drawMarkPriceLine(ctx: GraphicsContext, chartW: CGFloat, chartH: CGFloat) {
        let snaps = vm.snapshots
        guard snaps.count >= 2, let range = vm.priceRange, range.max > range.min else { return }

        let colW = chartW / CGFloat(snaps.count)
        var path = Path()
        var started = false

        for (col, snap) in snaps.enumerated() {
            let priceFrac = (snap.mp - range.min) / (range.max - range.min)
            let x = CGFloat(col) * colW + colW / 2
            let y = chartH * CGFloat(1 - priceFrac)
            if !started {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        // Glow effect — thicker semi-transparent stroke underneath
        ctx.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 3)
        ctx.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1)
    }

    // MARK: - Viridis Color Palette

    /// Maps a normalized value [0,1] to a viridis-inspired color (purple → blue → teal → green → yellow)
    private func viridisColor(_ t: Double) -> Color {
        // 6-stop gradient matching Coinglass heatmap
        let stops: [(r: Double, g: Double, b: Double)] = [
            (0.18, 0.0, 0.29),    // dark purple
            (0.07, 0.27, 0.50),   // dark blue
            (0.0, 0.52, 0.52),    // teal
            (0.15, 0.72, 0.34),   // green
            (0.70, 0.87, 0.17),   // yellow-green
            (0.99, 0.91, 0.14),   // bright yellow
        ]

        let clamped = max(0, min(1, t))
        // Apply power curve to make low values more subtle
        let curved = pow(clamped, 0.6)

        let segment = curved * Double(stops.count - 1)
        let idx = min(Int(segment), stops.count - 2)
        let frac = segment - Double(idx)

        let c0 = stops[idx]
        let c1 = stops[idx + 1]

        return Color(
            red: c0.r + (c1.r - c0.r) * frac,
            green: c0.g + (c1.g - c0.g) * frac,
            blue: c0.b + (c1.b - c0.b) * frac
        )
    }

    // MARK: - Axes

    @ViewBuilder
    private func priceAxisView(chartW: CGFloat, chartH: CGFloat) -> some View {
        if let range = vm.priceRange, range.max > range.min {
            let steps = 6
            ForEach(0...steps, id: \.self) { i in
                let frac = Double(i) / Double(steps)
                let price = range.min + frac * (range.max - range.min)
                let y = chartH * CGFloat(1 - frac)

                Text(formatPrice(price))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
                    .frame(width: priceAxisW - 4, alignment: .leading)
                    .position(x: chartW + (priceAxisW - 4) / 2 + 2, y: y)
            }
        }
    }

    @ViewBuilder
    private func timeAxisView(chartW: CGFloat, chartH: CGFloat, fullH: CGFloat) -> some View {
        let snaps = vm.snapshots
        if snaps.count >= 2 {
            let colW = chartW / CGFloat(snaps.count)
            let stride = max(1, snaps.count / 5)
            let y = chartH + timeAxisH / 2

            ForEach(0..<snaps.count, id: \.self) { i in
                if i % stride == 0 {
                    let x = CGFloat(i) * colW + colW / 2
                    if x > 0, x < chartW {
                        Text(formatTimestamp(snaps[i].t))
                            .font(.system(size: 8))
                            .foregroundColor(Color(white: 0.4))
                            .position(x: x, y: y)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading heatmap...")
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("Retry") { Task { await vm.fetch() } }
                .buttonStyle(.bordered)
                .tint(.hlGreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🔥")
                .font(.system(size: 40))
            Text("No heatmap data yet")
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.5))
            Text("Snapshots are taken every 5 minutes.\nData will appear shortly.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Coin Picker Sheet

    private var coinPickerSheet: some View {
        NavigationStack {
            List(vm.availableCoins, id: \.self) { coin in
                Button {
                    vm.changeCoin(coin)
                    vm.showCoinPicker = false
                } label: {
                    HStack(spacing: 12) {
                        CoinIconView(symbol: coin, hlIconName: coin, iconSize: 24)
                        Text(coin)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        if coin == vm.selectedCoin {
                            Image(systemName: "checkmark")
                                .foregroundColor(.hlGreen)
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Select Market")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { vm.showCoinPicker = false }
                        .foregroundColor(.hlGreen)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Crosshair

    @ViewBuilder
    private func crosshairTooltip(info: CrosshairInfo, at loc: CGPoint, chartW: CGFloat, chartH: CGFloat) -> some View {
        let tooltipW: CGFloat = 155
        let tooltipH: CGFloat = 72
        // Position tooltip to avoid going off-screen
        let x = loc.x > chartW / 2 ? loc.x - tooltipW - 12 : loc.x + 12
        let y = max(4, min(chartH - tooltipH - 4, loc.y - tooltipH / 2))

        VStack(alignment: .leading, spacing: 4) {
            Text(formatTimestampFull(info.timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.5))

            HStack(spacing: 0) {
                Text("Price: ")
                    .foregroundColor(Color(white: 0.5))
                Text(formatPrice(info.price))
                    .foregroundColor(.white)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            HStack(spacing: 0) {
                Text("Mark: ")
                    .foregroundColor(Color(white: 0.5))
                Text(formatPrice(info.markPrice))
                    .foregroundColor(.white)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            HStack(spacing: 0) {
                Text("Liq Vol: ")
                    .foregroundColor(Color(white: 0.5))
                Text(formatVolume(info.liqVolume))
                    .foregroundColor(info.liqVolume > 0 ? Color(red: 0.99, green: 0.91, blue: 0.14) : Color(white: 0.4))
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(white: 0.08).opacity(0.95))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(white: 0.2), lineWidth: 0.5))
        .position(x: x + tooltipW / 2, y: y + tooltipH / 2)
    }

    private func computeCrosshairInfo(at point: CGPoint, chartW: CGFloat, chartH: CGFloat) -> CrosshairInfo? {
        let snaps = vm.snapshots
        guard !snaps.isEmpty, let range = vm.priceRange, range.max > range.min else { return nil }

        let colW = chartW / CGFloat(snaps.count)
        let colIndex = min(max(0, Int(point.x / colW)), snaps.count - 1)
        let snap = snaps[colIndex]

        // Price from Y position
        let priceFrac = 1.0 - Double(point.y / chartH)
        let price = range.min + priceFrac * (range.max - range.min)

        // Find closest bucket to get liq volume
        var closestLiqVol: Double = 0
        var closestDist: Double = .infinity
        for bucket in snap.b {
            guard bucket.count >= 2 else { continue }
            let dist = abs(bucket[0] - price)
            if dist < closestDist {
                closestDist = dist
                closestLiqVol = bucket[1]
            }
        }

        return CrosshairInfo(
            price: price,
            timestamp: snap.t,
            liqVolume: closestLiqVol,
            markPrice: snap.mp
        )
    }

    private func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "$%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "$%.1fK", v / 1_000) }
        if v > 0 { return String(format: "$%.0f", v) }
        return "$0"
    }

    private static let fullTimeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd MMM, HH:mm"
        return fmt
    }()

    private func formatTimestampFull(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return Self.fullTimeFmt.string(from: date)
    }

    // MARK: - Formatters

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.0f", p) }
        if p >= 1_000  { return String(format: "%.1f", p) }
        if p >= 1      { return String(format: "%.2f", p) }
        if p >= 0.01   { return String(format: "%.4f", p) }
        return String(format: "%.6f", p)
    }

    private static let timeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd, HH:mm"
        return fmt
    }()

    private func formatTimestamp(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        return Self.timeFmt.string(from: date)
    }
}
