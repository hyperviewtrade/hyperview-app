import Foundation
import SwiftUI
import Combine

@MainActor
final class StakingViewModel: ObservableObject {

    // MARK: - Published state

    @Published var validators: [ValidatorInfo] = []
    @Published var rewardHistory: [StakingReward] = []
    @Published var actionHistory: [StakingAction] = []

    // Delegator summary
    @Published var delegated: Double = 0
    @Published var undelegated: Double = 0
    @Published var pendingWithdrawal: Double = 0
    @Published var delegations: [StakingDelegation] = []
    @Published var totalRewards: Double = 0

    // Staking form
    @Published var selectedValidator: ValidatorInfo?
    @Published var stakeAmount: String = ""
    @Published var isUndelegate: Bool = false
    @Published var isSubmitting: Bool = false
    @Published var txResult: String?
    @Published var txError: String?

    // Loading
    @Published var isLoading = false
    @Published var errorMsg: String?

    private let api = HyperliquidAPI.shared

    // MARK: - Load all data

    func loadAll(address: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMsg = nil

        do {
            // Concurrent fetch: validators + delegator data
            async let validatorsTask = api.fetchValidatorSummaries()
            async let summaryTask = api.fetchDelegatorSummary(address: address)
            async let delegationsTask = api.fetchDelegations(address: address)
            async let rewardsTask = api.fetchDelegatorRewards(address: address)
            async let historyTask = api.fetchDelegatorHistory(address: address)

            let (validatorsRaw, summaryRaw, delegationsRaw, rewardsRaw, historyRaw) =
                try await (validatorsTask, summaryTask, delegationsTask, rewardsTask, historyTask)

            // Parse validators
            parseValidators(validatorsRaw)

            // Parse delegator summary
            delegated = Double(summaryRaw["delegated"] as? String ?? "0") ?? 0
            undelegated = Double(summaryRaw["undelegated"] as? String ?? "0") ?? 0
            pendingWithdrawal = Double(summaryRaw["totalPendingWithdrawal"] as? String ?? "0") ?? 0

            // Parse delegations
            let validatorNameMap = Dictionary(uniqueKeysWithValues: validators.map { ($0.address.lowercased(), $0.name) })
            delegations = delegationsRaw.compactMap { d -> StakingDelegation? in
                guard let validator = d["validator"] as? String,
                      let amtStr = d["amount"] as? String,
                      let amt = Double(amtStr)
                else { return nil }
                let lockTs = d["lockedUntilTimestamp"] as? Int64 ?? (d["lockedUntilTimestamp"] as? NSNumber)?.int64Value
                let lockDate = lockTs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                let name = validatorNameMap[validator.lowercased()] ?? shortAddr(validator)
                return StakingDelegation(validator: validator, validatorName: name,
                                          amount: amt, lockedUntil: lockDate)
            }

            // Parse rewards
            rewardHistory = rewardsRaw.compactMap { r -> StakingReward? in
                guard let timeMs = r["time"] as? Int64 ?? (r["time"] as? NSNumber)?.int64Value,
                      let source = r["source"] as? String,
                      let amtStr = r["totalAmount"] as? String,
                      let amt = Double(amtStr)
                else { return nil }
                return StakingReward(time: Date(timeIntervalSince1970: Double(timeMs) / 1000),
                                     source: source, amount: amt)
            }
            .sorted { $0.time > $1.time }
            totalRewards = rewardHistory.reduce(0) { $0 + $1.amount }

            // Parse action history
            parseActionHistory(historyRaw, validatorNameMap: validatorNameMap)

        } catch {
            errorMsg = error.localizedDescription
        }

        isLoading = false
    }

    func refresh(address: String) async {
        isLoading = false   // allow reload
        await loadAll(address: address)
    }

    // MARK: - Submit stake / unstake

    func submitStake(address: String) async {
        guard let validator = selectedValidator,
              let amount = Double(stakeAmount), amount > 0
        else {
            txError = "Invalid amount"
            return
        }

        isSubmitting = true
        txResult = nil
        txError = nil

        do {
            let weiAmount = hypeToWei(amount)
            let payload = try await TransactionSigner.signTokenDelegate(
                validator: validator.address,
                amount: weiAmount,
                isUndelegate: isUndelegate
            )
            let response = try await TransactionSigner.postAction(payload)

            if let status = response["status"] as? String, status == "ok" {
                txResult = isUndelegate ? "Unstaking submitted" : "Staking submitted"
                stakeAmount = ""
                // Refresh data
                await refresh(address: address)
            } else if let error = response["error"] as? String {
                txError = error
            } else {
                txResult = isUndelegate ? "Unstaking submitted" : "Staking submitted"
                stakeAmount = ""
            }
        } catch {
            txError = error.localizedDescription
        }

        isSubmitting = false
    }

    // MARK: - Parsing

    private func parseValidators(_ raw: [[String: Any]]) {
        let totalStake = raw.reduce(0.0) { sum, v in
            sum + (Double(v["stake"] as? String ?? "0") ?? 0)
        }

        validators = raw.compactMap { v -> ValidatorInfo? in
            guard let address = v["validator"] as? String else { return nil }
            let name = (v["name"] as? String) ?? shortAddr(address)
            let stake = Double(v["stake"] as? String ?? "0") ?? 0
            let commission = Double(v["commission"] as? String ?? "0") ?? 0
            let isActive = v["isActive"] as? Bool ?? false
            let isJailed = v["isJailed"] as? Bool ?? false
            let nRecentBlocks = v["nRecentBlocks"] as? Int ?? 0
            let pct = totalStake > 0 ? (stake / totalStake) * 100 : 0
            let uptime = Double(nRecentBlocks) / 1000.0 * 100.0

            return ValidatorInfo(
                id: address,
                address: address,
                name: name,
                stake: stake,
                commission: commission,
                isActive: isActive,
                isJailed: isJailed,
                nRecentBlocks: nRecentBlocks,
                stakePercentage: pct,
                uptimePercent: min(uptime, 100)
            )
        }
        .sorted { $0.stake > $1.stake }
    }

    private func parseActionHistory(_ raw: [[String: Any]], validatorNameMap: [String: String]) {
        actionHistory = raw.compactMap { h -> StakingAction? in
            // Try multiple possible field names from the API
            let timeMs: Int64?
            if let t = h["time"] as? Int64 {
                timeMs = t
            } else if let t = (h["time"] as? NSNumber)?.int64Value {
                timeMs = t
            } else {
                timeMs = nil
            }
            guard let ts = timeMs else { return nil }

            let actionStr = h["action"] as? String ?? h["type"] as? String ?? ""
            let actionType: StakingAction.ActionType
            if actionStr.lowercased().contains("undelegate") {
                actionType = .undelegate
            } else {
                actionType = .delegate
            }

            let validator = h["validator"] as? String ?? ""
            let name = validatorNameMap[validator.lowercased()] ?? shortAddr(validator)

            // Amount: could be in "amount" or "wei" field
            var amount: Double = 0
            if let amtStr = h["amount"] as? String, let amt = Double(amtStr) {
                amount = amt
            } else if let wei = h["wei"] {
                amount = weiToHYPE(wei)
            }

            let hash = h["hash"] as? String

            return StakingAction(
                time: Date(timeIntervalSince1970: Double(ts) / 1000),
                actionType: actionType,
                validator: validator,
                validatorName: name,
                amount: amount,
                hash: hash
            )
        }
        .sorted { $0.time > $1.time }
    }

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}
