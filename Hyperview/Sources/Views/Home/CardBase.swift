import SwiftUI

// MARK: - Shared helpers used by all smart money cards

enum CardHelpers {
    /// Relative timestamp formatter
    static func relativeTime(_ date: Date) -> String {
        let diff = Int(-date.timeIntervalSinceNow)
        if diff < 60   { return "\(diff)s ago" }
        if diff < 3600 { return "\(diff / 60)m ago" }
        let h = diff / 3600
        let m = (diff % 3600) / 60
        return m > 0 ? "\(h)h \(m)m ago" : "\(h)h ago"
    }

    /// Share via UIActivityViewController
    @MainActor
    static func shareText(_ text: String, image: UIImage? = nil) {
        var items: [Any] = [text]
        if let img = image { items.insert(img, at: 0) }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let vc    = scene.windows.first?.rootViewController else { return }
        let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.present(ac, animated: true)
    }
}

// Convenience global aliases for backward compatibility
func relativeTime(_ date: Date) -> String { CardHelpers.relativeTime(date) }
@MainActor func shareText(_ text: String, image: UIImage? = nil) { CardHelpers.shareText(text, image: image) }

// MARK: - Card container

struct CardContainer<Content: View>: View {
    let borderColor: Color
    let content: Content

    init(borderColor: Color = Color.hlDivider, @ViewBuilder content: () -> Content) {
        self.borderColor = borderColor
        self.content     = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(Color.hlCardBackground)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

// MARK: - Stat cell

struct StatCell: View {
    let label: String
    let value: String
    var valueColor: Color = .white
    var large: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: large ? 16 : 13,
                              weight: large ? .bold : .semibold,
                              design: large ? .default : .monospaced))
                .foregroundColor(valueColor)
        }
    }
}

// MARK: - Direction badge

struct DirectionBadge: View {
    let isLong: Bool

    var body: some View {
        Text(isLong ? "LONG" : "SHORT")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(isLong ? .hlGreen : .tradingRed)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isLong ? Color.hlGreen : Color.tradingRed).opacity(0.15))
            .cornerRadius(6)
    }
}

// MARK: - Share button

struct ShareButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text("Share")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Color(white: 0.45))
        }
    }
}
