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

    @Flag(
        name: .long,
        help: "Strip page chrome (nav, header, footer, cookies, sidebars) before conversion"
    )
    var main: Bool = false

    @Flag(
        name: .long,
        help: "Output only the frontmatter block (status, final-url, title, description, fetched-at) — skip the body"
    )
    var head: Bool = false

    @Flag(
        name: .long,
        help: "Suppress the frontmatter block (output the body markdown only)"
    )
    var skipFrontmatter: Bool = false

    @Option(
        name: .long,
        help: "Wait this many seconds (decimal allowed) after the page loads, before extracting. Bounded by --timeout."
    )
    var wait: Double = 0

    @Option(
        name: .long,
        help: "Wait until at least one element matches this CSS selector before extracting. MutationObserver-driven, bounded by --timeout."
    )
    var waitFor: String?

    @Option(
        name: .long,
        help: "Wait until the body's visible text contains this substring before extracting. MutationObserver-driven, bounded by --timeout."
    )
    var waitForText: String?

    mutating func run() async throws {
        guard let parsedURL = URL(string: url) else {
            throw ValidationError("Invalid URL: \(url)")
        }

        if verbose {
            fputs("Fetching \(parsedURL.absoluteString)...\n", stderr)
        }

        let options = FetchOptions(
            timeout: timeout,
            extractMainOnly: main,
            waitSeconds: wait,
            waitForSelector: waitFor,
            waitForText: waitForText,
            verbose: verbose
        )

        let page = try await WebPageFetcher.fetch(from: parsedURL, options: options)

        if !skipFrontmatter {
            let metadata = (try? HTMLToMarkdown.extractMetadata(page.html))
                ?? PageMetadata(title: nil, description: nil)
            print(Frontmatter(page: page, metadata: metadata).format())
            if !head { print("") }
        }

        if head { return }

        if verbose {
            fputs("Converting to markdown...\n", stderr)
        }

        let markdown = try HTMLToMarkdown.convert(page.html, baseURL: parsedURL)
        print(markdown)
    }
}
