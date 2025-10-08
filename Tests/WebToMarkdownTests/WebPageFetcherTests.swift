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
}
