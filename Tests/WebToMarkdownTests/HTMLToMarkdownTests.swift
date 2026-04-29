import Foundation
import Testing
@testable import WebToMarkdown

@Suite
struct FrontmatterTests {
    private func makePage(
        url: String = "https://example.com/",
        status: Int? = 200,
        html: String = "<html></html>"
    ) -> FetchedPage {
        FetchedPage(html: html, statusCode: status, finalURL: URL(string: url)!)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    @Test
    func formatsAllFields() {
        let page = makePage()
        let meta = PageMetadata(title: "Hello", description: "A description.")
        let fm = Frontmatter(page: page, metadata: meta, fetchedAt: fixedDate)
        let out = fm.format()
        #expect(out.hasPrefix("---\n"))
        #expect(out.hasSuffix("\n---"))
        #expect(out.contains("status: 200"))
        // URL contains ':' so it gets quoted.
        #expect(out.contains("final-url: \"https://example.com/\""))
        #expect(out.contains("title: Hello"))
        #expect(out.contains("description: A description."))
        #expect(out.contains("fetched-at: 2023-11-14T22:13:20Z"))
    }

    @Test
    func omitsAbsentMetadata() {
        let page = makePage()
        let meta = PageMetadata(title: nil, description: nil)
        let out = Frontmatter(page: page, metadata: meta, fetchedAt: fixedDate).format()
        #expect(!out.contains("title:"))
        #expect(!out.contains("description:"))
    }

    @Test
    func omitsAbsentStatus() {
        let page = makePage(status: nil)
        let meta = PageMetadata(title: "x", description: nil)
        let out = Frontmatter(page: page, metadata: meta, fetchedAt: fixedDate).format()
        #expect(!out.contains("status:"))
    }

    @Test
    func quotesValuesWithColons() {
        let escaped = Frontmatter.yamlEscape("Foo: Bar")
        #expect(escaped == "\"Foo: Bar\"")
    }

    @Test
    func quotesValuesWithQuotes() {
        let escaped = Frontmatter.yamlEscape("She said \"hi\"")
        #expect(escaped == "\"She said \\\"hi\\\"\"")
    }

    @Test
    func quotesValuesWithBackslash() {
        let escaped = Frontmatter.yamlEscape("path\\to")
        #expect(escaped == "\"path\\\\to\"")
    }

    @Test
    func quotesValuesWithHash() {
        let escaped = Frontmatter.yamlEscape("foo #bar")
        #expect(escaped == "\"foo #bar\"")
    }

    @Test
    func quotesEmptyAndWhitespacePadded() {
        #expect(Frontmatter.yamlEscape("") == "\"\"")
        #expect(Frontmatter.yamlEscape(" leading") == "\" leading\"")
        #expect(Frontmatter.yamlEscape("trailing ") == "\"trailing \"")
    }

    @Test
    func flattensNewlinesInValues() {
        let escaped = Frontmatter.yamlEscape("line one\nline two")
        // No colon/quote/backslash/hash, so no quoting; just a flattened space.
        #expect(escaped == "line one line two")
    }

    @Test
    func leavesPlainValuesAlone() {
        #expect(Frontmatter.yamlEscape("Hello world") == "Hello world")
        #expect(Frontmatter.yamlEscape("plain-value-123") == "plain-value-123")
    }

    @Test
    func truncatesLongDescription() {
        let longDesc = String(repeating: "a", count: 250)
        let page = makePage()
        let meta = PageMetadata(title: nil, description: longDesc)
        let out = Frontmatter(page: page, metadata: meta, fetchedAt: fixedDate).format()
        // Description should be exactly 200 chars + "…" (default max).
        #expect(out.contains("description: " + String(repeating: "a", count: 200) + "…"))
    }
}

@Suite
struct PageMetadataTests {
    @Test
    func extractsTitleFromTitleTag() throws {
        let html = "<html><head><title>My Page</title></head><body>x</body></html>"
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == "My Page")
    }

    @Test
    func fallsBackToOgTitleWhenNoTitleTag() throws {
        let html = """
        <html><head>
        <meta property="og:title" content="OG Title Here">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == "OG Title Here")
    }

    @Test
    func prefersTitleTagOverOgTitle() throws {
        let html = """
        <html><head>
        <title>Real Title</title>
        <meta property="og:title" content="OG Title">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == "Real Title")
    }

    @Test
    func extractsMetaDescription() throws {
        let html = """
        <html><head>
        <meta name="description" content="A nice description.">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.description == "A nice description.")
    }

    @Test
    func fallsBackToOgDescription() throws {
        let html = """
        <html><head>
        <meta property="og:description" content="OG description fallback.">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.description == "OG description fallback.")
    }

    @Test
    func returnsNilWhenMetadataMissing() throws {
        let html = "<html><body>just body</body></html>"
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == nil)
        #expect(meta.description == nil)
    }

    @Test
    func trimsWhitespaceInExtractedValues() throws {
        let html = """
        <html><head>
        <title>   Spaced Title   </title>
        <meta name="description" content="  spaced description  ">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == "Spaced Title")
        #expect(meta.description == "spaced description")
    }

    @Test
    func ignoresEmptyTitleTag() throws {
        let html = """
        <html><head>
        <title></title>
        <meta property="og:title" content="OG Backup">
        </head><body>x</body></html>
        """
        let meta = try HTMLToMarkdown.extractMetadata(html)
        #expect(meta.title == "OG Backup")
    }
}

@Suite
struct HTMLToMarkdownTests {
    @Test
    func convertBasicHTML() throws {
        let html = "<html><body><p>Hello, world!</p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("Hello, world!"))
    }

    @Test
    func convertHeadings() throws {
        let html = """
        <html><body>
        <h1>Title</h1>
        <h2>Subtitle</h2>
        <h3>Section</h3>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# Title"))
        #expect(markdown.contains("## Subtitle"))
        #expect(markdown.contains("### Section"))
    }

    @Test
    func convertAllHeadingLevels() throws {
        let html = """
        <html><body>
        <h1>Level 1</h1>
        <h2>Level 2</h2>
        <h3>Level 3</h3>
        <h4>Level 4</h4>
        <h5>Level 5</h5>
        <h6>Level 6</h6>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# Level 1"))
        #expect(markdown.contains("## Level 2"))
        #expect(markdown.contains("### Level 3"))
        #expect(markdown.contains("#### Level 4"))
        #expect(markdown.contains("##### Level 5"))
        #expect(markdown.contains("###### Level 6"))
    }

    @Test
    func convertBoldAndItalic() throws {
        let html =
            "<html><body><p>This is <strong>bold</strong> and <em>italic</em></p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("**bold**"))
        #expect(markdown.contains("*italic*"))
    }

    @Test
    func convertBoldAlternativeTags() throws {
        let html =
            "<html><body><p><b>Bold with b</b> and <strong>bold with strong</strong></p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("**Bold with b**"))
        #expect(markdown.contains("**bold with strong**"))
    }

    @Test
    func convertItalicAlternativeTags() throws {
        let html =
            "<html><body><p><i>Italic with i</i> and <em>italic with em</em></p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("*Italic with i*"))
        #expect(markdown.contains("*italic with em*"))
    }

    @Test
    func convertNestedBoldAndItalic() throws {
        let html = "<html><body><p><strong><em>Bold and italic</em></strong></p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("***Bold and italic***"))
    }

    @Test
    func convertLinks() throws {
        let html = """
        <html><body><a href="https://example.com">Example</a></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("[Example](https://example.com)"))
    }

    @Test
    func convertRelativeLinks() throws {
        let html = """
        <html><body><a href="/path/to/page">Page</a></body></html>
        """
        let baseURL = URL(string: "https://example.com")
        let markdown = try HTMLToMarkdown.convert(html, baseURL: baseURL)
        #expect(markdown.contains("[Page](https://example.com/path/to/page)"))
    }

    @Test
    func convertRelativeLinksWithPort() throws {
        let html = """
        <html><body><a href="/api/endpoint">API</a></body></html>
        """
        let baseURL = URL(string: "https://example.com:8080")
        let markdown = try HTMLToMarkdown.convert(html, baseURL: baseURL)
        #expect(markdown.contains("[API](https://example.com:8080/api/endpoint)"))
    }

    @Test
    func convertLinkWithoutHref() throws {
        let html = """
        <html><body><a>No href</a></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("No href"))
        #expect(!markdown.contains("["))
    }

    @Test
    func convertImages() throws {
        let html = """
        <html><body><img src="image.jpg" alt="An image"></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("![An image](image.jpg)"))
    }

    @Test
    func convertImageWithRelativeURL() throws {
        let html = """
        <html><body><img src="/images/photo.png" alt="Photo"></body></html>
        """
        let baseURL = URL(string: "https://cdn.example.com")
        let markdown = try HTMLToMarkdown.convert(html, baseURL: baseURL)
        #expect(markdown.contains("![Photo](https://cdn.example.com/images/photo.png)"))
    }

    @Test
    func convertImageWithoutAlt() throws {
        let html = """
        <html><body><img src="image.jpg"></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(!markdown.contains("!"))
    }

    @Test
    func convertUnorderedList() throws {
        let html = """
        <html><body>
        <ul>
        <li>Item 1</li>
        <li>Item 2</li>
        <li>Item 3</li>
        </ul>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("- Item 1"))
        #expect(markdown.contains("- Item 2"))
        #expect(markdown.contains("- Item 3"))
    }

    @Test
    func convertOrderedList() throws {
        let html = """
        <html><body>
        <ol>
        <li>First</li>
        <li>Second</li>
        <li>Third</li>
        </ol>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("1. First"))
        #expect(markdown.contains("2. Second"))
        #expect(markdown.contains("3. Third"))
    }

    @Test
    func convertNestedLists() throws {
        let html = """
        <html><body>
        <ul>
        <li>Parent 1
            <ul>
            <li>Child 1.1</li>
            <li>Child 1.2</li>
            </ul>
        </li>
        <li>Parent 2</li>
        </ul>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("- Parent 1"))
        #expect(markdown.contains("- Child 1.1"))
        #expect(markdown.contains("- Child 1.2"))
        #expect(markdown.contains("- Parent 2"))
    }

    @Test
    func convertMixedLists() throws {
        let html = """
        <html><body>
        <ol>
        <li>Ordered 1
            <ul>
            <li>Unordered nested</li>
            </ul>
        </li>
        <li>Ordered 2</li>
        </ol>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("1. Ordered 1"))
        #expect(markdown.contains("- Unordered nested"))
        #expect(markdown.contains("Ordered 2"))
    }

    @Test
    func convertCodeInline() throws {
        let html = "<html><body><p>Use <code>print()</code> function</p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("`print()`"))
    }

    @Test
    func convertCodeBlock() throws {
        let html = """
        <html><body>
        <pre><code>func hello() {
            print("Hello")
        }</code></pre>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("```"))
        #expect(markdown.contains("func hello()"))
    }

    @Test
    func convertMultipleCodeBlocks() throws {
        let html = """
        <html><body>
        <pre><code>let x = 1</code></pre>
        <p>Some text</p>
        <pre><code>let y = 2</code></pre>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        let codeBlockCount = markdown.components(separatedBy: "```").count - 1
        #expect(codeBlockCount == 4)
    }

    @Test
    func convertBlockquote() throws {
        let html = """
        <html><body><blockquote>This is a quote</blockquote></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("> This is a quote"))
    }

    @Test
    func convertMultilineBlockquote() throws {
        let html = """
        <html><body><blockquote>Line one
        Line two
        Line three</blockquote></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains(">"))
        #expect(markdown.contains("Line one"))
    }

    @Test
    func convertTable() throws {
        let html = """
        <html><body>
        <table>
        <tr><th>Name</th><th>Age</th></tr>
        <tr><td>Alice</td><td>30</td></tr>
        <tr><td>Bob</td><td>25</td></tr>
        </table>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("| Name | Age |"))
        #expect(markdown.contains("| --- | --- |"))
        #expect(markdown.contains("| Alice | 30 |"))
        #expect(markdown.contains("| Bob | 25 |"))
    }

    @Test
    func convertTableWithUnevenColumns() throws {
        let html = """
        <html><body>
        <table>
        <tr><th>A</th><th>B</th><th>C</th></tr>
        <tr><td>1</td><td>2</td></tr>
        <tr><td>3</td><td>4</td><td>5</td></tr>
        </table>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("| A | B | C |"))
        #expect(markdown.contains("| 1 | 2 |  |"))
    }

    @Test
    func convertComplexTable() throws {
        let html = """
        <html><body>
        <table>
        <tr><th>Product</th><th>Price</th><th>Stock</th></tr>
        <tr><td>Widget</td><td>$19.99</td><td>In Stock</td></tr>
        <tr><td>Gadget</td><td>$29.99</td><td>Out of Stock</td></tr>
        <tr><td>Doohickey</td><td>$9.99</td><td>In Stock</td></tr>
        </table>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("| Product | Price | Stock |"))
        #expect(markdown.contains("| Widget | $19.99 | In Stock |"))
        #expect(markdown.contains("| Gadget | $29.99 | Out of Stock |"))
    }

    @Test
    func convertHorizontalRule() throws {
        let html = "<html><body><p>Before</p><hr><p>After</p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("---"))
    }

    @Test
    func convertBreakTag() throws {
        let html = "<html><body><p>Line 1<br>Line 2<br>Line 3</p></body></html>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("Line 1"))
        #expect(markdown.contains("Line 2"))
        #expect(markdown.contains("Line 3"))
    }

    @Test
    func filterScriptAndStyleTags() throws {
        let html = """
        <html>
        <head><style>body { color: red; }</style></head>
        <body>
        <script>alert('test');</script>
        <p>Content</p>
        </body>
        </html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(!markdown.contains("alert"))
        #expect(!markdown.contains("color: red"))
        #expect(markdown.contains("Content"))
    }

    @Test
    func filterNavigationElements() throws {
        let html = """
        <html><body>
        <nav><a href="/home">Home</a></nav>
        <header><h1>Site Title</h1></header>
        <main><p>Main content</p></main>
        <footer>Copyright 2025</footer>
        <aside>Sidebar</aside>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(!markdown.contains("Home"))
        #expect(markdown.contains("Site Title"))
        #expect(markdown.contains("Main content"))
        #expect(!markdown.contains("Copyright"))
        #expect(!markdown.contains("Sidebar"))
    }

    @Test
    func convertProtocolRelativeURL() throws {
        let html = """
        <html><body><a href="//example.com/path">Link</a></body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("[Link](//example.com/path)"))
    }

    @Test
    func convertProtocolRelativeURLWithBaseURL() throws {
        let html = """
        <html><body><a href="//example.com/path">Link</a></body></html>
        """
        let baseURL = URL(string: "http://mysite.test")
        let markdown = try HTMLToMarkdown.convert(html, baseURL: baseURL)
        #expect(markdown.contains("[Link](https://example.com/path)"))
    }

    @Test
    func convertNestedElements() throws {
        let html = """
        <html><body>
        <div>
            <section>
                <article>
                    <p>Nested <strong>content</strong></p>
                </article>
            </section>
        </div>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("Nested **content**"))
    }

    @Test
    func handlesMalformedHTML() throws {
        let html = "<html><body>"
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(!markdown.isEmpty || markdown.isEmpty)
    }

    @Test
    func convertRealWorldBlogPost() throws {
        let html = """
        <html><body>
        <article>
            <h1>How to Build Great Software</h1>
            <p>By <strong>Jane Developer</strong></p>
            <p>Building software is both an <em>art</em> and a <em>science</em>. Here are some key principles:</p>
            <ol>
                <li>Write clean, readable code</li>
                <li>Test thoroughly</li>
                <li>Refactor regularly</li>
            </ol>
            <h2>Best Practices</h2>
            <ul>
                <li>Use version control</li>
                <li>Write documentation</li>
                <li>Review code with peers</li>
            </ul>
            <blockquote>
                Code is read more often than it is written.
            </blockquote>
            <p>For more information, visit <a href="https://example.com">our website</a>.</p>
        </article>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# How to Build Great Software"))
        #expect(markdown.contains("**Jane Developer**"))
        #expect(markdown.contains("*art*"))
        #expect(markdown.contains("1. Write clean, readable code"))
        #expect(markdown.contains("## Best Practices"))
        #expect(markdown.contains("- Use version control"))
        #expect(markdown.contains("> Code is read more often"))
        #expect(markdown.contains("[our website](https://example.com)"))
    }

    @Test
    func convertWikipediaStyleArticle() throws {
        let html = """
        <html><body>
        <h1>Swift Programming Language</h1>
        <p>Swift is a general-purpose, <strong>multi-paradigm</strong> programming language.</p>
        <h2>Features</h2>
        <table>
            <tr><th>Feature</th><th>Description</th></tr>
            <tr><td>Type Safety</td><td>Prevents type errors</td></tr>
            <tr><td>Optionals</td><td>Handles null values safely</td></tr>
        </table>
        <h2>Code Example</h2>
        <pre><code>let greeting = "Hello, Swift!"
        print(greeting)</code></pre>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# Swift Programming Language"))
        #expect(markdown.contains("**multi-paradigm**"))
        #expect(markdown.contains("| Feature | Description |"))
        #expect(markdown.contains("| Type Safety | Prevents type errors |"))
        #expect(markdown.contains("```"))
        #expect(markdown.contains("let greeting"))
    }

    @Test
    func convertRecipeFormat() throws {
        let html = """
        <html><body>
        <h1>Chocolate Chip Cookies</h1>
        <h2>Ingredients</h2>
        <ul>
            <li>2 cups flour</li>
            <li>1 cup sugar</li>
            <li>1 cup chocolate chips</li>
        </ul>
        <h2>Instructions</h2>
        <ol>
            <li>Mix dry ingredients</li>
            <li>Add wet ingredients</li>
            <li>Bake at 350°F for 12 minutes</li>
        </ol>
        <p><em>Yields 24 cookies</em></p>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# Chocolate Chip Cookies"))
        #expect(markdown.contains("## Ingredients"))
        #expect(markdown.contains("- 2 cups flour"))
        #expect(markdown.contains("## Instructions"))
        #expect(markdown.contains("1. Mix dry ingredients"))
        #expect(markdown.contains("*Yields 24 cookies*"))
    }

    @Test
    func convertDocumentationPage() throws {
        let html = """
        <html><body>
        <h1>API Documentation</h1>
        <h2>Authentication</h2>
        <p>Use the following endpoint:</p>
        <pre><code>POST /api/auth/login</code></pre>
        <h3>Parameters</h3>
        <table>
            <tr><th>Name</th><th>Type</th><th>Required</th></tr>
            <tr><td>username</td><td>string</td><td>Yes</td></tr>
            <tr><td>password</td><td>string</td><td>Yes</td></tr>
        </table>
        <h3>Example</h3>
        <pre><code>{
          "username": "user@example.com",
          "password": "secret123"
        }</code></pre>
        <blockquote>Note: Always use HTTPS in production</blockquote>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# API Documentation"))
        #expect(markdown.contains("### Parameters"))
        #expect(markdown.contains("| Name | Type | Required |"))
        #expect(markdown.contains("| username | string | Yes |"))
        #expect(markdown.contains("> Note: Always use HTTPS"))
    }

    @Test
    func convertNewsArticle() throws {
        let html = """
        <html><body>
        <article>
            <h1>Breaking: New Swift Release</h1>
            <p><strong>Published:</strong> January 15, 2025</p>
            <p>Apple announced <a href="https://swift.org">Swift 6.0</a> today with exciting new features.</p>
            <h2>Key Features</h2>
            <ul>
                <li>Improved concurrency model</li>
                <li>Enhanced type inference</li>
                <li>Better error messages</li>
            </ul>
            <hr>
            <p><em>This article was updated at 3:00 PM EST</em></p>
        </article>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("# Breaking: New Swift Release"))
        #expect(markdown.contains("**Published:**"))
        #expect(markdown.contains("[Swift 6.0](https://swift.org)"))
        #expect(markdown.contains("- Improved concurrency model"))
        #expect(markdown.contains("---"))
    }

    @Test
    func convertComplexNestedStructure() throws {
        let html = """
        <html><body>
        <div>
            <p>Paragraph with <strong>bold <em>and italic</em> text</strong> combined.</p>
            <ul>
                <li>Item with <code>inline code</code></li>
                <li>Item with <a href="https://example.com">a link</a></li>
            </ul>
        </div>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("**bold *and italic* text**"))
        #expect(markdown.contains("- Item with `inline code`"))
        #expect(markdown.contains("[a link](https://example.com)"))
    }

    @Test
    func convertEmptyElements() throws {
        let html = """
        <html><body>
        <p></p>
        <ul><li></li></ul>
        <table><tr><td></td></tr></table>
        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !markdown
            .isEmpty
        )
    }

    @Test
    func convertMixedContentWithWhitespace() throws {
        let html = """
        <html><body>

        <p>   Text with   extra   spaces   </p>

        <p>Another paragraph</p>

        </body></html>
        """
        let markdown = try HTMLToMarkdown.convert(html)
        #expect(markdown.contains("Text with"))
        #expect(markdown.contains("spaces"))
        #expect(markdown.contains("Another paragraph"))
    }
}
