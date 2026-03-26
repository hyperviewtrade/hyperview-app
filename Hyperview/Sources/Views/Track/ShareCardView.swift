import SwiftUI
import PhotosUI

struct ShareCardView: View {
    let position: TrackedPosition
    let market: Market
    let alias: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOverlay: Int = 0
    @State private var selectedPhoto: UIImage? = nil
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var selectedMemeIndex: Int = {
        Int.random(in: 0..<6)
    }()
    @State private var showSavedToast = false
    @State private var toastMessage = ""
    @State private var photoOffset: CGSize = .zero
    @State private var showPhotoCropper = false
    @State private var showSizeInToken = false
    @State private var showFullAddress = false
    @State private var pendingPhoto: UIImage? = nil

    private let cardHeight: CGFloat = 340

    private var isLarp: Bool { position.notionalUSD < 1_000 }

    /// Resolve alias: passed alias > custom alias (UserDefaults) > global alias > nil
    private var resolvedAlias: String? {
        // 1. Alias passed from parent view
        if let a = alias, !a.isEmpty { return a }
        let lower = position.address.lowercased()
        // 2. Custom aliases set by user in WalletView
        let customAliases = UserDefaults.standard.dictionary(forKey: "customWalletAliases") as? [String: String] ?? [:]
        if let custom = customAliases[lower], !custom.isEmpty { return custom }
        // 3. Global aliases from Hypurrscan
        if let global = WalletDetailViewModel.globalAliases?[lower], !global.isEmpty { return global }
        return nil
    }

    /// Footer display: alias by default, tap to toggle address
    private var footerDisplayName: String {
        if showFullAddress { return position.address }
        return resolvedAlias ?? position.address
    }

    // Meme image names from assets
    private static let larpMemes = [
        "larp_Bozo_Clown", "larp_kekw", "larp_IMG_7376",
        "larp_Ryan_Gosling_laughing", "larp_Sure_Jan", "larp_Bro_thinks_hes_him"
    ]
    private static let pnlMemes = [
        "pnl_IMG_6191", "pnl_Jordan_Belfort", "pnl_Money_printer_go_brrrr",
        "pnl_Patrick_Bateman", "pnl_Pepe_in_suit", "pnl_Thomas_Shelby_smoking",
        "pnl_sigmaface"
    ]

    // Pre-loaded thumbnails for smooth scrolling in picker
    private static let larpThumbs: [UIImage] = larpMemes.compactMap { UIImage(named: $0) }
    private static let pnlThumbs: [UIImage] = pnlMemes.compactMap { UIImage(named: $0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Card preview — constrained to screen width
                    cardPreview
                        .frame(width: UIScreen.main.bounds.width - 32)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity)

                    // Meme picker + photo library
                    if isLarp {
                        larpMemePicker
                        photoPicker
                    } else {
                        overlayPicker
                        photoPicker
                    }

                    // Action buttons
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            saveButton
                            copyButton
                        }
                        shareButton
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle(isLarp ? "LARP Card" : "PNL Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.hlGreen)
                }
            }
            .overlay(alignment: .bottom) {
                if showSavedToast {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.hlGreen)
                        Text(toastMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.15))
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showPhotoCropper) {
                if let img = pendingPhoto {
                    PhotoCropperView(image: img, cardHeight: cardHeight) { offset in
                        photoOffset = offset
                        selectedPhoto = img
                        pendingPhoto = nil
                    } onCancel: {
                        pendingPhoto = nil
                    }
                }
            }
        }
    }

    // MARK: - Card Preview

    @ViewBuilder
    private var cardPreview: some View {
        if isLarp {
            larpCard
        } else {
            pnlCard
        }
    }

    // MARK: - LARP Card

    private var larpCard: some View {
        let name = resolvedAlias ?? position.shortAddress
        let side = position.isLong ? "LONG" : "SHORT"

        return VStack(spacing: 0) {
            // Meme area with header inside
            GeometryReader { geo in
                ZStack {
                    // Meme background image
                    if let photo = selectedPhoto {
                        Image(uiImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .offset(photoOffset)
                            .frame(width: geo.size.width, height: cardHeight)
                            .clipped()
                    } else {
                        let memeIdx = selectedMemeIndex % Self.larpMemes.count
                        if let img = UIImage(named: Self.larpMemes[memeIdx]) {
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: cardHeight)
                                .clipped()
                        }
                    }

                    // Dark overlay
                    LinearGradient(
                        colors: [Color.black.opacity(0.6), Color.black.opacity(0.4), Color.black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Color.red.opacity(0.12)

                    VStack(spacing: 6) {
                        // Header inside the image
                        HStack {
                            Text("LARP DETECTED")
                                .font(.system(size: 20, weight: .black))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 4, x: 0, y: 2)
                            Spacer()
                            Text("🤡")
                                .font(.system(size: 28))
                        }

                        Spacer()

                        Text("\(name)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 4, x: 0, y: 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text("is \(side) \(position.leverage)× on \(position.coin)")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 4, x: 0, y: 2)

                        Text("with only")
                            .font(.system(size: 13))
                            .foregroundColor(Color(white: 0.7))
                            .shadow(color: .black, radius: 3, x: 0, y: 1)

                        Text(showSizeInToken ? position.formattedSize : position.formattedNotional)
                            .font(.system(size: showSizeInToken ? 24 : 32, weight: .black, design: .rounded))
                            .foregroundColor(.tradingRed)
                            .shadow(color: .black, radius: 6, x: 0, y: 3)
                            .onTapGesture { showSizeInToken.toggle() }

                        Text("😹😹😹")
                            .font(.system(size: 24))

                        Spacer()
                    }
                    .padding(16)
                }
            }
            .frame(height: cardHeight)

            // Details + Footer
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    detailColumn("Entry", position.formattedEntry)
                    Spacer()
                    detailColumn("Mark", position.formattedMark)
                    Spacer()
                    detailColumn("PnL", position.formattedPnl, color: position.livePnl >= 0 ? .hlGreen : .tradingRed)
                }

                HStack(spacing: 4) {
                    let hasAlias = resolvedAlias != nil && !showFullAddress
                    Text(footerDisplayName)
                        .font(.system(size: hasAlias ? 12 : 7, weight: hasAlias ? .bold : .medium, design: .monospaced))
                        .foregroundColor(hasAlias ? .white : Color(white: 0.3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .onTapGesture { showFullAddress.toggle() }
                    Spacer()
                    Text("Powered by")
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.35))
                    Text("Hyperview")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.hlGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color(white: 0.08))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.tradingRed.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - PNL Card

    private var pnlCard: some View {
        let name = resolvedAlias ?? position.shortAddress
        let side = position.isLong ? "LONG" : "SHORT"
        let isProfit = position.livePnl >= 0
        let pnlPercent = position.entryPrice > 0
            ? ((position.liveMarkPrice - position.entryPrice) / position.entryPrice * 100 * (position.isLong ? 1 : -1))
            : 0
        let roePct = pnlPercent * Double(position.leverage)

        return VStack(spacing: 0) {
            // Header with overlay background
            GeometryReader { geo in
                ZStack {
                    // Background: selected photo or meme
                    if let photo = selectedPhoto {
                        Image(uiImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .offset(photoOffset)
                            .frame(width: geo.size.width, height: cardHeight)
                            .clipped()
                            .overlay(Color.black.opacity(0.5))
                    } else if selectedOverlay < Self.pnlMemes.count,
                              let img = UIImage(named: Self.pnlMemes[selectedOverlay]) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: cardHeight)
                            .clipped()
                            .overlay(Color.black.opacity(0.45))
                    } else {
                        Color(white: 0.08)
                    }

                    // Overlay content
                    VStack(spacing: 8) {
                        HStack {
                            Text("\(position.coin)-PERP")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 4, x: 0, y: 2)

                            Text(side)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(position.isLong ? Color.hlGreen : Color.tradingRed)
                                .cornerRadius(4)

                            Text("\(position.leverage)×")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(white: 0.8))
                                .shadow(color: .black, radius: 3, x: 0, y: 1)

                            Spacer()
                        }

                        Spacer()

                        Text(String(format: "%@%.2f%%", roePct >= 0 ? "+" : "", roePct))
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundColor(isProfit ? .hlGreen : .tradingRed)
                            .shadow(color: .black, radius: 6, x: 0, y: 3)

                        Text(position.formattedPnl)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(isProfit ? .hlGreen : .tradingRed)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .shadow(color: .black, radius: 5, x: 0, y: 2)

                        Spacer()
                    }
                    .padding(16)
                }
            }
            .frame(height: cardHeight)

            // Details + Footer
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.45))
                        Text(showSizeInToken ? position.formattedSize : position.formattedNotional)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .onTapGesture { showSizeInToken.toggle() }
                    Spacer()
                    detailColumn("Entry", position.formattedEntry)
                    Spacer()
                    detailColumn("Mark", position.formattedMark)
                }

                HStack(spacing: 4) {
                    let hasAlias = resolvedAlias != nil && !showFullAddress
                    Text(footerDisplayName)
                        .font(.system(size: hasAlias ? 12 : 7, weight: hasAlias ? .bold : .medium, design: .monospaced))
                        .foregroundColor(hasAlias ? .white : Color(white: 0.3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .onTapGesture { showFullAddress.toggle() }
                    Spacer()
                    Text("Powered by")
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.35))
                    Text("Hyperview")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.hlGreen)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .background(Color(white: 0.08))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(white: 0.15), lineWidth: 1)
        )
    }

    private func pnlDetailItem(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.6))
                .shadow(color: .black, radius: 3, x: 0, y: 1)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .shadow(color: .black, radius: 4, x: 0, y: 2)
        }
    }


    // MARK: - LARP Meme Picker

    private var larpMemePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKGROUND")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(0..<Self.larpThumbs.count, id: \.self) { idx in
                        Button {
                            selectedMemeIndex = idx
                            selectedPhoto = nil
                            photoOffset = .zero
                        } label: {
                            Image(uiImage: Self.larpThumbs[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                                .clipped()
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedMemeIndex == idx && selectedPhoto == nil
                                                ? Color.hlGreen : Color(white: 0.2), lineWidth: 2)
                                )
                        }
                    }

                    if let photo = selectedPhoto {
                        Image(uiImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                            .clipped()
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.hlGreen, lineWidth: 2)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Overlay Picker

    private var overlayPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKGROUND")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    // Meme presets
                    ForEach(0..<Self.pnlThumbs.count, id: \.self) { idx in
                        Button {
                            selectedOverlay = idx
                            selectedPhoto = nil
                            photoOffset = .zero
                        } label: {
                            Image(uiImage: Self.pnlThumbs[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                                .clipped()
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedOverlay == idx && selectedPhoto == nil
                                                ? Color.hlGreen : Color(white: 0.2), lineWidth: 2)
                                )
                        }
                    }

                    // Photo thumbnail
                    if let photo = selectedPhoto {
                        Image(uiImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                            .clipped()
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.hlGreen, lineWidth: 2)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }


    // MARK: - Photo Picker

    private var photoPicker: some View {
        PhotosPicker(selection: $photoPickerItem, matching: .images) {
            HStack {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 14))
                Text("Choose from Library")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.hlGreen)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.hlGreen.opacity(0.1))
            .cornerRadius(10)
        }
        .padding(.horizontal, 16)
        .onChange(of: photoPickerItem) { _, item in
            Task {
                guard let item else { return }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    pendingPhoto = img
                    photoOffset = .zero
                    showPhotoCropper = true
                }
            }
        }
    }

    // MARK: - Save Button (image only)

    private var saveButton: some View {
        Button {
            saveImage()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(white: 0.12))
            .cornerRadius(10)
        }
    }

    // MARK: - Copy Button (text only)

    private var copyButton: some View {
        Button {
            copyText()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                Text("Copy")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(white: 0.12))
            .cornerRadius(10)
        }
    }

    // MARK: - Share Button

    private var shareButton: some View {
        Button {
            shareToX()
        } label: {
            HStack(spacing: 8) {
                Image("XLogo")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 24, height: 24)
                Text("Share on X")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color(white: 0.12))
            .cornerRadius(12)
        }
    }

    // MARK: - Save Image

    @MainActor
    private func saveImage() {
        let cardWidth = UIScreen.main.bounds.width - 32
        let cardView = cardPreview
            .frame(width: cardWidth)
            .padding(1)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }

        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)

        showToast(isLarp ? "LARP card saved to library" : "PNL card saved to library")
    }

    // MARK: - Copy Text

    @MainActor
    private func copyText() {
        UIPasteboard.general.string = buildShareText()
        showToast("Copied to clipboard")
    }

    private func showToast(_ message: String) {
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.3)) { showSavedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.3)) { showSavedToast = false }
        }
    }

    // MARK: - Render & Share

    /// Build share text (used by both Save and Share)
    private func buildShareText() -> String {
        let side = position.isLong ? "long" : "short"
        let sideUpper = position.isLong ? "LONG" : "SHORT"
        let displayName = resolvedAlias ?? position.address
        let walletLink = "https://hyperview-backend-production-075c.up.railway.app/w/\(position.address)"

        if isLarp {
            return "LARP DETECTED ! 🤡\n\nThis bozo is \(sideUpper) $\(position.coin) with only \(position.formattedNotional)\n\nCheck his wallet here: \(walletLink)\n\nTracked with @Hyperviewtrade "
        } else {
            let pnlPercent = position.entryPrice > 0
                ? ((position.liveMarkPrice - position.entryPrice) / position.entryPrice * 100 * (position.isLong ? 1 : -1))
                : 0
            let roePct = pnlPercent * Double(position.leverage)
            return "$\(position.coin) \(sideUpper) \(position.leverage)× | PnL: \(position.formattedPnl) (\(String(format: "%+.2f%%", roePct)))\n\n\(displayName)\n\nCheck his wallet here: \(walletLink)\n\nTracked with @Hyperviewtrade "
        }
    }

    @MainActor
    private func shareToX() {
        let cardWidth = UIScreen.main.bounds.width - 32
        let cardView = cardPreview
            .frame(width: cardWidth)
            .padding(1)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }

        let text = buildShareText()

        // Copy image to clipboard so user can paste it in X
        UIPasteboard.general.image = image

        // URL-encode the text for the X intent URL
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        // Try opening X app directly, fall back to web intent
        let xAppURL = URL(string: "x://post?text=\(encodedText)")
        let twitterAppURL = URL(string: "twitter://post?message=\(encodedText)")
        let webURL = URL(string: "https://x.com/intent/tweet?text=\(encodedText)")

        if let xApp = xAppURL, UIApplication.shared.canOpenURL(xApp) {
            UIApplication.shared.open(xApp)
        } else if let twApp = twitterAppURL, UIApplication.shared.canOpenURL(twApp) {
            UIApplication.shared.open(twApp)
        } else if let web = webURL {
            UIApplication.shared.open(web)
        }
    }

    // MARK: - Helpers

    private func detailColumn(_ label: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

// MARK: - Photo Cropper

struct PhotoCropperView: View {
    let image: UIImage
    let cardHeight: CGFloat
    let onConfirm: (CGSize) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    private var currentOffset: CGSize {
        CGSize(width: offset.width + dragOffset.width,
               height: offset.height + dragOffset.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Drag to adjust position")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)

                // Preview area matching card aspect ratio
                GeometryReader { geo in
                    ZStack {
                        Color.black

                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .offset(currentOffset)
                            .frame(width: geo.size.width, height: cardHeight)
                            .clipped()

                        // Dimmed overlay to show the visible area
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.hlGreen.opacity(0.6), lineWidth: 2)
                    }
                    .frame(width: geo.size.width, height: cardHeight)
                    .cornerRadius(12)
                    .gesture(
                        DragGesture()
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            }
                    )
                }
                .frame(height: cardHeight)
                .padding(.horizontal, 16)

                Spacer()

                // Buttons
                HStack(spacing: 16) {
                    Button {
                        dismiss()
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(white: 0.15))
                            .cornerRadius(12)
                    }

                    Button {
                        dismiss()
                        onConfirm(offset)
                    } label: {
                        Text("Confirm")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.hlGreen)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("Adjust Photo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
