import SwiftUI

/// Market sentiment view — shows trader positioning by wallet size and PNL cohorts.
struct SentimentView: View {
    @ObservedObject private var vm = SentimentViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if vm.isLoading && vm.walletSizeCohorts.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.hlGreen)
                        .scaleEffect(1.2)
                    Text("Loading sentiment…")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                }
                Spacer()
            } else if let error = vm.errorMsg, vm.walletSizeCohorts.isEmpty {
                Spacer()
                errorView(error)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // ── TOP CARDS ────────────────────────────
                        HStack(spacing: 10) {
                            longShortCard
                            fearGreedCard
                        }
                        .padding(.horizontal, 14)

                        // ── SENTIMENT HEATMAP ─────────────────────
                        if !vm.heatmapTiles.isEmpty {
                            SentimentHeatmapView(tiles: vm.heatmapTiles, maxTiles: 10)
                                .padding(.horizontal, 14)
                        }

                        // ── ALL-TIME PNL ──────────────────────────
                        cohortSection(
                            title: "ALL-TIME PNL",
                            cohorts: vm.pnlCohorts
                        )

                        // ── WALLET SIZE ───────────────────────────
                        cohortSection(
                            title: "WALLET SIZE",
                            cohorts: vm.walletSizeCohorts
                        )
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await vm.refresh()
                }
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
        .task {
            await vm.load()
        }
    }

    // MARK: - Long/Short Card

    private var longShortCard: some View {
        VStack(spacing: 8) {
            Text("LONG vs SHORT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .tracking(1)

            if let longPct = vm.longPercent, let shortPct = vm.shortPercent {
                // Bar
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.hlGreen)
                            .frame(width: geo.size.width * CGFloat(longPct / 100))
                        Rectangle()
                            .fill(Color.tradingRed)
                    }
                    .cornerRadius(4)
                }
                .frame(height: 10)

                // Labels
                HStack {
                    Text(String(format: "%.1f%%", longPct))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.hlGreen)
                    Spacer()
                    Text(String(format: "%.1f%%", shortPct))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.tradingRed)
                }

                HStack {
                    Text("Long")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                    Spacer()
                    Text("Short")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.4))
                }
            } else {
                Spacer()
                ProgressView().tint(.white).scaleEffect(0.7)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }

    // MARK: - Fear & Greed Card

    private var fearGreedCard: some View {
        VStack(spacing: 8) {
            Text("FEAR & GREED")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .tracking(1)

            if let value = vm.fearGreedValue, let label = vm.fearGreedLabel {
                Spacer()

                Text("\(value)")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(fearGreedColor(value))

                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(fearGreedColor(value))

                Spacer()
            } else {
                Spacer()
                ProgressView().tint(.white).scaleEffect(0.7)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 110)
        .background(Color(white: 0.09))
        .cornerRadius(12)
    }

    private func fearGreedColor(_ value: Int) -> Color {
        switch value {
        case 0..<25:   return Color.tradingRed           // Extreme Fear
        case 25..<45:  return Color.orange                // Fear
        case 45..<55:  return Color(white: 0.5)           // Neutral
        case 55..<75:  return Color.hlGreen.opacity(0.8)  // Greed
        default:       return Color.hlGreen               // Extreme Greed
        }
    }

    // MARK: - Cohort Section

    private func cohortSection(title: String, cohorts: [CohortSentiment]) -> some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .tracking(1.5)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Cohort rows — tappable to drill into wallet list
            VStack(spacing: 6) {
                ForEach(cohorts) { cohort in
                    NavigationLink {
                        WalletStatsView(
                            title: cohort.name,
                            emoji: cohort.emoji,
                            range: cohort.range,
                            cohortCount: cohort.walletCount,
                            minUpnl: cohortMinUpnl(cohort, title: title),
                            maxUpnl: cohortMaxUpnl(cohort, title: title),
                            minOpenValue: cohortMinOpenValue(cohort, title: title),
                            maxOpenValue: cohortMaxOpenValue(cohort, title: title)
                        )
                    } label: {
                        cohortRow(cohort)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    // MARK: - Cohort Row

    private func cohortRow(_ cohort: CohortSentiment) -> some View {
        HStack(spacing: 10) {
            // Emoji
            Text(cohort.emoji)
                .font(.system(size: 22))
                .frame(width: 32)

            // Name + range
            VStack(alignment: .leading, spacing: 2) {
                Text(cohort.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(cohort.range)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.4))
            }

            Spacer()

            // Wallet count
            Text(formatCount(cohort.walletCount))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(white: 0.6))

            // Sentiment badge
            sentimentBadge(cohort)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .cornerRadius(10)
    }

    // MARK: - Sentiment Badge

    private func sentimentBadge(_ cohort: CohortSentiment) -> some View {
        Text(cohort.sentimentLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(badgeTextColor(cohort))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeBackgroundColor(cohort))
            .cornerRadius(6)
    }

    private func badgeTextColor(_ cohort: CohortSentiment) -> Color {
        switch cohort.sentimentColor {
        case "green": return Color.hlGreen
        case "red":   return Color.tradingRed
        default:      return Color(white: 0.5)
        }
    }

    private func badgeBackgroundColor(_ cohort: CohortSentiment) -> Color {
        switch cohort.sentimentColor {
        case "green": return Color.hlGreen.opacity(0.15)
        case "red":   return Color.tradingRed.opacity(0.15)
        default:      return Color(white: 0.15)
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Failed to load sentiment")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.5))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await vm.refresh() }
            } label: {
                Text("Retry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.hlGreen)
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - Helpers

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    // MARK: - Cohort Filter Helpers

    /// Parse range like "$100K - $1M" or "-$50K - $0" into numeric bounds
    private func parseRangeValue(_ str: String) -> Double? {
        var s = str.trimmingCharacters(in: .whitespaces)
        let negative = s.hasPrefix("-")
        s = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        if negative && s.hasPrefix("-") { s = String(s.dropFirst()) }

        var multiplier: Double = 1
        if s.hasSuffix("K") || s.hasSuffix("k") { multiplier = 1_000; s = String(s.dropLast()) }
        if s.hasSuffix("M") || s.hasSuffix("m") { multiplier = 1_000_000; s = String(s.dropLast()) }
        if s.hasSuffix("B") || s.hasSuffix("b") { multiplier = 1_000_000_000; s = String(s.dropLast()) }

        guard let val = Double(s) else { return nil }
        return (negative ? -1 : 1) * val * multiplier
    }

    /// Split range string by " - " or " to " and return [min, max]
    private func splitRange(_ range: String) -> [String] {
        // Clean up: remove "PNL", "+", trailing "+"
        var s = range
            .replacingOccurrences(of: " PNL", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Try " to " first (PNL ranges), then " - " (wallet size ranges)
        let parts: [String]
        if s.contains(" to ") {
            parts = s.components(separatedBy: " to ")
        } else if s.contains(" - ") {
            parts = s.components(separatedBy: " - ")
        } else {
            parts = [s]
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func cohortMinUpnl(_ cohort: CohortSentiment, title: String) -> Double? {
        guard title == "ALL-TIME PNL" else { return nil }
        let parts = splitRange(cohort.range)
        guard let first = parts.first else { return nil }
        // "+$1M+" means min=$1M, no max
        let cleaned = first.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        return parseRangeValue(cleaned.hasPrefix("-") ? cleaned : first)
    }

    private func cohortMaxUpnl(_ cohort: CohortSentiment, title: String) -> Double? {
        guard title == "ALL-TIME PNL" else { return nil }
        let parts = splitRange(cohort.range)
        // "+$1M+" or "-$1M+" = no max
        if cohort.range.hasSuffix("+") { return nil }
        guard parts.count >= 2 else { return nil }
        return parseRangeValue(parts[1])
    }

    private func cohortMinOpenValue(_ cohort: CohortSentiment, title: String) -> Double? {
        guard title == "WALLET SIZE" else { return nil }
        let parts = splitRange(cohort.range)
        guard let first = parts.first else { return nil }
        return parseRangeValue(first)
    }

    private func cohortMaxOpenValue(_ cohort: CohortSentiment, title: String) -> Double? {
        guard title == "WALLET SIZE" else { return nil }
        let parts = splitRange(cohort.range)
        // "$5M+" = no max
        if cohort.range.hasSuffix("+") { return nil }
        guard parts.count >= 2 else { return nil }
        return parseRangeValue(parts[1])
    }
}
