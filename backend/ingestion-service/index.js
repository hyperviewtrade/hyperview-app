/**
 * Hyperview Ingestion Service v2.0
 *
 * Single WebSocket connection to Hyperliquid → Redis cache → REST API + Pub/Sub.
 * Eliminates per-client HL connections for shared data (prices, trades, markets).
 *
 * Architecture:
 *   1 WS to wss://api.hyperliquid.xyz/ws  (allMids + trades for 16 coins)
 *   Polls metaAndAssetCtxs every 60s
 *   Polls perpDexs every 60s (cached 2h in Redis)
 *   Polls liquidations every 15s from legacy backend
 *   Detects whale trades >= $100k and publishes to Redis
 *   Serves REST API on process.env.PORT (default 3001)
 */

'use strict';

const WebSocket    = require('ws');
const Redis        = require('ioredis');
const express      = require('express');
const compression  = require('compression');

// ─────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────

const HL_WS_URL           = process.env.HL_WS_URL       || 'wss://api.hyperliquid.xyz/ws';
const HL_INFO_URL         = process.env.HL_INFO_URL      || 'https://api.hyperliquid.xyz/info';
const REDIS_URL           = process.env.REDIS_URL        || 'redis://localhost:6379';
const PORT                = parseInt(process.env.PORT, 10) || 3001;
const BACKEND_URL         = process.env.BACKEND_URL      || 'https://hyperview-backend-production-075c.up.railway.app';

const MARKET_POLL_MS      = 60_000;       // 60 s
const DEX_POLL_MS         = 60_000;       // 60 s  (Redis TTL = 2 h)
const LIQ_POLL_MS         = 15_000;       // 15 s
const WHALE_THRESHOLD_USD = 100_000;      // $100 k
const WS_STALE_MS         = 12_000;       // force reconnect if no allMids in 12 s
const MAX_WHALE_LIST      = 200;          // keep last 200 whale events in Redis
const MAX_HIP3_CONCURRENT = 30;           // max parallel HL calls for hip3
const HIP3_CACHE_TTL      = 30;           // seconds

const MONITORED_COINS = [
  'BTC', 'ETH', 'SOL', 'HYPE', 'XRP', 'BNB',
  'DOGE', 'AVAX', 'LINK', 'ARB', 'OP', 'SUI',
  'INJ', 'TIA', 'NEAR', 'TON',
];

// ─────────────────────────────────────────────────────────────
// Redis
// ─────────────────────────────────────────────────────────────

const redis = new Redis(REDIS_URL, {
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => Math.min(times * 200, 5_000),
  lazyConnect: true,
  enableReadyCheck: true,
  reconnectOnError: (err) => {
    const targetErrors = ['READONLY', 'ECONNRESET', 'ETIMEDOUT'];
    return targetErrors.some(e => err.message.includes(e));
  },
});

let redisReady = false;
redis.on('error',   (err) => { console.error('[Redis] Error:', err.message); redisReady = false; });
redis.on('connect', ()    => { console.log('[Redis] Connected');             redisReady = true;  });
redis.on('close',   ()    => { redisReady = false; });

// Safe Redis wrappers — never throw if Redis is down
async function redisSet(key, ttl, value) {
  if (!redisReady) return;
  try { await redis.setex(key, ttl, value); } catch (e) { console.error('[Redis] SET error:', e.message); }
}
async function redisGet(key) {
  if (!redisReady) return null;
  try { return await redis.get(key); } catch (e) { console.error('[Redis] GET error:', e.message); return null; }
}
async function redisPub(channel, data) {
  if (!redisReady) return;
  try { await redis.publish(channel, data); } catch (e) { /* silent */ }
}

// ─────────────────────────────────────────────────────────────
// Metrics
// ─────────────────────────────────────────────────────────────

const metrics = {
  wsReconnects:        0,
  apiErrors:           0,
  apiCalls:            0,
  messagesProcessed:   0,
  whaleEventsDetected: 0,
  lastPriceUpdate:     null,
  lastMarketUpdate:    null,
  lastLiqUpdate:       null,
  startTime:           Date.now(),
};

// ─────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function iso() { return new Date().toISOString().slice(11, 23); }

function log(tag, msg) { console.log(`[${iso()}][${tag}] ${msg}`); }

// ─────────────────────────────────────────────────────────────
// Hyperliquid REST helper with retry + 429 handling
// ─────────────────────────────────────────────────────────────

async function hlPost(body, retries = 3, timeoutMs = 15_000) {
  for (let attempt = 0; attempt < retries; attempt++) {
    try {
      metrics.apiCalls++;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);

      const res = await fetch(HL_INFO_URL, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json' },
        body:    JSON.stringify(body),
        signal:  controller.signal,
      });
      clearTimeout(timer);

      if (res.status === 429) {
        const delay = Math.pow(3, attempt) * 500 + Math.random() * 300;
        log('HL', `Rate limited (429), retry in ${Math.round(delay)}ms`);
        await sleep(delay);
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
      return await res.json();
    } catch (err) {
      metrics.apiErrors++;
      if (err.name === 'AbortError') {
        log('HL', `Request timeout (attempt ${attempt + 1}/${retries})`);
      }
      if (attempt === retries - 1) throw err;
      await sleep(Math.pow(2, attempt) * 1_000);
    }
  }
}

// ─────────────────────────────────────────────────────────────
// In-memory state
// ─────────────────────────────────────────────────────────────

let latestPrices    = {};          // allMids cache (in-memory fallback when Redis down)
let cachedDexNames  = [];          // perpDex vault addresses
let cachedMeta      = null;        // full metaAndAssetCtxs response
let cachedOI        = {};          // extracted OI map

// ─────────────────────────────────────────────────────────────
// WebSocket Connection to Hyperliquid
// ─────────────────────────────────────────────────────────────

let ws                 = null;
let wsReconnectAttempt = 0;
let lastAllMidsTime    = Date.now();
let pingInterval       = null;
let staleCheckInterval = null;
let shuttingDown       = false;

function connectWebSocket() {
  if (shuttingDown) return;
  log('WS', 'Connecting to Hyperliquid...');

  try {
    ws = new WebSocket(HL_WS_URL, {
      handshakeTimeout: 10_000,
      perMessageDeflate: false,
    });
  } catch (err) {
    log('WS', `Connection creation failed: ${err.message}`);
    scheduleReconnect();
    return;
  }

  ws.on('open', () => {
    log('WS', 'Connected');
    wsReconnectAttempt = 0;
    lastAllMidsTime = Date.now();

    // Subscribe: allMids
    wsSend({ method: 'subscribe', subscription: { type: 'allMids' } });

    // Subscribe: trades for each monitored coin
    for (const coin of MONITORED_COINS) {
      wsSend({ method: 'subscribe', subscription: { type: 'trades', coin } });
    }
  });

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      metrics.messagesProcessed++;
      handleWSMessage(msg);
    } catch (err) {
      // Ignore parse errors for ping/pong frames
    }
  });

  ws.on('close', (code, reason) => {
    log('WS', `Disconnected (code=${code}, reason=${reason || 'none'})`);
    cleanupWS();
    scheduleReconnect();
  });

  ws.on('error', (err) => {
    log('WS', `Error: ${err.message}`);
  });

  ws.on('pong', () => {
    // Connection alive
  });

  // Ping every 20s
  clearInterval(pingInterval);
  pingInterval = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.ping();
    }
  }, 20_000);

  // Stale check: if no allMids in WS_STALE_MS, force reconnect
  clearInterval(staleCheckInterval);
  staleCheckInterval = setInterval(() => {
    if (Date.now() - lastAllMidsTime > WS_STALE_MS && ws && ws.readyState === WebSocket.OPEN) {
      log('WS', `No allMids in ${WS_STALE_MS / 1000}s — forcing reconnect`);
      ws.terminate();
    }
  }, WS_STALE_MS);
}

function wsSend(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function cleanupWS() {
  clearInterval(pingInterval);
  clearInterval(staleCheckInterval);
  pingInterval = null;
  staleCheckInterval = null;
}

function scheduleReconnect() {
  if (shuttingDown) return;
  metrics.wsReconnects++;
  const delay = Math.min(Math.pow(2, wsReconnectAttempt) * 1_000, 16_000) + Math.random() * 500;
  wsReconnectAttempt++;
  log('WS', `Reconnecting in ${Math.round(delay)}ms (attempt ${wsReconnectAttempt})`);
  setTimeout(connectWebSocket, delay);
}

// ─────────────────────────────────────────────────────────────
// WS Message Handler
// ─────────────────────────────────────────────────────────────

async function handleWSMessage(msg) {
  if (!msg.channel || !msg.data) return;

  switch (msg.channel) {
    case 'allMids': {
      const mids = msg.data.mids;
      if (!mids || typeof mids !== 'object') return;

      latestPrices = mids;
      lastAllMidsTime = Date.now();
      metrics.lastPriceUpdate = lastAllMidsTime;

      const json = JSON.stringify(mids);
      await redisSet('prices', 5, json);
      await redisPub('channel:prices', json);
      break;
    }

    case 'trades': {
      const trades = msg.data;
      if (!Array.isArray(trades)) return;

      for (const trade of trades) {
        const px  = parseFloat(trade.px  || 0);
        const sz  = parseFloat(trade.sz  || 0);
        const notional = px * sz;

        if (notional >= WHALE_THRESHOLD_USD) {
          metrics.whaleEventsDetected++;
          const whaleEvent = {
            coin:     trade.coin,
            side:     trade.side,        // "B" or "A"
            px:       trade.px,
            sz:       trade.sz,
            notional: Math.round(notional),
            hash:     trade.hash || null,
            time:     trade.time || Date.now(),
            tid:      trade.tid  || null,
          };
          const json = JSON.stringify(whaleEvent);

          // Publish to relay for live clients
          await redisPub('channel:whales', json);

          // Append to recent whales list (capped)
          if (redisReady) {
            try {
              await redis.lpush('whale_events', json);
              await redis.ltrim('whale_events', 0, MAX_WHALE_LIST - 1);
              await redis.expire('whale_events', 3_600); // 1h TTL
            } catch (e) { /* non-critical */ }
          }
        }
      }
      break;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Polling: metaAndAssetCtxs (60s)
// ─────────────────────────────────────────────────────────────

async function pollMarketData() {
  try {
    const data = await hlPost({ type: 'metaAndAssetCtxs' });
    if (!data || !Array.isArray(data) || data.length < 2) return;

    cachedMeta = data;
    metrics.lastMarketUpdate = Date.now();

    const [meta, contexts] = data;
    const universe = meta.universe || [];

    // Build OI map
    const oiMap = {};
    for (let i = 0; i < Math.min(universe.length, contexts.length); i++) {
      const coin = universe[i].name;
      const ctx  = contexts[i];
      oiMap[coin] = {
        openInterest: ctx.openInterest,
        funding:      ctx.funding,
        premium:      ctx.premium,
        volume24h:    ctx.dayNtlVlm,
        markPx:       ctx.markPx,
        prevDayPx:    ctx.prevDayPx,
        impactPxs:    ctx.impactPxs,
      };
    }
    cachedOI = oiMap;

    // Write to Redis
    const metaJson = JSON.stringify(data);
    const oiJson   = JSON.stringify(oiMap);
    await redisSet('markets:meta', 65, metaJson);
    await redisSet('markets:oi',   65, oiJson);

    // Notify relay subscribers
    await redisPub('channel:markets', JSON.stringify({ updated: true, count: universe.length }));

    log('Poll', `Market data updated: ${universe.length} perps`);
  } catch (err) {
    log('Poll', `Market data error: ${err.message}`);
    metrics.apiErrors++;
  }
}

// ─────────────────────────────────────────────────────────────
// Polling: DEX names / perpDexs (60s poll, 2h Redis TTL)
// ─────────────────────────────────────────────────────────────

async function pollDexNames() {
  try {
    // First check Redis — if still cached, skip the API call
    const cached = await redisGet('dex_names');
    if (cached) {
      const parsed = JSON.parse(cached);
      if (Array.isArray(parsed) && parsed.length > 0) {
        cachedDexNames = parsed;
        return;
      }
    }

    const dexData = await hlPost({ type: 'perpDexs' });
    if (!Array.isArray(dexData) || dexData.length === 0) return;

    // perpDexs returns an array of objects with { name, ... } or strings
    const names = dexData.map(d => {
      if (typeof d === 'string') return d;
      if (d && typeof d === 'object') return d.name || d.address || null;
      return null;
    }).filter(Boolean);

    if (names.length === 0) return;

    cachedDexNames = names;
    await redisSet('dex_names', 7_200, JSON.stringify(names)); // 2h TTL
    log('Poll', `DEX names updated: ${names.length} vaults`);
  } catch (err) {
    log('Poll', `DEX names error: ${err.message}`);
  }
}

// ─────────────────────────────────────────────────────────────
// Polling: Liquidations (15s)
// ─────────────────────────────────────────────────────────────

async function pollLiquidations() {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10_000);

    const res = await fetch(`${BACKEND_URL}/liquidations?limit=100`, {
      signal: controller.signal,
      headers: { 'Accept': 'application/json' },
    });
    clearTimeout(timer);

    if (!res.ok) {
      if (res.status !== 404) log('Poll', `Liquidations HTTP ${res.status}`);
      return;
    }

    const data = await res.json();
    const json = JSON.stringify(data);

    metrics.lastLiqUpdate = Date.now();
    await redisSet('liquidations', 20, json);
    await redisPub('channel:liquidations', json);
  } catch (err) {
    if (err.name !== 'AbortError') {
      log('Poll', `Liquidations error: ${err.message}`);
    }
  }
}

// ─────────────────────────────────────────────────────────────
// HIP-3 Batch Position Fetching
// ─────────────────────────────────────────────────────────────

// Simple concurrency limiter for parallel HL calls
async function parallelLimit(tasks, limit) {
  const results = [];
  const executing = new Set();

  for (const task of tasks) {
    const p = task().then(
      (val) => ({ status: 'fulfilled', value: val }),
      (err) => ({ status: 'rejected',  reason: err }),
    );
    results.push(p);
    executing.add(p);
    const clean = () => executing.delete(p);
    p.then(clean, clean);

    if (executing.size >= limit) {
      await Promise.race(executing);
    }
  }
  return Promise.all(results);
}

async function fetchHIP3Positions(address, dexes) {
  if (!address || typeof address !== 'string') {
    return { positions: [], dexStates: {}, timestamp: Date.now(), cached: false };
  }

  // Check Redis cache first
  const cacheKey = `hip3:${address.toLowerCase()}`;
  const cached = await redisGet(cacheKey);
  if (cached) {
    try {
      const parsed = JSON.parse(cached);
      parsed.cached = true;
      return parsed;
    } catch (_) { /* corrupted cache, refetch */ }
  }

  // Determine DEX list
  const dexList = (Array.isArray(dexes) && dexes.length > 0) ? dexes : cachedDexNames;
  if (dexList.length === 0) {
    return { positions: [], dexStates: {}, timestamp: Date.now(), cached: false, error: 'no_dexes' };
  }

  // Fetch all clearinghouseState in parallel (capped concurrency)
  const tasks = dexList.map(dex => () =>
    hlPost({ type: 'clearinghouseState', user: address, dex }, 2, 10_000)
      .then(state => ({ dex, state, ok: true }))
      .catch(err => ({ dex, state: null, ok: false, error: err.message }))
  );

  const results = await parallelLimit(tasks, MAX_HIP3_CONCURRENT);

  const positions = [];
  const dexStates = {};
  let errors = 0;

  for (const result of results) {
    if (result.status !== 'fulfilled') { errors++; continue; }
    const { dex, state, ok } = result.value;
    if (!ok || !state) { errors++; continue; }

    dexStates[dex] = state;

    const assetPositions = state.assetPositions || [];
    for (const ap of assetPositions) {
      const pos = ap.position || ap;
      const szi = parseFloat(pos.szi || '0');
      if (Math.abs(szi) < 1e-9) continue;

      positions.push({
        dex,
        coin:           pos.coin,
        szi:            pos.szi,
        entryPx:        pos.entryPx,
        positionValue:  pos.positionValue,
        unrealizedPnl:  pos.unrealizedPnl,
        liquidationPx:  pos.liquidationPx,
        leverage:       pos.leverage,
        marginUsed:     pos.marginUsed,
        returnOnEquity: pos.returnOnEquity,
        maxLeverage:    pos.maxLeverage,
      });
    }
  }

  const response = {
    positions,
    dexStates,
    timestamp: Date.now(),
    cached: false,
    dexCount: dexList.length,
    errorCount: errors,
  };

  // Cache result
  await redisSet(cacheKey, HIP3_CACHE_TTL, JSON.stringify(response));

  return response;
}

// ─────────────────────────────────────────────────────────────
// Express API
// ─────────────────────────────────────────────────────────────

const app = express();

// Middleware
app.use(compression());
app.use(express.json({ limit: '1mb' }));

// CORS
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// Request logging (lightweight)
app.use((req, res, next) => {
  if (req.path !== '/health' && req.path !== '/metrics') {
    const start = Date.now();
    res.on('finish', () => {
      const ms = Date.now() - start;
      if (ms > 1000) log('HTTP', `${req.method} ${req.path} → ${res.statusCode} (${ms}ms) SLOW`);
    });
  }
  next();
});

// ── GET /health ──────────────────────────────────────────────

app.get('/health', (_req, res) => {
  const wsOk    = ws && ws.readyState === WebSocket.OPEN;
  const healthy = wsOk && redisReady;

  res.status(healthy ? 200 : 503).json({
    status:       healthy ? 'ok' : 'degraded',
    uptime:       Math.floor((Date.now() - metrics.startTime) / 1000),
    wsConnected:  wsOk,
    redisConnected: redisReady,
    lastPriceAge: metrics.lastPriceUpdate ? Math.floor((Date.now() - metrics.lastPriceUpdate) / 1000) : null,
    lastMarketAge: metrics.lastMarketUpdate ? Math.floor((Date.now() - metrics.lastMarketUpdate) / 1000) : null,
  });
});

// ── GET /prices ──────────────────────────────────────────────

app.get('/prices', async (_req, res) => {
  try {
    const cached = await redisGet('prices');
    if (cached) {
      res.set('Cache-Control', 'public, max-age=2');
      return res.json(JSON.parse(cached));
    }
    // Fallback to in-memory
    res.set('Cache-Control', 'public, max-age=1');
    res.json(latestPrices);
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── POST /prices/filtered ────────────────────────────────────

app.post('/prices/filtered', (req, res) => {
  try {
    const { coins } = req.body;
    if (!Array.isArray(coins) || coins.length === 0) {
      return res.status(400).json({ error: 'coins array required' });
    }
    if (coins.length > 300) {
      return res.status(400).json({ error: 'max 300 coins' });
    }

    const filtered = {};
    for (const coin of coins) {
      if (typeof coin === 'string' && latestPrices[coin] !== undefined) {
        filtered[coin] = latestPrices[coin];
      }
    }
    res.set('Cache-Control', 'public, max-age=2');
    res.json(filtered);
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── GET /markets ─────────────────────────────────────────────

app.get('/markets', async (_req, res) => {
  try {
    // Try Redis first
    const cached = await redisGet('markets:meta');
    if (cached) {
      res.set('Cache-Control', 'public, max-age=30');
      return res.json(JSON.parse(cached));
    }
    // Try in-memory
    if (cachedMeta) {
      res.set('Cache-Control', 'public, max-age=15');
      return res.json(cachedMeta);
    }
    // Force fetch
    await pollMarketData();
    if (cachedMeta) return res.json(cachedMeta);
    res.status(503).json({ error: 'market_data_unavailable' });
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── GET /markets/oi ──────────────────────────────────────────

app.get('/markets/oi', async (_req, res) => {
  try {
    const cached = await redisGet('markets:oi');
    if (cached) {
      res.set('Cache-Control', 'public, max-age=30');
      return res.json(JSON.parse(cached));
    }
    if (Object.keys(cachedOI).length > 0) {
      return res.json(cachedOI);
    }
    res.status(503).json({ error: 'oi_data_unavailable' });
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── POST /hip3-positions (CRITICAL: eliminates N+1) ──────────

app.post('/hip3-positions', async (req, res) => {
  try {
    const { address, dexes } = req.body;
    if (!address || typeof address !== 'string') {
      return res.status(400).json({ error: 'address required' });
    }
    // Basic address validation (0x hex or HL-style)
    if (address.length < 10 || address.length > 66) {
      return res.status(400).json({ error: 'invalid address format' });
    }

    const result = await fetchHIP3Positions(address, dexes);
    res.set('Cache-Control', 'private, max-age=25');
    res.json(result);
  } catch (err) {
    log('API', `/hip3-positions error: ${err.message}`);
    res.status(500).json({ error: 'hip3_fetch_failed', message: err.message });
  }
});

// ── GET /liquidations/cached ─────────────────────────────────

app.get('/liquidations/cached', async (_req, res) => {
  try {
    const cached = await redisGet('liquidations');
    if (cached) {
      res.set('Cache-Control', 'public, max-age=10');
      return res.json(JSON.parse(cached));
    }
    res.json({ liquidations: [], count: 0 });
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── GET /whales ──────────────────────────────────────────────

app.get('/whales', async (req, res) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 50, 1), MAX_WHALE_LIST);
    if (!redisReady) return res.json([]);

    const events = await redis.lrange('whale_events', 0, limit - 1);
    res.set('Cache-Control', 'public, max-age=1');
    res.json(events.map(e => {
      try { return JSON.parse(e); } catch (_) { return null; }
    }).filter(Boolean));
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── GET /dex-names ───────────────────────────────────────────

app.get('/dex-names', async (_req, res) => {
  try {
    const cached = await redisGet('dex_names');
    if (cached) {
      res.set('Cache-Control', 'public, max-age=3600');
      return res.json(JSON.parse(cached));
    }
    // Fallback to in-memory
    res.set('Cache-Control', 'public, max-age=60');
    res.json(cachedDexNames);
  } catch (err) {
    res.status(500).json({ error: 'internal_error' });
  }
});

// ── GET /metrics ─────────────────────────────────────────────

app.get('/metrics', (_req, res) => {
  res.json({
    ...metrics,
    uptime_seconds:   Math.floor((Date.now() - metrics.startTime) / 1000),
    ws_state:         ws && ws.readyState === WebSocket.OPEN ? 'connected' : 'disconnected',
    ws_reconnects:    wsReconnectAttempt,
    redis_state:      redisReady ? 'connected' : 'disconnected',
    cached_dex_count: cachedDexNames.length,
    prices_count:     Object.keys(latestPrices).length,
    memory_mb:        Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
  });
});

// 404 catch-all
app.use((_req, res) => { res.status(404).json({ error: 'not_found' }); });

// Error handler
app.use((err, _req, res, _next) => {
  log('HTTP', `Unhandled error: ${err.message}`);
  res.status(500).json({ error: 'internal_error' });
});

// ─────────────────────────────────────────────────────────────
// Polling intervals (stored for graceful shutdown)
// ─────────────────────────────────────────────────────────────

let marketInterval = null;
let dexInterval    = null;
let liqInterval    = null;

// ─────────────────────────────────────────────────────────────
// Startup
// ─────────────────────────────────────────────────────────────

let httpServer = null;

async function start() {
  console.log('');
  console.log('╔══════════════════════════════════════════╗');
  console.log('║   Hyperview Ingestion Service v2.0       ║');
  console.log('╚══════════════════════════════════════════╝');
  console.log('');

  // 1. Connect Redis
  log('Boot', 'Connecting to Redis...');
  await redis.connect();
  log('Boot', 'Redis connected');

  // 2. Connect WebSocket to Hyperliquid
  connectWebSocket();

  // 3. Initial data fetch (sequential to avoid rate-limit on startup)
  log('Boot', 'Fetching initial data...');
  await pollDexNames();
  await sleep(200); // Small gap to avoid 429
  await pollMarketData();
  await sleep(200);
  pollLiquidations(); // Fire and forget — non-critical

  // 4. Start polling loops
  marketInterval = setInterval(pollMarketData,   MARKET_POLL_MS);
  dexInterval    = setInterval(pollDexNames,     DEX_POLL_MS);
  liqInterval    = setInterval(pollLiquidations, LIQ_POLL_MS);

  // 5. Start HTTP server
  httpServer = app.listen(PORT, () => {
    log('Boot', `HTTP listening on port ${PORT}`);
    log('Boot', `Endpoints: /health /prices /markets /hip3-positions /whales /liquidations/cached /dex-names /metrics`);
    console.log('');
  });
}

// ─────────────────────────────────────────────────────────────
// Graceful Shutdown
// ─────────────────────────────────────────────────────────────

async function shutdown(signal) {
  log('Shutdown', `Received ${signal}, cleaning up...`);
  shuttingDown = true;

  // Stop polling
  clearInterval(marketInterval);
  clearInterval(dexInterval);
  clearInterval(liqInterval);

  // Close WS
  cleanupWS();
  if (ws) {
    try { ws.close(1000, 'shutdown'); } catch (_) {}
  }

  // Close HTTP server
  if (httpServer) {
    await new Promise((resolve) => httpServer.close(resolve));
    log('Shutdown', 'HTTP server closed');
  }

  // Disconnect Redis
  try { await redis.quit(); } catch (_) {}
  log('Shutdown', 'Redis disconnected');

  log('Shutdown', 'Done. Goodbye.');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

// Prevent unhandled rejections from crashing the process
process.on('unhandledRejection', (reason) => {
  log('WARN', `Unhandled rejection: ${reason}`);
});

// ─── Go ──────────────────────────────────────────────────────

start().catch(err => {
  console.error('[FATAL] Startup error:', err);
  process.exit(1);
});
