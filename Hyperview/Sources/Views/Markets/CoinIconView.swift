import SwiftUI

/// Icône d'un marché via Hyperliquid CDN (SVG) + cercle coloré en fallback.
struct CoinIconView: View {
    let symbol: String
    var hlIconName: String? = nil
    var iconSize: CGFloat = 28
    var isSpot: Bool = false

    var body: some View {
        if let name = hlIconName {
            let urls = Self.candidateURLs(for: name, isSpot: isSpot)
            if let primary = urls.first {
                SVGIconView(
                    url: primary,
                    fallbackURLs: Array(urls.dropFirst()),
                    fallbackSymbol: symbol,
                    size: iconSize
                )
            } else {
                fallbackCircle
            }
        } else {
            fallbackCircle
        }
    }

    /// Build a list of candidate SVG URLs to try, in priority order.
    static func candidateURLs(for coin: String, isSpot: Bool) -> [URL] {
        var bases: [String] = [coin]

        // HIP-3 dex prefix: "xyz:GOLD" → try "xyz:GOLD", then "GOLD"
        if let colonIdx = coin.firstIndex(of: ":") {
            let afterColon = String(coin[coin.index(after: colonIdx)...])
            if !afterColon.isEmpty {
                bases.append(afterColon)
            }
            // Also try stripping numeric prefix: "1000PEPE" → "PEPE"
            let stripped = afterColon.drop { $0.isNumber }
            if !stripped.isEmpty && String(stripped) != afterColon {
                bases.append(String(stripped))
            }
        }

        // "k" prefix (km dex): "kPEPE" → "PEPE"
        if coin.hasPrefix("k"), coin.count > 2, coin.dropFirst().first?.isUppercase == true {
            bases.append(String(coin.dropFirst()))
        }

        // Numeric prefix: "1000PEPE" → "PEPE"
        let numStripped = coin.drop { $0.isNumber }
        if !numStripped.isEmpty && String(numStripped) != coin {
            bases.append(String(numStripped))
        }

        if isSpot {
            // Strip leading "U" → UPUMP→PUMP, UETH→ETH, USOL→SOL
            let stripped = String(coin.dropFirst())
            if coin.count > 3, coin.hasPrefix("U"),
               !stripped.hasPrefix("SD"), !stripped.hasPrefix("SE") {
                bases.append(stripped)
            }
            // Strip trailing "0" → XAUT0→XAUT, USDT0→USDT
            if coin.hasSuffix("0"), coin.count > 2 {
                bases.append(String(coin.dropLast()))
            }
        }
        // For each base name, try _spot first (if spot), then plain
        var names: [String] = []
        for base in bases {
            if isSpot { names.append("\(base)_spot") }
            names.append(base)
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.compactMap { svgURL(for: $0) }
    }

    private var fallbackCircle: some View {
        ZStack {
            Circle().fill(Self.color(for: symbol))
            Text(String(symbol.prefix(1)).uppercased())
                .font(.system(size: iconSize * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: iconSize, height: iconSize)
    }

    static func svgURL(for name: String) -> URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "https://app.hyperliquid.xyz/coins/\(encoded).svg")
    }

    static func color(for s: String) -> Color {
        let h = s.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Color(hue: Double(abs(h) % 360) / 360.0, saturation: 0.55, brightness: 0.55)
    }
}

// MARK: - Dual Coin Icon (overlapping pair, e.g. ETH/BTC)

/// Displays two overlapping coin icons for pair charts (e.g. ETHBTC).
/// The base icon sits on the left, the quote icon overlaps slightly to the right.
struct DualCoinIconView: View {
    let baseSymbol: String
    let quoteSymbol: String
    var baseHLName: String? = nil
    var quoteHLName: String? = nil
    var containerSize: CGFloat = 28

    private var coinSize: CGFloat { containerSize * 0.75 }
    private var offset: CGFloat { containerSize * 0.40 }

    var body: some View {
        ZStack(alignment: .leading) {
            CoinIconView(symbol: baseSymbol, hlIconName: baseHLName, iconSize: coinSize)
            CoinIconView(symbol: quoteSymbol, hlIconName: quoteHLName, iconSize: coinSize)
                .offset(x: offset)
        }
        .frame(width: containerSize + offset, height: containerSize)
    }
}

// MARK: - CoreSVG dynamic bridge (loaded via dlsym — no linker dependency)

private let _cgHandle: UnsafeMutableRawPointer? = dlopen(nil, RTLD_NOW)

private let _createFromData: (
    @convention(c) (CFData, CFDictionary?) -> UnsafeRawPointer?
)? = {
    guard let sym = dlsym(_cgHandle, "CGSVGDocumentCreateFromData") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CFData, CFDictionary?) -> UnsafeRawPointer?).self)
}()

private let _getCanvasSize: (
    @convention(c) (UnsafeRawPointer) -> CGSize
)? = {
    guard let sym = dlsym(_cgHandle, "CGSVGDocumentGetCanvasSize") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeRawPointer) -> CGSize).self)
}()

private let _drawSVG: (
    @convention(c) (CGContext, UnsafeRawPointer) -> Void
)? = {
    guard let sym = dlsym(_cgHandle, "CGContextDrawSVGDocument") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGContext, UnsafeRawPointer) -> Void).self)
}()

private let _releaseSVG: (
    @convention(c) (UnsafeRawPointer) -> Void
)? = {
    guard let sym = dlsym(_cgHandle, "CGSVGDocumentRelease") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeRawPointer) -> Void).self)
}()

private let _coreSVGAvailable: Bool = {
    _createFromData != nil && _getCanvasSize != nil && _drawSVG != nil
}()

// MARK: - Dedicated URLSession for icon loading (throttled)

private let iconSession: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.httpMaximumConnectionsPerHost = 20
    cfg.timeoutIntervalForRequest = 15
    cfg.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 100_000_000)
    return URLSession(configuration: cfg)
}()

// MARK: - SVG icon cache

private final class SVGIconCache {
    static let shared = SVGIconCache()
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.countLimit = 500 }
    func clear() { cache.removeAllObjects() }
    func get(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

// MARK: - SVG icon view

private struct SVGIconView: View {
    let url: URL
    var fallbackURLs: [URL] = []
    let fallbackSymbol: String
    let size: CGFloat

    @State private var image: UIImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(CoinIconView.color(for: fallbackSymbol))
                    Text(String(fallbackSymbol.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            // Check memory cache first
            if let cached = SVGIconCache.shared.get(url) {
                self.image = cached
                loaded = true
                return
            }
            // Only skip if already loaded for THIS url
            guard !loaded else { return }
            await loadAndRender()
        }
        .onChange(of: url) { _, _ in
            // Reset when URL changes (e.g. user picks a different token)
            loaded = false
            image = nil
        }
    }

    private func loadAndRender() async {
        // 1. Try local disk cache (from IconCacheService bundle)
        // Check all candidate names (backend caches under the coin name, not the CDN variant)
        let allURLs = [url] + fallbackURLs
        for candidateURL in allURLs {
            let name = candidateURL.deletingPathExtension().lastPathComponent
            if let localData = IconCacheService.shared.svgData(for: name) {
                if let img = Self.renderSVG(data: localData, size: size, symbol: fallbackSymbol) {
                    SVGIconCache.shared.set(img, for: url)
                    self.image = img
                    loaded = true
                    return
                }
            }
        }
        // Also check the base symbol name directly (backend stores under coin name e.g. "HFUN")
        let iconName = fallbackSymbol
        if let localData = IconCacheService.shared.svgData(for: iconName) {
            if let img = Self.renderSVG(data: localData, size: size, symbol: fallbackSymbol) {
                SVGIconCache.shared.set(img, for: url)
                self.image = img
                loaded = true
                return
            }
        }

        // 2. Fallback: fetch from CDN directly (try primary URL, then fallback URLs)
        let urlsToTry = [url] + fallbackURLs
        do {
            for tryURL in urlsToTry {
                var request = URLRequest(url: tryURL)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await iconSession.data(for: request)

                // Skip HTML error pages (icon doesn't exist on CDN)
                if data.starts(with: [0x3C, 0x21]) { continue }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }

                if let img = Self.renderSVG(data: data, size: size, symbol: fallbackSymbol) {
                    SVGIconCache.shared.set(img, for: url)
                    self.image = img
                    break
                }
            }
            loaded = true
        } catch {
            // Timeout / network error — don't mark loaded → retry on next appear
        }
    }

    private static func renderSVG(data: Data, size: CGFloat, symbol: String = "") -> UIImage? {
        guard _coreSVGAvailable,
              let create = _createFromData,
              let getSize = _getCanvasSize,
              let draw = _drawSVG
        else { return nil }

        guard let docPtr = create(data as CFData, nil) else { return nil }
        defer { _releaseSVG?(docPtr) }

        let canvas = getSize(docPtr)
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let scale = UIScreen.main.scale
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let targetSize = CGSize(width: size, height: size)
        let s = min(size / canvas.width, size / canvas.height)

        // First render without background
        let plain = UIGraphicsImageRenderer(size: targetSize, format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size)
            cg.scaleBy(x: 1, y: -1)
            cg.scaleBy(x: s, y: s)
            draw(cg, docPtr)
        }

        // Known dark logos that always need a white circle background
        let knownDarkLogos: Set<String> = ["MEGA", "MegaETH"]
        let needsWhiteBg = knownDarkLogos.contains(symbol) || imageNeedsLightBackground(plain)
        guard needsWhiteBg else { return plain }

        return UIGraphicsImageRenderer(size: targetSize, format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(origin: .zero, size: targetSize))
            cg.translateBy(x: 0, y: size)
            cg.scaleBy(x: 1, y: -1)
            cg.scaleBy(x: s, y: s)
            draw(cg, docPtr)
        }
    }

    /// Analyze rendered image pixels to decide if icon needs a light background.
    /// Returns true when opaque pixels are mostly dark AND not colorful.
    /// Handles all fill types: inline hex, CSS styles, named colors, default black.
    private static func imageNeedsLightBackground(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }

        let bpr = w * 4
        var px = [UInt8](repeating: 0, count: h * bpr)
        // Native iOS pixel format: BGRA (premultipliedFirst + little-endian)
        guard let ctx = CGContext(
            data: &px, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // BGRA memory layout: [B, G, R, A]
        var totalBright = 0, opaqueCount = 0, colorfulCount = 0
        for offset in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[offset + 3])
            guard a > 200 else { continue } // only fully opaque pixels
            opaqueCount += 1
            let r = Int(px[offset + 2])
            let g = Int(px[offset + 1])
            let b = Int(px[offset])
            totalBright += (r + g + b) / 3
            if max(r, max(g, b)) - min(r, min(g, b)) > 50 { colorfulCount += 1 }
        }

        guard opaqueCount > 0 else { return false }
        let avgBright = totalBright / opaqueCount
        let colorfulRatio = Double(colorfulCount) / Double(opaqueCount)
        // Needs light bg if average brightness is low AND few pixels are colorful
        return avgBright < 110 && colorfulRatio < 0.15
    }
}
