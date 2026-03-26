import SwiftUI
import Combine

// MARK: - Home Card Configuration

struct HomeCardConfig: Identifiable, Codable {
    let id: String
    let label: String
    let icon: String
    var isVisible: Bool

    static let allCards: [HomeCardConfig] = [
        .init(id: "balance",     label: "Total Balance",         icon: "dollarsign.circle",     isVisible: true),
        .init(id: "positions",   label: "Positions",             icon: "chart.line.uptrend.xyaxis", isVisible: true),
        .init(id: "earn",        label: "Earn",                  icon: "leaf.fill",             isVisible: true),
        .init(id: "twap",        label: "TWAP HYPE Buy Pressure",icon: "arrow.triangle.swap",   isVisible: true),
        .init(id: "buyback",     label: "HYPE Buyback",          icon: "flame.fill",            isVisible: true),
        .init(id: "markets",     label: "Markets",               icon: "chart.bar.fill",        isVisible: true),
        .init(id: "heatmap",     label: "Sentiment Heatmap",     icon: "square.grid.3x3.fill",  isVisible: true),
        .init(id: "unstaking",   label: "Upcoming Unstaking",    icon: "lock.open.fill",        isVisible: true),
        .init(id: "staking",     label: "Staking Summary",       icon: "lock.fill",             isVisible: true),
    ]
}

// MARK: - Home Card Order Manager

@MainActor
final class HomeCardOrder: ObservableObject {
    static let shared = HomeCardOrder()

    @Published var cards: [HomeCardConfig] = []

    private let storageKey = "homeCardOrder_v1"

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([HomeCardConfig].self, from: data) {
            // Merge saved with defaults (in case new cards were added)
            var result = saved
            for card in HomeCardConfig.allCards {
                if !result.contains(where: { $0.id == card.id }) {
                    result.append(card)
                }
            }
            cards = result
        } else {
            cards = HomeCardConfig.allCards
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func isVisible(_ id: String) -> Bool {
        cards.first(where: { $0.id == id })?.isVisible ?? true
    }

    func orderedVisibleIDs() -> [String] {
        cards.filter(\.isVisible).map(\.id)
    }

    func move(from source: IndexSet, to destination: Int) {
        cards.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func toggle(_ id: String) {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            cards[idx].isVisible.toggle()
            save()
        }
    }

    func reset() {
        cards = HomeCardConfig.allCards
        save()
    }
}

// MARK: - Settings Sheet

struct HomeSettingsSheet: View {
    @ObservedObject private var cardOrder = HomeCardOrder.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cardOrder.cards) { card in
                        HStack(spacing: 12) {
                            // Visibility toggle
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    cardOrder.toggle(card.id)
                                }
                            } label: {
                                Image(systemName: card.isVisible ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(card.isVisible ? .hlGreen : Color(white: 0.3))
                                    .font(.system(size: 20))
                            }
                            .buttonStyle(.plain)

                            Image(systemName: card.icon)
                                .font(.system(size: 14))
                                .foregroundColor(card.isVisible ? .white : Color(white: 0.35))
                                .frame(width: 24)

                            Text(card.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(card.isVisible ? .white : Color(white: 0.35))

                            Spacer()
                        }
                        .listRowBackground(Color(white: 0.09))
                    }
                    .onMove { source, destination in
                        cardOrder.move(from: source, to: destination)
                    }
                } header: {
                    Text("Drag to reorder, tap to show/hide")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.4))
                }

                Section {
                    Button {
                        withAnimation { cardOrder.reset() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Default")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.tradingRed)
                    }
                    .listRowBackground(Color(white: 0.09))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.06))
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Home Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
        }
    }
}
