import Foundation
import Testing
@testable import WebToMarkdown

@Suite
struct WebPageFetcherTests {
    @Test
    func fetchSimpleHTML() async throws {
        let url = URL(string: "https://example.com")!
        let html = try await WebPageFetcher.fetchHTML(from: url)
        #expect(!html.isEmpty)
        #expect(html.contains("<html") || html.contains("<!DOCTYPE"))
    }

    @Test
    func fetchHTMLWithTimeout() async throws {
        let url = URL(string: "https://example.com")!
        let html = try await WebPageFetcher.fetchHTML(from: url, timeout: 10)
        #expect(!html.isEmpty)
    }

    @Test
    func errorOnInvalidURL() async throws {
        let url = URL(string: "https://this-domain-does-not-exist-12345.com")!
        await #expect(throws: WebPageFetcher.Error.self) {
            try await WebPageFetcher.fetchHTML(from: url, timeout: 5)
        }
    }

    @Test
    func fetchReturnsStatusAndFinalURL() async throws {
        let url = URL(string: "https://example.com")!
        let page = try await WebPageFetcher.fetch(from: url)
        #expect(page.statusCode == 200)
        #expect(page.finalURL.host == "example.com")
        #expect(!page.html.isEmpty)
    }

    @Test
    func waitForExistingSelectorReturnsImmediately() async throws {
        let url = URL(string: "https://example.com")!
        let timeout: TimeInterval = 10
        let start = Date()
        let page = try await WebPageFetcher.fetch(
            from: url,
            timeout: timeout,
            waitForSelector: "h1"
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(!page.html.isEmpty)
        #expect(
            elapsed < timeout - 1,
            "Selector that already exists should complete well before the configured timeout"
        )
    }

    @Test
    func waitForNonexistentSelectorTimesOut() async throws {
        let url = URL(string: "https://example.com")!
        await #expect(throws: WebPageFetcher.Error.self) {
            try await WebPageFetcher.fetch(
                from: url,
                timeout: 3,
                waitForSelector: ".never-matches-xyz-12345"
            )
        }
    }

    @Test
    func waitForSelectorHandlesAttributeMutation() async throws {
        let url = dataURL(
            """
            <html>
              <body>
                <main id="content">Loading</main>
                <script>
                  setTimeout(function() {
                    document.getElementById("content").setAttribute("data-ready", "true");
                  }, 100);
                </script>
              </body>
            </html>
            """
        )

        let page = try await WebPageFetcher.fetch(
            from: url,
            timeout: 5,
            waitForSelector: "[data-ready='true']"
        )

        #expect(page.html.contains("data-ready=\"true\""))
    }

    @Test
    func fixedWaitDelaysExtraction() async throws {
        let url = URL(string: "https://example.com")!
        let start = Date()
        _ = try await WebPageFetcher.fetch(
            from: url,
            timeout: 10,
            waitSeconds: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(
            elapsed >= 0.9,
            "Fixed wait should add approximately its duration (0.1s tolerance for timer precision)"
        )
    }

    @Test
    func canCancelFetch() async throws {
        let url = URL(string: "https://example.com")!
        let loadTask = Task.detached {
            try await WebPageFetcher.fetchHTML(from: url)
        }

        // NOTE: If you want to test cancellation during different
        //       parts of the fetch HTML operation, just play with
        //       the number of times to yield.
        await yield(1)
        loadTask.cancel()

        switch await loadTask.result {
        case .success:
            Issue.record()
        case let .failure(error):
            #expect(error is CancellationError)
        }
    }
}

private func yield(_ times: Int) async {
    guard times > 0 else { return }
    for _ in 0 ..< times {
        await Task.yield()
    }
}

private func dataURL(_ html: String) -> URL {
    let encoded = Data(html.utf8).base64EncodedString()
    return URL(string: "data:text/html;charset=utf-8;base64,\(encoded)")!
}
