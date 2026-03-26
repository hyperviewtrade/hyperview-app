import Foundation

struct Candle: Identifiable, Codable {
    /// Deterministic ID from open time + symbol + interval — stable across decodes
    var id: String { "\(t):\(s):\(i)" }
    let t: Int64   // open time ms
    let T: Int64   // close time ms
    let s: String  // symbol
    let i: String  // interval
    let o: String  // open
    let c: String  // close
    let h: String  // high
    let l: String  // low
    let v: String  // volume (coin qty)
    let n: Int     // trades count

    enum CodingKeys: String, CodingKey {
        case t, T, s, i, o, c, h, l, v, n
    }

    var open:   Double { Double(o) ?? 0 }
    var close:  Double { Double(c) ?? 0 }
    var high:   Double { Double(h) ?? 0 }
    var low:    Double { Double(l) ?? 0 }
    var volume: Double { Double(v) ?? 0 }

    var openTime:  Date { Date(timeIntervalSince1970: Double(t) / 1000) }
    var closeTime: Date { Date(timeIntervalSince1970: Double(T) / 1000) }

    var isGreen:    Bool   { close >= open }
    var bodyTop:    Double { max(open, close) }
    var bodyBottom: Double { min(open, close) }
}

// MARK: - Intervals

enum ChartInterval: String, CaseIterable, Identifiable {
    case oneMin     = "1m"
    case twoMin     = "2m"
    case threeMin   = "3m"
    case fiveMin    = "5m"
    case fifteenMin = "15m"
    case thirtyMin  = "30m"
    case oneHour    = "1h"
    case twoHour    = "2h"
    case fourHour   = "4h"
    case eightHour  = "8h"
    case twelveHour = "12h"
    case oneDay     = "1d"
    case threeDays  = "3d"
    case oneWeek    = "1w"
    case oneMonth   = "1M"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var durationSeconds: Int {
        switch self {
        case .oneMin:     return 60
        case .twoMin:     return 120
        case .threeMin:   return 180
        case .fiveMin:    return 300
        case .fifteenMin: return 900
        case .thirtyMin:  return 1800
        case .oneHour:    return 3_600
        case .twoHour:    return 7_200
        case .fourHour:   return 14_400
        case .eightHour:  return 28_800
        case .twelveHour: return 43_200
        case .oneDay:     return 86_400
        case .threeDays:  return 259_200
        case .oneWeek:    return 604_800
        case .oneMonth:   return 2_592_000
        }
    }

    var defaultCount: Int {
        switch self {
        case .oneMin, .twoMin, .threeMin, .fiveMin, .fifteenMin, .thirtyMin: return 200
        case .oneHour, .twoHour, .fourHour, .eightHour, .twelveHour: return 300
        case .oneDay: return 365
        case .threeDays, .oneWeek, .oneMonth: return 200
        }
    }

    // Quick-access bar (shown inline, others in Menu)
    static let quickAccess: [ChartInterval] = [.fiveMin, .fifteenMin, .oneHour, .fourHour, .oneDay, .oneWeek]
}
