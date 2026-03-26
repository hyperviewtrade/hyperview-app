import Foundation
import Combine

/// Cohort sentiment data for display.
struct CohortSentiment: Identifiable {
    let id: Int          // HyperTracker segment ID
    let name: String     // e.g. "Whale", "Smart Money"
    let emoji: String
    let range: String    // e.g. "$1M - $5M"
    let walletCount: Int
    let bias: Double     // -1 (bearish) to +1 (bullish)

    var sentimentLabel: String {
        switch bias {
        case 0.6...:          return "Bullish ↗"
        case 0.2..<0.6:       return "Slightly Bullish ↗"
        case -0.2..<0.2:      return "Neutral →"
        case -0.6..<(-0.2):   return "Slightly Bearish ↘"
        default:              return "Bearish ↘"
        }
    }

    var sentimentColor: String {
        switch bias {
        case 0.2...:   return "green"
        case -0.2..<0.2: return "gray"
        default:        return "red"
        }
    }
}

@MainActor
final class SentimentViewModel: ObservableObject {

    static let shared = SentimentViewModel()

    @Published var walletSizeCohorts: [CohortSentiment] = []
    @Published var pnlCohorts: [CohortSentiment] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var lastUpdated: Date?

    // Fear & Greed
    @Published var fearGreedValue: Int? = nil         // 0-100
    @Published var fearGreedLabel: String? = nil       // "Fear", "Greed", etc.

    // Heatmap tiles (per-coin sentiment from long/short data)
    @Published var heatmapTiles: [SentimentTile] = []

    // Long/Short ratio (Hyperliquid aggregate)
    @Published var longPercent: Double? = nil           // 0-100
    @Published var shortPercent: Double? = nil          // 0-100

    // Backend endpoint — caches HyperTracker data server-side (4h TTL)
    private static let sentimentURL = URL(string: "https://hyperview-backend-production-075c.up.railway.app/sentiment")!

    /// Local cache TTL — avoid redundant calls even to our own backend
    private static let localCacheTTL: TimeInterval = 10 * 60  // 10 min

    private var isCacheValid: Bool {
        guard let last = lastUpdated else { return false }
        return Date().timeIntervalSince(last) < Self.localCacheTTL
            && !walletSizeCohorts.isEmpty
    }

    func load() async {
        guard !isCacheValid, !isLoading else { return }
        await fetchAll()
    }

    func refresh() async {
        guard !isCacheValid else { return }
        await fetchAll()
    }

    func forceRefresh() async {
        lastUpdated = nil
        await fetchAll()
    }

    private func fetchAll() async {
        // Launch all fetches independently — UI updates as each completes
        async let b: () = fetchFromBackend()
        async let f: () = fetchFearAndGreed()
        async let l: () = fetchLongShortRatio()
        _ = await (b, f, l)
    }

    private func fetchFromBackend() async {
        isLoading = true
        errorMsg = nil

        do {
            var request = URLRequest(url: Self.sentimentURL)
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }

            // Parse PNL cohorts
            if let pnlArray = json["pnl"] as? [[String: Any]] {
                pnlCohorts = pnlArray.compactMap { parseCohort($0) }
            }

            // Parse wallet size cohorts
            if let walletArray = json["walletSize"] as? [[String: Any]] {
                walletSizeCohorts = walletArray.compactMap { parseCohort($0) }
            }

            lastUpdated = Date()
        } catch {
            if walletSizeCohorts.isEmpty {
                errorMsg = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Fear & Greed (alternative.me — free, no key)

    private func fetchFearAndGreed() async {
        // Restore cached value instantly
        if fearGreedValue == nil {
            let cached = UserDefaults.standard.integer(forKey: "cached_fng_value")
            let cachedLabel = UserDefaults.standard.string(forKey: "cached_fng_label")
            if cached > 0 {
                fearGreedValue = cached
                fearGreedLabel = cachedLabel
            }
        }

        guard let url = URL(string: "https://api.alternative.me/fng/?limit=1") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6 // short timeout — this API is often slow
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let valueStr = first["value"] as? String,
                  let value = Int(valueStr) else { return }
            fearGreedValue = value
            fearGreedLabel = first["value_classification"] as? String ?? ""
            // Cache for instant display next time
            UserDefaults.standard.set(value, forKey: "cached_fng_value")
            UserDefaults.standard.set(fearGreedLabel, forKey: "cached_fng_label")
        } catch {
            print("[sentiment] Fear & Greed fetch failed: \(error)")
        }
    }

    // MARK: - Long/Short Ratio (real position counts from backend)

    private static let longShortURL = URL(string: "https://hyperview-backend-production-075c.up.railway.app/long-short")!

    private func fetchLongShortRatio() async {
        // Restore cached values instantly
        if longPercent == 50 {
            let cl = UserDefaults.standard.double(forKey: "cached_long_pct")
            let cs = UserDefaults.standard.double(forKey: "cached_short_pct")
            if cl > 0 { longPercent = cl; shortPercent = cs }
        }

        do {
            var request = URLRequest(url: Self.longShortURL)
            request.timeoutInterval = 6
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lp = json["longPercent"] as? Double,
                  let sp = json["shortPercent"] as? Double
            else { return }

            longPercent = lp
            shortPercent = sp
            UserDefaults.standard.set(lp, forKey: "cached_long_pct")
            UserDefaults.standard.set(sp, forKey: "cached_short_pct")

            // Build heatmap tiles from per-coin data
            if let coins = json["coins"] as? [String: [String: Any]] {
                var tiles: [SentimentTile] = []
                for (coin, info) in coins {
                    let longs = info["longs"] as? Int ?? 0
                    let shorts = info["shorts"] as? Int ?? 0
                    let total = longs + shorts
                    guard total >= 50 else { continue } // skip tiny markets
                    let coinLp = info["longPercent"] as? Double ?? 50
                    // Clean coin name for display
                    let display = coin.contains(":") ? coin : coin
                    tiles.append(SentimentTile(
                        id: coin,
                        coin: display,
                        positionCount: total,
                        longPercent: coinLp
                    ))
                }
                heatmapTiles = tiles.sorted { $0.positionCount > $1.positionCount }
            }
        } catch {
            print("[sentiment] Long/Short fetch failed: \(error)")
        }
    }

    private func parseCohort(_ dict: [String: Any]) -> CohortSentiment? {
        guard let id = dict["id"] as? Int,
              let name = dict["name"] as? String else { return nil }

        return CohortSentiment(
            id: id,
            name: name,
            emoji: dict["emoji"] as? String ?? "📊",
            range: dict["range"] as? String ?? "",
            walletCount: (dict["walletCount"] as? NSNumber)?.intValue ?? 0,
            bias: (dict["bias"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}
