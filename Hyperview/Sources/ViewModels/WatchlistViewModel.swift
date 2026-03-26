import SwiftUI
import Combine
import WidgetKit

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published private(set) var symbols: [String]

    private let key = "hl_watchlist_v1"
    private let sharedDefaults = UserDefaults(suiteName: "group.com.Hyperview.Hyperview")

    init() {
        symbols = UserDefaults.standard.stringArray(forKey: key)
            ?? ["BTC", "ETH", "SOL", "ARB", "AVAX", "WIF", "PEPE"]
        syncToWidget()
    }

    func isWatched(_ symbol: String) -> Bool {
        symbols.contains(symbol)
    }

    func toggle(_ symbol: String) {
        if let idx = symbols.firstIndex(of: symbol) {
            symbols.remove(at: idx)
        } else {
            symbols.insert(symbol, at: 0)
        }
        persist()
    }

    func remove(at offsets: IndexSet) {
        symbols.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        symbols.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(symbols, forKey: key)
        syncToWidget()
    }

    /// Sync watchlist to App Group so the widget can order favorites first
    private func syncToWidget() {
        sharedDefaults?.set(symbols, forKey: "widget_watchlist")
    }

    /// Force widget refresh after user explicitly changes favorites
    func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: "MarketWidget")
    }
}
