import Foundation
import Markdown

/// Converts Markdown source into a self-contained, sanitised HTML document for
/// the `WKWebView` preview.
///
/// Parsing is done by `swift-markdown` (cmark-gfm with the GFM table,
/// strikethrough, and task-list extensions). Rendering is intentionally local
/// rather than using `HTMLFormatter`: raw HTML from the source is escaped
/// instead of passed through, link schemes are allow-listed, and images are
/// restricted to local relative paths. The resulting string is safe to load
/// with JavaScript and remote networking disabled.
public enum MarkdownPreviewRenderer {
    /// The exact CSP shipped with every preview document. Kept as a constant so
    /// tests can assert on the security posture without parsing the whole page.
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'none'",
        "style-src 'unsafe-inline'",
        "img-src file: data:",
        "font-src 'none'",
        "media-src 'none'",
        "connect-src 'none'",
        "frame-src 'none'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'"
    ].joined(separator: "; ")

    /// Deeply nested Markdown is rendered up to this depth; beyond it the
    /// renderer emits a plain-text marker instead of recursing further. This
    /// keeps adversarial nesting from exhausting the stack.
    static let maximumNestingDepth = 80

    /// cmark-gfm recurses per block nesting level, so an adversarial file with
    /// thousands of nested quotes can exhaust the stack before our own depth
    /// guard runs. Clamp pathological nesting before parsing; the source file
    /// is never modified, only this preview rendering.
    static let maximumBlockNesting = 24
    static let maximumIndentColumns = 120

    /// Renders only the article fragment. Useful for focused rendering tests.
    public static func fragment(markdown: String) -> String {
        let prepared = clampedForParsing(markdown)
        let document = Document(parsing: prepared.text, options: [.disableSmartOpts])
        let body = renderChildren(document, depth: 0)
        guard prepared.wasClamped else { return body }
        return "<p class=\"depth-limit\">[deeply nested content was simplified for this preview]</p>\n" + body
    }

    /// Keeps block nesting within what the parser can recurse through safely.
    static func clampedForParsing(_ markdown: String) -> (text: String, wasClamped: Bool) {
        guard !markdown.isEmpty else { return (markdown, false) }
        var wasClamped = false
        var output: [Substring] = []
        output.reserveCapacity(markdown.utf8.count / 24)

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var working = line

            var cursor = working.startIndex
            var depth = 0
            var afterMarkers = cursor
            while cursor < working.endIndex {
                var probe = cursor
                var spaces = 0
                while probe < working.endIndex, working[probe] == " ", spaces < 4 {
                    probe = working.index(after: probe)
                    spaces += 1
                }
                guard probe < working.endIndex, working[probe] == ">" else { break }
                depth += 1
                probe = working.index(after: probe)
                if probe < working.endIndex, working[probe] == " " {
                    probe = working.index(after: probe)
                }
                cursor = probe
                afterMarkers = probe
            }
            if depth > maximumBlockNesting {
                let rest = working[afterMarkers...]
                working = Substring(String(repeating: "> ", count: maximumBlockNesting) + rest)
                wasClamped = true
            }

            var indentColumns = 0
            var indentEnd = working.startIndex
            while indentEnd < working.endIndex {
                if working[indentEnd] == " " {
                    indentColumns += 1
                } else if working[indentEnd] == "\t" {
                    indentColumns += 4
                } else {
                    break
                }
                indentEnd = working.index(after: indentEnd)
            }
            if indentColumns > maximumIndentColumns {
                working = Substring(
                    String(repeating: " ", count: maximumIndentColumns) + working[indentEnd...]
                )
                wasClamped = true
            }
            output.append(working)
        }

        return (output.joined(separator: "\n"), wasClamped)
    }

    /// Renders a complete HTML document with the strict CSP and the preview
    /// stylesheet.
    public static func documentHTML(markdown: String, title: String = "Preview") -> String {
        let body = fragment(markdown: markdown)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(escapeAttribute(contentSecurityPolicy))">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escapeText(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)</article>
        </body>
        </html>
        """
    }

    // MARK: - Rendering

    private static func renderChildren(_ node: Markup, depth: Int) -> String {
        guard depth <= maximumNestingDepth else {
            return "<span class=\"depth-limit\">[deeply nested content omitted]</span>\n"
        }
        var output = ""
        for child in node.children {
            output += render(child, depth: depth + 1)
        }
        return output
    }

    private static func render(_ node: Markup, depth: Int) -> String {
        switch node {
        case let document as Document:
            return renderChildren(document, depth: depth)

        case let paragraph as Paragraph:
            return "<p>\(renderChildren(paragraph, depth: depth))</p>\n"

        case let heading as Heading:
            let level = min(max(heading.level, 1), 6)
            return "<h\(level)>\(renderChildren(heading, depth: depth))</h\(level)>\n"

        case let quote as BlockQuote:
            return "<blockquote>\n\(renderChildren(quote, depth: depth))</blockquote>\n"

        case is ThematicBreak:
            return "<hr>\n"

        case let code as CodeBlock:
            let language = sanitizedLanguage(code.language)
            let attribute = language.isEmpty ? "" : " class=\"language-\(language)\""
            return "<pre><code\(attribute)>\(escapeText(code.code))</code></pre>\n"

        case let html as HTMLBlock:
            return "<pre class=\"raw-html\">\(escapeText(html.rawHTML))</pre>\n"

        case let list as UnorderedList:
            return "<ul>\n\(renderChildren(list, depth: depth))</ul>\n"

        case let list as OrderedList:
            let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            return "<ol\(start)>\n\(renderChildren(list, depth: depth))</ol>\n"

        case let item as ListItem:
            var checkbox = ""
            switch item.checkbox {
            case .checked?:
                checkbox = "<input type=\"checkbox\" disabled checked> "
            case .unchecked?:
                checkbox = "<input type=\"checkbox\" disabled> "
            case nil:
                break
            }
            if item.checkbox != nil {
                // GFM task items are parsed as loose list items, so unwrap the
                // paragraph to keep the checkbox inline with its label.
                let content = item.children.map { child -> String in
                    if let paragraph = child as? Paragraph {
                        return renderChildren(paragraph, depth: depth)
                    }
                    return render(child, depth: depth + 1)
                }.joined()
                return "<li class=\"task-item\">\(checkbox)\(content)</li>\n"
            }
            return "<li>\(renderChildren(item, depth: depth))</li>\n"

        case let table as Table:
            return renderTable(table, depth: depth)

        case let row as Table.Row:
            return "<tr>\(renderChildren(row, depth: depth))</tr>\n"

        case let cell as Table.Cell:
            let tag = cellIsHeader(cell) ? "th" : "td"
            return "<\(tag)>\(renderChildren(cell, depth: depth))</\(tag)>"

        case let text as Text:
            return escapeText(text.string)

        case let emphasis as Emphasis:
            return "<em>\(renderChildren(emphasis, depth: depth))</em>"

        case let strong as Strong:
            return "<strong>\(renderChildren(strong, depth: depth))</strong>"

        case let strike as Strikethrough:
            return "<del>\(renderChildren(strike, depth: depth))</del>"

        case let code as InlineCode:
            return "<code>\(escapeText(code.code))</code>"

        case let html as InlineHTML:
            return escapeText(html.rawHTML)

        case let link as Link:
            return renderLink(link, depth: depth)

        case let image as Image:
            return renderImage(image)

        case is SoftBreak:
            return "\n"

        case is LineBreak:
            return "<br>\n"

        case let symbol as SymbolLink:
            if let destination = symbol.destination {
                return "<code>\(escapeText(destination))</code>"
            }
            return ""

        default:
            return renderChildren(node, depth: depth)
        }
    }

    private static func renderTable(_ table: Table, depth: Int) -> String {
        let alignments = table.columnAlignments
        var output = "<div class=\"table-wrap\"><table>\n"
        output += "<thead>\n<tr>"
        let headerCells = Array(table.head.cells)
        for (index, cell) in headerCells.enumerated() {
            output += "<th\(alignmentAttribute(alignments, index: index))>\(renderChildren(cell, depth: depth))</th>"
        }
        output += "</tr>\n</thead>\n"
        if !table.body.isEmpty {
            output += "<tbody>\n"
            for row in table.body.rows {
                output += "<tr>"
                for (index, cell) in row.cells.enumerated() {
                    output += "<td\(alignmentAttribute(alignments, index: index))>\(renderChildren(cell, depth: depth))</td>"
                }
                output += "</tr>\n"
            }
            output += "</tbody>\n"
        }
        output += "</table></div>\n"
        return output
    }

    private static func alignmentAttribute(_ alignments: [Table.ColumnAlignment?], index: Int) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left:
            return " style=\"text-align: left\""
        case .center:
            return " style=\"text-align: center\""
        case .right:
            return " style=\"text-align: right\""
        }
    }

    private static func cellIsHeader(_ cell: Table.Cell) -> Bool {
        var parent = cell.parent
        while let current = parent {
            if current is Table.Head { return true }
            if current is Table.Body { return false }
            parent = current.parent
        }
        return false
    }

    private static func renderLink(_ link: Link, depth: Int) -> String {
        let content = renderChildren(link, depth: depth)
        guard let destination = link.destination,
              let url = sanitizedLinkURL(destination) else {
            return content
        }
        let title = link.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<a href=\"\(escapeAttribute(url))\"\(title) rel=\"noopener noreferrer\">\(content)</a>"
    }

    private static func renderImage(_ image: Image) -> String {
        let alt = escapeAttribute(image.plainText)
        guard let source = image.source,
              let url = sanitizedImageURL(source) else {
            return "<span class=\"blocked-image\">[image blocked: \(alt)]</span>"
        }
        let title = image.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        return "<img src=\"\(escapeAttribute(url))\" alt=\"\(alt)\"\(title)>"
    }

    // MARK: - Sanitisation

    /// Links may be relative, fragment-only, http(s), or mailto. Everything
    /// else (notably `javascript:` and `data:`) is dropped.
    static func sanitizedLinkURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") { return trimmed }
        if let scheme = scheme(of: trimmed) {
            let allowed = ["http", "https", "mailto"]
            guard allowed.contains(scheme) else { return nil }
            return trimmed
        }
        if trimmed.hasPrefix("//") { return nil }
        return trimmed
    }

    /// Images must be local and relative so the preview can never fetch a
    /// remote resource.
    static func sanitizedImageURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard scheme(of: trimmed) == nil else { return nil }
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/") else { return nil }
        return trimmed
    }

    private static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let prefix = url[url.startIndex..<colon]
        guard !prefix.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-")
        guard prefix.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard prefix.unicodeScalars.first.map({ $0.properties.isAlphabetic }) == true else { return nil }
        return prefix.lowercased()
    }

    private static func sanitizedLanguage(_ raw: String?) -> String {
        guard let raw else { return "" }
        let allowed = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(allowed.prefix(40))
    }

    // MARK: - Escaping

    static func escapeText(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            default: output.append(character)
            }
        }
        return output
    }

    static func escapeAttribute(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    :root {
      color-scheme: light dark;
      --text: #1f2328;
      --muted: #59636e;
      --border: #d1d9e0;
      --code-bg: rgba(129, 139, 152, 0.12);
      --quote-border: #d1d9e0;
      --link: #0969da;
      --table-stripe: rgba(129, 139, 152, 0.06);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #e6edf3;
        --muted: #9198a1;
        --border: #3d444d;
        --code-bg: rgba(110, 118, 129, 0.25);
        --quote-border: #3d444d;
        --link: #4493f8;
        --table-stripe: rgba(110, 118, 129, 0.1);
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: transparent; }
    body {
      color: var(--text);
      font: -apple-system-body;
      font-family: -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
      font-size: 14px;
      line-height: 1.55;
      overflow-wrap: break-word;
    }
    .markdown-body { padding: 18px 22px 48px; max-width: 46rem; margin: 0 auto; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.6em; font-weight: 600; }
    h1 { font-size: 1.9em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
    h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.05em; }
    p { margin: 0 0 0.9em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 650; }
    del { color: var(--muted); }
    code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.92em; }
    code { background: var(--code-bg); border-radius: 4px; padding: 0.15em 0.35em; }
    pre { background: var(--code-bg); border-radius: 6px; padding: 12px 14px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    pre.raw-html { color: var(--muted); white-space: pre-wrap; }
    blockquote { margin: 0 0 1em; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--quote-border); }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
    li { margin: 0.2em 0; }
    li > input[type="checkbox"] { margin-right: 0.35em; vertical-align: middle; }
    hr { border: 0; border-top: 1px solid var(--border); margin: 1.6em 0; }
    .table-wrap { overflow-x: auto; margin: 0 0 1em; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; }
    thead th { background: var(--table-stripe); font-weight: 600; }
    tbody tr:nth-child(2n) { background: var(--table-stripe); }
    img { max-width: 100%; height: auto; }
    .blocked-image { color: var(--muted); font-style: italic; }
    """
}
