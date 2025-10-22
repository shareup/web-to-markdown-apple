# web-to-markdown-apple

Convert web pages to Markdown using WKWebView and SwiftSoup.

## Installation

```bash
bin/install.sh
```

## Usage

```bash
web-to-markdown https://example.com
web-to-markdown https://example.com --timeout 30 --verbose
```

## Library

```swift
import WebToMarkdown

// Fetch HTML from a URL using WKWebView
let html = try await WebPageFetcher.fetchHTML(from: url, timeout: 30)

// Convert HTML to Markdown
let markdown = try HTMLToMarkdown.convert(html, baseURL: url)
```

## Testing

```bash
swift test
```

## Development

- Before commiting your code, always format it using:

```bash
bin/format.sh
```
