import Foundation

struct PriceAlert: Identifiable, Codable {
    var id:        UUID
    var symbol:    String
    var price:     Double
    var condition: Condition
    var isActive:  Bool
    var createdAt: Date

    enum Condition: String, Codable, CaseIterable {
        case above = "Above"
        case below = "Below"
    }

    /// Resilient decoder — old JSON missing `isActive`/`createdAt` won't lose data
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(UUID.self, forKey: .id)        ?? UUID()
        symbol    = try c.decode(String.self, forKey: .symbol)
        price     = try c.decode(Double.self, forKey: .price)
        condition = try c.decode(Condition.self, forKey: .condition)
        isActive  = try c.decodeIfPresent(Bool.self, forKey: .isActive)  ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    init(id: UUID = UUID(), symbol: String, price: Double, condition: Condition,
         isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id; self.symbol = symbol; self.price = price
        self.condition = condition; self.isActive = isActive; self.createdAt = createdAt
    }

    var displayPrice: String {
        if price >= 10_000 { return String(format: "%.0f", price) }
        if price >= 1_000  { return String(format: "%.1f", price) }
        if price >= 1      { return String(format: "%.3f", price) }
        return String(format: "%.6f", price)
    }
}

// MARK: - UserDefaults persistence

extension PriceAlert {
    static var all: [PriceAlert] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "hl_price_alerts"),
                  let alerts = try? JSONDecoder().decode([PriceAlert].self, from: data)
            else { return [] }
            return alerts
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "hl_price_alerts")
            }
        }
    }
}
