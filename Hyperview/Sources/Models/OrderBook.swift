import Foundation

struct OrderBookLevel: Codable, Identifiable {
    /// Deterministic ID from price string — stable across decodes
    var id: String { px }
    let px: String
    let sz: String
    let n: Int
    var total: Double = 0   // cumulative depth from the spread; not persisted/decoded

    enum CodingKeys: String, CodingKey { case px, sz, n }

    var price: Double { Double(px) ?? 0 }
    var size:  Double { Double(sz) ?? 0 }
}

struct OrderBook {
    let coin: String
    var bids: [OrderBookLevel]
    var asks: [OrderBookLevel]

    var bestBid: Double { bids.first?.price ?? 0 }
    var bestAsk: Double { asks.first?.price ?? 0 }
    var spread:  Double { bestAsk - bestBid }
    var midPrice: Double { (bestBid + bestAsk) / 2 }

    var spreadPct: Double {
        guard midPrice > 0 else { return 0 }
        return (spread / midPrice) * 100
    }

    var maxBidSize: Double { bids.prefix(15).map(\.size).max() ?? 1 }
    var maxAskSize: Double { asks.prefix(15).map(\.size).max() ?? 1 }
    var maxSize:    Double { max(maxBidSize, maxAskSize) }

    // MARK: - Slippage calculation

    /// Estimate slippage for a market/aggressive-limit order.
    /// Walks through the order book to simulate fills.
    /// Returns (avgFillPrice, slippagePct) or nil if book is empty.
    func estimateSlippage(isBuy: Bool, sizeTokens: Double) -> (avgPrice: Double, slippagePct: Double)? {
        let levels = isBuy ? asks : bids
        guard !levels.isEmpty, let bestPrice = levels.first?.price, bestPrice > 0 else { return nil }

        var remaining = sizeTokens
        var totalCost: Double = 0

        for level in levels {
            guard level.size > 0 else { continue }
            let fillSize = min(remaining, level.size)
            totalCost += fillSize * level.price
            remaining -= fillSize
            if remaining <= 0 { break }
        }

        let filled = sizeTokens - max(remaining, 0)
        guard filled > 0 else { return nil }

        let avgPrice = totalCost / filled
        let slippage = abs(avgPrice - bestPrice) / bestPrice * 100
        return (avgPrice, slippage)
    }

    /// Check if a limit price would cross the spread and estimate slippage.
    /// Returns slippage % if the order would fill aggressively, nil if it would rest.
    func checkLimitSlippage(isBuy: Bool, limitPrice: Double, sizeTokens: Double) -> Double? {
        // Buy limit >= best ask → crosses spread (fills as taker)
        // Sell limit <= best bid → crosses spread (fills as taker)
        if isBuy && limitPrice >= bestAsk && bestAsk > 0 {
            return estimateSlippage(isBuy: true, sizeTokens: sizeTokens)?.slippagePct
        }
        if !isBuy && limitPrice <= bestBid && bestBid > 0 {
            return estimateSlippage(isBuy: false, sizeTokens: sizeTokens)?.slippagePct
        }
        return nil // Order would rest on the book
    }

    // MARK: - Initial depth seeding

    /// Pads the book with synthetic zero-size levels so the ladder is immediately
    /// dense while waiting for WebSocket updates to fill in real liquidity.
    mutating func seedInitialDepth(levels: Int = 150) {
        guard let bestBid = bids.first?.price,
              let bestAsk = asks.first?.price else { return }

        var bidLevels: [OrderBookLevel] = bids
        var askLevels: [OrderBookLevel] = asks

        let bidStep = (bids.first?.price ?? 0) - (bids.dropFirst().first?.price ?? 0)
        let askStep = (asks.dropFirst().first?.price ?? 0) - (asks.first?.price ?? 0)

        let step = max(abs(bidStep), abs(askStep), 0.5)

        var price = bestBid

        while bidLevels.count < levels {
            price -= step
            bidLevels.append(OrderBookLevel(px: String(format: "%.8f", price),
                                            sz: "0.00000000",
                                            n:  0))
        }

        price = bestAsk

        while askLevels.count < levels {
            price += step
            askLevels.append(OrderBookLevel(px: String(format: "%.8f", price),
                                            sz: "0.00000000",
                                            n:  0))
        }

        bids = bidLevels
        asks = askLevels
    }

    // MARK: - WebSocket merge

    /// Merges a Hyperliquid l2Book WebSocket update into this book.
    ///
    /// Strategy — price-level patch (preserves deep REST snapshot):
    ///   For each level in the WS update:
    ///     • size == 0 → remove that exact price key from the book
    ///     • size  > 0 → insert or update that exact price key
    ///   All other existing levels (from the REST snapshot) are left untouched.
    ///
    /// This keeps the full snapshot depth (~5000 levels) intact so large
    /// aggregation ticks (100 / 1000) always have enough raw levels to fill
    /// the visible ladder.
    func merging(update: OrderBook) -> OrderBook {
        // Build mutable price → level maps from the existing (deep) book.
        // Use String key (px) to avoid floating-point hashing issues.
        var bidMap: [String: OrderBookLevel] = Dictionary(
            bids.map { ($0.px, $0) },
            uniquingKeysWith: { _, new in new }
        )
        var askMap: [String: OrderBookLevel] = Dictionary(
            asks.map { ($0.px, $0) },
            uniquingKeysWith: { _, new in new }
        )

        // Patch bids: remove zero-size levels, upsert non-zero levels.
        for level in update.bids {
            if level.size == 0 {
                bidMap.removeValue(forKey: level.px)
            } else {
                bidMap[level.px] = level
            }
        }

        // Patch asks: remove zero-size levels, upsert non-zero levels.
        for level in update.asks {
            if level.size == 0 {
                askMap.removeValue(forKey: level.px)
            } else {
                askMap[level.px] = level
            }
        }

        // Rebuild sorted arrays from the patched maps.
        let mergedBids = Array(bidMap.values.sorted { $0.price > $1.price }.prefix(1000))
        let mergedAsks = Array(askMap.values.sorted { $0.price < $1.price }.prefix(1000))

        return OrderBook(coin: coin, bids: mergedBids, asks: mergedAsks)
    }
}

extension OrderBook: Equatable {
    static func == (lhs: OrderBook, rhs: OrderBook) -> Bool {
        lhs.coin == rhs.coin &&
        lhs.bids.count == rhs.bids.count &&
        lhs.asks.count == rhs.asks.count &&
        lhs.bids.first?.px == rhs.bids.first?.px &&
        lhs.asks.first?.px == rhs.asks.first?.px &&
        lhs.bids.first?.sz == rhs.bids.first?.sz &&
        lhs.asks.first?.sz == rhs.asks.first?.sz
    }
}

struct Trade: Identifiable, Codable {
    /// Deterministic ID from trade ID — stable across decodes
    var id: Int64 { tid }
    let coin: String
    let side: String
    let px:   String
    let sz:   String
    let time: Int64
    let hash: String
    let tid:  Int64

    var price:  Double { Double(px) ?? 0 }
    var size:   Double { Double(sz) ?? 0 }
    var isBuy:  Bool   { side == "B" }
    var tradeTime: Date { Date(timeIntervalSince1970: Double(time) / 1000) }
}
