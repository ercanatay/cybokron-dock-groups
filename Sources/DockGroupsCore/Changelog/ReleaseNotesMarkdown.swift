import Foundation

/// A block of release notes as Settings → Changelog shows it. The text of headings, list items and
/// paragraphs is inline Markdown (bold, italics, links, `code`) for `ReleaseNotesMarkdown.inline(_:)`;
/// code blocks are kept as they are.
public enum ReleaseNotesBlock: Equatable, Sendable {
    /// `#` to `######`: `level` is 1 to 6.
    case heading(level: Int, text: String)
    /// A list item. `marker` is "•" for `-`, `*` and `+` items and the number of a numbered one
    /// ("2."); `depth` is 0 at the margin and grows by one for every two spaces of indentation.
    case listItem(marker: String, depth: Int, text: String)
    /// Consecutive lines of text (a blockquote's too), line breaks kept as GitHub shows them.
    case paragraph(String)
    /// The lines of a fenced code block (```` ``` ```` or `~~~`).
    case code(String)
    /// A thematic break: `---`, `***` or `___`.
    case rule
}

/// The Markdown subset of GitHub release notes that Settings → Changelog renders: headings, bullet
/// and numbered lists (nested by indentation), paragraphs, blockquotes, fenced code, rules, and the
/// inline syntax within them. Anything else shows as plain text; HTML comments (such as the one
/// GitHub's generated notes start with) are left out.
public enum ReleaseNotesMarkdown {
    /// The deepest list nesting shown; deeper items are drawn at this depth.
    public static let maximumListDepth = 4

    /// `markdown` cut into blocks; empty when there's nothing to show (no text, or only whitespace and
    /// HTML comments).
    public static func blocks(_ markdown: String) -> [ReleaseNotesBlock] {
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var fence = ""
        // A line right under a list item (no blank line between) continues the item.
        var continuesListItem = false

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in lines(of: markdown) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var code = codeLines {
                if isFence(trimmed, closing: fence) {
                    blocks.append(.code(code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    code.append(line)
                    codeLines = code
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                endParagraph()
                fence = String(trimmed.prefix(3))
                codeLines = []
                continuesListItem = false
                continue
            }
            if trimmed.isEmpty {
                endParagraph()
                continuesListItem = false
                continue
            }
            if let heading = heading(trimmed) {
                endParagraph()
                blocks.append(heading)
                continuesListItem = false
                continue
            }
            if isRule(trimmed) {
                endParagraph()
                blocks.append(.rule)
                continuesListItem = false
                continue
            }
            if let item = listItem(line) {
                endParagraph()
                blocks.append(item)
                continuesListItem = true
                continue
            }
            if continuesListItem, case .listItem(let marker, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + " " + trimmed)
                continue
            }
            paragraph.append(trimmed.hasPrefix(">") ? unquoted(trimmed) : trimmed)
        }
        endParagraph()
        // A code block that's never closed runs to the end (without the blank lines there).
        if var codeLines {
            while let last = codeLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                codeLines.removeLast()
            }
            if !codeLines.isEmpty {
                blocks.append(.code(codeLines.joined(separator: "\n")))
            }
        }
        return blocks.filter { block in
            if case .paragraph(let text) = block { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        }
    }

    /// Inline Markdown as styled text: bold, italics, strikethrough, `code` and links (bare
    /// `https://` addresses become links too). Only web and mail links stay clickable; text that
    /// can't be parsed is shown as it is.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let unsafeLinks = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            return ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") ? nil : run.range
        }
        for range in unsafeLinks {
            result[range].link = nil
        }
        return result
    }

    // MARK: - Lines

    /// The lines of `markdown`, any line ending, without HTML comments.
    private static func lines(of markdown: String) -> [String] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        return normalized.components(separatedBy: "\n")
    }

    /// A line of only the fence's character, at least three of them: what closes a code block.
    private static func isFence(_ trimmed: String, closing fence: String) -> Bool {
        guard let character = fence.first, trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == character }
    }

    /// `## Title` (and `## Title ##`); a `#` without a space after it (`#12`) isn't a heading.
    private static func heading(_ trimmed: String) -> ReleaseNotesBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence of #s.
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound])
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return text.isEmpty ? nil : .heading(level: hashes.count, text: text)
    }

    /// Three or more `-`, `*` or `_` (the same one), spaces allowed between them.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`, indented by any number of spaces.
    private static func listItem(_ line: String) -> ReleaseNotesBlock? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let width = indentation.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indentation.count)
        let marker: String
        let text: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"
            text = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let afterDigits = rest.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
                  afterDigits.dropFirst().first == " "
            else { return nil }
            marker = "\(digits)."
            text = afterDigits.dropFirst(2)
        }
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .listItem(marker: marker, depth: min(width / 2, maximumListDepth), text: content)
    }

    /// A blockquote line without its `>` markers.
    private static func unquoted(_ trimmed: String) -> String {
        var text = Substring(trimmed)
        while text.first == ">" {
            text = text.dropFirst().drop { $0 == " " }
        }
        return String(text)
    }
}
