import SwiftUI

// MARK: - TWAP Recommendation Engine

struct TWAPRecommendation {
    let durationMinutes: Int
    let participationRate: Double   // % of market volume our order represents
    let reasoning: String

    /// Compute optimal TWAP duration based on market conditions.
    ///
    /// Logic:
    /// - Target participation rate: 2-5% of market volume during TWAP window
    /// - Factor in order book depth: if slippage is high, increase duration
    /// - Min 5 min, max 24h (Hyperliquid TWAP limits)
    ///
    /// Parameters:
    ///   - orderSizeUSD: notional value of the order
    ///   - volume24h: 24h market volume in USD
    ///   - slippagePct: estimated instant slippage %
    ///   - bookDepthUSD: total liquidity in the relevant book side (approximate)
    static func compute(
        orderSizeUSD: Double,
        volume24h: Double,
        slippagePct: Double,
        bookDepthUSD: Double
    ) -> TWAPRecommendation {
        guard volume24h > 0 else {
            return TWAPRecommendation(
                durationMinutes: 30,
                participationRate: 0,
                reasoning: "Low volume market — a 30-minute TWAP spreads your order to minimize impact."
            )
        }

        // Volume per minute
        let volPerMin = volume24h / 1440.0

        // Target: our order should be < 3% of the volume during the TWAP window
        // duration = orderSize / (volPerMin * targetRate)
        let targetRate = 0.03
        var durationFromVolume = orderSizeUSD / (volPerMin * targetRate)

        // Adjust for slippage severity — high slippage → longer TWAP
        if slippagePct > 2.0 {
            durationFromVolume *= 1.5
        } else if slippagePct > 0.5 {
            durationFromVolume *= 1.2
        }

        // Adjust for book depth — if order > 50% of visible depth, extend
        if bookDepthUSD > 0 && orderSizeUSD > bookDepthUSD * 0.5 {
            let depthRatio = orderSizeUSD / bookDepthUSD
            durationFromVolume *= min(depthRatio, 3.0)
        }

        // Clamp to Hyperliquid limits (5 min - 24h)
        let rawMinutes = Int(durationFromVolume.rounded())
        let clamped = max(5, min(1440, rawMinutes))

        // Round to clean values
        let duration: Int
        switch clamped {
        case 5...7:     duration = 5
        case 8...12:    duration = 10
        case 13...20:   duration = 15
        case 21...40:   duration = 30
        case 41...75:   duration = 60
        case 76...150:  duration = 120
        case 151...300: duration = 240
        case 301...600: duration = 480
        default:        duration = min(clamped, 1440)
        }

        // Actual participation rate with chosen duration
        let actualRate = (orderSizeUSD / (volPerMin * Double(duration))) * 100

        // Build reasoning
        let volumeLabel = formatCompact(volume24h)
        let sizeLabel = formatCompact(orderSizeUSD)
        let durationLabel = formatDuration(duration)

        var reasons: [String] = []
        reasons.append("Your \(sizeLabel) order represents \(String(format: "%.1f", actualRate))% of \(coin(volume24h))'s volume over \(durationLabel).")

        if slippagePct > 0.5 {
            reasons.append("Instant execution would cause ~\(String(format: "%.2f", slippagePct))% slippage.")
        }

        if bookDepthUSD > 0 && orderSizeUSD > bookDepthUSD * 0.3 {
            reasons.append("Your size exceeds \(Int(orderSizeUSD / bookDepthUSD * 100))% of visible order book depth.")
        }

        reasons.append("A \(durationLabel) TWAP splits this into smaller sub-orders to minimize market impact.")

        return TWAPRecommendation(
            durationMinutes: duration,
            participationRate: actualRate,
            reasoning: reasons.joined(separator: " ")
        )
    }

    private static func coin(_ vol: Double) -> String {
        "this market" // placeholder, overridden by view
    }

    private static func formatCompact(_ v: Double) -> String {
        if v >= 1_000_000 { return "$\(String(format: "%.1fM", v / 1_000_000))" }
        if v >= 1_000 { return "$\(String(format: "%.0fK", v / 1_000))" }
        return "$\(String(format: "%.0f", v))"
    }

    static func formatDuration(_ mins: Int) -> String {
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            if m > 0 { return "\(h)h\(m)m" }
            return "\(h)h"
        }
        return "\(mins)min"
    }
}

// MARK: - Slippage Warning View

/// Full-screen slippage warning overlay shown when an order has significant slippage.
/// Offers "Proceed Anyway" or "Use TWAP" with a recommended duration.
struct SlippageWarningView: View {
    let slippagePct: Double
    let orderSizeUSD: Double
    let volume24h: Double
    let bookDepthUSD: Double
    let coin: String
    let isBuy: Bool
    let onDismiss: () -> Void
    let onProceed: () -> Void
    let onTWAP: (Int) -> Void  // passes recommended duration in minutes

    @AppStorage("hl_hideSlippageWarning") private var hideWarning = false
    @State private var dontShowAgain = false

    private var recommendation: TWAPRecommendation {
        TWAPRecommendation.compute(
            orderSizeUSD: orderSizeUSD,
            volume24h: volume24h,
            slippagePct: slippagePct,
            bookDepthUSD: bookDepthUSD
        )
    }

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    // Warning icon
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.yellow)

                    Text("Slippage Warning")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    // Warning message
                    Text("Your order will be filled as a market order due to the price entered. The size you're trying to execute exceeds the available liquidity in the order book, resulting in significant slippage.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)

                    // Slippage badge
                    HStack(spacing: 8) {
                        Text("Estimated slippage")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.5))
                        Text(String(format: "%.2f%%", slippagePct))
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(slippagePct > 1.0 ? .tradingRed : .yellow)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.12))
                    .cornerRadius(10)

                    // TWAP recommendation box (only if order >= $1000 HL minimum)
                    let rec = recommendation
                    if orderSizeUSD >= 1000 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.2.circlepath")
                                    .foregroundColor(.hlGreen)
                                Text("Recommended: \(TWAPRecommendation.formatDuration(rec.durationMinutes)) TWAP")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.hlGreen)
                            }

                            Text(rec.reasoning)
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.hlGreen.opacity(0.08))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.hlGreen.opacity(0.25), lineWidth: 1)
                        )
                    }

                    // Don't show again checkbox
                    Button {
                        dontShowAgain.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: dontShowAgain ? "checkmark.square.fill" : "square")
                                .foregroundColor(dontShowAgain ? .hlGreen : Color(white: 0.4))
                                .font(.system(size: 18))
                            Text("Don't show this again")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.5))
                        }
                    }
                    .buttonStyle(.plain)

                    // Buttons
                    let twapEligible = orderSizeUSD >= 1000 // HL minimum for TWAP

                    VStack(spacing: 10) {
                        if twapEligible {
                            // TWAP button (primary action)
                            Button {
                                if dontShowAgain { hideWarning = true }
                                onTWAP(rec.durationMinutes)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.2.circlepath")
                                    Text("Use \(TWAPRecommendation.formatDuration(rec.durationMinutes)) TWAP")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.hlGreen)
                                .foregroundColor(.black)
                                .cornerRadius(10)
                            }
                        }

                        // Proceed anyway
                        Button {
                            if dontShowAgain { hideWarning = true }
                            onProceed()
                        } label: {
                            Text("Proceed Anyway")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(isBuy ? Color.hlGreen : Color.tradingRed)
                                .foregroundColor(isBuy ? .black : .white)
                                .cornerRadius(10)
                        }

                        if !twapEligible {
                            // Cancel when TWAP not available
                            Button {
                                if dontShowAgain { hideWarning = true }
                                onDismiss()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(Color(white: 0.15))
                                    .foregroundColor(Color(white: 0.6))
                                    .cornerRadius(10)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 60)
        }
    }
}
