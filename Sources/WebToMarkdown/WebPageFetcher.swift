import Foundation
import os.log
import Synchronized
import WebKit


private let log = OSLog(subsystem: "com.shareup.web-to-markdown", category: "web-page-fetcher")

public enum WebPageFetcher {
    public enum Error: Swift.Error {
        case loadFailed(String)
        case timeout
        case noHTML
    }

    public static func fetchHTML(from url: URL, timeout: TimeInterval = 30) async throws -> String {
        os_log(
            .info,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Loading URL: %{public}s",
            url.absoluteString
        )

        let state = Locked(State.initial)
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await withTaskCancellationHandler(
                    operation: { @MainActor () -> Void in
                        let config = WKWebViewConfiguration()
                        config.defaultWebpagePreferences.preferredContentMode = .mobile
                        
                        let webView = WKWebView(frame: .zero, configuration: config)
                        state.access { $0.start(with: webView, continuation: continuation) }
                        
                        let cssScript = WKUserScript(
                            source: """
                            var style = document.createElement('style');
                            style.textContent = 'img, video, iframe, svg { display: none !important; }';
                            document.head.appendChild(style);
                            """,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true
                        )
                        webView.configuration.userContentController.addUserScript(cssScript)
                        
                        let delegate = NavigationDelegate(
                            webView: webView,
                            state: state,
                            timeout: timeout
                        )
                        
                        webView.navigationDelegate = delegate
                        
                        let request = URLRequest(url: url, timeoutInterval: timeout)
                        webView.load(request)
                    },
                    onCancel: {
                        state.access { $0.cancel() }
                    },
                    isolation: MainActor.shared
                )
            }
        }
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let state: Locked<State>
    var timeoutTask: Task<Void, Never>?

    init(
        webView: WKWebView,
        state: Locked<State>,
        timeout: TimeInterval
    ) {
        self.webView = webView
        self.state = state
        super.init()

        timeoutTask = Task {
            MainActor.assertIsolated()
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled,
                  state.access({ $0.fail(with: WebPageFetcher.Error.timeout) })
            else { return }
            os_log(
                .error,
                log: log,
                "🔧TOOLCALL🔧 WebPageFetcher: Timeout after %f seconds",
                timeout
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard state.access({ $0.shouldLoadJavaScript }) else {
            return
        }
        
        os_log(.info, log: log, "🔧TOOLCALL🔧 WebPageFetcher: Page loaded, extracting HTML")

        webView
            .evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                guard let self else { return }

                timeoutTask?.cancel()

                if let error, state.access({ $0.fail(with: error) }) {
                    os_log(
                        .error,
                        log: log,
                        "🔧TOOLCALL🔧 WebPageFetcher: JavaScript error: %{public}s",
                        error.localizedDescription
                    )
                    return
                }

                guard let html = result as? String,
                      state.access({ $0.finish(with: html) })
                else {
                    if state.access({ $0.fail(with: WebPageFetcher.Error.noHTML) }) {
                        os_log(
                            .error,
                            log: log,
                            "🔧TOOLCALL🔧 WebPageFetcher: No HTML returned"
                        )
                    }
                    return
                }

                os_log(
                    .info,
                    log: log,
                    "🔧TOOLCALL🔧 WebPageFetcher: Extracted HTML of length: %d",
                    html.count
                )
            }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Swift.Error) {
        timeoutTask?.cancel()
        let error = WebPageFetcher.Error.loadFailed(error.localizedDescription)
        guard state.access({ $0.fail(with: error) }) else {
            return
        }

        os_log(
            .error,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Navigation failed: %{public}s",
            error.localizedDescription
        )
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Swift.Error
    ) {
        timeoutTask?.cancel()
        let error = WebPageFetcher.Error.loadFailed(error.localizedDescription)
        guard state.access({ $0.fail(with: error) }) else {
            return
        }

        os_log(
            .error,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Provisional navigation failed: %{public}s",
            error.localizedDescription
        )
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async
        -> WKNavigationActionPolicy
    {
        if let url = navigationAction.request.url {
            os_log(
                .info,
                log: log,
                "🔧TOOLCALL🔧 WebPageFetcher: Navigating to: %{public}s",
                url.absoluteString
            )
        }
        return .allow
    }
}

private typealias FetchContinuation = CheckedContinuation<String, Swift.Error>
private enum State: Sendable {
    case initial
    case inProgress(WKWebView, FetchContinuation)
    case terminal
    
    mutating func start(
        with webView: WKWebView,
        continuation: FetchContinuation
    ) {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            self = .inProgress(webView, continuation)
            
        case .inProgress:
            assertionFailure()
            break
            
        case .terminal:
            assertionFailure()
            break
        }
    }
    
    mutating func cancel() {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            self = .terminal
            
        case let .inProgress(webView, continuation):
            continuation.resume(throwing: CancellationError())
            MainActor.assumeIsolated {
                webView.stopLoading()
            }
            self = .terminal
            
        case .terminal:
            break
        }
    }
    
    mutating func finish(with html: String) -> Bool {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            assertionFailure()
            self = .terminal
            return false
            
        case let .inProgress(_, continuation):
            continuation.resume(returning: html)
            self = .terminal
            return true
            
        case .terminal:
            return false
        }
    }
    
    mutating func fail(with error: Swift.Error) -> Bool {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            self = .terminal
            return true
            
        case let .inProgress(webView, continuation):
            continuation.resume(throwing: error)
            MainActor.assumeIsolated {
                webView.stopLoading()
            }
            return true
            
        case .terminal:
            return false
        }
    }
    
    var shouldLoadJavaScript: Bool {
        MainActor.assertIsolated()
        switch self {
        case .initial, .terminal:
            return false
        case .inProgress:
            return true
        }
    }
}
