import SwiftUI

// MARK: - Question row (for predictions list)

struct QuestionRowView: View {
    let question: OutcomeQuestion

    var body: some View {
        HStack(spacing: 0) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.hlGreen.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: question.isMultiOutcome ? "list.bullet" : "chart.pie.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.hlGreen)
            }
            .padding(.trailing, 10)

            // Title + subtitle
            VStack(alignment: .leading, spacing: 3) {
                Text(question.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if question.isMultiOutcome {
                        Text("\(question.outcomes.count) outcomes")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.4))
                    }
                    // Show side names for single-outcome custom sides
                    if question.isBinarySingleOutcome, let o = question.outcomes.first {
                        ForEach(o.sides) { side in
                            sideMiniPill(side)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: probability or multi-outcome indicator
            if let first = question.outcomes.first, !question.isMultiOutcome {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(first.probabilityFormatted)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(probColor(first.side0Price))

                    // Show both sides
                    HStack(spacing: 4) {
                        ForEach(first.sides) { side in
                            sidePill(side)
                        }
                    }
                }
            } else {
                // Multi-outcome: show top outcome
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.3))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }

    private func sideMiniPill(_ side: OutcomeSide) -> some View {
        Text("\(side.name) \(String(format: "%.0f", side.price * 100))%")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(side.sideIndex == 0 ? .hlGreen : .tradingRed)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((side.sideIndex == 0 ? Color.hlGreen : Color.tradingRed).opacity(0.12))
            .cornerRadius(4)
    }

    private func sidePill(_ side: OutcomeSide) -> some View {
        HStack(spacing: 2) {
            Text(side.name.prefix(3).uppercased())
                .font(.system(size: 9, weight: .medium))
            Text(String(format: "%.0f\u{00A2}", side.price * 100))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(side.sideIndex == 0 ? .hlGreen : .tradingRed)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background((side.sideIndex == 0 ? Color.hlGreen : Color.tradingRed).opacity(0.12))
        .cornerRadius(4)
    }

    private func probColor(_ p: Double) -> Color {
        if p >= 0.7 { return .hlGreen }
        if p <= 0.3 { return .tradingRed }
        return .white
    }
}

// MARK: - Options (Price Binary) Row

struct OptionQuestionRowView: View {
    let question: OutcomeQuestion

    var body: some View {
        guard let outcome = question.outcomes.first, let pb = outcome.priceBinary else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: 0) {
                CoinIconView(symbol: pb.underlying, hlIconName: pb.underlying)
                    .padding(.trailing, 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(pb.underlying)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("above")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                        Text(pb.formattedStrike)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.6))
                    }
                    HStack(spacing: 6) {
                        Text(pb.period.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.hlGreen)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.hlGreen.opacity(0.12))
                            .cornerRadius(3)
                        Text(pb.timeRemaining)
                            .font(.system(size: 10))
                            .foregroundColor(expiryColor(pb))
                        Text(pb.formattedExpiryFull)
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.35))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(outcome.probabilityFormatted)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(probColor(outcome.side0Price))

                    HStack(spacing: 4) {
                        ForEach(outcome.sides) { side in
                            HStack(spacing: 2) {
                                Text(side.name.prefix(3).uppercased())
                                    .font(.system(size: 9, weight: .medium))
                                Text(String(format: "%.0f\u{00A2}", side.price * 100))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            }
                            .foregroundColor(side.sideIndex == 0 ? .hlGreen : .tradingRed)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((side.sideIndex == 0 ? Color.hlGreen : Color.tradingRed).opacity(0.12))
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        )
    }

    private func expiryColor(_ pb: PriceBinaryInfo) -> Color {
        guard let expiry = pb.expiry else { return Color(white: 0.4) }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return .tradingRed }
        if remaining < 3600 { return .orange }
        return Color(white: 0.4)
    }

    private func probColor(_ p: Double) -> Color {
        if p >= 0.7 { return .hlGreen }
        if p <= 0.3 { return .tradingRed }
        return .white
    }
}

// MARK: - Testnet badge

struct TestnetBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flask.fill")
                .font(.system(size: 10))
            Text("TESTNET")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }
}
