import Foundation
import SwiftUI
import Combine

// MARK: - Models

struct EarnAsset: Identifiable {
    let id = UUID()
    let coin: String
    let tokenIndex: Int
    let ltv: Double          // 0.5 = 50%
    let apy: Double          // 0.005 = 0.50%
    let oraclePrice: Double
    let userSupplied: Double // amount in token
    let userSuppliedExact: String // full precision string for withdraw all
    let userInterestEarned: Double
    let totalSupplied: Double // global (if available)
}

struct BorrowAsset: Identifiable {
    let id = UUID()
    let coin: String
    let tokenIndex: Int
    let apy: Double
    let oraclePrice: Double
    let userBorrowed: Double
    let userInterestOwed: Double
    let totalBorrowed: Double
}

// MARK: - ViewModel

@MainActor
final class EarnViewModel: ObservableObject {

    @Published var healthFactor: Double = 0       // percentage e.g. 107.76
    @Published var totalSuppliedUSD: Double = 0
    @Published var totalBorrowedUSD: Double = 0
    @Published var spotAccountValue: Double = 0   // sum of all token balances * price
    @Published var perpAccountValue: Double = 0   // from clearinghouseState
    @Published var supplyAssets: [EarnAsset] = []
    @Published var borrowAssets: [BorrowAsset] = []
    @Published var portfolioMarginRatio: Double = 0  // e.g. 0.2854 = 28.54%
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var portfolioMarginEnabled = false
    @Published var pmBalanceEntries: [TradeTabView.PMBalanceEntry] = []

    // Known earn-eligible tokens with their borrow/supply APY
    // These rates are from Hyperliquid's earn page (updated periodically)
    // UBTC = wrapped BTC on Hyperliquid spot
    private let supplyAPYs: [String: Double] = [
        "BTC": 0.0, "UBTC": 0.0, "HYPE": 0.0,
        "USDC": 0.005, "USDH": 0.0082
    ]
    private let borrowAPYs: [String: Double] = [
        "USDC": 0.05, "USDH": 0.05
    ]

    // Oracle prices (fetched from spot meta)
    private var oraclePrices: [String: Double] = [:]

    // Global supply/borrow totals (from HL Earn page, updated periodically)
    private let globalTotalSupplied: [String: Double] = [
        "UBTC": 23.88, "HYPE": 490_477.0, "USDC": 16_338_927.0, "USDH": 5_026_254.0
    ]
    private let globalTotalBorrowed: [String: Double] = [
        "USDC": 1_798_049.0, "USDH": 912_033.0
    ]

    func load() async {
        guard let address = WalletManager.shared.connectedWallet?.address else { return }
        isLoading = true
        errorMsg = nil

        do {
            // 1. Fetch oracle prices from allMids
            await fetchOraclePrices()

            // 2. Fetch spotClearinghouseState
            let url = URL(string: "https://api.hyperliquid.xyz/info")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "spotClearinghouseState",
                "user": address
            ])

            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            portfolioMarginEnabled = json["portfolioMarginEnabled"] as? Bool ?? false
            let pmRatio = Double(json["portfolioMarginRatio"] as? String ?? "0") ?? 0
            let balances = json["balances"] as? [[String: Any]] ?? []

            // In classic mode, fetch supply/withdraw history from ledger to compute supplied amounts
            var classicSupplied: [String: Double] = [:]
            var classicInterest: [String: Double] = [:]
            if !portfolioMarginEnabled {
                classicSupplied = await fetchClassicSuppliedAmounts(address: address)
                classicInterest = await fetchClassicInterestEarned(address: address)
                print("[EARN] Classic mode: supplied=\(classicSupplied), interest=\(classicInterest)")
            }

            var supplies: [EarnAsset] = []
            var borrows: [BorrowAsset] = []
            var totalSup: Double = 0
            var totalBor: Double = 0
            var spotVal: Double = 0

            for bal in balances {
                let coin = bal["coin"] as? String ?? ""
                let tokenIdx = bal["token"] as? Int ?? 0
                let ltv = Double(bal["ltv"] as? String ?? "0") ?? 0
                let isStable = coin == "USDC" || coin == "USDH" || coin == "USDT0" || coin == "USDE"
                let price = oraclePrices[coin] ?? (isStable ? 1.0 : 0)

                // Spot account value: sum of all total * price
                let totalAmt = Double(bal["total"] as? String ?? "0") ?? 0
                spotVal += totalAmt * price

                // PM mode: use 'supplied'/'borrowed' fields
                // Classic mode: use ledger-computed amounts
                let suppliedAmt = portfolioMarginEnabled
                    ? (Double(bal["supplied"] as? String ?? "0") ?? 0)
                    : (classicSupplied[coin] ?? 0)
                let borrowedAmt = Double(bal["borrowed"] as? String ?? "0") ?? 0
                let interestEarned = portfolioMarginEnabled ? 0 : (classicInterest[coin] ?? 0)

                // Skip tokens with no supply/borrow activity
                guard suppliedAmt > 0 || borrowedAmt > 0 else { continue }

                // Supply entry
                if suppliedAmt > 0 {
                    let totalWithInterest = suppliedAmt + interestEarned
                    let supUSD = totalWithInterest * price
                    totalSup += supUSD
                    supplies.append(EarnAsset(
                        coin: coin,
                        tokenIndex: tokenIdx,
                        ltv: ltv,
                        apy: supplyAPYs[coin] ?? 0,
                        oraclePrice: price,
                        userSupplied: totalWithInterest,
                        userSuppliedExact: String(format: "%.10f", totalWithInterest),
                        userInterestEarned: interestEarned,
                        totalSupplied: globalTotalSupplied[coin] ?? 0
                    ))
                }

                // Borrow entry
                if borrowedAmt > 0 {
                    let borUSD = borrowedAmt * price
                    totalBor += borUSD
                    borrows.append(BorrowAsset(
                        coin: coin,
                        tokenIndex: tokenIdx,
                        apy: borrowAPYs[coin] ?? 0.05,
                        oraclePrice: price,
                        userBorrowed: borrowedAmt,
                        userInterestOwed: 0,
                        totalBorrowed: globalTotalBorrowed[coin] ?? 0
                    ))
                }
            }

            // Health factor from supplied LTV vs borrowed
            // Health = (Sum of supplied * price * ltv) / (Sum of borrowed * price) * 100
            var collateralValue: Double = 0
            for s in supplies where s.ltv > 0 {
                collateralValue += s.userSupplied * s.oraclePrice * s.ltv
            }
            let hf = totalBor > 0 ? (collateralValue / totalBor) * 100 : 0

            // Fetch perp account value
            var perpVal: Double = 0
            do {
                var perpReq = URLRequest(url: url)
                perpReq.httpMethod = "POST"
                perpReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
                perpReq.httpBody = try JSONSerialization.data(withJSONObject: [
                    "type": "clearinghouseState",
                    "user": address
                ])
                let (perpData, _) = try await URLSession.shared.data(for: perpReq)
                let perpJson = try JSONSerialization.jsonObject(with: perpData) as? [String: Any] ?? [:]
                let ms = perpJson["marginSummary"] as? [String: Any] ?? [:]
                perpVal = Double(ms["accountValue"] as? String ?? "0") ?? 0
            } catch {}

            // Ensure all earn-eligible tokens appear in supply (even if 0)
            let earnEligible: [(coin: String, ltv: Double)] = [
                ("UBTC", 0.5), ("HYPE", 0.5), ("USDC", 0.0), ("USDH", 0.0)
            ]
            for elig in earnEligible {
                if !supplies.contains(where: { $0.coin == elig.coin }) {
                    let price = oraclePrices[elig.coin] ?? (elig.coin == "USDC" || elig.coin == "USDH" ? 1.0 : 0.0)
                    supplies.append(EarnAsset(
                        coin: elig.coin,
                        tokenIndex: 0,
                        ltv: elig.ltv,
                        apy: supplyAPYs[elig.coin] ?? 0,
                        oraclePrice: price,
                        userSupplied: 0,
                        userSuppliedExact: "0",
                        userInterestEarned: 0,
                        totalSupplied: globalTotalSupplied[elig.coin] ?? 0
                    ))
                }
            }

            // Build PMBalanceEntry list for RepaySheet
            var entries: [TradeTabView.PMBalanceEntry] = []
            for bal in balances {
                let coin = bal["coin"] as? String ?? ""
                let tokenIdx = bal["token"] as? Int ?? 0
                let totalAmt = Double(bal["total"] as? String ?? "0") ?? 0
                let holdAmt = Double(bal["hold"] as? String ?? "0") ?? 0
                let ltv = Double(bal["ltv"] as? String ?? "0") ?? 0
                let borrowedAmt = Double(bal["borrowed"] as? String ?? "0") ?? 0
                let isStable = coin == "USDC" || coin == "USDH"
                let price = oraclePrices[coin] ?? (isStable ? 1.0 : 0)

                guard totalAmt != 0 || borrowedAmt > 0 else { continue }

                let avail = totalAmt - holdAmt

                entries.append(TradeTabView.PMBalanceEntry(
                    coin: coin,
                    tokenIndex: tokenIdx,
                    ltv: ltv,
                    borrowCapUsed: 0,
                    netBalance: totalAmt,
                    availableBalance: avail,
                    usdcValue: totalAmt * price,
                    isBorrowed: borrowedAmt > 0
                ))
            }
            pmBalanceEntries = entries

            supplyAssets = supplies.sorted { $0.userSupplied * $0.oraclePrice > $1.userSupplied * $1.oraclePrice }
            borrowAssets = borrows.sorted { $0.userBorrowed * $0.oraclePrice > $1.userBorrowed * $1.oraclePrice }
            totalSuppliedUSD = totalSup
            totalBorrowedUSD = totalBor
            spotAccountValue = spotVal
            perpAccountValue = perpVal
            healthFactor = hf
            portfolioMarginRatio = pmRatio
            isLoading = false

        } catch {
            errorMsg = error.localizedDescription
            isLoading = false
        }
    }

    private func fetchOraclePrices() async {
        do {
            let url = URL(string: "https://api.hyperliquid.xyz/info")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["type": "allMids"])

            let (data, _) = try await URLSession.shared.data(for: req)
            if let mids = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (coin, priceStr) in mids {
                    if let p = Double(priceStr) {
                        oraclePrices[coin] = p
                    }
                }
            }
            // Add stablecoin prices
            oraclePrices["USDC"] = 1.0
            oraclePrices["USDH"] = 1.0
            oraclePrices["USDT0"] = 1.0
            oraclePrices["USDE"] = 1.0
            // UBTC = wrapped BTC, same price as BTC
            if let btcPrice = oraclePrices["BTC"] {
                oraclePrices["UBTC"] = btcPrice
            }
        } catch {}
    }

    // MARK: - Classic Mode Earn Data

    /// Fetch net supplied amounts per token from borrowLend ledger entries
    private func fetchClassicSuppliedAmounts(address: String) async -> [String: Double] {
        do {
            let url = URL(string: "https://api.hyperliquid.xyz/info")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "userNonFundingLedgerUpdates",
                "user": address,
                "startTime": 0
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }

            var supplied: [String: Double] = [:]

            for entry in entries {
                guard let delta = entry["delta"] as? [String: Any],
                      let type = delta["type"] as? String,
                      type == "borrowLend",
                      let token = delta["token"] as? String,
                      let amountStr = delta["amount"] as? String,
                      let amount = Double(amountStr),
                      let operation = delta["operation"] as? String
                else { continue }

                if operation == "supply" {
                    supplied[token, default: 0] += amount
                } else if operation == "withdraw" {
                    supplied[token, default: 0] -= amount
                }
            }

            // Remove negative or zero values
            return supplied.filter { $0.value > 0.001 }
        } catch {
            print("[EARN] Classic supplied fetch error: \(error)")
            return [:]
        }
    }

    /// Fetch interest earned per token from borrowLend ledger entries
    private func fetchClassicInterestEarned(address: String) async -> [String: Double] {
        do {
            let url = URL(string: "https://api.hyperliquid.xyz/info")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "userNonFundingLedgerUpdates",
                "user": address,
                "startTime": 0
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }

            var interest: [String: Double] = [:]

            for entry in entries {
                guard let delta = entry["delta"] as? [String: Any],
                      let type = delta["type"] as? String,
                      type == "borrowLend",
                      let token = delta["token"] as? String,
                      let interestStr = delta["interestAmount"] as? String,
                      let interestAmt = Double(interestStr),
                      interestAmt > 0
                else { continue }

                interest[token, default: 0] += interestAmt
            }

            return interest
        } catch {
            return [:]
        }
    }
}
