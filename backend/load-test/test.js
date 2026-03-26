/**
 * Hyperview Load Test Suite
 *
 * Simulates concurrent users connecting to the backend relay
 * and measures throughput, latency, and resource usage.
 *
 * Usage:
 *   node test.js --users=100 --duration=60 --target=ws://localhost:3002/relay
 */

const WebSocket = require('ws');

// Parse CLI args
const args = {};
process.argv.slice(2).forEach(arg => {
    const [key, val] = arg.replace('--', '').split('=');
    args[key] = val;
});

const NUM_USERS = parseInt(args.users) || 100;
const DURATION_SEC = parseInt(args.duration) || 60;
const TARGET_URL = args.target || 'ws://localhost:3002/relay';
const INGESTION_URL = args.ingestion || 'http://localhost:3001';

// Metrics collection
const metrics = {
    connections: { successful: 0, failed: 0, total: 0 },
    messages: { received: 0, bytes: 0 },
    latency: { samples: [], p50: 0, p95: 0, p99: 0, avg: 0 },
    errors: [],
    startTime: null,
    endTime: null,
};

// Simulated user
class SimulatedUser {
    constructor(id) {
        this.id = id;
        this.ws = null;
        this.connected = false;
        this.messageCount = 0;
        this.lastMessageTime = null;

        // Random watchlist (5-15 coins)
        const allCoins = ['BTC', 'ETH', 'SOL', 'HYPE', 'XRP', 'BNB', 'DOGE', 'AVAX', 'LINK', 'ARB', 'OP', 'SUI', 'INJ', 'TIA', 'NEAR', 'TON', 'APT', 'SEI', 'JUP', 'WIF'];
        const watchlistSize = 5 + Math.floor(Math.random() * 11);
        this.watchlist = allCoins.sort(() => Math.random() - 0.5).slice(0, watchlistSize);

        // Random position coins (0-5)
        const posCount = Math.floor(Math.random() * 6);
        this.positionCoins = this.watchlist.slice(0, posCount);
    }

    connect() {
        return new Promise((resolve, reject) => {
            metrics.connections.total++;

            try {
                this.ws = new WebSocket(TARGET_URL);

                this.ws.on('open', () => {
                    this.connected = true;
                    metrics.connections.successful++;

                    // Subscribe
                    this.send({ type: 'subscribe', channels: ['prices', 'whales', 'liquidations'] });
                    this.send({ type: 'setWatchlist', coins: this.watchlist });
                    this.send({ type: 'setPositionCoins', coins: this.positionCoins });
                    this.send({ type: 'setAddress', address: `0x${this.id.toString(16).padStart(40, '0')}` });

                    resolve();
                });

                this.ws.on('message', (data) => {
                    this.messageCount++;
                    metrics.messages.received++;
                    metrics.messages.bytes += data.length;

                    const now = Date.now();
                    if (this.lastMessageTime) {
                        metrics.latency.samples.push(now - this.lastMessageTime);
                    }
                    this.lastMessageTime = now;
                });

                this.ws.on('error', (err) => {
                    metrics.errors.push({ user: this.id, error: err.message, time: Date.now() });
                });

                this.ws.on('close', () => {
                    this.connected = false;
                });

                // Timeout
                setTimeout(() => {
                    if (!this.connected) {
                        metrics.connections.failed++;
                        reject(new Error(`User ${this.id} connection timeout`));
                    }
                }, 10000);

            } catch (err) {
                metrics.connections.failed++;
                reject(err);
            }
        });
    }

    send(data) {
        if (this.ws?.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(data));
        }
    }

    disconnect() {
        this.ws?.close();
    }
}

// Calculate percentiles
function percentile(arr, p) {
    if (arr.length === 0) return 0;
    const sorted = [...arr].sort((a, b) => a - b);
    const idx = Math.ceil(sorted.length * p / 100) - 1;
    return sorted[Math.max(0, idx)];
}

// Format bytes
function formatBytes(bytes) {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
}

// Main test runner
async function runTest() {
    console.log('==============================================================');
    console.log('              HYPERVIEW LOAD TEST SUITE                        ');
    console.log('==============================================================');
    console.log(`  Target:    ${TARGET_URL}`);
    console.log(`  Users:     ${NUM_USERS}`);
    console.log(`  Duration:  ${DURATION_SEC}s`);
    console.log('==============================================================');
    console.log('');

    // Check ingestion service health
    try {
        const healthRes = await fetch(`${INGESTION_URL}/health`);
        const health = await healthRes.json();
        console.log(`[Check] Ingestion service: ${health.status} (WS: ${health.wsConnected ? 'connected' : 'disconnected'})`);
    } catch (err) {
        console.warn(`[Check] Ingestion service not reachable: ${err.message}`);
    }

    // Phase 1: Connect users
    console.log(`\n[Phase 1] Connecting ${NUM_USERS} simulated users...`);
    metrics.startTime = Date.now();

    const users = [];
    const batchSize = 50; // Connect 50 at a time

    for (let i = 0; i < NUM_USERS; i += batchSize) {
        const batch = [];
        for (let j = i; j < Math.min(i + batchSize, NUM_USERS); j++) {
            const user = new SimulatedUser(j);
            users.push(user);
            batch.push(user.connect().catch(err => {
                console.error(`  User ${j} failed: ${err.message}`);
            }));
        }
        await Promise.allSettled(batch);
        console.log(`  Connected: ${metrics.connections.successful}/${metrics.connections.total}`);

        // Small delay between batches
        await new Promise(r => setTimeout(r, 200));
    }

    console.log(`[Phase 1] ${metrics.connections.successful} connected, ${metrics.connections.failed} failed`);

    // Phase 2: Run for duration
    console.log(`\n[Phase 2] Running for ${DURATION_SEC}s...`);

    const progressInterval = setInterval(() => {
        const elapsed = Math.floor((Date.now() - metrics.startTime) / 1000);
        const msgRate = metrics.messages.received / Math.max(elapsed, 1);
        const activeUsers = users.filter(u => u.connected).length;
        process.stdout.write(`\r  ${elapsed}s | Active: ${activeUsers} | Messages: ${metrics.messages.received} | Rate: ${msgRate.toFixed(0)}/s | Data: ${formatBytes(metrics.messages.bytes)}`);
    }, 2000);

    await new Promise(r => setTimeout(r, DURATION_SEC * 1000));
    clearInterval(progressInterval);

    // Phase 3: Disconnect and report
    console.log(`\n\n[Phase 3] Disconnecting users...`);
    users.forEach(u => u.disconnect());

    metrics.endTime = Date.now();
    const durationMs = metrics.endTime - metrics.startTime;

    // Calculate latency percentiles
    if (metrics.latency.samples.length > 0) {
        metrics.latency.p50 = percentile(metrics.latency.samples, 50);
        metrics.latency.p95 = percentile(metrics.latency.samples, 95);
        metrics.latency.p99 = percentile(metrics.latency.samples, 99);
        metrics.latency.avg = metrics.latency.samples.reduce((a, b) => a + b, 0) / metrics.latency.samples.length;
    }

    // Print report
    console.log('\n==============================================================');
    console.log('                     LOAD TEST RESULTS                        ');
    console.log('==============================================================');
    console.log(`  Duration:           ${(durationMs / 1000).toFixed(1)}s`);
    console.log(`  Connections:        ${metrics.connections.successful}/${metrics.connections.total} (${metrics.connections.failed} failed)`);
    console.log(`  Messages received:  ${metrics.messages.received}`);
    console.log(`  Data transferred:   ${formatBytes(metrics.messages.bytes)}`);
    console.log(`  Message rate:       ${(metrics.messages.received / (durationMs / 1000)).toFixed(0)}/s`);
    console.log(`  Per-user rate:      ${(metrics.messages.received / Math.max(metrics.connections.successful, 1) / (durationMs / 1000)).toFixed(1)}/s`);
    console.log('--------------------------------------------------------------');
    console.log(`  Latency p50:        ${metrics.latency.p50.toFixed(0)}ms`);
    console.log(`  Latency p95:        ${metrics.latency.p95.toFixed(0)}ms`);
    console.log(`  Latency p99:        ${metrics.latency.p99.toFixed(0)}ms`);
    console.log(`  Latency avg:        ${metrics.latency.avg.toFixed(0)}ms`);
    console.log('--------------------------------------------------------------');
    console.log(`  Errors:             ${metrics.errors.length}`);
    console.log('==============================================================');

    // Scaling projections
    const perUserBytesPerSec = metrics.messages.bytes / Math.max(metrics.connections.successful, 1) / (durationMs / 1000);
    console.log('\nScaling Projections:');
    console.log(`  1,000 users:  ${formatBytes(perUserBytesPerSec * 1000)}/s  (${formatBytes(perUserBytesPerSec * 1000 * 3600)}/hr)`);
    console.log(`  10,000 users: ${formatBytes(perUserBytesPerSec * 10000)}/s  (${formatBytes(perUserBytesPerSec * 10000 * 3600)}/hr)`);
    console.log(`  50,000 users: ${formatBytes(perUserBytesPerSec * 50000)}/s  (${formatBytes(perUserBytesPerSec * 50000 * 3600)}/hr)`);

    process.exit(0);
}

runTest().catch(err => {
    console.error('Test failed:', err);
    process.exit(1);
});
