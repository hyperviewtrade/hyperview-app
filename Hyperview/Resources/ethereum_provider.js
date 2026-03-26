// ethereum_provider.js — EIP-1193 Ethereum provider injected into WKWebView
// Bridges dapp calls to Swift via WKScriptMessageHandler

(function() {
    'use strict';

    var _callbacks = {};
    var _requestId = 0;
    var _listeners = {};

    var CHAIN_ID = '0xa4b1';       // Arbitrum One (42161)
    var NETWORK_VERSION = '42161';

    var provider = {
        isMetaMask: true,
        isHyperview: true,
        chainId: CHAIN_ID,
        networkVersion: NETWORK_VERSION,
        selectedAddress: null,
        _metamask: { isUnlocked: function() { return Promise.resolve(true); } },

        // ── EIP-1193 primary method ────────────────────────────
        request: function(args) {
            return new Promise(function(resolve, reject) {
                var id = 'req_' + (++_requestId);
                _callbacks[id] = { resolve: resolve, reject: reject };
                try {
                    window.webkit.messageHandlers.ethereum.postMessage({
                        id: id,
                        method: args.method,
                        params: args.params || []
                    });
                } catch(e) {
                    delete _callbacks[id];
                    reject({ code: -32603, message: 'Internal error: ' + e.message });
                }
            });
        },

        // ── Legacy methods (pre-EIP-1193) ──────────────────────
        enable: function() {
            return this.request({ method: 'eth_requestAccounts' });
        },

        send: function(methodOrPayload, paramsOrCallback) {
            // Synchronous-style for simple getters
            if (typeof methodOrPayload === 'string') {
                return this.request({ method: methodOrPayload, params: paramsOrCallback || [] });
            }
            // Callback-style
            if (typeof paramsOrCallback === 'function') {
                this.request({ method: methodOrPayload.method, params: methodOrPayload.params || [] })
                    .then(function(r) { paramsOrCallback(null, { id: methodOrPayload.id, jsonrpc: '2.0', result: r }); })
                    .catch(function(e) { paramsOrCallback(e); });
                return;
            }
            return this.request({ method: methodOrPayload.method, params: methodOrPayload.params || [] });
        },

        sendAsync: function(payload, callback) {
            this.request({ method: payload.method, params: payload.params || [] })
                .then(function(r) { callback(null, { id: payload.id, jsonrpc: '2.0', result: r }); })
                .catch(function(e) { callback(e); });
        },

        // ── EIP-1193 EventEmitter ──────────────────────────────
        on: function(event, handler) {
            if (!_listeners[event]) _listeners[event] = [];
            _listeners[event].push(handler);
            return this;
        },

        removeListener: function(event, handler) {
            var arr = _listeners[event];
            if (!arr) return this;
            _listeners[event] = arr.filter(function(h) { return h !== handler; });
            return this;
        },

        emit: function(event) {
            var args = Array.prototype.slice.call(arguments, 1);
            var arr = _listeners[event];
            if (!arr) return;
            arr.forEach(function(h) {
                try { h.apply(null, args); } catch(e) {}
            });
        }
    };

    // ── Response handler (called from Swift) ───────────────────
    window._hyperviewResponse = function(id, result, error) {
        var cb = _callbacks[id];
        if (!cb) return;
        delete _callbacks[id];
        if (error) {
            cb.reject({ code: error.code || 4001, message: error.message || 'Unknown error' });
        } else {
            // Track connected address
            if (Array.isArray(result) && result.length > 0
                && typeof result[0] === 'string' && result[0].startsWith('0x')
                && result[0].length === 42) {
                provider.selectedAddress = result[0];
                provider.emit('accountsChanged', result);
            }
            cb.resolve(result);
        }
    };

    // ── Install as window.ethereum (non-writable) ──────────────
    Object.defineProperty(window, 'ethereum', {
        value: provider,
        writable: false,
        configurable: false
    });

    // ── EIP-6963 provider announcement ─────────────────────────
    var info = Object.freeze({
        uuid: 'hyperview-wallet',
        name: 'Hyperview',
        icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="%2300C278"/><text x="16" y="22" text-anchor="middle" font-size="18" fill="white">H</text></svg>',
        rdns: 'com.hyperview.wallet'
    });

    function announce() {
        window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
            detail: Object.freeze({ info: info, provider: provider })
        }));
    }
    announce();
    window.addEventListener('eip6963:requestProvider', announce);
})();
