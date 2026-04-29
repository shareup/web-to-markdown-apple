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

/// All optional knobs a caller can tweak when fetching a page. Use the
/// default-initialized value for the simple case, then mutate the fields you
/// care about, or pass them at the init site.
public struct FetchOptions: Sendable {
    /// Overall fetch timeout, seconds. The fetch fails if everything
    /// (loading + waits + extraction) doesn't complete by this deadline.
    public var timeout: TimeInterval = 30

    /// Strip page chrome (nav/header/footer/cookie/sidebar/recommended)
    /// before HTML extraction.
    public var extractMainOnly: Bool = false

    /// Fixed delay (seconds) after the page finishes loading, before HTML is
    /// extracted. Useful for SPAs that hydrate after `window.load`.
    public var waitSeconds: TimeInterval = 0

    /// CSS selector to wait for. Extraction is delayed until at least one
    /// element matches. Event-driven via `MutationObserver`. Bounded by
    /// `timeout`.
    public var waitForSelector: String?

    /// Substring to wait for in the body's visible text. Extraction is
    /// delayed until found. Event-driven via `MutationObserver`. Bounded by
    /// `timeout`.
    public var waitForText: String?

    public init(
        timeout: TimeInterval = 30,
        extractMainOnly: Bool = false,
        waitSeconds: TimeInterval = 0,
        waitForSelector: String? = nil,
        waitForText: String? = nil
    ) {
        self.timeout = timeout
        self.extractMainOnly = extractMainOnly
        self.waitSeconds = waitSeconds
        self.waitForSelector = waitForSelector
        self.waitForText = waitForText
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
    /// See ``FetchOptions`` for the available knobs.
    public static func fetch(
        from url: URL,
        options: FetchOptions = FetchOptions()
    ) async throws -> FetchedPage {
        try await fetch(
            from: url,
            timeout: options.timeout,
            extractMainOnly: options.extractMainOnly,
            waitSeconds: options.waitSeconds,
            waitForSelector: options.waitForSelector,
            waitForText: options.waitForText
        )
    }

    /// Fetch a web page using individual parameters. Equivalent to passing a
    /// ``FetchOptions`` value; this overload keeps existing call sites
    /// working without adapter code.
    public static func fetch(
        from url: URL,
        timeout: TimeInterval = 30,
        extractMainOnly: Bool = false,
        waitSeconds: TimeInterval = 0,
        waitForSelector: String? = nil,
        waitForText: String? = nil
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
                            extractMainOnly: extractMainOnly,
                            waitSeconds: waitSeconds,
                            waitForSelector: waitForSelector,
                            waitForText: waitForText
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

/// Async JS run via `callAsyncJavaScript` after the page reports `didFinish`.
/// Optionally waits a fixed number of seconds, then for a selector to appear,
/// then for body text to contain a substring (event-driven via
/// `MutationObserver` — no polling). Optionally strips common chrome from the
/// DOM. Always returns `document.documentElement.outerHTML`.
///
/// All `waitFor*` operations are bounded by the outer Swift-side `timeout`,
/// which fails the fetch if the JS never resolves.
private let extractJS: String = #"""
if (typeof waitSeconds === "number" && waitSeconds > 0) {
  await new Promise(function(r) { setTimeout(r, waitSeconds * 1000); });
}

if (typeof waitForSelector === "string" && waitForSelector.length > 0) {
  await new Promise(function(resolve) {
    function check() {
      try { return document.querySelector(waitForSelector); }
      catch (e) { return null; }
    }
    if (check()) { resolve(); return; }
    var obs = new MutationObserver(function() {
      if (check()) { obs.disconnect(); resolve(); }
    });
    obs.observe(document.documentElement, { childList: true, subtree: true });
  });
}

if (typeof waitForText === "string" && waitForText.length > 0) {
  await new Promise(function(resolve) {
    function hasText() {
      var body = document.body;
      if (!body) return false;
      var t = body.innerText || body.textContent || "";
      return t.indexOf(waitForText) !== -1;
    }
    if (hasText()) { resolve(); return; }
    var target = document.body || document.documentElement;
    var obs = new MutationObserver(function() {
      if (hasText()) { obs.disconnect(); resolve(); }
    });
    obs.observe(target, { childList: true, subtree: true, characterData: true });
  });
}

if (extractMainOnly) {
  var selectors = [
    "nav", "header", "footer", "aside",
    '[role="banner"]', '[role="contentinfo"]', '[role="navigation"]',
    '[role="complementary"]',
    '[id*="cookie" i]', '[class*="cookie" i]',
    '[id*="consent" i]', '[class*="consent" i]',
    '[id*="newsletter" i]', '[class*="newsletter" i]',
    '[id*="subscribe" i]', '[class*="subscribe" i]',
    '[class*="related" i]', '[class*="recommend" i]',
    '[class*="sidebar" i]', '[id*="sidebar" i]',
    '[id*="banner" i]', '[class*="promo" i]',
    "noscript", "script[src]", "style"
  ];
  selectors.forEach(function(sel) {
    try {
      document.querySelectorAll(sel).forEach(function(el) { el.remove(); });
    } catch (e) {}
  });
}

return document.documentElement.outerHTML;
"""#

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let state: Locked<State>
    let extractMainOnly: Bool
    let waitSeconds: TimeInterval
    let waitForSelector: String?
    let waitForText: String?
    var timeoutTask: Task<Void, Never>?
    var capturedStatusCode: Int?

    init(
        webView: WKWebView,
        state: Locked<State>,
        timeout: TimeInterval,
        extractMainOnly: Bool,
        waitSeconds: TimeInterval,
        waitForSelector: String?,
        waitForText: String?
    ) {
        self.webView = webView
        self.state = state
        self.extractMainOnly = extractMainOnly
        self.waitSeconds = waitSeconds
        self.waitForSelector = waitForSelector
        self.waitForText = waitForText
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

        let finalURL = webView.url
        let status = capturedStatusCode

        let arguments: [String: Any] = [
            "waitSeconds": waitSeconds,
            "waitForSelector": waitForSelector ?? NSNull(),
            "waitForText": waitForText ?? NSNull(),
            "extractMainOnly": extractMainOnly,
        ]

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await webView.callAsyncJavaScript(
                    extractJS,
                    arguments: arguments,
                    contentWorld: .page
                )

                timeoutTask?.cancel()

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
            } catch {
                if state.access({ $0.fail(with: error) }) {
                    os_log(
                        .error,
                        log: log,
                        "🔧TOOLCALL🔧 WebPageFetcher: JavaScript error: %{public}s",
                        error.localizedDescription
                    )
                }
            }
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
