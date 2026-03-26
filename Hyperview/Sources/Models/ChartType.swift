import Foundation

// MARK: - Chart display type

enum ChartType: String, CaseIterable, Identifiable {
    case candles    = "Candles"
    case bars       = "Bars"
    case line       = "Line"
    case area       = "Area"
    case heikinAshi = "Heikin Ashi"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .candles:    return "chart.bar.fill"
        case .bars:       return "chart.bar"
        case .line:       return "chart.xyaxis.line"
        case .area:       return "chart.line.uptrend.xyaxis"
        case .heikinAshi: return "chart.bar.xaxis"
        }
    }

}
