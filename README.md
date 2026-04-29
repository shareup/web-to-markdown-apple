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

By default the output is a YAML frontmatter block followed by the body
markdown:

```
---
status: 200
final-url: https://example.com/
title: Example Domain
fetched-at: 2026-04-29T21:42:56Z
---

# Example Domain
…
```

### Flags

- `--main` — strip page chrome (nav, header, footer, cookies, sidebars,
  recommendations) before conversion. Useful for noisy product/listing pages.
- `--head` — print only the frontmatter block, skip the body. Fast URL
  validation in batch.
- `--skip-frontmatter` — output the body markdown only.
- `--wait <seconds>` — fixed delay (decimal allowed) after the page loads.
  Useful for SPAs that hydrate after `window.load`.
- `--wait-for <css-selector>` — wait until at least one element matches.
  Event-driven via `MutationObserver`, no polling. Bounded by `--timeout`.
- `--wait-for-text <substring>` — wait until the body's visible text contains
  the substring. Same `MutationObserver` pattern.
- `--timeout <seconds>` — overall fetch timeout (default 30s). Bounds all
  wait flags.

### Example: YouTube watch pages

YouTube hydrates async after `window.load`, so a plain fetch grabs the app
shell with `title: YouTube`. Wait for the subscribe button to render — it
appears only after page content is real:

```bash
web-to-markdown 'https://www.youtube.com/watch?v=...' \
  --wait-for '#subscribe-button' --timeout 20
```

Same idea works for other JS-heavy sites: find a selector or piece of body
text that only appears after meaningful hydration, and use it as the anchor.

## Library

```swift
import WebToMarkdown

// Fetch a page (defaults to a 30s timeout, no waits, no chrome stripping).
let page = try await WebPageFetcher.fetch(from: url)

// Same fetch with all knobs available, via FetchOptions.
var options = FetchOptions()
options.extractMainOnly = true
options.waitSeconds = 0.5
options.waitForSelector = "#subscribe-button"
options.timeout = 20
let richPage = try await WebPageFetcher.fetch(from: url, options: options)

// page.html, page.statusCode, page.finalURL — all on FetchedPage.
print(page.statusCode ?? -1, page.finalURL)

// Convert HTML to Markdown.
let markdown = try HTMLToMarkdown.convert(page.html, baseURL: page.finalURL)

// Extract <title> and meta description as Swift values.
let metadata = try HTMLToMarkdown.extractMetadata(page.html)
print(metadata.title ?? "", metadata.description ?? "")

// Build the same YAML frontmatter the CLI emits.
let frontmatter = Frontmatter(page: page, metadata: metadata).format()
print(frontmatter)

// Backwards-compatible HTML-only fetch.
let html = try await WebPageFetcher.fetchHTML(from: url, timeout: 30)
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
