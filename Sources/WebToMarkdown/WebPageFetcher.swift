import Foundation
import os.log
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

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
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
                    continuation: continuation,
                    timeout: timeout
                )

                webView.navigationDelegate = delegate

                let request = URLRequest(url: url, timeoutInterval: timeout)
                webView.load(request)
            }
        }
    }
}

@MainActor
private class NavigationDelegate: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let continuation: CheckedContinuation<String, Swift.Error>
    var hasCompleted = false
    var timeoutTask: Task<Void, Never>?

    init(
        webView: WKWebView,
        continuation: CheckedContinuation<String, Swift.Error>,
        timeout: TimeInterval
    ) {
        self.webView = webView
        self.continuation = continuation
        super.init()

        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !hasCompleted else { return }
            hasCompleted = true
            os_log(
                .error,
                log: log,
                "🔧TOOLCALL🔧 WebPageFetcher: Timeout after %f seconds",
                timeout
            )
            continuation.resume(throwing: WebPageFetcher.Error.timeout)
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard !hasCompleted else { return }

        os_log(.info, log: log, "🔧TOOLCALL🔧 WebPageFetcher: Page loaded, extracting HTML")

        webView
            .evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                guard let self else { return }

                self.timeoutTask?.cancel()

                guard !self.hasCompleted else { return }
                self.hasCompleted = true

                if let error {
                    os_log(
                        .error,
                        log: log,
                        "🔧TOOLCALL🔧 WebPageFetcher: JavaScript error: %{public}s",
                        error.localizedDescription
                    )
                    self.continuation.resume(throwing: error)
                    return
                }

                guard let html = result as? String else {
                    os_log(.error, log: log, "🔧TOOLCALL🔧 WebPageFetcher: No HTML returned")
                    self.continuation.resume(throwing: WebPageFetcher.Error.noHTML)
                    return
                }

                os_log(
                    .info,
                    log: log,
                    "🔧TOOLCALL🔧 WebPageFetcher: Extracted HTML of length: %d",
                    html.count
                )
                self.continuation.resume(returning: html)
            }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Swift.Error) {
        timeoutTask?.cancel()
        guard !hasCompleted else { return }
        hasCompleted = true

        os_log(
            .error,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Navigation failed: %{public}s",
            error.localizedDescription
        )
        continuation
            .resume(throwing: WebPageFetcher.Error.loadFailed(error.localizedDescription))
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: Swift.Error
    ) {
        timeoutTask?.cancel()
        guard !hasCompleted else { return }
        hasCompleted = true

        os_log(
            .error,
            log: log,
            "🔧TOOLCALL🔧 WebPageFetcher: Provisional navigation failed: %{public}s",
            error.localizedDescription
        )
        continuation
            .resume(throwing: WebPageFetcher.Error.loadFailed(error.localizedDescription))
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
