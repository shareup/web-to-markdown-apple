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

    mutating func run() async throws {
        guard let parsedURL = URL(string: url) else {
            throw ValidationError("Invalid URL: \(url)")
        }

        if verbose {
            fputs("Fetching \(parsedURL.absoluteString)...\n", stderr)
        }

        let page = try await WebPageFetcher.fetch(
            from: parsedURL,
            timeout: timeout,
            extractMainOnly: main
        )

        if !skipFrontmatter {
            let metadata = (try? HTMLToMarkdown.extractMetadata(page.html))
                ?? PageMetadata(title: nil, description: nil)
            print(formatFrontmatter(page: page, metadata: metadata))
            if !head { print("") }
        }

        if head { return }

        if verbose {
            fputs("Converting to markdown...\n", stderr)
        }

        let markdown = try HTMLToMarkdown.convert(page.html, baseURL: parsedURL)
        print(markdown)
    }

    private func formatFrontmatter(page: FetchedPage, metadata: PageMetadata) -> String {
        var lines = ["---"]
        if let status = page.statusCode {
            lines.append("status: \(status)")
        }
        lines.append("final-url: \(yamlEscape(page.finalURL.absoluteString))")
        if let title = metadata.title, !title.isEmpty {
            lines.append("title: \(yamlEscape(title))")
        }
        if let description = metadata.description, !description.isEmpty {
            lines.append("description: \(yamlEscape(truncate(description, max: 200)))")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("fetched-at: \(formatter.string(from: Date()))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Escape a string for use as a fake-YAML frontmatter scalar value.
    /// Quotes the value when it contains characters that would confuse a
    /// downstream YAML reader (`:`, `"`, `\\`, leading/trailing whitespace).
    /// Newlines are flattened to spaces — frontmatter is single-line per key.
    private func yamlEscape(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        let needsQuoting = flattened.contains(":")
            || flattened.contains("\"")
            || flattened.contains("\\")
            || flattened.contains("#")
            || flattened.first == " "
            || flattened.last == " "
            || flattened.isEmpty

        if needsQuoting {
            let escaped = flattened
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return flattened
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let end = s.index(s.startIndex, offsetBy: max)
        return String(s[s.startIndex ..< end]) + "…"
    }
}
