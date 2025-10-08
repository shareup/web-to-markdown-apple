import Foundation
import SwiftSoup

public enum HTMLToMarkdown {
    public enum Error: Swift.Error {
        case parsingFailed(String)
    }

    public static func convert(_ html: String, baseURL: URL? = nil) throws -> String {
        let document = try SwiftSoup.parse(html, baseURL?.absoluteString ?? "")

        guard let body = document.body() else {
            throw Error.parsingFailed("No body element found")
        }

        let markdown = try convertElement(body, baseURL: baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapseExcessiveNewlines(markdown)
    }

    private static func collapseExcessiveNewlines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private static func convertElement(_ element: Element, baseURL: URL?) throws -> String {
        var result = ""

        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                let text = textNode.text()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result += text
                }
            } else if let el = node as? Element {
                result += try convertTag(el, baseURL: baseURL)
            }
        }

        return result
    }

    private static func convertTag(_ element: Element, baseURL: URL?) throws -> String {
        let tag = element.tagName().lowercased()

        switch tag {
        case "script", "style", "nav", "footer", "aside", "iframe", "noscript":
            return ""

        case "h1":
            return "\n\n# \(try element.text())\n\n"
        case "h2":
            return "\n\n## \(try element.text())\n\n"
        case "h3":
            return "\n\n### \(try element.text())\n\n"
        case "h4":
            return "\n\n#### \(try element.text())\n\n"
        case "h5":
            return "\n\n##### \(try element.text())\n\n"
        case "h6":
            return "\n\n###### \(try element.text())\n\n"

        case "p":
            return "\n\n\(try convertElement(element, baseURL: baseURL))\n\n"

        case "br":
            return "\n"

        case "hr":
            return "\n\n---\n\n"

        case "strong", "b":
            return "**\(try convertElement(element, baseURL: baseURL))**"

        case "em", "i":
            return "*\(try convertElement(element, baseURL: baseURL))*"

        case "code":
            if element.parent()?.tagName().lowercased() == "pre" {
                return try element.text()
            }
            return "`\(try element.text())`"

        case "pre":
            return "\n\n```\n\(try convertElement(element, baseURL: baseURL))\n```\n\n"

        case "a":
            let text = try element.text()
            if let href = try? element.attr("href"), !href.isEmpty {
                let absoluteURL = resolveURL(href, baseURL: baseURL)
                return "[\(text)](\(absoluteURL))"
            }
            return text

        case "img":
            if let alt = try? element.attr("alt"), !alt.isEmpty,
               let src = try? element.attr("src"), !src.isEmpty
            {
                let absoluteURL = resolveURL(src, baseURL: baseURL)
                return "![\(alt)](\(absoluteURL))"
            }
            return ""

        case "ul", "ol":
            var listResult = "\n"
            let isOrdered = tag == "ol"
            var counter = 1

            for item in try element.select("li") {
                let prefix = isOrdered ? "\(counter). " : "- "
                let itemText = try convertElement(item, baseURL: baseURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                listResult += "\(prefix)\(itemText)\n"
                counter += 1
            }

            return "\(listResult)\n"

        case "li":
            return try convertElement(element, baseURL: baseURL)

        case "blockquote":
            let lines = try convertElement(element, baseURL: baseURL)
                .components(separatedBy: "\n")
                .map { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? ">" : "> \(trimmed)"
                }
            return "\n\n\(lines.joined(separator: "\n"))\n\n"

        case "table":
            return try convertTable(element, baseURL: baseURL)

        case "div", "section", "article", "main", "span", "header":
            return try convertElement(element, baseURL: baseURL)

        default:
            return try convertElement(element, baseURL: baseURL)
        }
    }

    private static func convertTable(_ table: Element, baseURL: URL?) throws -> String {
        var result = "\n\n"

        let rows = try table.select("tr")
        guard !rows.isEmpty() else { return "" }

        var columnCount = 0
        for row in rows {
            let cells = try row.select("th, td")
            columnCount = max(columnCount, cells.count)
        }

        guard columnCount > 0 else { return "" }

        var isFirstRow = true
        for row in rows {
            let cells = try row.select("th, td")
            var rowCells: [String] = []

            for cell in cells {
                let cellText = try convertElement(cell, baseURL: baseURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                rowCells.append(cellText)
            }

            while rowCells.count < columnCount {
                rowCells.append("")
            }

            result += "| \(rowCells.joined(separator: " | ")) |\n"

            if isFirstRow {
                result += "| " + Array(repeating: "---", count: columnCount)
                    .joined(separator: " | ") + " |\n"
                isFirstRow = false
            }
        }

        return result + "\n"
    }

    private static func resolveURL(_ urlString: String, baseURL: URL?) -> String {
        guard let baseURL else { return urlString }

        if urlString.starts(with: "http://") || urlString.starts(with: "https://") {
            return urlString
        }

        if urlString.starts(with: "//") {
            return "https:\(urlString)"
        }

        if urlString.starts(with: "/") {
            if let scheme = baseURL.scheme, let host = baseURL.host {
                let port = baseURL.port.map { ":\($0)" } ?? ""
                return "\(scheme)://\(host)\(port)\(urlString)"
            }
        }

        if let absoluteURL = URL(string: urlString, relativeTo: baseURL)?.absoluteString {
            return absoluteURL
        }

        return urlString
    }
}
