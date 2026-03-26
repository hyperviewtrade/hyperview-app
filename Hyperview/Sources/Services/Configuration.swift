import Foundation

/// Centralized app configuration — single source of truth for all URLs and environment settings.
enum AppEnvironment: String {
    case production
    case staging
    case development
}

struct Configuration {
    /// Current environment — change via build scheme or feature flag
    #if DEBUG
    static let environment: AppEnvironment = .development
    #else
    static let environment: AppEnvironment = .production
    #endif

    // MARK: - Backend URLs

    static var backendBaseURL: String {
        switch environment {
        case .production:
            return "https://hyperview-backend-production-075c.up.railway.app"
        case .staging:
            return "https://hyperview-backend-staging.up.railway.app"
        case .development:
            return "https://hyperview-backend-production-075c.up.railway.app" // Use prod for now
        }
    }

    // MARK: - Hyperliquid API

    static let hyperliquidInfoURL = URL(string: "https://api.hyperliquid.xyz/info")!
    static let hyperliquidExchangeURL = URL(string: "https://api.hyperliquid.xyz/exchange")!
    static let hyperliquidWSURL = URL(string: "wss://api.hyperliquid.xyz/ws")!
    static let hyperliquidTestnetInfoURL = URL(string: "https://api.hyperliquid-testnet.xyz/info")!

    // MARK: - Backend Relay WebSocket

    static var relayWSURL: String {
        switch environment {
        case .production:
            return "wss://hyperview-relay-production.up.railway.app/relay"
        case .staging:
            return "wss://hyperview-relay-staging.up.railway.app/relay"
        case .development:
            return "" // Disabled in dev — use direct HL connections
        }
    }

    // MARK: - External Services

    static let hyperunitBaseURL = "https://api.hyperunit.xyz"
    static let fearGreedURL = URL(string: "https://api.alternative.me/fng/?limit=1")!

    // MARK: - Feature Flags

    /// Enable gzip compression for backend requests
    static let enableGzipCompression = true

    /// HIP-3 DEX name cache TTL (seconds)
    static let dexNameCacheTTL: TimeInterval = 3600

    /// Order book WS health check interval (seconds)
    static let orderBookHealthCheckInterval: TimeInterval = 5

    /// Market data cache TTL (seconds)
    static let marketDataCacheTTL: TimeInterval = 55
}
