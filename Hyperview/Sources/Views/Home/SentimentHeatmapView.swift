import SwiftUI

// MARK: - Model

struct SentimentTile: Identifiable {
    let id: String
    let coin: String
    let positionCount: Int
    let longPercent: Double

    var sentimentLabel: String {
        switch longPercent {
        case 65...:        return "Very Bullish"
        case 55..<65:      return "Slightly Bullish"
        case 45..<55:      return "Indecisive"
        case 35..<45:      return "Slightly Bearish"
        default:           return "Bearish"
        }
    }

    var color: Color {
        switch longPercent {
        case 65...:        return Color(red: 0.15, green: 0.45, blue: 0.25)
        case 55..<65:      return Color(red: 0.25, green: 0.5, blue: 0.35)
        case 45..<55:      return Color(red: 0.35, green: 0.35, blue: 0.38)
        case 35..<45:      return Color(red: 0.75, green: 0.45, blue: 0.4)
        default:           return Color(red: 0.8, green: 0.4, blue: 0.35)
        }
    }
}

// MARK: - Treemap Layout

struct TreemapLayout {
    struct Rect {
        let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    }

    static func compute(values: [Double], in rect: CGRect) -> [Rect] {
        guard !values.isEmpty else { return [] }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in Rect(x: 0, y: 0, w: 0, h: 0) } }

        var rects = [Rect](repeating: Rect(x: 0, y: 0, w: 0, h: 0), count: values.count)
        var indices = Array(0..<values.count)
        indices.sort { values[$0] > values[$1] }

        squarify(indices: indices, values: values, total: total, rect: rect, rects: &rects)
        return rects
    }

    private static func squarify(indices: [Int], values: [Double], total: Double,
                                  rect: CGRect, rects: inout [Rect]) {
        guard !indices.isEmpty else { return }
        if indices.count == 1 {
            rects[indices[0]] = Rect(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
            return
        }

        let sum = indices.reduce(0.0) { $0 + values[$1] }
        guard sum > 0 else { return }

        let isWide = rect.width >= rect.height

        // Find best split
        var runningSum: Double = 0
        var bestSplit = 1
        var bestRatio = Double.infinity

        for i in 0..<(indices.count - 1) {
            runningSum += values[indices[i]]
            let fraction = runningSum / sum
            let side = isWide ? rect.width * fraction : rect.height * fraction
            let otherSide = isWide ? rect.height : rect.width

            let ratio1 = max(side / otherSide, otherSide / side)
            let remaining = isWide ? rect.width * (1 - fraction) : rect.height * (1 - fraction)
            let ratio2 = max(remaining / otherSide, otherSide / remaining)
            let worstRatio = max(ratio1, ratio2)

            if worstRatio < bestRatio {
                bestRatio = worstRatio
                bestSplit = i + 1
            }
        }

        let leftIndices = Array(indices[0..<bestSplit])
        let rightIndices = Array(indices[bestSplit...])
        let leftSum = leftIndices.reduce(0.0) { $0 + values[$1] }
        let fraction = leftSum / sum

        let leftRect: CGRect
        let rightRect: CGRect

        if isWide {
            let splitX = rect.minX + rect.width * fraction
            leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
            rightRect = CGRect(x: splitX, y: rect.minY, width: rect.width * (1 - fraction), height: rect.height)
        } else {
            let splitY = rect.minY + rect.height * fraction
            leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction)
            rightRect = CGRect(x: rect.minX, y: splitY, width: rect.width, height: rect.height * (1 - fraction))
        }

        squarify(indices: leftIndices, values: values, total: total, rect: leftRect, rects: &rects)
        squarify(indices: rightIndices, values: values, total: total, rect: rightRect, rects: &rects)
    }
}

// MARK: - Heatmap View

struct SentimentHeatmapView: View {
    let tiles: [SentimentTile]
    let maxTiles: Int
    @State private var selectedTile: SentimentTile? = nil

    init(tiles: [SentimentTile], maxTiles: Int = 10) {
        self.tiles = Array(tiles.sorted { $0.positionCount > $1.positionCount }.prefix(maxTiles))
        self.maxTiles = maxTiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top \(tiles.count) Open Perps")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)

            GeometryReader { geo in
                let values = tiles.map { Double($0.positionCount) }
                let rects = TreemapLayout.compute(values: values, in: CGRect(origin: .zero, size: geo.size))

                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { idx, tile in
                        if idx < rects.count {
                            let r = rects[idx]
                            tileView(tile, width: r.w, height: r.h)
                                .frame(width: max(r.w - 1, 0), height: max(r.h - 1, 0))
                                .offset(x: r.x, y: r.y)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedTile = selectedTile?.id == tile.id ? nil : tile
                                    }
                                }
                        }
                    }
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Detail popup when tapping a tile
            if let tile = selectedTile {
                tileDetail(tile)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func tileView(_ tile: SentimentTile, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = selectedTile?.id == tile.id

        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(tile.color)

            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white, lineWidth: 2)
            }

            // Always show coin name, adapt font size to available space
            VStack(spacing: 1) {
                Text(tile.coin)
                    .font(.system(size: max(min(min(width / 4.5, height / 3), 18), 6), weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)

                if height > 30 && width > 30 {
                    Text(tile.sentimentLabel)
                        .font(.system(size: max(min(min(width / 8, height / 5), 11), 5)))
                        .foregroundColor(Color(white: 0.85))
                        .lineLimit(2)
                        .minimumScaleFactor(0.3)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(2)
        }
    }

    private func tileDetail(_ tile: SentimentTile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.coin)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(tile.sentimentLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tile.longPercent >= 55 ? .hlGreen : tile.longPercent <= 45 ? .tradingRed : .gray)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(tile.positionCount) positions")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))

                HStack(spacing: 4) {
                    // Long bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.hlGreen)
                        .frame(width: CGFloat(tile.longPercent) * 0.8, height: 6)
                    // Short bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.tradingRed)
                        .frame(width: CGFloat(100 - tile.longPercent) * 0.8, height: 6)
                }

                HStack(spacing: 8) {
                    Text(String(format: "%.1f%% L", tile.longPercent))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.hlGreen)
                    Text(String(format: "%.1f%% S", 100 - tile.longPercent))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.tradingRed)
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.09))
        .cornerRadius(10)
    }
}
