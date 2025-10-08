import ArgumentParser
import Foundation
import WebToMarkdown

@main
struct WebToMarkdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "web-to-markdown",
        abstract: "Fetch a web page and convert it to Markdown"
    )

    @Argument(help: "The URL to fetch and convert")
    var url: String

    @Option(name: .shortAndLong, help: "Timeout in seconds (default: 30)")
    var timeout: Double = 30

    @Flag(name: .shortAndLong, help: "Output verbose logging")
    var verbose: Bool = false

    mutating func run() async throws {
        guard let url = URL(string: url) else {
            throw ValidationError("Invalid URL: \(url)")
        }

        if verbose {
            fputs("Fetching \(url.absoluteString)...\n", stderr)
        }

        let html = try await WebPageFetcher.fetchHTML(from: url, timeout: timeout)

        if verbose {
            fputs("Converting to markdown...\n", stderr)
        }

        let markdown = try HTMLToMarkdown.convert(html, baseURL: url)

        print(markdown)
    }
}
