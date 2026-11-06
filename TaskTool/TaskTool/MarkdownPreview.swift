import SwiftUI

/// Read-only rendering of markdown text: headings, bullet/numbered lists, quotes, code blocks,
/// rules and inline styling (bold, italic, code, links). Each source line is kept as its own
/// line, matching how task descriptions are typically written.
struct MarkdownPreview: View {
    let text: String

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case quote(text: String)
        case code(lines: [String])
        case rule
        case paragraph(text: String)
        case spacer
    }

    private static let imageRegex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^\)]+\)"#)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var body: some View {
        let blocks = Self.parse(text)

        if blocks.isEmpty {
            Text("Nothing to preview")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(Self.headingFont(level))
                .fontWeight(.bold)
                .padding(.top, 4)
        case let .bullet(indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .numbered(indent, number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .foregroundStyle(.secondary)
            }
        case let .code(lines):
            Text(lines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .paragraph(text):
            Text(Self.inline(text))
        case .spacer:
            Color.clear.frame(height: 6)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    // MARK: - Parsing

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var codeLines: [String]?
        let lines = stripImages(source)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let collected = codeLines {
                    blocks.append(.code(lines: collected))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                if case .spacer? = blocks.last { continue }
                if !blocks.isEmpty { blocks.append(.spacer) }
                continue
            }

            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if isRule(trimmed) {
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                blocks.append(.quote(text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let item = bulletMatch(rawLine) {
                blocks.append(.bullet(indent: item.indent, text: item.text))
            } else if let item = numberedMatch(rawLine) {
                blocks.append(.numbered(indent: item.indent, number: item.number, text: item.text))
            } else {
                blocks.append(.paragraph(text: trimmed))
            }
        }

        // Unterminated fence: still show what was collected.
        if let collected = codeLines {
            blocks.append(.code(lines: collected))
        }
        while case .spacer? = blocks.last { blocks.removeLast() }
        return blocks
    }

    /// Image references are shown in the task's Images section, so they're dropped here.
    private static func stripImages(_ source: String) -> String {
        guard let regex = imageRegex else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func indentLevel(_ line: String) -> (level: Int, rest: Substring) {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let width = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (width / 2, line.dropFirst(leading.count))
    }

    private static func bulletMatch(_ line: String) -> (indent: Int, text: String)? {
        let (indent, rest) = indentLevel(line)
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return (indent, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func numberedMatch(_ line: String) -> (indent: Int, number: String, text: String)? {
        let (indent, rest) = indentLevel(line)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") else { return nil }
        return (indent, String(digits), afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Inline styling

    private static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        // Make bare URLs clickable too.
        if let detector = linkDetector {
            let plain = String(attributed.characters)
            let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
            for match in matches {
                guard let url = match.url,
                      let range = Range(match.range, in: attributed),
                      attributed[range].link == nil
                else { continue }
                attributed[range].link = url
            }
        }
        return attributed
    }
}
