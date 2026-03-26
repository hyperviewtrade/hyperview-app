import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Model

struct WidgetPosition: Identifiable {
    let id = UUID()
    let coin: String
    let size: Double
    let entryPrice: Double
    let markPrice: Double
    let unrealizedPnl: Double
    let leverage: Int
    let liquidationPx: Double?

    var isLong: Bool { size >= 0 }
    var sizeAbs: Double { abs(size) }
    var pnlPct: Double {
        entryPrice != 0 ? (unrealizedPnl / (sizeAbs * entryPrice)) * 100 : 0
    }
    var formattedPnl: String { String(format: "%+.2f", unrealizedPnl) }
    var formattedPnlPct: String { String(format: "%+.2f%%", pnlPct) }
    var formattedEntry: String { formatPrice(entryPrice) }
    var formattedMark: String { formatPrice(markPrice) }

    private func formatPrice(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.0f", p) }
        if p >= 1_000  { return String(format: "%.1f", p) }
        if p >= 1      { return String(format: "%.2f", p) }
        if p >= 0.01   { return String(format: "%.4f", p) }
        return String(format: "%.6f", p)
    }

    var deepLinkURL: URL {
        var c = URLComponents()
        c.scheme = "hyperview"
        c.host = "position"
        c.queryItems = [URLQueryItem(name: "coin", value: coin)]
        return c.url ?? URL(string: "hyperview://trade")!
    }

    func formatLiq(_ p: Double) -> String {
        if p >= 10_000 { return String(format: "%.0f", p) }
        if p >= 1_000  { return String(format: "%.1f", p) }
        if p >= 1      { return String(format: "%.2f", p) }
        return String(format: "%.4f", p)
    }
}

// MARK: - Timeline Entry

struct PositionsEntry: TimelineEntry {
    let date: Date
    let positions: [WidgetPosition]

    static let placeholder = PositionsEntry(
        date: .now,
        positions: [
            WidgetPosition(coin: "BTC", size: 0.05, entryPrice: 95000, markPrice: 96500, unrealizedPnl: 75.0, leverage: 10, liquidationPx: 86000),
            WidgetPosition(coin: "ETH", size: -1.2, entryPrice: 3800, markPrice: 3750, unrealizedPnl: 60.0, leverage: 5, liquidationPx: 4200),
            WidgetPosition(coin: "SOL", size: 12.0, entryPrice: 170, markPrice: 178, unrealizedPnl: 96.0, leverage: 20, liquidationPx: 155),
        ]
    )
}

// MARK: - Shared Data Reader

private enum SharedPositionReader {
    static func load() -> [WidgetPosition] {
        guard let defaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview"),
              let arr = defaults.array(forKey: "widget_shared_positions") as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict -> WidgetPosition? in
            guard let coin = dict["coin"] as? String,
                  let size = dict["size"] as? Double,
                  let entry = dict["entry"] as? Double,
                  let mark = dict["mark"] as? Double,
                  let pnl = dict["pnl"] as? Double,
                  let lev = dict["lev"] as? Int else { return nil }
            return WidgetPosition(coin: coin, size: size, entryPrice: entry,
                                  markPrice: mark, unrealizedPnl: pnl,
                                  leverage: lev, liquidationPx: dict["liq"] as? Double)
        }
    }
}

// MARK: - Refresh Intent

struct RefreshPositionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Positions"

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "PositionsWidget")
        return .result()
    }
}

// MARK: - Provider

struct PositionsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PositionsEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PositionsEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        completion(PositionsEntry(date: .now, positions: SharedPositionReader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PositionsEntry>) -> Void) {
        let entry = PositionsEntry(date: .now, positions: SharedPositionReader.load())
        let next = Calendar.current.date(byAdding: .minute, value: 10, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget Definition

struct PositionsWidget: Widget {
    let kind = "PositionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PositionsWidgetProvider()) { entry in
            PositionsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.055, green: 0.055, blue: 0.055)
                }
        }
        .configurationDisplayName("Positions")
        .description("Your open Hyperliquid positions")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Colors

private let phlGreen = Color(red: 0.145, green: 0.839, blue: 0.584)
private let phlRed   = Color(red: 0.929, green: 0.251, blue: 0.329)
private let positionsURL = URL(string: "hyperview://trade")!

// MARK: - Entry View

struct PositionsWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: PositionsEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumPositionsView(positions: Array(entry.positions.prefix(3)), date: entry.date)
        default:
            LargePositionsView(positions: Array(entry.positions.prefix(8)), date: entry.date)
        }
    }
}

// MARK: - Medium Positions View

struct MediumPositionsView: View {
    let positions: [WidgetPosition]
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Link(destination: positionsURL) {
                    Text("POSITIONS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(phlGreen)
                }
                Spacer()
                Text("Updated \(date, style: .relative) ago")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.35))
                Button(intent: RefreshPositionsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            if positions.isEmpty {
                Spacer()
                Text("No position found")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            } else {
                ForEach(Array(positions.enumerated()), id: \.element.id) { index, pos in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                    Link(destination: pos.deepLinkURL) {
                    HStack(spacing: 6) {
                        Text(pos.coin)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(pos.isLong ? "LONG" : "SHORT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(pos.isLong ? phlGreen : phlRed)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background((pos.isLong ? phlGreen : phlRed).opacity(0.15))
                            .cornerRadius(3)
                        Text("\(pos.leverage)×")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(white: 0.4))
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(pos.formattedPnl + " USDC")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pos.unrealizedPnl >= 0 ? phlGreen : phlRed)
                            Text(pos.formattedPnlPct)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(pos.unrealizedPnl >= 0 ? phlGreen : phlRed)
                        }
                    }
                    .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}

// MARK: - Large Positions View

struct LargePositionsView: View {
    let positions: [WidgetPosition]
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Link(destination: positionsURL) {
                    Text("POSITIONS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(phlGreen)
                }
                Spacer()
                Text("Updated \(date, style: .relative) ago")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.35))
                Button(intent: RefreshPositionsIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)

            if positions.isEmpty {
                Spacer()
                Text("No position found")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.4))
                Spacer()
            } else {
                ForEach(Array(positions.enumerated()), id: \.element.id) { index, pos in
                    if index > 0 {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                    Link(destination: pos.deepLinkURL) {
                    VStack(spacing: 2) {
                        HStack(spacing: 5) {
                            Text(pos.coin)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(pos.isLong ? "LONG" : "SHORT")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(pos.isLong ? phlGreen : phlRed)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((pos.isLong ? phlGreen : phlRed).opacity(0.15))
                                .cornerRadius(3)
                            Text("\(pos.leverage)×")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(white: 0.4))
                            Spacer(minLength: 4)
                            Text(pos.formattedPnl + " USDC")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pos.unrealizedPnl >= 0 ? phlGreen : phlRed)
                            Text(pos.formattedPnlPct)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(pos.unrealizedPnl >= 0 ? phlGreen : phlRed)
                                .frame(width: 60, alignment: .trailing)
                        }
                        HStack {
                            Text("Entry")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(white: 0.35))
                            Text(pos.formattedEntry)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color(white: 0.55))
                            Spacer()
                            Text("Mark")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(white: 0.35))
                            Text(pos.formattedMark)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color(white: 0.55))
                            if let liq = pos.liquidationPx {
                                Spacer()
                                Text("Liq")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(white: 0.35))
                                Text(pos.formatLiq(liq))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 3)
                    }
                }
                if positions.count < 8 { Spacer() }
            }
        }
    }
}
