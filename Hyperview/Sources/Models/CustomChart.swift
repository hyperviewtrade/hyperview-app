import SwiftUI
import Combine
import WidgetKit

// MARK: - Custom Chart Market (non-Hyperliquid, TradingView-sourced)

struct CustomChart: Identifiable, Codable, Equatable {
    var id: String { symbol }
    let symbol: String        // e.g. "BINANCE:ETHUSDT", "NASDAQ:AAPL"
    let displayName: String   // e.g. "ETH/USDT"
    let iconBase: String      // First asset for icon: "ETH", "AAPL"
    let iconQuote: String?    // Second asset for dual icon: "BTC" in ETHBTC pair, nil for single assets
    let addedAt: Date

    /// TradingView symbol format (same as symbol)
    var tvSymbol: String { symbol }

    /// Whether this is a custom pair (assetA/assetB) vs a direct TradingView symbol
    var isPair: Bool { symbol.contains("/") }
}

// MARK: - Persistence

final class CustomChartStore: ObservableObject {
    static let shared = CustomChartStore()

    @Published var charts: [CustomChart] = []

    private let key = "custom_chart_markets"
    private let sharedDefaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview")

    private init() { load() }

    func add(_ chart: CustomChart) {
        charts.removeAll { $0.symbol == chart.symbol }
        charts.insert(chart, at: 0)
        save()
    }

    func remove(_ chart: CustomChart) {
        charts.removeAll { $0.symbol == chart.symbol }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        charts.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorder charts to match a new ordering (from unified list drag)
    func reorder(_ newOrder: [CustomChart]) {
        guard newOrder.count == charts.count else { return }
        charts = newOrder
        save()
    }

    func contains(_ symbol: String) -> Bool {
        charts.contains { $0.symbol == symbol }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(charts) {
            UserDefaults.standard.set(data, forKey: key)
        }
        syncToWidget()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CustomChart].self, from: data) else { return }
        charts = decoded
    }

    /// Write custom charts to App Group so the widget can display them
    private func syncToWidget() {
        guard let defaults = sharedDefaults else { return }
        let arr: [[String: Any]] = charts.map { chart in
            var dict: [String: Any] = [
                "symbol": chart.symbol,
                "displayName": chart.displayName,
                "iconBase": chart.iconBase,
                "isCustomTV": true
            ]
            if let quote = chart.iconQuote {
                dict["iconQuote"] = quote
            }
            return dict
        }
        defaults.set(arr, forKey: "widget_custom_charts")
        // Trigger widget refresh
        WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
    }
}
