import SwiftUI
import Charts
import Combine

enum BuybackTimeframe: String, CaseIterable {
    case h24 = "24H"
    case w1 = "1W"
    case m1 = "1M"
    case m3 = "3M"
    case all = "All"
}

struct FeesBuybackCard: View {
    @StateObject private var vm = FeesBuybackViewModel()
    @State private var selectedBar: FeeBar? = nil
    @State private var timeframe: BuybackTimeframe = .h24

    private let afAddress = "0xfefefefefefefefefefefefefefefefefefefefe"

    private var currentTotal: Double {
        switch timeframe {
        case .h24: return vm.total24h
        case .w1: return vm.total1w
        case .m1: return vm.total1m
        case .m3: return vm.total3m
        case .all: return vm.totalAll
        }
    }

    private var currentHype: Double {
        switch timeframe {
        case .h24: return vm.hypeBought24h
        case .w1: return vm.hypeBought1w
        case .m1: return vm.hypeBought1m
        case .m3: return vm.hypeBought3m
        case .all: return vm.hypeBoughtAll
        }
    }

    private var currentFills: Int {
        switch timeframe {
        case .h24: return vm.fillCount24h
        case .w1: return vm.fillCount1w
        case .m1: return vm.fillCount1m
        case .m3: return vm.fillCount3m
        case .all: return vm.fillCountAll
        }
    }

    private var currentBars: [FeeBar] {
        switch timeframe {
        case .h24: return vm.bars24h
        case .w1: return vm.bars1w
        case .m1: return vm.bars1m
        case .m3: return vm.bars3m
        case .all: return vm.barsAll
        }
    }

    private var labelInterval: Int {
        let count = currentBars.count
        // Show max ~6-8 labels regardless of timeframe
        let target = 6
        return max(1, count / target)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header with timeframe picker
            HStack {
                Text("🔥 HYPE Buyback")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()

                HStack(spacing: 0) {
                    ForEach(BuybackTimeframe.allCases, id: \.self) { tf in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                timeframe = tf
                                selectedBar = nil
                            }
                        } label: {
                            Text(tf.rawValue)
                                .font(.system(size: 11, weight: timeframe == tf ? .bold : .medium))
                                .foregroundColor(timeframe == tf ? .white : Color(white: 0.4))
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(
                                    timeframe == tf
                                        ? RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.18))
                                        : nil
                                )
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.1)))
            }

            // Total or selected bar tooltip
            if let bar = selectedBar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tooltipLabel(for: bar))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.hlGreen)
                    HStack(spacing: 12) {
                        Text(formatFees(bar.fees))
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        if bar.hype > 0 {
                            Text("\(formatHype(bar.hype)) HYPE")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            } else if vm.isLoading && vm.total24h == 0 {
                ProgressView().tint(.hlGreen)
                    .frame(height: 40)
            } else {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(formatFees(currentTotal))
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                    }

                    if currentHype > 0 {
                        HStack(spacing: 8) {
                            Text(formatHype(currentHype) + " HYPE bought")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.45))
                            Text("•")
                                .foregroundColor(Color(white: 0.2))
                            Text("\(currentFills) fills")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.45))
                            Spacer()
                        }
                    }
                }
            }

            // Bar chart
            if !currentBars.isEmpty {
                let displayBars = currentBars
                Chart(displayBars) { bar in
                    BarMark(
                        x: .value("Time", bar.label),
                        y: .value("Fees", bar.fees)
                    )
                    .foregroundStyle(
                        selectedBar?.label == bar.label
                            ? Color.hlGreen
                            : Color.hlGreen.opacity(0.5)
                    )
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        if let lbl = value.as(String.self) {
                            let idx = displayBars.firstIndex(where: { $0.label == lbl }) ?? 0
                            if idx % labelInterval == 0 {
                                AxisValueLabel {
                                    Text(lbl)
                                        .font(.system(size: 7))
                                        .foregroundColor(Color(white: 0.35))
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatAxisLabel(v))
                                    .font(.system(size: 8))
                                    .foregroundColor(Color(white: 0.35))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.15)
                                    .sequenced(before:
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                let x = value.location.x - geo[proxy.plotAreaFrame].origin.x
                                                if let lbl: String = proxy.value(atX: x) {
                                                    selectedBar = displayBars.first(where: { $0.label == lbl })
                                                }
                                            }
                                            .onEnded { _ in
                                                selectedBar = nil
                                            }
                                    )
                                    .onEnded { value in
                                        // Handle long press alone (tap on bar)
                                        if case .second(true, let drag?) = value {
                                            let x = drag.location.x - geo[proxy.plotAreaFrame].origin.x
                                            if let lbl: String = proxy.value(atX: x) {
                                                selectedBar = displayBars.first(where: { $0.label == lbl })
                                            }
                                        }
                                    }
                            )
                            .simultaneousGesture(
                                TapGesture()
                                    .onEnded { selectedBar = nil }
                            )
                    }
                }
                .frame(height: 80)
                .id(timeframe) // Force chart rebuild on timeframe change
            }

            // View Wallet button
            NavigationLink {
                WalletDetailView(address: afAddress)
                    .navigationTitle("Assistance Fund")
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                HStack(spacing: 6) {
                    Text("View Wallet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.hlGreen)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.hlGreen)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.hlGreen.opacity(0.1))
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0.09))
        )
        .task {
            await vm.loadWithRetry()
            // Auto-refresh every 5 min
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await vm.load()
            }
        }
    }

    private func formatFees(_ v: Double) -> String {
        if v >= 1_000_000 {
            return String(format: "$%.2fM", v / 1_000_000)
        }
        if v >= 1_000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "en_US")
            f.maximumFractionDigits = 0
            return "$\(f.string(from: NSNumber(value: v)) ?? "\(Int(v))")"
        }
        return String(format: "$%.0f", v)
    }

    private func formatHype(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    private func tooltipLabel(for bar: FeeBar) -> String {
        let bars = currentBars
        switch timeframe {
        case .h24:
            return bar.label  // "09h"
        case .w1, .m1:
            return bar.label  // "03/17"
        case .m3:
            // Weekly bar — show range "03/17 - 03/23"
            if bar.ts > 0 {
                let fmt = DateFormatter()
                fmt.dateFormat = "MM/dd"
                fmt.timeZone = .current
                let start = Date(timeIntervalSince1970: bar.ts / 1000)
                let end = Date(timeIntervalSince1970: bar.ts / 1000 + 6 * 86400) // +6 days
                return "\(fmt.string(from: start)) - \(fmt.string(from: end))"
            }
            return bar.label
        case .all:
            // Monthly bar — show full month name
            if bar.ts > 0 {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMMM yyyy"
                fmt.timeZone = .current
                return fmt.string(from: Date(timeIntervalSince1970: bar.ts / 1000))
            }
            return bar.label
        }
    }

    private func formatAxisLabel(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "$%.0f", v)
    }
}

// MARK: - Model & ViewModel

struct FeeBar: Identifiable {
    let id = UUID()
    let label: String
    let fees: Double
    let hype: Double
    let ts: Double  // timestamp in ms (0 if unavailable)

    init(label: String, fees: Double, hype: Double, ts: Double = 0) {
        self.label = label
        self.fees = fees
        self.hype = hype
        self.ts = ts
    }
}

@MainActor
final class FeesBuybackViewModel: ObservableObject {
    @Published var total24h: Double = 0
    @Published var hypeBought24h: Double = 0
    @Published var fillCount24h: Int = 0
    @Published var bars24h: [FeeBar] = []

    @Published var total1w: Double = 0
    @Published var hypeBought1w: Double = 0
    @Published var fillCount1w: Int = 0
    @Published var bars1w: [FeeBar] = []

    @Published var total1m: Double = 0
    @Published var hypeBought1m: Double = 0
    @Published var fillCount1m: Int = 0
    @Published var bars1m: [FeeBar] = []

    @Published var total3m: Double = 0
    @Published var hypeBought3m: Double = 0
    @Published var fillCount3m: Int = 0
    @Published var bars3m: [FeeBar] = []

    @Published var totalAll: Double = 0
    @Published var hypeBoughtAll: Double = 0
    @Published var fillCountAll: Int = 0
    @Published var barsAll: [FeeBar] = []

    @Published var isLoading = false

    private static let endpoint = URL(string: "https://hyperview-backend-production-075c.up.railway.app/fees-24h")!
    private static let cacheKey = "fees_buyback_cache"

    init() {
        // Restore from local cache immediately
        loadFromCache()
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Don't restore stale cache with 24h = $0
        let t24 = json["total24h"] as? Double ?? 0
        if t24 > 0 {
            applyJSON(json)
        } else {
            // Delete stale cache
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
    }

    private func saveToCache(_ data: Data) {
        // Only cache valid data (24h > 0) to avoid persisting stale/empty responses
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t24 = json["total24h"] as? Double, t24 > 0 {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            var req = URLRequest(url: Self.endpoint)
            req.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: req)

            // Save raw JSON for instant restore next launch
            saveToCache(data)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            applyJSON(json)
        } catch {
            print("[FeesBuyback] Load error: \(error.localizedDescription)")
        }
    }

    private func applyJSON(_ json: [String: Any]) {
        // 24h
        total24h = json["total24h"] as? Double ?? 0
        hypeBought24h = json["hypeBought24h"] as? Double ?? 0
        fillCount24h = json["fillCount24h"] as? Int ?? 0
        bars24h = parseBars(json["hourlyBars"] as? [[String: Any]] ?? [], localHourFormat: true)

        // 1W
        total1w = json["total1w"] as? Double ?? 0
        hypeBought1w = json["hypeBought1w"] as? Double ?? 0
        fillCount1w = json["fillCount1w"] as? Int ?? 0
        bars1w = parseBars(json["weeklyBars"] as? [[String: Any]] ?? [], localHourFormat: false)

        // 1M
        total1m = json["total1m"] as? Double ?? 0
        hypeBought1m = json["hypeBought1m"] as? Double ?? 0
        fillCount1m = json["fillCount1m"] as? Int ?? 0
        bars1m = parseBars(json["monthlyBars"] as? [[String: Any]] ?? [], localHourFormat: false)

        // 3M
        total3m = json["total3m"] as? Double ?? 0
        hypeBought3m = json["hypeBought3m"] as? Double ?? 0
        fillCount3m = json["fillCount3m"] as? Int ?? 0
        bars3m = parseBars(json["bars3m"] as? [[String: Any]] ?? [], localHourFormat: false)

        // All Time
        totalAll = json["totalAll"] as? Double ?? 0
        hypeBoughtAll = json["hypeBoughtAll"] as? Double ?? 0
        fillCountAll = json["fillCountAll"] as? Int ?? 0
        barsAll = parseBars(json["barsAll"] as? [[String: Any]] ?? [], localHourFormat: false)
    }

    private func parseBars(_ bars: [[String: Any]], localHourFormat: Bool) -> [FeeBar] {
        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "HH'h'"
        hourFmt.timeZone = .current

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "MM/dd"
        dayFmt.timeZone = .current

        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMM yy"
        monthFmt.timeZone = .current

        return bars.compactMap { b in
            guard let fees = b["fees"] as? Double else { return nil }
            let hype = b["hype"] as? Double ?? 0
            let ts = b["ts"] as? Double ?? 0

            let label: String
            if ts > 0 {
                let date = Date(timeIntervalSince1970: ts / 1000)
                if localHourFormat {
                    label = hourFmt.string(from: date)
                } else {
                    // Use raw label to detect bar type
                    let raw = b["label"] as? String ?? ""
                    if raw.hasPrefix("20") && raw.count <= 7 {
                        // Monthly bar: "2024-11" → "Nov 24"
                        label = monthFmt.string(from: date)
                    } else {
                        // Daily or weekly bar: use MM/dd
                        label = dayFmt.string(from: date)
                    }
                }
            } else {
                label = b["label"] as? String ?? "?"
            }

            return FeeBar(label: label, fees: fees, hype: hype, ts: ts)
        }
    }

    func loadWithRetry(maxRetries: Int = 3) async {
        for attempt in 0..<maxRetries {
            await load()
            if total24h > 0 { return }
            if attempt < maxRetries - 1 {
                try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 5) * 1_000_000_000)
            }
        }
    }
}
