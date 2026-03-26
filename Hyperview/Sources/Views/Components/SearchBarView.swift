import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    var placeholder: String = "Search"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
                .font(.system(size: 15))

            TextField(placeholder, text: $text)
                .foregroundColor(.white)
                .font(.system(size: 15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                    // Delay unfocus slightly so simultaneousGesture doesn't re-focus
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.system(size: 15))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.hlSurface)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                isFocused = true
            }
        )
    }
}
