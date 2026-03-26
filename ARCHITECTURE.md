# Hyperview — System Architecture

> Last updated: 2026-03-26
> Status: Post-optimization (Phases 1-5 implemented)

---

## 1. System Overview

```
                          EXTERNAL APIS
    +---------------------------------------------------+
    |                                                   |
    |   wss://api.hyperliquid.xyz/ws                    |
    |     - allMids (prices, ~1s)                       |
    |     - trades (top 16 coins, ~10-50/s)             |
    |                                                   |
    |   https://api.hyperliquid.xyz/info                |
    |     - metaAndAssetCtxs (polled 60s)               |
    |     - perpDexs (polled 1h)                        |
    |     - clearinghouseState (per-user, on-demand)    |
    |     - webData2, candle, l2Book (direct from iOS)  |
    |                                                   |
    +-------------|------|--------|---------------------+
                  |      |        |
                  v      v        |
    +-------------------------+   |
    |   INGESTION SERVICE     |   |
    |   (Node.js, port 3001)  |   |
    |                         |   |
    |   1 WS conn -> HL      |   |
    |   Polls market data     |   |
    |   Polls liquidations    |   |
    |   Whale detection       |   |
    |   HIP-3 batch fetch     |   |
    |                         |   |
    |   REST API:             |   |
    |     /health             |   |
    |     /prices             |   |
    |     /prices/filtered    |   |
    |     /markets            |   |
    |     /markets/oi         |   |
    |     /hip3-positions     |   |
    |     /liquidations/cached|   |
    |     /whales             |   |
    |     /dex-names          |   |
    |     /metrics            |   |
    +-----------||------------+   |
                ||                |
          writes || publishes     |
                ||                |
           +----vv----+          |
           |  REDIS   |          |
           | (cache + |          |
           |  pub/sub)|          |
           +----||----+          |
                ||                |
         subscribes ||            |
                ||                |
    +-----------vv------------+   |
    |   WS RELAY              |   |
    |   (Node.js, port 3002)  |   |
    |                         |   |
    |   Redis sub -> fan-out  |   |
    |   Per-client filtering  |   |
    |   Price throttling (2s) |   |
    |   Channels:             |   |
    |     prices (filtered)   |   |
    |     whales              |   |
    |     liquidations        |   |
    |     markets             |   |
    |                         |   |
    |   WS endpoint:          |   |
    |     /relay              |   |
    +-----------||------------+   |
                ||                |
                vv                v
    +----------------------------------------------+
    |          iOS CLIENT (SwiftUI)                 |
    |                                              |
    |  WS Relay connection:                        |
    |    ws://relay:3002/relay                      |
    |    -> prices, whales, liquidations            |
    |                                              |
    |  Direct HL WebSocket:                        |
    |    wss://api.hyperliquid.xyz/ws               |
    |    -> webData2 (portfolio)                    |
    |    -> candle (charts)                         |
    |    -> l2Book (order book)                     |
    |                                              |
    |  REST (Ingestion service):                   |
    |    /hip3-positions (batch)                    |
    |    /markets, /markets/oi                      |
    |    /whales, /dex-names                        |
    |                                              |
    |  REST (Railway legacy backend):              |
    |    /hip3-markets                              |
    |    /daily-opens                               |
    |    /sentiment                                 |
    |    /leaderboard                               |
    |    /smart-money                               |
    |    /liquidations                              |
    +----------------------------------------------+
```

---

## 2. Data Flow Matrix

| Data Type | Source | Path | Update Freq | Latency Target | Consumer |
|-----------|--------|------|-------------|----------------|----------|
| Mid prices (allMids) | HL WS | HL -> Ingestion -> Redis pub/sub -> Relay -> iOS | ~1s from HL, throttled 2s to client | <3s | Watchlist, Dashboard, Positions |
| Whale trades (>$100k) | HL WS (trades) | HL -> Ingestion (filter) -> Redis pub/sub -> Relay -> iOS | Event-driven | <2s | Whale feed |
| Liquidations | Railway backend | Backend -> Ingestion (poll 15s) -> Redis -> Relay -> iOS | 15s | <20s | Liquidation feed |
| Market metadata | HL REST | Ingestion (poll 60s) -> Redis -> REST API -> iOS | 60s | <65s | Markets tab |
| Open interest | HL REST | Ingestion (poll 60s) -> Redis -> REST API -> iOS | 60s | <65s | Analytics |
| HIP-3 positions | HL REST | iOS -> Ingestion /hip3-positions -> HL (fan-out) -> Redis (30s cache) | On-demand, cached 30s | <5s | Portfolio |
| DEX vault list | HL REST | Ingestion (poll 1h) -> Redis (2h TTL) -> REST API -> iOS | 1h | N/A | HIP-3 portfolio |
| Portfolio (webData2) | HL WS | iOS -> HL direct | Real-time | <1s | Portfolio tab |
| Candles (charts) | HL WS | iOS -> HL direct | Real-time | <500ms | Chart view |
| Order book (l2Book) | HL WS | iOS -> HL direct | Real-time | <500ms | Trading view |
| Sentiment (Fear/Greed) | alternative.me | Railway backend -> iOS | 8h | N/A | Dashboard |
| Daily opens | HL REST | Railway backend (cached 300s) -> iOS | Daily | N/A | P&L calculations |
| Leaderboard | HL REST | Railway backend (cached 120s) -> iOS | 2min | N/A | Leaderboard tab |
| Smart money | Railway backend | Railway backend (cached 60s) -> iOS | 60s | N/A | Smart money tab |

### Why Direct vs Relayed?

- **Relayed (via backend):** Shared data identical across all users (prices, whales, liquidations). One upstream connection serves N clients.
- **Direct (iOS -> HL):** User-specific or latency-critical data (portfolio, charts, order book). Adding a relay hop would increase latency without reducing upstream load.

---

## 3. Redis Schema

### Cache Keys

| Key | Type | Value Description | TTL | Written By |
|-----|------|-------------------|-----|------------|
| `prices` | STRING | JSON object: `{ "BTC": "62150.5", "ETH": "3050.2", ... }` (all mid prices) | 5s | Ingestion (on WS allMids) |
| `markets:meta` | STRING | Full `metaAndAssetCtxs` response from HL (~200KB JSON) | 65s | Ingestion (poll 60s) |
| `markets:oi` | STRING | Extracted OI data: `{ "BTC": { "openInterest": "...", "funding": "...", ... } }` | 65s | Ingestion (poll 60s) |
| `hip3:{address}` | STRING | Aggregated HIP-3 positions for a wallet address (~5KB) | 30s | Ingestion (on-demand) |
| `dex_names` | STRING | JSON array of DEX vault names/addresses | 7200s (2h) | Ingestion (poll 1h) |
| `liquidations` | STRING | Latest liquidation data from Railway backend | 15s | Ingestion (poll 15s) |
| `whale_events` | LIST | Last 100 whale trade events (LPUSH, LTRIM 0..99) | 3600s (1h) | Ingestion (on WS trades) |

### Pub/Sub Channels

| Channel | Payload | Publisher | Subscribers |
|---------|---------|-----------|-------------|
| `channel:prices` | Full allMids JSON | Ingestion | WS Relay |
| `channel:whales` | Single whale event JSON | Ingestion | WS Relay |
| `channel:liquidations` | Liquidation batch JSON | Ingestion | WS Relay |
| `channel:markets` | `"updated"` (notification only) | Ingestion | WS Relay |

### Memory Budget (estimated)

| Data | Size Per Key | Max Keys | Total |
|------|-------------|----------|-------|
| prices | ~20KB | 1 | 20KB |
| markets:meta | ~200KB | 1 | 200KB |
| markets:oi | ~50KB | 1 | 50KB |
| hip3:{address} | ~5KB | N users | 5KB * N |
| whale_events | ~0.5KB each | 100 entries | 50KB |
| liquidations | ~50KB | 1 | 50KB |
| dex_names | ~2KB | 1 | 2KB |
| **At 100 users** | | | **~870KB** |
| **At 1,000 users** | | | **~5.4MB** |
| **At 10,000 users** | | | **~50MB** |
| **At 50,000 users** | | | **~250MB** |

---

## 4. WebSocket Subscription Strategy

### Relay Connection (iOS -> WS Relay)

The iOS client opens one persistent WebSocket to the relay at `/relay`.

**Client-to-server messages:**

```
{ "type": "subscribe",       "channels": ["prices", "whales", "liquidations"] }
{ "type": "unsubscribe",     "channels": ["whales"] }
{ "type": "setWatchlist",    "coins": ["BTC", "ETH", "SOL"] }
{ "type": "setPositionCoins","coins": ["BTC"] }
{ "type": "setAddress",      "address": "0xabc..." }
{ "type": "getSnapshot",     "channels": ["prices", "whales"] }
```

**Server-to-client messages:**

```
{ "type": "connected", "id": "client_42" }
{ "channel": "prices", "data": { "BTC": "62150.5", "ETH": "3050.2" } }
{ "channel": "whales", "data": { "coin": "BTC", "side": "B", "sz": "5.0", "px": "62000", "notional": 310000 } }
{ "channel": "liquidations", "data": { ... } }
{ "channel": "markets", "data": { "updated": true } }
{ "type": "snapshot", "data": { "prices": {...}, "whales": [...] } }
```

**Filtering logic:**
- Prices are filtered to only coins in the client's `watchlist + positionCoins`.
- If no watchlist is set, all prices are sent (for the Markets tab).
- Prices are throttled to max 1 update per 2 seconds per client.
- Pending price updates are batched and flushed on the next 2s tick.

### Direct HL Connections (iOS -> Hyperliquid)

The iOS client maintains separate direct WebSocket connections to Hyperliquid for:

| Channel | When Connected | Lifecycle |
|---------|---------------|-----------|
| `webData2` | Portfolio tab is active | Connect on tab appear, disconnect on disappear |
| `candle` | Chart is visible | Connect on chart load, disconnect on dismiss |
| `l2Book` | Order book is visible | Connect on view appear, disconnect on disappear |

These remain direct because:
1. `webData2` contains user-specific portfolio data that cannot be shared.
2. `candle` and `l2Book` require sub-second latency for trading UX.
3. Adding a relay hop would increase latency by 50-200ms without reducing upstream load (each user needs different data).

---

## 5. Scaling Plan

### Tier 1: 1 - 5,000 users

| Component | Spec | Cost |
|-----------|------|------|
| Railway: Ingestion service | 1 instance, 512MB RAM | ~$20/mo |
| Railway: WS Relay | 1 instance, 512MB RAM | ~$20/mo |
| Railway: Legacy API server | 1 instance (existing) | ~$20/mo |
| Railway: Redis addon | 30-50MB | ~$5/mo |
| Railway: Egress | ~10GB/mo (post-compression) | ~$5/mo |
| **Total** | | **~$70/mo** |

**Key optimizations active:**
- Gzip compression on all REST responses (3x reduction)
- Cache-Control headers on slow-changing endpoints
- Batch HIP-3 endpoint (N+1 -> 1 request per user per 30s)
- Filtered price relay (10x per-client WS bandwidth reduction)

### Tier 2: 5,000 - 20,000 users

| Component | Spec | Cost |
|-----------|------|------|
| Railway Pro: Ingestion service | 1 instance, 1GB RAM | ~$25/mo |
| Railway Pro: WS Relay | 1 instance, 2GB RAM | ~$30/mo |
| Railway Pro: Legacy API server | 1 instance | ~$25/mo |
| Redis Cloud (Redis Labs) | 250MB, persistent | ~$7/mo |
| Railway: Egress | ~50GB/mo | ~$25/mo |
| Domain + SSL | | ~$15/mo |
| **Total** | | **~$127/mo** |

**Key changes from Tier 1:**
- Move Redis to managed Redis Cloud for persistence and monitoring.
- Increase relay server RAM to handle 20k concurrent WebSocket connections.
- Monitor relay server CPU; single Node.js process handles ~10-15k connections.

### Tier 3: 20,000 - 50,000 users

| Component | Spec | Cost |
|-----------|------|------|
| Railway Pro: Ingestion service | 1 instance, 1GB RAM | ~$25/mo |
| Railway Pro: WS Relay (x2) | 2 instances behind LB, sticky sessions | ~$60/mo |
| Railway Pro: Legacy API server | 1 instance | ~$25/mo |
| Redis Cloud | 1GB, HA replica | ~$30/mo |
| Load Balancer | Railway internal or Cloudflare | ~$20/mo |
| Egress | ~200GB/mo | ~$100/mo |
| **Total** | | **~$260/mo** |

**Key changes from Tier 2:**
- Horizontal scaling: 2 relay instances with sticky sessions (WebSocket affinity).
- Both relay instances subscribe to the same Redis pub/sub channels independently.
- Redis upgraded to HA with replica for failover.
- Consider Cloudflare WebSocket proxying for DDoS protection.

### Tier 4: 50,000+ users

| Component | Spec | Cost |
|-----------|------|------|
| AWS ECS / Fly.io: Ingestion | 1 container, 1 vCPU, 2GB | ~$50/mo |
| AWS ECS / Fly.io: WS Relay (x4) | 4 containers, autoscaling | ~$200/mo |
| AWS ECS / Fly.io: API server | 2 containers, autoscaling | ~$100/mo |
| AWS ElastiCache Redis | r6g.large, multi-AZ | ~$200/mo |
| AWS ALB | WebSocket support, sticky sessions | ~$50/mo |
| CloudFront CDN | Static assets, coin icons | ~$50/mo |
| Egress | ~1TB/mo | ~$100/mo |
| Monitoring (Datadog/Grafana Cloud) | | ~$50/mo |
| **Total** | | **~$800/mo** |

**Key changes from Tier 3:**
- Multi-region deployment (US-East + EU-West).
- Auto-scaling relay instances based on connection count.
- CDN for static assets (coin icons, TradingView bundle).
- Dedicated monitoring and alerting.

---

## 6. Failure Modes

### Hyperliquid WebSocket Disconnection

| Aspect | Detail |
|--------|--------|
| **Detection** | `ws.on('close')` event in Ingestion service |
| **Impact** | Prices stop updating; whale detection paused |
| **Mitigation** | Exponential backoff reconnect (1s, 2s, 4s, ..., max 16s) |
| **Client experience** | Prices freeze at last known value; relay continues sending cached data from Redis (`prices` key, 5s TTL). After 5s without refresh, Redis key expires. Clients see stale prices with a "delayed" indicator. |
| **Recovery** | Auto-reconnect re-subscribes to allMids + trades. Prices resume within seconds. |

### Redis Down

| Aspect | Detail |
|--------|--------|
| **Detection** | `redis.on('error')` in both Ingestion and Relay |
| **Impact** | Ingestion: cannot cache, cannot pub/sub. Relay: no messages to fan out. REST API: cache misses, falls back to in-memory or force-fetches. |
| **Mitigation** | Ingestion maintains `latestPrices` in-memory as fallback for `/prices` endpoint. Relay becomes non-functional (no pub/sub delivery). |
| **Client experience** | REST endpoints degrade gracefully (slower, direct HL fetch). WebSocket relay goes silent. Direct HL connections unaffected. |
| **Recovery** | Redis reconnect with retry strategy (200ms, 400ms, ..., max 5s). On reconnect, ingestion re-publishes current state. |

### WS Relay Server Crash

| Aspect | Detail |
|--------|--------|
| **Detection** | All client WebSockets receive `close` event |
| **Impact** | Clients lose relay connection (prices, whales, liquidations via push) |
| **Mitigation** | iOS client implements reconnect with backoff. Railway auto-restarts the process. At Tier 3+, load balancer routes to surviving instance. |
| **Client experience** | 5-15s gap in pushed data. REST endpoints unaffected. Direct HL connections unaffected. Client reconnects and sends `getSnapshot` to catch up. |
| **Recovery** | Process restart + client reconnect. Snapshot request fills the gap. |

### Ingestion Service Crash

| Aspect | Detail |
|--------|--------|
| **Detection** | No Redis publishes; relay stops receiving data; `/health` returns error |
| **Impact** | All cached data expires per TTL. No new prices, whales, or market data. |
| **Mitigation** | Railway auto-restart. Redis TTLs ensure stale data expires naturally. |
| **Client experience** | Data freezes then disappears as TTLs expire. REST returns empty/error. Direct HL connections unaffected (portfolio, charts, order book still work). |
| **Recovery** | Process restart. Immediate poll of market data + DEX names. WS reconnect to HL. Full recovery in <30s. |

### Hyperliquid REST API Rate Limited (429)

| Aspect | Detail |
|--------|--------|
| **Detection** | HTTP 429 response in `hlPost()` |
| **Impact** | Market data poll or HIP-3 batch fetch delayed |
| **Mitigation** | Exponential backoff with jitter (300ms * 3^attempt + random 200ms). Max 3 retries. |
| **Client experience** | Slightly stale market data. HIP-3 positions may show cached (30s old) data. |
| **Recovery** | Automatic after backoff. Rate limits typically clear within 1-5s. |

### Network Partition (Ingestion <-> Redis)

| Aspect | Detail |
|--------|--------|
| **Detection** | Redis operations timeout/error |
| **Impact** | Same as Redis Down from Ingestion perspective |
| **Mitigation** | In-memory fallback for prices. Relay may still function if its Redis connection is healthy. |
| **Client experience** | Partial degradation. REST may work (in-memory fallback). Relay may lag or stop. |

---

## 7. Monitoring

### Key Metrics to Track

| Metric | Source | Warning Threshold | Critical Threshold |
|--------|--------|-------------------|-------------------|
| Relay active connections | `GET /metrics` on Relay | >80% of target capacity | >95% of target capacity |
| Relay messages/sec | `metrics.messagesRelayed` | >50,000/s | >100,000/s |
| Relay bytes/sec | `metrics.bytesRelayed` | >50MB/s | >100MB/s |
| Ingestion WS state | `metrics.ws_state` | disconnected >5s | disconnected >30s |
| Ingestion WS reconnects | `metrics.wsReconnects` | >5 in 1h | >20 in 1h |
| Ingestion API errors | `metrics.apiErrors` | >10 in 5min | >50 in 5min |
| Ingestion messages processed | `metrics.messagesProcessed` | <1/s (data stopped) | 0 for 30s |
| Redis memory usage | `INFO memory` | >70% of max | >90% of max |
| Redis connected clients | `INFO clients` | >100 | >500 (leak) |
| Redis pub/sub message rate | `INFO stats` | N/A | 0 for 10s |
| Last price update age | `Date.now() - metrics.lastPriceUpdate` | >5s | >15s |
| Last market data update age | `Date.now() - metrics.lastMarketUpdate` | >90s | >180s |
| HIP-3 request latency | Application timing | >3s p95 | >10s p95 |
| Node.js heap usage | `process.memoryUsage()` | >512MB | >1GB |
| Node.js event loop lag | Custom measurement | >100ms | >500ms |

### Health Check Endpoints

| Endpoint | URL | Expected Response |
|----------|-----|-------------------|
| Ingestion health | `GET :3001/health` | `{ "status": "ok", "wsConnected": true }` |
| Ingestion metrics | `GET :3001/metrics` | Full metrics JSON |
| Relay health | `GET :3002/health` | `{ "status": "ok", "activeConnections": N }` |
| Relay metrics | `GET :3002/metrics` | Connection/message counts |

### Alerting Rules

1. **Price staleness**: If `lastPriceUpdate` is >15s old, page on-call. This means HL WS is down or Ingestion is crashed.
2. **Relay zero connections**: If `activeConnections` drops to 0 during business hours, investigate. Could be relay crash, DNS issue, or deploy in progress.
3. **Error rate spike**: If `apiErrors` increases by >20 in 5 minutes, check HL API status and rate limits.
4. **Memory leak**: If Node.js heap grows monotonically over 24h without stabilizing, investigate for leaked closures or unbounded caches.

---

## 8. Before/After Comparison

### Requests per Minute to Hyperliquid API

| Scenario | Before (per client) | Before (100 users) | After (100 users) | After (10k users) |
|----------|-------------------|--------------------|--------------------|---------------------|
| allMids (WS) | 1 WS conn each | 100 WS connections | 1 WS connection | 1 WS connection |
| trades (WS) | N/A (not tracked) | N/A | 1 WS connection (16 coin subs) | 1 WS connection |
| metaAndAssetCtxs | 1 req/60s each | 100 req/min | 1 req/min | 1 req/min |
| perpDexs | 1 req/60s each | 100 req/min | 1 req/60min | 1 req/60min |
| clearinghouseState (HIP-3) | ~20 req/refresh each | 2,000 req/min | ~3 req/min (cached) | ~300 req/min (cached) |
| **Total HL API load** | | **~2,300 req/min** | **~5 req/min** | **~302 req/min** |
| **Reduction factor** | | | **460x** | **7.6x vs linear** |

### Network Egress (downstream to clients)

| Data Stream | Before (per client/s) | After (per client/s) | Reduction |
|-------------|----------------------|---------------------|-----------|
| allMids (all 200 coins) | ~20KB/s | 0 (relay pushes) | N/A |
| allMids (filtered, 10 coins) | N/A | ~1KB/2s = 0.5KB/s | N/A |
| metaAndAssetCtxs | ~200KB/60s = 3.3KB/s | ~200KB/60s gzipped ~70KB/60s = 1.2KB/s | 2.8x |
| HIP-3 (20 DEX responses) | ~100KB/refresh | ~5KB/30s (batch, gzipped) = 0.17KB/s | 20x |
| Liquidations | ~50KB/15s = 3.3KB/s | Pushed via relay, ~2KB/event | ~3x |
| **Total per client** | **~27KB/s** | **~2KB/s** | **~13x** |

### Egress at Scale

| User Count | Before (monthly) | After (monthly) | Savings |
|------------|------------------|-----------------|---------|
| 100 | ~70GB | ~5GB | 14x |
| 1,000 | ~700GB | ~50GB | 14x |
| 10,000 | ~7TB | ~520GB | 13x |
| 50,000 | ~35TB | ~2.6TB | 13x |

### Latency (client-perceived)

| Data Type | Before | After | Improvement |
|-----------|--------|-------|-------------|
| Price update | ~1s (direct WS) | ~2-3s (relay, throttled) | Slightly slower (acceptable tradeoff for 460x API reduction) |
| Whale alert | N/A (not available) | <2s | New feature |
| Liquidation update | 15s (poll) | <2s (push) | 7x faster |
| HIP-3 positions | 3-10s (N+1 serial) | 1-3s (batch, cached) | 3-5x faster |
| Market data | 1-5s (direct fetch) | 1-2s (cached) | ~2x faster |
| Portfolio (webData2) | <1s (direct WS) | <1s (still direct) | No change |
| Charts (candle) | <500ms (direct WS) | <500ms (still direct) | No change |

---

## Component Inventory

| Component | Location | Port | Language | Dependencies |
|-----------|----------|------|----------|-------------|
| iOS App | `/Hyperview/` | N/A | Swift/SwiftUI | URLSession, native WS |
| Ingestion Service | `/backend/ingestion-service/` | 3001 | Node.js | ws, ioredis, express, compression |
| WS Relay | `/backend/ws-relay/` | 3002 | Node.js | ws, ioredis |
| Load Test | `/backend/load-test/` | N/A | Node.js | ws |
| TradingView Bundle | `/TradingViewBundle/` | N/A | JS/HTML | TradingView Lightweight Charts |
| Widgets | `/HyperviewWidgets/` | N/A | Swift/WidgetKit | N/A |

---

## Deployment Topology (Current: Railway)

```
Railway Project
  |
  +-- Service: ingestion-service
  |     Dockerfile: /backend/ingestion-service/Dockerfile
  |     Env: REDIS_URL, PORT=3001, BACKEND_URL
  |     Health: GET /health
  |
  +-- Service: ws-relay
  |     Dockerfile: /backend/ws-relay/Dockerfile
  |     Env: REDIS_URL, PORT=3002
  |     Health: GET /health
  |
  +-- Service: legacy-api (existing Railway backend)
  |     Env: PORT=3000
  |     Endpoints: /liquidations, /hip3-markets, /daily-opens, etc.
  |
  +-- Plugin: Redis
        URL: redis://default:***@containers-us-west-XXX.railway.app:6379
```

---

## Key Design Decisions

| Decision | Choice | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Price relay vs direct WS | Relay via backend | Each client connects to HL directly | 1 connection for N users; filtered to watchlist saves 90% bandwidth |
| Portfolio/charts WS | Direct to HL | Relay through backend | User-specific, latency-critical; relay adds no value |
| HIP-3 positions | Batch on server | Client-side N+1 fan-out | Eliminates N+1 problem; server-to-server not rate-limited per IP |
| Cache layer | Redis | In-memory Node.js Map | Shared across instances; survives deploys; pub/sub built in |
| WS library | Node.js `ws` | Socket.IO, uWebSockets.js | Lightweight, no client dependency, battle-tested |
| Hosting (Phase 1-3) | Railway | Fly.io, AWS, Render | Already deployed; lowest migration effort; sufficient for <50k users |
| Price throttle | 2s per client | 1s, 5s | Balances freshness vs bandwidth; 2s is fast enough for watchlist display |
