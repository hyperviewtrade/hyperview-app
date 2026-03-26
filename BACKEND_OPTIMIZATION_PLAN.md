# Hyperview Backend Optimization Plan

> Agent 6 — Backend & Scalability
> Created: 2026-03-26
> Status: Draft
> Priority reference: HIGH-09 (centralized configuration)

---

## Overview

This document outlines a phased backend architecture plan to reduce network egress, improve latency, and prepare the Hyperview iOS app for scale. The current architecture has the client making many direct calls to both the Railway backend and the Hyperliquid API. This plan consolidates those calls, adds caching, and introduces a relay layer for shared real-time data.

**Current pain points:**
- Railway backend URL hardcoded in 7+ Swift files (resolved by `Configuration.swift` — HIGH-09)
- No response compression on Railway endpoints
- No HTTP caching headers on any endpoint
- HIP-3 portfolio view triggers N+1 requests (1 per DEX vault)
- Every client opens its own WebSocket for shared market data
- No server-side caching of Hyperliquid API responses

---

## Phase 1: Immediate Backend Changes (Week 1)

### 1.1 Gzip Compression on All Railway Responses

Add Express middleware to compress every response body.

**Implementation (server-side):**
```js
const compression = require('compression');
app.use(compression({ level: 6, threshold: 512 }));
```

- `level: 6` balances CPU vs compression ratio.
- `threshold: 512` skips tiny responses (health checks, etc.).
- Expected reduction: **~3x** for JSON payloads (typical JSON compresses 60-80%).

**Client-side:** iOS `URLSession` already sends `Accept-Encoding: gzip` by default and decompresses transparently. The `Configuration.enableGzipCompression` flag exists for future opt-out if needed.

### 1.2 Cache-Control Headers

Add per-route `Cache-Control` headers so iOS `URLSession` (and any CDN layer added later) can serve stale-while-fresh responses.

| Endpoint | `max-age` | Rationale |
|----------|-----------|-----------|
| `GET /hip3-markets` | 60s | Market metadata changes rarely |
| `GET /daily-opens` | 300s | Updates once per day at 00:00 UTC |
| `GET /sentiment` | 600s | Fear & Greed index updates every 8h |
| `GET /leaderboard` | 120s | Acceptable staleness for rankings |
| `GET /smart-money` | 60s | Position data refreshes every ~60s |

**Implementation (server-side):**
```js
app.get('/hip3-markets', (req, res) => {
  res.set('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
  // ... existing handler
});
```

### 1.3 ETag Support

Add ETag support for the two largest, most frequently polled endpoints.

**Endpoints:** `/hip3-markets`, `/daily-opens`

**Implementation:** Use `express-etag` or compute a SHA-256 hash of the response body. When the client sends `If-None-Match`, return `304 Not Modified` with an empty body.

**Expected impact:** Eliminates redundant payload transfer for unchanged data. Combined with `Cache-Control`, most requests within the TTL window will not even reach the server.

---

## Phase 2: Batch HIP-3 Endpoint (Week 2)

### 2.1 Problem

The HIP-3 portfolio view currently works as follows:
1. Client fetches the list of DEX vaults from `/hip3-markets` (1 request).
2. For each DEX vault, the client calls the Hyperliquid `clearinghouseState` endpoint to get the user's position (N requests).
3. Total: **N+1 requests per user per refresh cycle** (N = number of DEX vaults, currently ~15-30).

This is expensive in bandwidth, latency, and Hyperliquid API rate-limit budget.

### 2.2 Solution: `POST /hip3-positions`

Move the fan-out to the server. The backend makes N parallel calls to Hyperliquid (server-to-server, not subject to per-IP client rate limits) and returns a single aggregated response.

**Request:**
```json
{
  "address": "0xabc123...",
  "dexes": ["dex1_address", "dex2_address", "..."]
}
```

**Response:**
```json
{
  "positions": [
    {
      "dex": "dex1_address",
      "coin": "BTC",
      "szi": "0.5",
      "entryPx": "62000.0",
      "unrealizedPnl": "1500.00",
      "leverage": "5.0"
    }
  ],
  "dexes": {
    "dex1_address": {
      "accountValue": "100000.00",
      "totalMarginUsed": "50000.00"
    }
  },
  "cachedAt": 1711468800
}
```

**Server-side pseudocode:**
```js
app.post('/hip3-positions', async (req, res) => {
  const { address, dexes } = req.body;
  const cacheKey = `hip3:positions:${address}`;

  // Check Redis first
  const cached = await redis.get(cacheKey);
  if (cached) return res.json(JSON.parse(cached));

  // Fan-out parallel requests to Hyperliquid
  const results = await Promise.all(
    dexes.map(dex => fetchClearinghouseState(dex))
  );

  const response = aggregatePositions(results, dexes);
  await redis.setex(cacheKey, 30, JSON.stringify(response));
  res.json(response);
});
```

**Expected impact:** N+1 requests per user per cycle reduced to **1 request per user per 30 seconds**.

---

## Phase 3: Redis Caching Layer (Week 2-3)

### 3.1 Key Schema

| Key | Value | TTL | Source |
|-----|-------|-----|--------|
| `markets:meta` | Full `metaAndAssetCtxs` response | 60s | Hyperliquid API |
| `markets:spot` | Full `spotMetaAndAssetCtxs` response | 60s | Hyperliquid API |
| `hip3:positions:{address}` | User HIP-3 aggregated positions | 35s | Computed (Phase 2) |
| `liqs:latest` | Last 50 liquidations | 15s | Hyperliquid API |
| `prices:all` | All mid prices (allMids) | 5s | Hyperliquid WS (Phase 4) |
| `sentiment:fng` | Fear & Greed index | 600s | alternative.me API |
| `daily:opens` | Daily open prices | 300s | Hyperliquid API |
| `leaderboard:top100` | Top 100 traders | 120s | Hyperliquid API |

### 3.2 Memory Estimation

| Data | Estimated Size | Keys at 10k Users |
|------|---------------|-------------------|
| Market metadata | ~200KB | 2 keys |
| Per-user HIP-3 positions | ~5KB | 10,000 keys |
| Liquidations | ~50KB | 1 key |
| Prices | ~20KB | 1 key |
| Sentiment/Daily | ~5KB | 2 keys |
| **Total** | | **~50MB** |

### 3.3 Infrastructure Options

| Option | Free Tier | Paid Tier | Notes |
|--------|-----------|-----------|-------|
| Redis Cloud (Redis Labs) | 30MB | $7/mo for 250MB | Managed, persistent |
| Railway Redis addon | N/A | ~$5/mo | Same network, lowest latency |
| Upstash Redis | 10k commands/day | $0.2/100k commands | Serverless, pay-per-use |

**Recommendation:** Start with Railway Redis addon for lowest latency (same internal network). Migrate to Redis Cloud if Railway scaling becomes a concern.

### 3.4 Cache Invalidation Strategy

- **TTL-based expiry** for all keys (simplest, sufficient for market data).
- **Write-through** for data updated by the ingestion worker (Phase 4): worker writes to Redis on each WS message, TTL acts as safety net.
- **Manual invalidation** not required for v1 since all data is inherently time-series.

---

## Phase 4: Data Ingestion Worker (Month 2)

### 4.1 Architecture

A single long-lived Node.js process maintains one persistent WebSocket connection to the Hyperliquid API and writes updates to Redis.

```
[Hyperliquid WS API]
        |
        v
  [Ingestion Worker]  ──writes──>  [Redis]
        |                              |
        v                              v
  (whale event filter)         [Railway API Server]
        |                              |
        v                              v
  Redis Stream "whale_events"   [iOS Client]
```

### 4.2 Subscriptions

| Channel | Data | Write Frequency |
|---------|------|----------------|
| `allMids` | Mid prices for all coins | ~1s |
| `trades` (top 20 coins) | Individual trades | ~10-50/s |

### 4.3 Whale Event Detection

Filter trades from the `trades` subscription:
- Threshold: trade size >= $100,000
- On match: publish to Redis Stream `whale_events` with fields:
  - `coin`, `side`, `sz`, `px`, `time`, `hash`
- Stream max length: 1000 entries (auto-trimmed via `XADD ... MAXLEN ~ 1000`)

### 4.4 Benefits

- **1 WS connection** serves all users (vs. 10,000 individual connections for shared data like allMids).
- Data is always warm in Redis; API server reads from cache, never blocks on Hyperliquid.
- Whale detection happens server-side without client polling.

### 4.5 Resilience

- Auto-reconnect with exponential backoff (1s, 2s, 4s, max 30s).
- Health check: if no `allMids` update received in 10s, force reconnect.
- Process manager: use Railway's built-in restart policy or PM2.

---

## Phase 5: WebSocket Relay (Month 2-3)

### 5.1 Channel Classification

| Channel | Relay via Backend? | Rationale |
|---------|-------------------|-----------|
| `allMids` (filtered) | Yes | Shared data, client only needs watchlist subset |
| `whale_events` | Yes | Server-generated, not available from HL |
| `webData2` | No (direct to HL) | User-specific, low-latency required for portfolio |
| `candle` | No (direct to HL) | Low-latency required for charts |
| `l2Book` | No (direct to HL) | Low-latency required for order book |

### 5.2 Relay Architecture

```
[Ingestion Worker] ──pub──> [Redis Pub/Sub]
                                    |
                              ──sub──>  [WS Relay Server]
                                              |
                                        [iOS Clients]
```

**Technology:** Node.js `ws` library. Each client subscribes to specific channels on connect. The relay server subscribes to Redis pub/sub channels and fans out to connected clients.

### 5.3 Filtered allMids

Instead of sending all ~200 coin prices every second, the relay only sends prices for coins in the user's watchlist. This reduces per-client bandwidth by ~90%.

**Protocol:**
```json
// Client -> Server: subscribe
{ "op": "subscribe", "coins": ["BTC", "ETH", "SOL"] }

// Server -> Client: filtered update
{ "ch": "allMids", "data": { "BTC": "62150.5", "ETH": "3050.2", "SOL": "145.8" } }
```

### 5.4 Horizontal Scaling

When a single relay server cannot handle all connections:
1. Run multiple relay instances behind a load balancer with sticky sessions (WS requires connection affinity).
2. All instances subscribe to the same Redis pub/sub channels.
3. Each instance only serves its connected clients.

---

## Phase 6: Scaling Milestones

| Users | Infrastructure | Monthly Cost | Key Changes |
|-------|---------------|-------------|-------------|
| 1-5k | Current Railway (Hobby) + Redis addon | ~$70 | Add compression, caching headers, batch endpoint |
| 5-20k | Railway Pro + Redis Cloud 250MB | ~$200 | Add ingestion worker, WS relay |
| 20-50k | 2x Railway instances + Redis Cluster | ~$500 | Horizontal scaling, sticky sessions for WS |
| 50k+ | Fly.io or AWS ECS + ElastiCache Redis | ~$1-2k | Multi-region, managed orchestration |

### Cost Breakdown (5-20k tier)

| Component | Cost |
|-----------|------|
| Railway Pro (API server) | $20/mo |
| Railway Pro (Ingestion worker) | $20/mo |
| Railway Pro (WS relay) | $20/mo |
| Redis Cloud 250MB | $7/mo |
| Railway egress (post-optimization) | ~$50/mo |
| Domain + SSL | ~$15/mo |
| **Total** | **~$132/mo** |

---

## Network Egress Reduction Summary

| Optimization | Reduction Factor | Phase |
|-------------|-----------------|-------|
| Gzip compression on all responses | 3x | 1 |
| Cache-Control headers (stale-while-fresh) | 2x for slow-changing data | 1 |
| ETag / 304 Not Modified | 1.5x for unchanged data | 1 |
| Batch HIP-3 endpoint (`/hip3-positions`) | Nx (N = DEX count, ~15-30) | 2 |
| Redis-cached market data | 10,000x (1 fetch vs N clients) | 3 |
| Filtered allMids relay (watchlist only) | 10x per-client WS bandwidth | 5 |
| CDN for coin icons (future) | 95% icon egress eliminated | Future |
| **Total estimated** | **5-10x overall** | |

---

## iOS Client Migration Checklist

After each backend phase ships, corresponding iOS changes are needed:

### After Phase 1 (Compression + Caching)
- [x] `Configuration.swift` created with centralized URLs (HIGH-09)
- [ ] Replace all hardcoded Railway URLs with `Configuration.backendBaseURL`
- [ ] Verify `URLSession` is using default caching behavior (it should be)
- [ ] No code changes needed for gzip (handled by `URLSession` automatically)

### After Phase 2 (Batch HIP-3)
- [ ] Replace N individual `clearinghouseState` calls with single `POST /hip3-positions`
- [ ] Update `HIP3AnnotationCache` to consume new response format
- [ ] Add 30s client-side refresh interval to match server cache TTL

### After Phase 3 (Redis Caching)
- [ ] No iOS changes required (server-side only)
- [ ] Optional: reduce polling frequency if server cache makes data fresher

### After Phase 5 (WS Relay)
- [ ] Connect to backend WS relay for `allMids` and `whale_events`
- [ ] Keep direct HL connections for `webData2`, `candle`, `l2Book`
- [ ] Update `WebSocketManager` to handle two connection targets

---

## Files Referenced

| File | Purpose |
|------|---------|
| `Hyperview/Sources/Services/Configuration.swift` | Centralized URL and feature flag configuration (created by this plan) |
| `Hyperview/Sources/Services/HyperliquidAPI.swift` | Primary API client — migrate to use `Configuration` URLs |
| `Hyperview/Sources/Services/MarketDataService.swift` | Market data polling — benefits from caching headers |
| `Hyperview/Sources/Services/WebSocketManager.swift` | WS connections — future relay migration target |
| `Hyperview/Sources/Services/SmartMoneyService.swift` | Uses backend URL — migrate to `Configuration` |
| `Hyperview/Sources/Services/HIP3AnnotationCache.swift` | HIP-3 data — biggest beneficiary of batch endpoint |

---

## Decision Log

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Cache layer | Redis | In-memory (Node.js Map) | Redis persists across deploys, shareable across instances |
| WS relay tech | Node.js `ws` | Socket.IO, uWebSockets.js | Lightweight, no client library needed, proven at scale |
| Hosting | Railway (short-term) | Fly.io, AWS | Already deployed, lowest migration effort |
| Batch endpoint | POST /hip3-positions | GraphQL, gRPC | REST is consistent with existing API, simplest to implement |
