import Foundation

/// Renders the standard YAML frontmatter block (`---` … `---`) used by the
/// `web-to-markdown` CLI. The struct holds the raw inputs as Swift types —
/// consumers who want the data without the formatting can just read the
/// stored properties or build their own representation. We emit YAML
/// directly without pulling in a YAML library; the output parses as real
/// YAML on the consumer side.
public struct Frontmatter: Sendable {
    public let page: FetchedPage
    public let metadata: PageMetadata
    public let fetchedAt: Date

    /// Maximum length of the rendered `description` field (longer values are
    /// truncated with an ellipsis). The default keeps frontmatter scannable.
    public var descriptionMaxLength: Int = 200

    public init(
        page: FetchedPage,
        metadata: PageMetadata,
        fetchedAt: Date = Date(),
        descriptionMaxLength: Int = 200
    ) {
        self.page = page
        self.metadata = metadata
        self.fetchedAt = fetchedAt
        self.descriptionMaxLength = descriptionMaxLength
    }

    /// Format as a YAML block: `---` line, one `key: value` per line,
    /// closing `---`. Values containing characters that would confuse a YAML
    /// reader (`:`, `"`, `\\`, `#`, leading/trailing whitespace) are
    /// double-quoted with `\\` and `"` escaped. Newlines in values are
    /// flattened to spaces.
    public func format() -> String {
        var lines = ["---"]
        if let status = page.statusCode {
            lines.append("status: \(status)")
        }
        lines.append("final-url: \(yamlEscape(page.finalURL.absoluteString))")
        if let title = metadata.title, !title.isEmpty {
            lines.append("title: \(yamlEscape(title))")
        }
        if let description = metadata.description, !description.isEmpty {
            lines.append(
                "description: \(yamlEscape(truncate(description, max: descriptionMaxLength)))"
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("fetched-at: \(yamlEscape(formatter.string(from: fetchedAt)))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Public for unit tests and library consumers who want to format their
    /// own values with the same escape rules.
    public static func yamlEscape(_ value: String) -> String {
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

    private func yamlEscape(_ value: String) -> String {
        Self.yamlEscape(value)
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let end = s.index(s.startIndex, offsetBy: max)
        return String(s[s.startIndex ..< end]) + "…"
    }
}
