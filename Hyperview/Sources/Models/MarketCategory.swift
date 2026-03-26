import Foundation

// MARK: - Main Category (top row chips — matches Hyperliquid)

enum MainCategory: String, CaseIterable, Identifiable {
    case all         = "All"
    case perps       = "Perps"
    case spot        = "Spot"
    case predictions = "Predictions"
    case options     = "Options"
    case trending    = "Trending"

    // Hidden from top row — accessed as Perps sub-categories
    case crypto      = "Crypto"
    case tradfi      = "Tradfi"
    case hip3        = "HIP-3"
    case preLaunch   = "Pre-launch"

    var id: String { rawValue }

    /// Categories shown in the top row of MarketsView
    static var topRow: [MainCategory] {
        [.all, .perps, .spot, .predictions, .options, .trending]
    }
}

// MARK: - Perp Sub-Category (second row under Perps)

enum PerpSubCategory: String, CaseIterable, Identifiable {
    case all       = "All"
    case crypto    = "Crypto"
    case tradfi    = "Tradfi"
    case hip3      = "HIP-3"
    case preLaunch = "Pre-launch"

    var id: String { rawValue }
}

// MARK: - Spot Quote Category (second row under Spot — matches Hyperliquid)

enum SpotQuoteCategory: String, CaseIterable, Identifiable {
    case all  = "All"
    case usdc = "USDC"
    case usdh = "USDH"
    case usdt = "USDT"

    var id: String { rawValue }

    /// Match a pair's quote currency to this category
    static func detect(forQuote quote: String) -> SpotQuoteCategory {
        let q = quote.uppercased()
        if q == "USDC" { return .usdc }
        if q == "USDH" { return .usdh }
        if q.hasPrefix("USDT") { return .usdt }  // USDT0 → USDT
        return .all
    }
}

// MARK: - Crypto Sub-Category (second row under Crypto)

enum CryptoSubCategory: String, CaseIterable, Identifiable {
    case all            = "All"
    case defi           = "DeFi"
    case ai             = "AI"
    case gaming         = "Gaming"
    case layer1         = "Layer 1"
    case layer2         = "Layer 2"
    case memes          = "Memes"
    case infrastructure = "Infra"

    var id: String { rawValue }

    /// Strip DEX prefix from symbol (e.g. "hyna:BTC" → "BTC")
    private static func stripPrefix(_ symbol: String) -> String {
        let s = symbol.uppercased()
        return s.contains(":") ? String(s.split(separator: ":").last ?? Substring(s)) : s
    }

    /// Returns true if the symbol matches any known crypto token set
    static func isCrypto(_ symbol: String) -> Bool {
        let s = stripPrefix(symbol)
        return layer1Set.contains(s) || layer2Set.contains(s) ||
               defiSet.contains(s) || aiSet.contains(s) ||
               gamingSet.contains(s) || memeSet.contains(s) ||
               infraSet.contains(s)
    }

    // MARK: - Detection from asset name

    static func detect(for symbol: String) -> CryptoSubCategory {
        let s = stripPrefix(symbol)
        if memeSet.contains(s)    { return .memes }
        if aiSet.contains(s)      { return .ai }
        if gamingSet.contains(s)  { return .gaming }
        if defiSet.contains(s)    { return .defi }
        if layer2Set.contains(s)  { return .layer2 }
        if layer1Set.contains(s)  { return .layer1 }
        if infraSet.contains(s)   { return .infrastructure }
        return .all   // unclassified tokens still show under "All"
    }

    // MARK: - Asset sets

    static let layer1Set: Set<String> = [
        "BTC","ETH","SOL","AVAX","ADA","DOT","ATOM","NEAR","APT","SUI","SEI",
        "INJ","TIA","ALGO","XRP","BNB","TON","TRX","LTC","BCH","ETC","XLM",
        "VET","HBAR","EGLD","ONE","KAVA","CELO","FTM","FLOW","MINA","ICP",
        "ROSE","ZIL","QTUM","WAVES","NEO","EOS","XTZ","ZEC","DCR","DASH",
        "XMR","KAS","KSM","SCRT","OSMO","JUNO","EVMOS","LUNC","LUNA","KDA",
        "ALPH","ERGO","RVN","ZEN","NANO","IOTA","MIOTA","HIVE","STEEM","XDC"
    ]

    static let layer2Set: Set<String> = [
        "ARB","OP","MATIC","IMX","STRK","MANTA","BLAST","ZK","MNT","METIS",
        "BOBA","SKALE","LRC","OMG","CELR","TAIKO","MODE","SCROLL","LINEA",
        "STARKNET","LOOPRING","DYDX","ZKSYNC","POLYGON","MANTLE","BASE",
        "OPTIMISM","ARBITRUM","IMMUTABLE"
    ]

    static let defiSet: Set<String> = [
        "UNI","AAVE","COMP","CRV","MKR","SNX","SUSHI","CAKE","BAL","YFI",
        "RUNE","GMX","GNS","PENDLE","RDNT","JOE","SPELL","LDO","RPL","FXS",
        "CVX","ANKR","1INCH","PERP","KWENTA","UMAMI","VELA","GAINS","HYPE",
        "FLUID","JUP","RAY","ORCA","DRIFT","ZETA","STG","AERO","MORPHO",
        "EIGEN","ENA","ETHENA","BERA","W","ONDO","LISTA","HYPERLIQUID",
        "HLP","VENUS","ALPHA","BIFI","ALPACA","FIS","REEF","OHM",
        "TOKE","ANGLE","PREMIA","LYRA","RIBBON","DOPEX","HEGIC","OPYN",
        "HOOK","VERTEX"
    ]

    static let aiSet: Set<String> = [
        "FET","AGIX","OCEAN","RNDR","RENDER","TAO","WLD","GRT","NMR","AKT",
        "AIOZ","IO","VIRTUAL","AGENT","ARC","GRIFFAIN","ZEREBRO",
        "MASA","ALT","ATH","KAGI","IQ","PYTH","BITTENSOR",
        "CORTEX","DEEPBRAIN","FETCH","SINGULARITYNET","AI16Z","ELIZA",
        "AIXBT","SWARMS","PIPPIN","ACT","DOLOS","OPUS","FXAI",
        "NEIROETH","CLANKER","DEAI","SENTAI"
    ]

    static let gamingSet: Set<String> = [
        "AXS","SAND","MANA","ENJ","GALA","ILV","ALICE","HERO","TLM","SLP",
        "LOOKS","GODS","ATLAS","POLIS","MAGIC","PIXEL","BEAM","RON","PYR",
        "YGG","SUPER","RFOX","GMT","GST","AURY","STAR","CWAR","NAKA",
        "TAMA","ACE","PUFFER","NOT","NOTCOIN","BLUR","LOOKSRARE","TENSOR",
        "RONIN","DFG","GAFI","MAVIA","BIGTIME","SHRAPNEL","ILLUVIUM"
    ]

    static let memeSet: Set<String> = [
        "DOGE","SHIB","PEPE","FLOKI","BONK","WIF","BOME","DOGWIFHAT","MEME",
        "NEIRO","MOG","POPCAT","PNUT","GOAT","PONKE","TURBO","ELON",
        "BABYDOGE","SAMO","HOGE","AIDOGE","AKITA","LADYS","WOJAK","TOSHI",
        "SLERF","MYRO","BODEN","COPE","CHEEMS","SNEK","BRETT","KENDU",
        "SPX","SIGMA","GIGACHAD","CHAD","GIGA","TRUMP","MELANIA","VINE",
        "FARTCOIN","MOODENG","LUCE","CATI","HMSTR","DOGS","HAMSTER","COQ",
        "WEN","MEW","QUACK","SILLY","MNDE","ANALOS","MICHI","WHALES",
        "CATBOY","CRINGE","CAT","DOG","HABIBI","REKT","BASED",
        "ANDY","BITCOIN","BALD","NUANCE","DEGEN","HIGHER","LOWER"
    ]

    static let infraSet: Set<String> = [
        "LINK","BAND","API3","TRB","UMA","DIA","THETA","TFUEL","STORJ","FIL",
        "AR","HNT","IOTX","MXC","JASMY","GNO","SAFE","LIT","CLV","POKT",
        "DIMO","WORMHOLE","JTO","JITO","MARGINFI","NEON","KAMINO","MSOL",
        "BIRDEYE","STETH","RETH","WEETH","RSETH","CBBTC","WBTC","STBTC",
        "METH","EZETH","STSOL","SSOL","JSOL","LSETH","APXETH","UNIETH",
        "LIDO","ROCKET","STAKEWISE","FRAX"
    ]
}

// MARK: - Tradfi Sub-Category (second row under Tradfi)

enum TradfiSubCategory: String, CaseIterable, Identifiable {
    case all         = "All"
    case stocks      = "Stocks"
    case commodities = "Commodities"
    case forex       = "Forex"
    case indices     = "Indices"

    var id: String { rawValue }

    static func detect(for symbol: String) -> TradfiSubCategory {
        // Strip DEX prefix (e.g. "xyz:GOLD" → "GOLD")
        let raw = symbol.uppercased()
        let s = raw.contains(":") ? String(raw.split(separator: ":").last ?? Substring(raw)) : raw
        if stocksSet.contains(s)      { return .stocks }
        if commoditiesSet.contains(s)  { return .commodities }
        if forexSet.contains(s)        { return .forex }
        if indicesSet.contains(s)      { return .indices }
        return .all
    }

    static let stocksSet: Set<String> = [
        "AAPL","AMD","AMZN","BABA","BMNR","COIN","COST","CRWV","GME","GOOGL",
        "HOOD","HYUNDAI","INTC","KIOXIA","LLY","META","MSFT","MSTR",
        "MU","NFLX","NVDA","ORCL","PLTR","RIVN","RTX","SKHX","SMSN","SNDK",
        "SOFTBANK","TSLA","TSM","CRCL"
    ]

    static let commoditiesSet: Set<String> = [
        "ALUMINIUM","BRENTOIL","CL","COPPER","GOLD","NATGAS","OIL",
        "PALLADIUM","PLATINUM","SILVER","URANIUM","URNM","USOIL","WTI",
        "GLDMINE","GOLDJM","SILVERJM"
    ]

    static let forexSet: Set<String> = [
        "EUR","JPY","DXY","GBP","CHF","AUD","CAD","NZD","CNY","CNH",
        "SGD","HKD","SEK","NOK","MXN","BRL","INR","KRW","TWD","ZAR"
    ]

    static let indicesSet: Set<String> = [
        "EWJ","EWY","JP225","KR200","MAG7","SMALL2000","US500","USA500",
        "USAR","USBOND","USENERGY","USTECH","VIX","XYZ100",
        "ANTHROPIC","BIOTECH","DEFENSE","ENERGY","INFOTECH","NUCLEAR",
        "OPENAI","ROBOT","SEMIS","SPACEX","SEMI"
    ]
}
