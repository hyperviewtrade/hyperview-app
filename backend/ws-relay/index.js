/**
 * Hyperview WebSocket Relay v2.0
 *
 * Subscribes to Redis pub/sub channels published by the ingestion service
 * and fans out filtered, throttled data to connected iOS clients.
 *
 * Channels relayed:
 *   prices       → filtered per user's watchlist + position coins, throttled 2s
 *   whales       → all whale trades >= $100k
 *   liquidations → liquidation batches
 *   markets      → market data refresh notifications
 *
 * Client protocol (JSON over WebSocket):
 *   → { type: "subscribe",       channels: ["prices", "whales"] }
 *   → { type: "unsubscribe",     channels: ["prices"] }
 *   → { type: "setWatchlist",    coins: ["BTC", "ETH", "SOL"] }
 *   → { type: "setPositionCoins", coins: ["BTC"] }
 *   → { type: "setAddress",      address: "0x..." }
 *   → { type: "getSnapshot",     channels: ["prices", "whales"] }
 *   ← { type: "connected",       id: "c_42" }
 *   ← { channel: "prices",       data: { "BTC": "62150.5", ... } }
 *   ← { channel: "whales",       data: { coin, side, px, sz, notional, time } }
 *   ← { channel: "liquidations", data: { ... } }
 *   ← { channel: "markets",      data: { updated: true } }
 *   ← { type: "snapshot",        data: { prices: {...}, whales: [...] } }
 */

'use strict';

const WebSocket = require('ws');
const Redis     = require('ioredis');
const http      = require('http');

// ─────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────

const REDIS_URL          = process.env.REDIS_URL || 'redis://localhost:6379';
const PORT               = parseInt(process.env.PORT, 10) || 3002;
const PRICE_THROTTLE_MS  = 2_000;     // max 1 price push per client every 2s
const PRICE_FLUSH_MS     = 2_000;     // flush pending prices every 2s
const PING_INTERVAL_MS   = 25_000;    // ping clients every 25s
const PONG_TIMEOUT_MS    = 10_000;    // terminate if no pong in 10s
const MAX_CONNECTIONS    = 50_000;    // hard cap
const MAX_MSG_SIZE       = 4_096;     // max inbound message size (bytes)
const SNAPSHOT_MAX_WHALES = 50;       // max whale events in snapshot

// Valid subscription channels
const VALID_CHANNELS = new Set(['prices', 'whales', 'liquidations', 'markets']);

// ─────────────────────────────────────────────────────────────
// Redis clients
// ─────────────────────────────────────────────────────────────

// Subscriber — dedicated connection for pub/sub (ioredis requirement)
const redisSub = new Redis(REDIS_URL, {
  maxRetriesPerRequest: null,   // infinite retry for subscriber
  retryStrategy: (times) => Math.min(times * 200, 5_000),
});

// Reader — for get/lrange operations (snapshots)
const redisReader = new Redis(REDIS_URL, {
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => Math.min(times * 200, 5_000),
});

let redisReady = false;
redisSub.on('error',   (err) => console.error('[Redis-Sub] Error:', err.message));
redisSub.on('connect', ()    => { console.log('[Redis-Sub] Connected'); redisReady = true; });
redisSub.on('close',   ()    => { redisReady = false; });
redisReader.on('error', (err) => console.error('[Redis-Read] Error:', err.message));

// ─────────────────────────────────────────────────────────────
// Metrics
// ─────────────────────────────────────────────────────────────

const metrics = {
  totalConnections: 0,
  activeConnections: 0,
  peakConnections: 0,
  messagesRelayed: 0,
  messagesReceived: 0,
  bytesRelayed: 0,
  priceUpdatesRelayed: 0,
  whaleEventsRelayed: 0,
  liqUpdatesRelayed: 0,
  snapshotsServed: 0,
  droppedMessages: 0,
  startTime: Date.now(),
};

// ─────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────

function iso() { return new Date().toISOString().slice(11, 23); }
function log(tag, msg) { console.log(`[${iso()}][${tag}] ${msg}`); }

// ─────────────────────────────────────────────────────────────
// Client Connection
// ─────────────────────────────────────────────────────────────

class ClientConnection {
  constructor(ws, id) {
    this.ws            = ws;
    this.id            = id;
    this.watchlist     = new Set();       // coins for price filtering
    this.positionCoins = new Set();       // coins with open positions
    this.address       = null;            // wallet address
    this.subscriptions = new Set();       // active channel subs
    this.lastPriceSend = 0;              // throttle timestamp
    this.pendingPrices = null;           // buffered price update
    this.alive         = true;           // pong tracking
    this.connectedAt   = Date.now();
  }

  /** All coins this client cares about for price filtering */
  get relevantCoins() {
    if (this.watchlist.size === 0 && this.positionCoins.size === 0) return null; // null = send all
    const s = new Set(this.watchlist);
    for (const c of this.positionCoins) s.add(c);
    return s;
  }

  /** Send JSON to client. Returns false if send failed. */
  send(data) {
    if (this.ws.readyState !== WebSocket.OPEN) return false;

    try {
      const msg = typeof data === 'string' ? data : JSON.stringify(data);
      this.ws.send(msg);
      metrics.messagesRelayed++;
      metrics.bytesRelayed += msg.length;
      return true;
    } catch (err) {
      metrics.droppedMessages++;
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Client Registry
// ─────────────────────────────────────────────────────────────

const clients = new Map();  // id → ClientConnection
let clientIdCounter = 0;

function addClient(ws) {
  const id = `c_${++clientIdCounter}`;
  const client = new ClientConnection(ws, id);
  clients.set(id, client);
  metrics.totalConnections++;
  metrics.activeConnections = clients.size;
  if (clients.size > metrics.peakConnections) metrics.peakConnections = clients.size;
  return client;
}

function removeClient(id) {
  clients.delete(id);
  metrics.activeConnections = clients.size;
}

// ─────────────────────────────────────────────────────────────
// HTTP Server (health + metrics endpoints)
// ─────────────────────────────────────────────────────────────

const httpServer = http.createServer((req, res) => {
  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');

  if (req.url === '/health') {
    const healthy = redisReady;
    res.writeHead(healthy ? 200 : 503);
    res.end(JSON.stringify({
      status:            healthy ? 'ok' : 'degraded',
      activeConnections: metrics.activeConnections,
      peakConnections:   metrics.peakConnections,
      messagesRelayed:   metrics.messagesRelayed,
      uptimeSeconds:     Math.floor((Date.now() - metrics.startTime) / 1000),
      redisConnected:    redisReady,
    }));
    return;
  }

  if (req.url === '/metrics') {
    res.writeHead(200);
    res.end(JSON.stringify({
      ...metrics,
      uptime_seconds: Math.floor((Date.now() - metrics.startTime) / 1000),
      redis_connected: redisReady,
      memory_mb: Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
    }));
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ error: 'not_found' }));
});

// ─────────────────────────────────────────────────────────────
// WebSocket Server
// ─────────────────────────────────────────────────────────────

const wss = new WebSocket.Server({
  server: httpServer,
  path: '/relay',
  maxPayload: MAX_MSG_SIZE,
  perMessageDeflate: false,      // disable compression — we send small JSON
  clientTracking: false,         // we manage clients ourselves
});

wss.on('connection', (ws, req) => {
  // Reject if at capacity
  if (clients.size >= MAX_CONNECTIONS) {
    ws.close(1013, 'server_full');
    return;
  }

  const client = addClient(ws);
  const ip = req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.socket.remoteAddress || 'unknown';

  log('Relay', `+ ${client.id} from ${ip} (active: ${metrics.activeConnections})`);

  // Send welcome
  client.send({ type: 'connected', id: client.id, serverTime: Date.now() });

  // ── Inbound messages ───────────────────────────────────────

  ws.on('message', (raw) => {
    metrics.messagesReceived++;

    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (_) {
      return; // silently ignore invalid JSON
    }

    if (!msg || typeof msg.type !== 'string') return;
    handleClientMessage(client, msg);
  });

  // ── Disconnect ─────────────────────────────────────────────

  ws.on('close', (code, reason) => {
    removeClient(client.id);
    log('Relay', `- ${client.id} (code=${code}, active: ${metrics.activeConnections})`);
  });

  ws.on('error', (err) => {
    // Swallow — close event will handle cleanup
  });

  // ── Ping/Pong for liveness ─────────────────────────────────

  ws.on('pong', () => {
    client.alive = true;
  });
});

// ─────────────────────────────────────────────────────────────
// Client Message Handler
// ─────────────────────────────────────────────────────────────

async function handleClientMessage(client, msg) {
  switch (msg.type) {

    // ── subscribe ────────────────────────────────────────────
    case 'subscribe': {
      const channels = msg.channels;
      if (!Array.isArray(channels)) return;
      for (const ch of channels) {
        if (typeof ch === 'string' && VALID_CHANNELS.has(ch)) {
          client.subscriptions.add(ch);
        }
      }
      break;
    }

    // ── unsubscribe ──────────────────────────────────────────
    case 'unsubscribe': {
      const channels = msg.channels;
      if (!Array.isArray(channels)) return;
      for (const ch of channels) {
        if (typeof ch === 'string') client.subscriptions.delete(ch);
      }
      break;
    }

    // ── setWatchlist ─────────────────────────────────────────
    case 'setWatchlist': {
      const coins = msg.coins;
      if (!Array.isArray(coins)) return;
      client.watchlist = new Set(
        coins.filter(c => typeof c === 'string').slice(0, 200)
      );
      break;
    }

    // ── setPositionCoins ─────────────────────────────────────
    case 'setPositionCoins': {
      const coins = msg.coins;
      if (!Array.isArray(coins)) return;
      client.positionCoins = new Set(
        coins.filter(c => typeof c === 'string').slice(0, 100)
      );
      break;
    }

    // ── setAddress ───────────────────────────────────────────
    case 'setAddress': {
      if (typeof msg.address === 'string' && msg.address.length >= 10 && msg.address.length <= 66) {
        client.address = msg.address;
      }
      break;
    }

    // ── getSnapshot (cached state for fast startup) ──────────
    case 'getSnapshot': {
      const channels = msg.channels;
      if (!Array.isArray(channels)) return;
      await sendSnapshot(client, channels);
      break;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Snapshot: send cached Redis state to a newly connected client
// ─────────────────────────────────────────────────────────────

async function sendSnapshot(client, channels) {
  const snapshots = {};

  try {
    if (channels.includes('prices')) {
      const cached = await redisReader.get('prices');
      if (cached) {
        const allPrices = JSON.parse(cached);
        const relevant = client.relevantCoins;
        if (!relevant) {
          snapshots.prices = allPrices;
        } else {
          const filtered = {};
          for (const coin of relevant) {
            if (allPrices[coin] !== undefined) filtered[coin] = allPrices[coin];
          }
          snapshots.prices = filtered;
        }
      }
    }

    if (channels.includes('whales')) {
      const events = await redisReader.lrange('whale_events', 0, SNAPSHOT_MAX_WHALES - 1);
      snapshots.whales = events.map(e => {
        try { return JSON.parse(e); } catch (_) { return null; }
      }).filter(Boolean);
    }

    if (channels.includes('liquidations')) {
      const cached = await redisReader.get('liquidations');
      if (cached) snapshots.liquidations = JSON.parse(cached);
    }

    if (channels.includes('markets')) {
      const cached = await redisReader.get('markets:oi');
      if (cached) snapshots.markets = JSON.parse(cached);
    }
  } catch (err) {
    log('Snapshot', `Error for ${client.id}: ${err.message}`);
  }

  client.send({ type: 'snapshot', data: snapshots, serverTime: Date.now() });
  metrics.snapshotsServed++;
}

// ─────────────────────────────────────────────────────────────
// Redis Pub/Sub → Fan-out
// ─────────────────────────────────────────────────────────────

redisSub.subscribe(
  'channel:prices',
  'channel:whales',
  'channel:liquidations',
  'channel:markets',
  (err, count) => {
    if (err) {
      log('Redis', `Subscribe error: ${err.message}`);
    } else {
      log('Redis', `Subscribed to ${count} channels`);
    }
  }
);

redisSub.on('message', (channel, message) => {
  switch (channel) {
    case 'channel:prices':
      handlePriceUpdate(message);
      break;
    case 'channel:whales':
      broadcastWhale(message);
      break;
    case 'channel:liquidations':
      broadcastLiquidations(message);
      break;
    case 'channel:markets':
      broadcastMarketUpdate(message);
      break;
  }
});

// ─────────────────────────────────────────────────────────────
// Broadcast: Filtered + Throttled Prices
// ─────────────────────────────────────────────────────────────

function handlePriceUpdate(pricesJson) {
  let allPrices;
  try { allPrices = JSON.parse(pricesJson); } catch (_) { return; }

  const now = Date.now();

  for (const [, client] of clients) {
    if (!client.subscriptions.has('prices')) continue;

    // Throttle: buffer if sent too recently
    if (now - client.lastPriceSend < PRICE_THROTTLE_MS) {
      client.pendingPrices = allPrices;
      continue;
    }

    // Send immediately
    sendFilteredPrices(client, allPrices, now);
  }
}

function sendFilteredPrices(client, allPrices, now) {
  client.lastPriceSend = now;
  client.pendingPrices = null;

  const relevant = client.relevantCoins;

  if (!relevant) {
    // No watchlist set — send everything (Markets tab needs all coins)
    client.send({ channel: 'prices', data: allPrices });
  } else {
    // Filter to only the coins this client cares about
    const filtered = {};
    let count = 0;
    for (const coin of relevant) {
      if (allPrices[coin] !== undefined) {
        filtered[coin] = allPrices[coin];
        count++;
      }
    }
    if (count > 0) {
      client.send({ channel: 'prices', data: filtered });
    }
  }
  metrics.priceUpdatesRelayed++;
}

// ─────────────────────────────────────────────────────────────
// Price Flush Timer: send buffered prices every PRICE_FLUSH_MS
// ─────────────────────────────────────────────────────────────

const priceFlushTimer = setInterval(() => {
  const now = Date.now();

  for (const [, client] of clients) {
    if (!client.pendingPrices) continue;
    if (now - client.lastPriceSend < PRICE_THROTTLE_MS) continue;

    sendFilteredPrices(client, client.pendingPrices, now);
  }
}, PRICE_FLUSH_MS);

// ─────────────────────────────────────────────────────────────
// Broadcast: Whale Events (no filtering, broadcast to all subs)
// ─────────────────────────────────────────────────────────────

function broadcastWhale(eventJson) {
  let event;
  try { event = JSON.parse(eventJson); } catch (_) { return; }

  // Pre-stringify to avoid re-serializing for each client
  const msg = JSON.stringify({ channel: 'whales', data: event });

  for (const [, client] of clients) {
    if (!client.subscriptions.has('whales')) continue;
    client.send(msg);
  }
  metrics.whaleEventsRelayed++;
}

// ─────────────────────────────────────────────────────────────
// Broadcast: Liquidations
// ─────────────────────────────────────────────────────────────

function broadcastLiquidations(liqJson) {
  let data;
  try { data = JSON.parse(liqJson); } catch (_) { return; }

  const msg = JSON.stringify({ channel: 'liquidations', data });

  for (const [, client] of clients) {
    if (!client.subscriptions.has('liquidations')) continue;
    client.send(msg);
  }
  metrics.liqUpdatesRelayed++;
}

// ─────────────────────────────────────────────────────────────
// Broadcast: Market Update (lightweight notification)
// ─────────────────────────────────────────────────────────────

function broadcastMarketUpdate(msgJson) {
  let data;
  try { data = JSON.parse(msgJson); } catch (_) { data = { updated: true }; }

  const msg = JSON.stringify({ channel: 'markets', data });

  for (const [, client] of clients) {
    if (!client.subscriptions.has('markets')) continue;
    client.send(msg);
  }
}

// ─────────────────────────────────────────────────────────────
// Ping/Pong: detect dead clients
// ─────────────────────────────────────────────────────────────

const pingTimer = setInterval(() => {
  for (const [id, client] of clients) {
    if (!client.alive) {
      // No pong since last ping — terminate
      log('Ping', `${id} unresponsive — terminating`);
      client.ws.terminate();
      removeClient(id);
      continue;
    }
    client.alive = false;
    try { client.ws.ping(); } catch (_) {}
  }
}, PING_INTERVAL_MS);

// ─────────────────────────────────────────────────────────────
// Periodic Stats Log
// ─────────────────────────────────────────────────────────────

const statsTimer = setInterval(() => {
  if (metrics.activeConnections > 0 || metrics.messagesRelayed > 0) {
    log('Stats', `clients=${metrics.activeConnections} peak=${metrics.peakConnections} relayed=${metrics.messagesRelayed} bytes=${(metrics.bytesRelayed / 1024 / 1024).toFixed(1)}MB`);
  }
}, 60_000);

// ─────────────────────────────────────────────────────────────
// Startup
// ─────────────────────────────────────────────────────────────

httpServer.listen(PORT, () => {
  console.log('');
  console.log('╔══════════════════════════════════════════╗');
  console.log('║   Hyperview WebSocket Relay v2.0          ║');
  console.log('╚══════════════════════════════════════════╝');
  console.log('');
  log('Boot', `Listening on port ${PORT}`);
  log('Boot', `WS endpoint: ws://localhost:${PORT}/relay`);
  log('Boot', `HTTP endpoints: /health /metrics`);
  log('Boot', `Max connections: ${MAX_CONNECTIONS}`);
  log('Boot', `Price throttle: ${PRICE_THROTTLE_MS}ms per client`);
  console.log('');
});

// ─────────────────────────────────────────────────────────────
// Graceful Shutdown
// ─────────────────────────────────────────────────────────────

async function shutdown(signal) {
  log('Shutdown', `Received ${signal}`);

  // Stop timers
  clearInterval(priceFlushTimer);
  clearInterval(pingTimer);
  clearInterval(statsTimer);

  // Close all client connections
  for (const [id, client] of clients) {
    try {
      client.ws.close(1001, 'server_shutdown');
    } catch (_) {
      try { client.ws.terminate(); } catch (_) {}
    }
  }
  clients.clear();
  log('Shutdown', 'All clients disconnected');

  // Close HTTP/WS server
  wss.close();
  await new Promise(resolve => httpServer.close(resolve));
  log('Shutdown', 'Server closed');

  // Disconnect Redis
  try { redisSub.disconnect();   } catch (_) {}
  try { redisReader.disconnect(); } catch (_) {}
  log('Shutdown', 'Redis disconnected');

  log('Shutdown', 'Done. Goodbye.');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

process.on('unhandledRejection', (reason) => {
  log('WARN', `Unhandled rejection: ${reason}`);
});
