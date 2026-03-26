import SwiftUI

/// Container view for the Whales section — switches between Positions and Sentiment tabs.
struct WhalesContainerView: View {
    @State private var selectedTab: WhaleTab = .positions

    private enum WhaleTab: String, CaseIterable {
        case positions = "Positions"
        case sentiment = "Sentiment"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab picker ──────────────────────────────────
            HStack(spacing: 0) {
                ForEach(WhaleTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.rawValue)
                                .font(.system(size: 15, weight: selectedTab == tab ? .bold : .medium))
                                .foregroundColor(selectedTab == tab ? .white : Color(white: 0.45))

                            Rectangle()
                                .fill(selectedTab == tab ? Color.hlGreen : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // ── Content — keep both alive to avoid re-fetching ────
            ZStack {
                LargestPositionsView()
                    .opacity(selectedTab == .positions ? 1 : 0)
                    .allowsHitTesting(selectedTab == .positions)

                SentimentView()
                    .opacity(selectedTab == .sentiment ? 1 : 0)
                    .allowsHitTesting(selectedTab == .sentiment)
            }
        }
        .background(Color.hlBackground.ignoresSafeArea())
    }
}
