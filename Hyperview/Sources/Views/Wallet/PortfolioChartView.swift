import SwiftUI

struct PortfolioChartView: View {
    @ObservedObject var vm: PortfolioChartViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Value display
            valueHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Chart
            if vm.isLoading {
                ProgressView().tint(.white)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            } else if vm.points.count >= 2 {
                chartArea
                    .frame(height: 200)
                    .padding(.top, 8)
            } else {
                Text("No data available")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.4))
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }

            // Timeframe + metric selectors
            controls
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)

        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Value header

    private var valueHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.scopeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.5))

                Text(formatValue(vm.currentValue))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(vm.chartColor)

                if let date = vm.currentDate {
                    Text(formatDate(date))
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Volume")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.5))

                Text(formatCompact(vm.volume))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Interactive chart

    private var chartArea: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pts = vm.points
            let minVal = pts.map(\.value).min() ?? 0
            let maxVal = pts.map(\.value).max() ?? 1
            let range = max(maxVal - minVal, 0.01)

            ZStack(alignment: .topLeading) {
                // Fill gradient
                Path { path in
                    for (i, pt) in pts.enumerated() {
                        let x = CGFloat(i) / CGFloat(max(pts.count - 1, 1)) * w
                        let y = h - ((CGFloat(pt.value - minVal) / CGFloat(range)) * h)
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [vm.chartColor.opacity(0.25), vm.chartColor.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                // Line
                Path { path in
                    for (i, pt) in pts.enumerated() {
                        let x = CGFloat(i) / CGFloat(max(pts.count - 1, 1)) * w
                        let y = h - ((CGFloat(pt.value - minVal) / CGFloat(range)) * h)
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(vm.chartColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                // Selection indicator
                if let idx = vm.selectedIndex, idx >= 0, idx < pts.count {
                    let x = CGFloat(idx) / CGFloat(max(pts.count - 1, 1)) * w
                    let y = h - ((CGFloat(pts[idx].value - minVal) / CGFloat(range)) * h)

                    // Vertical line
                    Rectangle()
                        .fill(Color(white: 0.3))
                        .frame(width: 1, height: h)
                        .position(x: x, y: h / 2)

                    // Dot
                    Circle()
                        .fill(vm.chartColor)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: y)

                    // Value tooltip
                    let tooltipText = formatCompact(pts[idx].value)
                    Text(tooltipText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(vm.chartColor)
                        .cornerRadius(4)
                        .position(
                            x: min(max(x, 40), w - 40),
                            y: max(y - 18, 12)
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = drag.location.x
                        let fraction = x / w
                        let idx = Int(round(fraction * CGFloat(max(pts.count - 1, 1))))
                        vm.selectedIndex = max(0, min(idx, pts.count - 1))
                    }
                    .onEnded { _ in
                        vm.selectedIndex = nil
                    }
            )
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            // Timeframe pills
            HStack(spacing: 6) {
                ForEach(PortfolioTimeframe.allCases) { tf in
                    Button { vm.selectTimeframe(tf) } label: {
                        Text(tf.rawValue)
                            .font(.system(size: 12, weight: vm.timeframe == tf ? .semibold : .regular))
                            .foregroundColor(vm.timeframe == tf ? .black : Color(white: 0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(vm.timeframe == tf ? Color.hlGreen : Color(white: 0.15))
                            .cornerRadius(16)
                    }
                }
                Spacer()
            }

            // Metric toggle
            HStack(spacing: 6) {
                ForEach(PortfolioMetric.allCases) { m in
                    Button { vm.selectMetric(m) } label: {
                        Text(m.rawValue)
                            .font(.system(size: 12, weight: vm.metric == m ? .semibold : .regular))
                            .foregroundColor(vm.metric == m ? .black : Color(white: 0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(vm.metric == m ? Color.hlGreen : Color(white: 0.15))
                            .cornerRadius(16)
                    }
                }
                Spacer()
            }

            // PnL scope toggle (only when PnL metric is selected)
            if vm.metric == .pnl {
                HStack(spacing: 6) {
                    ForEach(PnlScope.allCases) { scope in
                        Button { vm.selectPnlScope(scope) } label: {
                            Text(scope.rawValue)
                                .font(.system(size: 12, weight: vm.pnlScope == scope ? .semibold : .regular))
                                .foregroundColor(vm.pnlScope == scope ? .black : Color(white: 0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(vm.pnlScope == scope ? Color.hlGreen : Color(white: 0.15))
                                .cornerRadius(16)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Formatters

    private func formatValue(_ v: Double) -> String {
        let sign = v >= 0 ? (vm.metric == .pnl ? "+" : "") : ""
        if abs(v) >= 1_000_000_000 { return "\(sign)$\(String(format: "%.2fB", v / 1_000_000_000))" }
        if abs(v) >= 1_000_000     { return "\(sign)$\(String(format: "%.2fM", v / 1_000_000))" }
        if abs(v) >= 1_000         { return "\(sign)$\(String(format: "%.2fK", v / 1_000))" }
        return "\(sign)$\(String(format: "%.2f", v))"
    }

    private func formatCompact(_ v: Double) -> String {
        if abs(v) >= 1_000_000_000 { return "$\(String(format: "%.2fB", v / 1_000_000_000))" }
        if abs(v) >= 1_000_000     { return "$\(String(format: "%.2fM", v / 1_000_000))" }
        if abs(v) >= 1_000         { return "$\(String(format: "%.1fK", v / 1_000))" }
        return "$\(String(format: "%.2f", v))"
    }

    private static let dateFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd MMM yyyy, HH:mm"
        return fmt
    }()

    private func formatDate(_ date: Date) -> String {
        Self.dateFmt.string(from: date)
    }
}
