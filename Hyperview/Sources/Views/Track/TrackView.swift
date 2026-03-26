import SwiftUI

struct TrackView: View {
    @EnvironmentObject var marketsVM: MarketsViewModel

    @State private var addressInput = ""
    @State private var showWalletDetail = false
    @State private var trackedAddress = ""
    @State private var allAliases: [String: String] = [:]  // address → alias name

    // Perp search
    @State private var showMarketPicker = false
    @State private var selectedMarket: Market?
    @State private var selectedOutcome: OutcomeQuestion?
    @State private var sideFilter: SideFilter = .both
    @State private var selectedOutcomeIndex: Int?   // nil = all outcomes
    @State private var minAmount = ""
    @State private var maxAmount = ""
    @State private var minEntry  = ""
    @State private var maxEntry  = ""
    @State private var showSearchResults = false
    @State private var showOutcomeSearchResults = false

    enum SideFilter: String, CaseIterable {
        case both  = "Both"
        case long  = "Long"
        case short = "Short"
    }

    /// Index of the side to filter on (0 = Yes/first side, 1 = No/second side), nil = both
    @State private var outcomeSideIndex: Int?

    private var isOutcomeMode: Bool { selectedOutcome != nil }

    /// The sides available for filtering — from the first outcome (or selected outcome)
    private var outcomeSides: [OutcomeSide] {
        guard let question = selectedOutcome else { return [] }
        if let idx = selectedOutcomeIndex, question.outcomes.indices.contains(idx) {
            return question.outcomes[idx].sides
        }
        return question.outcomes.first?.sides ?? []
    }

    /// Label for the outcome side filter button
    private var outcomeSideLabel: String {
        guard let idx = outcomeSideIndex else { return "Both" }
        return outcomeSides.first(where: { $0.sideIndex == idx })?.name ?? "Both"
    }

    private enum Field: Int, CaseIterable { case address, minAmount, maxAmount, minEntry, maxEntry }
    @FocusState private var focusedField: Field?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    // ── Track Address ──────────────────────────────────
                    addressSection
                        .padding(.horizontal, 14)

                    // ── Search Perp Positions ─────────────────────────
                    perpSearchSection
                        .padding(.horizontal, 14)

                    // Spacer so keyboard doesn't cover bottom fields
                    Color.clear.frame(height: 60).id("bottom")
                }
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedField) { _, field in
                guard let field else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(field, anchor: .center)
                }
            }
        } // ScrollViewReader
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Show keyboard bar whenever a field is focused (more reliable than
            // UIKit notifications alone, which can miss events after navigation pop)
            if focusedField != nil {
                keyboardBar
            }
        }
        .background(Color.hlBackground)
        .navigationTitle("Track")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showWalletDetail) {
            WalletDetailView(address: trackedAddress)
                .navigationTitle("Wallet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
        }
        .navigationDestination(isPresented: $showSearchResults) {
            if let market = selectedMarket {
                TrackSearchResultsView(
                    market: market,
                    sideFilter: sideFilter == .long ? .long : sideFilter == .short ? .short : nil,
                    minAmount: Self.parseDecimal(minAmount),
                    maxAmount: Self.parseDecimal(maxAmount),
                    minEntry: Self.parseDecimal(minEntry),
                    maxEntry: Self.parseDecimal(maxEntry)
                )
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .navigationDestination(isPresented: $showOutcomeSearchResults) {
            if let question = selectedOutcome {
                TrackOutcomeSearchResultsView(
                    question: question,
                    selectedOutcomeIndex: selectedOutcomeIndex,
                    sideIndex: outcomeSideIndex,
                    minSize: Self.parseDecimal(minAmount),
                    maxSize: Self.parseDecimal(maxAmount),
                    minPrice: Self.parseDecimalRaw(minEntry),
                    maxPrice: Self.parseDecimalRaw(maxEntry)
                )
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .task { await loadAliases() }
        .sheet(isPresented: $showMarketPicker) {
            MarketPickerSheet(
                selection: $selectedMarket,
                outcomeSelection: $selectedOutcome,
                isPresented: $showMarketPicker
            )
            .environmentObject(marketsVM)
        }
        .onChange(of: selectedMarket?.symbol) { _, _ in
            // Reset filters when switching to perp market
            if selectedMarket != nil {
                selectedOutcomeIndex = nil
                outcomeSideIndex = nil
            }
            clearFilters()
        }
        .onChange(of: selectedOutcome?.id) { _, _ in
            // Reset filters when switching to outcome market
            if selectedOutcome != nil {
                sideFilter = .both
                selectedOutcomeIndex = nil
                outcomeSideIndex = nil
            }
            clearFilters()
        }
    }

    private func clearFilters() {
        minAmount = ""
        maxAmount = ""
        minEntry = ""
        maxEntry = ""
    }

    // MARK: - Address section

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Track a Wallet", systemImage: "person.magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)

            Text("Paste a Hyperliquid address to view positions, PnL, transactions and more.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))

            HStack(spacing: 10) {
                TextField("0x…", text: $addressInput)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .address)
                    .padding(.horizontal, 12)
                    .padding(.trailing, addressInput.isEmpty ? 0 : 24)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.08))
                    .cornerRadius(10)
                    .overlay(alignment: .trailing) {
                        if !addressInput.isEmpty {
                            Button {
                                addressInput = ""
                                focusedField = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.trailing, 8)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )

                Button {
                    if let pasted = UIPasteboard.general.string {
                        addressInput = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 16))
                        .foregroundColor(.hlGreen)
                        .frame(width: 40, height: 40)
                        .background(Color.hlGreen.opacity(0.12))
                        .cornerRadius(10)
                }
            }

            // ── Alias suggestions ──────────────────────────
            if !aliasSuggestions.isEmpty && focusedField == .address {
                VStack(spacing: 0) {
                    ForEach(aliasSuggestions, id: \.address) { suggestion in
                        Button {
                            focusedField = nil
                            trackedAddress = suggestion.address
                            showWalletDetail = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(suggestion.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.hlGreen)
                                Spacer()
                                Text(shortAddr(suggestion.address))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(white: 0.4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }

                        if suggestion.address != aliasSuggestions.last?.address {
                            Divider().background(Color(white: 0.18))
                        }
                    }
                }
                .background(Color(white: 0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(white: 0.2), lineWidth: 1)
                )
            }

            Button {
                let addr = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard addr.hasPrefix("0x"), addr.count == 42 else { return }
                focusedField = nil  // dismiss keyboard before navigation
                trackedAddress = addr
                showWalletDetail = true
            } label: {
                Text("Track Wallet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(isValidAddress ? Color.hlGreen : Color(white: 0.2))
                    .cornerRadius(10)
            }
            .disabled(!isValidAddress)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    private var isValidAddress: Bool {
        let addr = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return addr.hasPrefix("0x") && addr.count == 42
    }

    // MARK: - Perp search section

    private var perpSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LARP DETECTOR")
                .font(.system(size: 22, weight: .black, design: .default))
                .foregroundColor(.white)

            Text(isOutcomeMode
                 ? "Find wallets with recent trades on this market."
                 : "Find wallets with open perp positions matching your criteria.")
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))

            // Market picker
            HStack(spacing: 10) {
                Button { showMarketPicker = true } label: {
                    HStack {
                        Text(selectedOutcome?.displayTitle ?? selectedMarket?.displayName ?? "Select Market")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor((selectedMarket != nil || selectedOutcome != nil) ? .white : Color(white: 0.4))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.08))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )
                }

                // Side filter — adapts to mode
                if isOutcomeMode {
                    Menu {
                        Button {
                            outcomeSideIndex = nil
                        } label: {
                            if outcomeSideIndex == nil {
                                Label("Both", systemImage: "checkmark")
                            } else {
                                Text("Both")
                            }
                        }
                        ForEach(outcomeSides) { side in
                            Button {
                                outcomeSideIndex = side.sideIndex
                            } label: {
                                if outcomeSideIndex == side.sideIndex {
                                    Label(side.name, systemImage: "checkmark")
                                } else {
                                    Text(side.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(outcomeSideLabel)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(outcomeSideIndex == nil ? Color(white: 0.4) : outcomeSideIndex == 0 ? .hlGreen : .tradingRed)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(white: 0.2), lineWidth: 1)
                        )
                    }
                    .frame(minWidth: 100)
                } else {
                    Menu {
                        ForEach(SideFilter.allCases, id: \.self) { side in
                            Button {
                                sideFilter = side
                            } label: {
                                if sideFilter == side {
                                    Label(side.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(side.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sideFilter.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(sideFilter == .both ? Color(white: 0.4) : sideFilter == .long ? .hlGreen : .tradingRed)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(white: 0.2), lineWidth: 1)
                        )
                    }
                    .frame(width: 100)
                }
            }

            // Outcome picker (only for multi-outcome markets)
            if let question = selectedOutcome, question.isMultiOutcome {
                Text("Outcome")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.5))
                    .padding(.top, 4)

                Menu {
                    Button {
                        selectedOutcomeIndex = nil
                    } label: {
                        if selectedOutcomeIndex == nil {
                            Label("All Outcomes", systemImage: "checkmark")
                        } else {
                            Text("All Outcomes")
                        }
                    }
                    ForEach(Array(question.outcomes.enumerated()), id: \.offset) { idx, outcome in
                        Button {
                            selectedOutcomeIndex = idx
                        } label: {
                            if selectedOutcomeIndex == idx {
                                Label(outcome.name, systemImage: "checkmark")
                            } else {
                                Text(outcome.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        if let idx = selectedOutcomeIndex, question.outcomes.indices.contains(idx) {
                            Text(question.outcomes[idx].name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                        } else {
                            Text("All Outcomes")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(white: 0.4))
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.08))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(white: 0.2), lineWidth: 1)
                    )
                }
            }

            // Amount range
            Text(isOutcomeMode ? "Trade Size (USD)" : "Position Size (USD)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.5))
                .padding(.top, 4)

            HStack(spacing: 10) {
                numberField("Min", text: $minAmount, field: .minAmount)
                numberField("Max", text: $maxAmount, field: .maxAmount)
            }

            // Price range
            Text(isOutcomeMode ? "Price (%)" : "Entry Price")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.5))
                .padding(.top, 4)

            HStack(spacing: 10) {
                numberField(isOutcomeMode ? "Min %" : "Min", text: $minEntry, field: .minEntry)
                numberField(isOutcomeMode ? "Max %" : "Max", text: $maxEntry, field: .maxEntry)
            }

            // Search button
            Button {
                focusedField = nil
                if isOutcomeMode {
                    showOutcomeSearchResults = true
                } else {
                    showSearchResults = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background((selectedMarket != nil || selectedOutcome != nil) ? Color.hlGreen : Color(white: 0.2))
                .cornerRadius(10)
            }
            .disabled(selectedMarket == nil && selectedOutcome == nil)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )
        )
    }

    /// Parse a decimal string, stripping comma grouping separators.
    private static func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(stripCommas(trimmed))
    }

    /// Parse a percentage input (e.g. "65") → 0.65 probability
    private static func parseDecimalRaw(_ text: String) -> Double? {
        guard let val = parseDecimal(text) else { return nil }
        return val / 100.0
    }

    private func numberField(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: field)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.trailing, text.wrappedValue.isEmpty ? 0 : 24)
            .padding(.vertical, 10)
            .background(Color(white: 0.08))
            .cornerRadius(10)
            .overlay(alignment: .trailing) {
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                        focusedField = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .padding(.trailing, 8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(white: 0.2), lineWidth: 1)
            )
            .onChange(of: text.wrappedValue) { oldValue, newValue in
                // Skip cascade: if value is already properly formatted, it's our own SET
                guard formatDecimalWithCommas(newValue) != newValue else { return }
                let formatted = formatDecimalOnChange(oldValue: oldValue, newValue: newValue)
                if formatted != newValue { text.wrappedValue = formatted }
            }
            .id(field)
    }

    // MARK: - Alias autocomplete

    private var aliasSuggestions: [(address: String, name: String)] {
        let input = addressInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard input.count >= 2 else { return [] }
        // Don't suggest when user already typed a full-ish address
        if input.hasPrefix("0x") && input.count > 10 { return [] }
        return allAliases
            .filter { $0.value.lowercased().contains(input) || $0.key.contains(input) }
            .sorted { $0.value.lowercased() < $1.value.lowercased() }
            .prefix(5)
            .map { (address: $0.key, name: $0.value) }
    }

    private func loadAliases() async {
        // Custom aliases (instant, from UserDefaults)
        var merged = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        // Global aliases (fetch from Hypurrscan)
        if let url = URL(string: "https://api.hypurrscan.io/globalAliases"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (k, v) in dict {
                let key = k.lowercased()
                if merged[key] == nil { merged[key] = v }  // custom aliases take priority
            }
        }
        allAliases = merged
    }

    private func shortAddr(_ addr: String) -> String {
        guard addr.count > 10 else { return addr }
        return "\(addr.prefix(6))…\(addr.suffix(4))"
    }

    // MARK: - Keyboard bar

    private var keyboardBar: some View {
        HStack(spacing: 12) {
            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue - 1) }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .address ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .address)

            Button {
                focusedField = focusedField.flatMap { Field(rawValue: $0.rawValue + 1) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(focusedField == .maxEntry ? Color(white: 0.3) : .white)
            }
            .disabled(focusedField == .maxEntry)

            Spacer()

            Button("Done") {
                focusedField = nil
            }
            .fontWeight(.semibold)
            .foregroundColor(.hlGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }
}
