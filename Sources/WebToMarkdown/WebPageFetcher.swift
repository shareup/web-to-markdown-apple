import Foundation
import os.log
import Synchronized
import WebKit

private let log = OSLog(subsystem: "com.shareup.web-to-markdown", category: "web-page-fetcher")

public struct FetchedPage: Sendable {
    public let html: String
    public let statusCode: Int?
    public let finalURL: URL

    public init(html: String, statusCode: Int?, finalURL: URL) {
        self.html = html
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public enum WebPageFetcher {
    public enum Error: Swift.Error {
        case loadFailed(String)
        case timeout
        case noHTML
    }

    /// Fetch a web page and return HTML plus response metadata.
    ///
    /// - Parameter extractMainOnly: when `true`, common page chrome (nav,
    ///   header, footer, cookies, sidebars, related/recommended sections) is
    ///   stripped from the DOM before the HTML is returned. Cuts noise on
    ///   listing/article pages dramatically.
    public static func fetch(
        from url: URL,
        timeout: TimeInterval = 30,
        extractMainOnly: Bool = false
    ) async throws -> FetchedPage {
        os_log(
            .info,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Loading URL: %{public}s",
            url.absoluteString
        )

        let state = Locked(State.initial)

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation(
                    isolation: MainActor.shared
                ) { continuation in
                    MainActor.assertIsolated()
                    MainActor.assumeIsolated {
                        guard state.access({ $0.prepare(with: continuation) }) else {
                            return
                        }

                        let config = WKWebViewConfiguration()
                        config.defaultWebpagePreferences.preferredContentMode = .mobile

                        let webView = WKWebView(frame: .zero, configuration: config)

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
                            timeout: timeout,
                            extractMainOnly: extractMainOnly
                        )

                        state.access { state in
                            state.start(
                                with: webView,
                                delegate: delegate
                            )
                        }

                        webView.navigationDelegate = delegate

                        guard !Task.isCancelled else {
                            state.access { $0.cancel() }
                            return
                        }

                        let request = URLRequest(url: url, timeoutInterval: timeout)
                        webView.load(request)
                    }
                }
            },
            onCancel: {
                Task { @MainActor in
                    state.access { $0.cancel() }
                }
            },
            isolation: MainActor.shared
        )
    }

    /// Backwards-compatible wrapper returning just HTML.
    public static func fetchHTML(
        from url: URL,
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await fetch(from: url, timeout: timeout).html
    }
}

/// JS that removes common chrome from a loaded page (nav, header, footer,
/// cookie banners, recommendations, sidebars, etc.) and then returns the
/// stripped outerHTML. Used by `extractMainOnly`.
private let stripChromeAndExtractJS: String = """
(function() {
  var selectors = [
    'nav', 'header', 'footer', 'aside',
    '[role="banner"]', '[role="contentinfo"]', '[role="navigation"]',
    '[role="complementary"]',
    '[id*="cookie" i]', '[class*="cookie" i]',
    '[id*="consent" i]', '[class*="consent" i]',
    '[id*="newsletter" i]', '[class*="newsletter" i]',
    '[id*="subscribe" i]', '[class*="subscribe" i]',
    '[class*="related" i]', '[class*="recommend" i]',
    '[class*="sidebar" i]', '[id*="sidebar" i]',
    '[id*="banner" i]', '[class*="promo" i]',
    'noscript', 'script[src]', 'style'
  ];
  selectors.forEach(function(sel) {
    try {
      document.querySelectorAll(sel).forEach(function(el) { el.remove(); });
    } catch (e) {}
  });
  return document.documentElement.outerHTML;
})()
"""

private let extractJS = "document.documentElement.outerHTML"

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let state: Locked<State>
    let extractMainOnly: Bool
    var timeoutTask: Task<Void, Never>?
    var capturedStatusCode: Int?

    init(
        webView: WKWebView,
        state: Locked<State>,
        timeout: TimeInterval,
        extractMainOnly: Bool
    ) {
        self.webView = webView
        self.state = state
        self.extractMainOnly = extractMainOnly
        super.init()

        timeoutTask = Task { @MainActor in
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

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            capturedStatusCode = httpResponse.statusCode
            os_log(
                .info,
                log: log,
                "🔧TOOLCALL🔧 WebPageFetcher: Response status: %d",
                httpResponse.statusCode
            )
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard state.access({ $0.shouldLoadJavaScript }) else {
            return
        }

        os_log(.info, log: log, "🔧TOOLCALL🔧 WebPageFetcher: Page loaded, extracting HTML")

        let js = extractMainOnly ? stripChromeAndExtractJS : extractJS
        let finalURL = webView.url
        let status = capturedStatusCode

        webView.evaluateJavaScript(js) { [weak self] result, error in
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

            guard let html = result as? String else {
                if state.access({ $0.fail(with: WebPageFetcher.Error.noHTML) }) {
                    os_log(
                        .error,
                        log: log,
                        "🔧TOOLCALL🔧 WebPageFetcher: No HTML returned"
                    )
                }
                return
            }

            let resolved = finalURL ?? webView.url ?? URL(string: "about:blank")!
            let page = FetchedPage(html: html, statusCode: status, finalURL: resolved)

            _ = state.access { $0.finish(with: page) }

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

private typealias FetchContinuation = CheckedContinuation<FetchedPage, Swift.Error>
private enum State: Sendable {
    case initial
    case inProgress(WKWebView, NavigationDelegate, FetchContinuation)
    case terminal
    case waitingForWebView(FetchContinuation)

    mutating func prepare(
        with continuation: FetchContinuation
    ) -> Bool {
        guard !Task.isCancelled else {
            self = .terminal
            continuation.resume(throwing: CancellationError())
            return false
        }

        switch self {
        case .initial:
            self = .waitingForWebView(continuation)
            return true

        case .inProgress, .waitingForWebView:
            assertionFailure()
            continuation.resume(throwing: CancellationError())
            return false

        case .terminal:
            continuation.resume(throwing: CancellationError())
            return false
        }
    }

    mutating func start(
        with webView: WKWebView,
        delegate: NavigationDelegate
    ) {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            assertionFailure()
            self = .terminal

        case .inProgress:
            assertionFailure()

        case .terminal:
            break

        case let .waitingForWebView(continuation):
            self = .inProgress(webView, delegate, continuation)
        }
    }

    @MainActor
    mutating func cancel() {
        switch self {
        case .initial:
            self = .terminal

        case let .inProgress(webView, _, continuation):
            self = .terminal
            continuation.resume(throwing: CancellationError())
            webView.stopLoading()

        case .terminal:
            break

        case let .waitingForWebView(continuation):
            self = .terminal
            continuation.resume(throwing: CancellationError())
        }
    }

    mutating func finish(with page: FetchedPage) -> Bool {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            assertionFailure()
            self = .terminal
            return false

        case let .inProgress(_, _, continuation):
            self = .terminal
            continuation.resume(returning: page)
            return true

        case .terminal:
            return false

        case let .waitingForWebView(continuation):
            assertionFailure()
            self = .terminal
            continuation.resume(returning: page)
            return true
        }
    }

    @MainActor
    mutating func fail(with error: Swift.Error) -> Bool {
        switch self {
        case .initial:
            self = .terminal
            return true

        case let .inProgress(webView, _, continuation):
            self = .terminal
            continuation.resume(throwing: error)
            webView.stopLoading()
            return true

        case .terminal:
            return false

        case let .waitingForWebView(continuation):
            self = .terminal
            continuation.resume(throwing: error)
            return true
        }
    }

    @MainActor
    var shouldLoadJavaScript: Bool {
        switch self {
        case .initial, .terminal:
            return false

        case .waitingForWebView:
            assertionFailure()
            return true

        case .inProgress:
            return true
        }
    }
}
