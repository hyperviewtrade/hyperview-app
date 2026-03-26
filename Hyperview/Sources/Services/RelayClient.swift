import Foundation
import Combine

/// Connects to the Hyperview backend WebSocket relay for shared data streams.
/// This reduces per-client connections to Hyperliquid for data that doesn't need
/// sub-100ms latency (prices, whale events, liquidations).
///
/// Architecture:
/// - Direct HL WS: l2Book, candle, webData2 (latency-critical)
/// - Backend relay: prices (filtered), whales, liquidations (fan-out)
@MainActor
final class RelayClient: ObservableObject {
    static let shared = RelayClient()

    // MARK: - Published State

    @Published private(set) var isConnected = false

    /// Filtered price updates from relay (only watchlist + position coins)
    let pricePublisher = PassthroughSubject<[String: String], Never>()

    /// Whale trade events (pre-filtered >= $100k by backend)
    let whalePublisher = PassthroughSubject<[String: Any], Never>()

    /// Liquidation updates (push instead of polling)
    let liquidationPublisher = PassthroughSubject<[String: Any], Never>()

    // MARK: - Private State

    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var pingTimer: AnyCancellable?
    private var watchlist: Set<String> = []
    private var positionCoins: Set<String> = []
    private var userAddress: String?

    /// Whether the relay is enabled (can be disabled as feature flag)
    private let relayEnabled: Bool

    // MARK: - Init

    private init() {
        // Only enable relay if backend relay URL is configured
        relayEnabled = !Configuration.relayWSURL.isEmpty
    }

    // MARK: - Connection

    func connect() {
        guard relayEnabled else { return }
        guard task == nil || task?.state != .running else { return }

        guard let url = URL(string: Configuration.relayWSURL) else {
            print("[Relay] Invalid relay URL")
            return
        }

        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
        task?.resume()

        isConnected = true
        reconnectAttempt = 0

        // Start receiving messages
        receiveMessage()

        // Start ping
        startPing()

        // Subscribe to channels
        subscribe(channels: ["prices", "whales", "liquidations"])

        // Set watchlist if already known
        if !watchlist.isEmpty {
            sendWatchlist()
        }
        if let addr = userAddress {
            sendAddress(addr)
        }

        print("[Relay] Connected to backend relay")
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        pingTimer = nil
    }

    // MARK: - Subscriptions

    func updateWatchlist(_ coins: Set<String>) {
        watchlist = coins
        sendWatchlist()
    }

    func updatePositionCoins(_ coins: Set<String>) {
        positionCoins = coins
        sendJSON(["type": "setPositionCoins", "coins": Array(coins)])
    }

    func updateAddress(_ address: String?) {
        userAddress = address
        if let addr = address {
            sendAddress(addr)
        }
    }

    // MARK: - Private Methods

    private func subscribe(channels: [String]) {
        sendJSON(["type": "subscribe", "channels": channels])
    }

    private func sendWatchlist() {
        sendJSON(["type": "setWatchlist", "coins": Array(watchlist)])
    }

    private func sendAddress(_ address: String) {
        sendJSON(["type": "setAddress", "address": address])
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(str)) { error in
            if let error = error {
                print("[Relay] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func receiveMessage() {
        guard let task = self.task else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.receiveMessage() // Continue receiving

                case .failure(let error):
                    print("[Relay] Receive error: \(error.localizedDescription)")
                    self?.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let str: String
        switch message {
        case .string(let s): str = s
        case .data(let d): str = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }

        guard let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = json["channel"] as? String
        else { return }

        switch channel {
        case "prices":
            if let prices = json["data"] as? [String: String] {
                pricePublisher.send(prices)
            }

        case "whales":
            if let event = json["data"] as? [String: Any] {
                whalePublisher.send(event)
            }

        case "liquidations":
            if let liqData = json["data"] as? [String: Any] {
                liquidationPublisher.send(liqData)
            }

        default:
            break
        }
    }

    private func handleDisconnect() {
        isConnected = false
        pingTimer = nil

        // Exponential backoff reconnect
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)) * 1_000_000_000, 16_000_000_000)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay))
            connect()
        }
    }

    private func startPing() {
        pingTimer = Timer.publish(every: 25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
    }

    // MARK: - Snapshot Request

    /// Request initial cached state from relay (for fast startup)
    func requestSnapshot(channels: [String]) {
        sendJSON(["type": "getSnapshot", "channels": channels])
    }
}
