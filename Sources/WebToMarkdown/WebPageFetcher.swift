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
                            timeout: timeout
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
                // NOTE: Even though `isolation: MainActor.shared` is specified
                //       below, neither `operation` nor `onCancel` are called
                //       on `MainActor` if they weren't already running on
                //       `MainActor`.
                //
                //       I'm no Swift Foundation engineer, but it doesn't seem
                //       like `isolation` is used anywhere in the current version
                //       of `withTaskCancellationHandler()`:
                //
                //       ```
                //       public func withTaskCancellationHandler<T>(
                //         operation: () async throws -> T,
                //         onCancel handler: @Sendable () -> Void,
                //         isolation: isolated (any Actor)? = #isolation
                //       ) async rethrows -> T {
                //         // unconditionally add the cancellation record to the task.
                //         // if the task was already cancelled, it will be executed right away.
                //         let record = unsafe _taskAddCancellationHandler(handler: handler)
                //         defer { unsafe _taskRemoveCancellationHandler(record: record) }
                //
                //
                //         return try await operation()
                //       }
                //       ```
                //
                //       https://github.com/swiftlang/swift/blob/5d480ef063859a0f459f4149df536db4fb330a50/stdlib/public/Concurrency/TaskCancellation.swift#L73-L84
                Task { @MainActor in
                    state.access { $0.cancel() }
                }
            },
            isolation: MainActor.shared
        )
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
            break
            
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
    
    mutating func finish(with html: String) -> Bool {
        MainActor.assertIsolated()
        switch self {
        case .initial:
            assertionFailure()
            self = .terminal
            return false
            
        case let .inProgress(_, _, continuation):
            self = .terminal
            continuation.resume(returning: html)
            return true
            
        case .terminal:
            return false
            
        case let .waitingForWebView(continuation):
            assertionFailure()
            self = .terminal
            continuation.resume(returning: html)
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
