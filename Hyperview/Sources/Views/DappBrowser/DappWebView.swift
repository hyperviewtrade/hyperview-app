import SwiftUI
import WebKit

struct DappWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var provider: EthereumProvider

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Inject ethereum provider JS at document start
        if let jsPath = Bundle.main.path(forResource: "ethereum_provider", ofType: "js"),
           let js = try? String(contentsOfFile: jsPath, encoding: .utf8) {
            #if DEBUG
            print("[DappWebView] JS provider loaded (\(js.count) chars)")
            #endif
            let script = WKUserScript(source: js, injectionTime: .atDocumentStart,
                                      forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
        } else {
            #if DEBUG
            print("[DappWebView] WARNING: ethereum_provider.js NOT FOUND in bundle")
            #endif
        }

        // Inject console capture for debugging
        let consoleCapture = WKUserScript(
            source: """
            (function() {
                var orig = console.log;
                var origErr = console.error;
                var origWarn = console.warn;
                console.log = function() {
                    orig.apply(console, arguments);
                    try { window.webkit.messageHandlers.consoleLog.postMessage(
                        Array.from(arguments).map(String).join(' ')
                    ); } catch(e) {}
                };
                console.error = function() {
                    origErr.apply(console, arguments);
                    try { window.webkit.messageHandlers.consoleLog.postMessage(
                        'ERROR: ' + Array.from(arguments).map(String).join(' ')
                    ); } catch(e) {}
                };
                console.warn = function() {
                    origWarn.apply(console, arguments);
                    try { window.webkit.messageHandlers.consoleLog.postMessage(
                        'WARN: ' + Array.from(arguments).map(String).join(' ')
                    ); } catch(e) {}
                };
                window.addEventListener('error', function(e) {
                    try { window.webkit.messageHandlers.consoleLog.postMessage(
                        'UNCAUGHT: ' + e.message + ' at ' + e.filename + ':' + e.lineno
                    ); } catch(ex) {}
                });
                window.addEventListener('unhandledrejection', function(e) {
                    try { window.webkit.messageHandlers.consoleLog.postMessage(
                        'UNHANDLED_REJECTION: ' + (e.reason ? (e.reason.message || String(e.reason)) : 'unknown')
                    ); } catch(ex) {}
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(consoleCapture)

        // Register message handlers
        config.userContentController.add(
            WeakScriptMessageHandler(delegate: provider),
            name: EthereumProvider.handlerName
        )
        config.userContentController.add(
            context.coordinator,
            name: "consoleLog"
        )

        // WebAuthn / passkeys support
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        webView.allowsBackForwardNavigationGestures = true

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        provider.webView = webView
        #if DEBUG
        print("[DappWebView] Loading URL: \(url)")
        #endif
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        // MARK: - Console log capture
        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            #if DEBUG
            if let text = message.body as? String {
                print("[WebView] \(text)")
            }
            #endif
        }

        // MARK: - Navigation
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            #if DEBUG
            if let url = action.request.url {
                print("[DappWebView Nav] \(action.navigationType.rawValue) → \(url)")
            }
            #endif
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            print("[DappWebView] Page loaded: \(webView.url?.absoluteString ?? "nil")")
            #endif
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            print("[DappWebView] Navigation FAILED: \(error.localizedDescription)")
            #endif
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            print("[DappWebView] Provisional navigation FAILED: \(error.localizedDescription)")
            #endif
        }

        // MARK: - UI Delegate (alerts, confirm, prompt, popups)
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            #if DEBUG
            print("[WebView Alert] \(message)")
            #endif
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            #if DEBUG
            print("[WebView Confirm] \(message)")
            #endif
            // Show a native alert instead of auto-approving
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first?.rootViewController else {
                completionHandler(false)
                return
            }
            // Walk to the topmost presented VC
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            topVC.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            #if DEBUG
            print("[WebView Prompt] \(prompt)")
            #endif
            completionHandler(defaultText)
        }

        // Handle window.open() — return same webView to keep navigation in-app
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Load popup URLs in the same webView
            if let url = action.request.url {
                #if DEBUG
                print("[WebView Popup] \(url)")
                #endif
                webView.load(action.request)
            }
            return nil
        }
    }
}
