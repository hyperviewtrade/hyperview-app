import Foundation

// MARK: - Validator info (from validatorSummaries API)

struct ValidatorInfo: Identifiable {
    let id: String              // = address
    let address: String
    let name: String
    let stake: Double           // total HYPE staked
    let commission: Double      // e.g. 0.05 = 5%
    let isActive: Bool
    let isJailed: Bool
    let nRecentBlocks: Int
    var stakePercentage: Double // % of total network stake
    var uptimePercent: Double   // nRecentBlocks / 1000 * 100

    /// Estimated APR (approximation based on network emission)
    var estimatedAPR: Double {
        guard commission < 1 else { return 0 }
        // ~3% base network emission minus commission
        return 3.0 * (1.0 - commission)
    }
}

// MARK: - Unstaking queue entry (from Hypurrscan /unstakingQueue)

struct UnstakingQueueEntry: Identifiable {
    let id = UUID()
    let time: Date              // when unstaking finishes
    let userAddress: String
    let amountHYPE: Double      // wei / 1e8
}

// MARK: - Aggregated daily bar (for unstaking chart)

struct DailyUnstakingBar: Identifiable {
    let id: String              // date string
    let date: Date
    let totalHYPE: Double
}

// MARK: - Staking action (from delegatorHistory)

struct StakingAction: Identifiable {
    let id = UUID()
    let time: Date
    let actionType: ActionType
    let validator: String
    let validatorName: String
    let amount: Double
    let hash: String?

    enum ActionType: String {
        case delegate = "Delegate"
        case undelegate = "Undelegate"
    }
}

// MARK: - Wei ↔ HYPE conversion

/// 1 HYPE = 100,000,000 wei (8 decimals)
func weiToHYPE(_ wei: Any) -> Double {
    if let s = wei as? String, let d = Double(s) {
        return d / 100_000_000
    }
    if let n = wei as? NSNumber {
        return n.doubleValue / 100_000_000
    }
    if let d = wei as? Double {
        return d / 100_000_000
    }
    if let i = wei as? Int {
        return Double(i) / 100_000_000
    }
    return 0
}

/// Convert HYPE to wei string for API calls
func hypeToWei(_ hype: Double) -> String {
    let wei = UInt64(hype * 100_000_000)
    return String(wei)
}
