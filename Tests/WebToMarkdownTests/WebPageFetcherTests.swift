import Foundation
import Testing
@testable import WebToMarkdown

@Suite struct WebPageFetcherTests {
    @Test func fetchSimpleHTML() async throws {
        let url = URL(string: "https://example.com")!
        let html = try await WebPageFetcher.fetchHTML(from: url)
        #expect(!html.isEmpty)
        #expect(html.contains("<html") || html.contains("<!DOCTYPE"))
    }

    @Test func fetchHTMLWithTimeout() async throws {
        let url = URL(string: "https://example.com")!
        let html = try await WebPageFetcher.fetchHTML(from: url, timeout: 10)
        #expect(!html.isEmpty)
    }

    @Test func errorOnInvalidURL() async throws {
        let url = URL(string: "https://this-domain-does-not-exist-12345.com")!
        await #expect(throws: WebPageFetcher.Error.self) {
            try await WebPageFetcher.fetchHTML(from: url, timeout: 5)
        }
    }
    
    @Test func canCancelFetch() async throws {
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
