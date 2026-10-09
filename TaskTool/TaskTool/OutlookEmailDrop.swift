import Foundation
import SwiftUI

struct OutlookEmailMessage: Equatable {
    static let maximumMessageBytes = 16 * 1024 * 1024
    private static let maximumBodyCharacters = 20_000
    private static let maximumHeaderBytes = 64 * 1024

    let subject: String
    let sender: String?
    let date: String?
    let body: String?
    let bodyWasTruncated: Bool
    let bodyDiagnostic: String?

    var taskBody: String {
        var lines = ["Captured from Outlook."]
        if let sender {
            lines.append("From: \(sender)")
        }
        if let date {
            lines.append("Date: \(date)")
        }
        if let body, !body.isEmpty {
            lines.append("")
            lines.append("Email body:")
            lines.append(body)
            if bodyWasTruncated {
                lines.append("[Email body truncated.]")
            }
        }
        return lines.joined(separator: "\n")
    }

    init(subject: String, sender: String?, date: String?, body: String? = nil) {
        self.subject = subject
        self.sender = sender
        self.date = date
        self.body = body
        bodyWasTruncated = false
        bodyDiagnostic = nil
    }

    init(data: Data) throws {
        let boundedData = Data(data.prefix(Self.maximumMessageBytes))
        guard let entity = Self.parseEntity(boundedData) else {
            throw OutlookEmailDropError.invalidEmailFile
        }

        guard let rawSubject = entity.headers["subject"], !rawSubject.isEmpty else {
            throw OutlookEmailDropError.missingSubject
        }
        subject = Self.decodeEncodedWords(rawSubject)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            throw OutlookEmailDropError.missingSubject
        }
        guard subject.utf8.count <= 200 else {
            throw OutlookEmailDropError.valueTooLong("subject")
        }
        sender = try Self.decodeHeader(entity.headers["from"], name: "sender", maximumLength: 2_000)
        date = try Self.decodeHeader(entity.headers["date"], name: "date", maximumLength: 256)

        let candidates = Self.bodyCandidates(from: entity, depth: 0)
        let selectedBody: String?
        if let plainTextBody = candidates.plain.first {
            selectedBody = plainTextBody
        } else if let htmlBody = candidates.html.first {
            selectedBody = Self.htmlToText(htmlBody)
        } else {
            selectedBody = nil
        }
        bodyDiagnostic = selectedBody?.isEmpty != false ? Self.bodyDiagnostic(for: entity) : nil
        if let selectedBody, !selectedBody.isEmpty {
            body = String(selectedBody.prefix(Self.maximumBodyCharacters))
            bodyWasTruncated = selectedBody.count > Self.maximumBodyCharacters
                || data.count > Self.maximumMessageBytes
        } else {
            body = nil
            bodyWasTruncated = false
        }
    }

    private static func parseEntity(_ data: Data) -> ParsedEmailEntity? {
        let headerData = Data(data.prefix(maximumHeaderBytes))
        guard let separator = headerData.range(of: Data([13, 10, 13, 10]))
                ?? headerData.range(of: Data([10, 10])) else {
            return nil
        }

        let rawHeaders = Data(headerData[..<separator.lowerBound])
        guard let headerText = String(data: rawHeaders, encoding: .utf8)
                ?? String(data: rawHeaders, encoding: .isoLatin1) else {
            return nil
        }

        var headers: [String: String] = [:]
        var lastHeaderKey: String?
        for line in headerText.components(separatedBy: .newlines) {
            if line.first == " " || line.first == "\t",
               let previousKey = lastHeaderKey {
                headers[previousKey, default: ""].append(" " + line.trimmingCharacters(in: .whitespaces))
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[key] = value
                lastHeaderKey = key
            } else {
                lastHeaderKey = nil
            }
        }

        let bodyOffset = separator.upperBound
        return ParsedEmailEntity(headers: headers, body: Data(data.dropFirst(bodyOffset)))
    }

    private static func bodyCandidates(
        from entity: ParsedEmailEntity,
        depth: Int
    ) -> (plain: [String], html: [String]) {
        guard depth < 10, !isAttachment(entity.headers) else { return ([], []) }

        let contentType = entity.headers["content-type"] ?? "text/plain"
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "text/plain"

        if mediaType.hasPrefix("multipart/"),
           let boundary = parameter(named: "boundary", in: contentType)
                ?? inferredBoundary(in: entity.body) {
            var plain: [String] = []
            var html: [String] = []
            for partData in multipartParts(in: entity.body, boundary: boundary) {
                guard let part = parseEntity(partData) else { continue }
                let partCandidates = bodyCandidates(from: part, depth: depth + 1)
                plain.append(contentsOf: partCandidates.plain)
                html.append(contentsOf: partCandidates.html)
            }
            return (plain, html)
        }

        guard mediaType == "text/plain" || mediaType == "text/html" else {
            return ([], [])
        }

        let transferEncoding = entity.headers["content-transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bytes: Data
        switch transferEncoding {
        case "base64":
            bytes = Data(base64Encoded: entity.body, options: .ignoreUnknownCharacters) ?? entity.body
        case "quoted-printable":
            bytes = decodeQuotedPrintable(entity.body)
        default:
            bytes = entity.body
        }

        let charset = parameter(named: "charset", in: contentType)
        let encoding = stringEncoding(for: charset)
        let decoded = String(data: bytes, encoding: encoding)
            ?? String(data: bytes, encoding: .utf8)
            ?? String(decoding: bytes, as: UTF8.self)
        let cleaned = normalizeBody(decoded)
        guard !cleaned.isEmpty else { return ([], []) }
        return mediaType == "text/plain" ? ([cleaned], []) : ([], [cleaned])
    }

    private static func bodyDiagnostic(for entity: ParsedEmailEntity) -> String {
        let structure = bodyStructure(from: entity, depth: 0)
            .prefix(8)
            .joined(separator: " -> ")
        return "No readable text body found (\(structure))."
    }

    private static func bodyStructure(from entity: ParsedEmailEntity, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        let contentType = entity.headers["content-type"] ?? "text/plain"
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "unknown"
        let transferEncoding = entity.headers["content-transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "none"
        let current = "\(mediaType), transfer: \(transferEncoding), bytes: \(entity.body.count)"
        guard mediaType.hasPrefix("multipart/") else { return [current] }
        guard let boundary = parameter(named: "boundary", in: contentType)
                ?? inferredBoundary(in: entity.body) else {
            let names = parameterNames(in: contentType).joined(separator: ",")
            return [current + ", boundary: missing, parameters: [\(names)], inferred boundary: unavailable"]
        }

        let parts = multipartParts(in: entity.body, boundary: boundary)
        guard !parts.isEmpty else { return [current + ", boundary found, parts: 0"] }
        return [current + ", boundary found, parts: \(parts.count)"] + parts.flatMap { partData in
            guard let part = parseEntity(partData) else { return ["unparsed MIME part"] }
            return bodyStructure(from: part, depth: depth + 1)
        }
    }

    private static func inferredBoundary(in body: Data) -> String? {
        let sample = Data(body.prefix(1024 * 1024))
        guard let text = String(data: sample, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let closingLines = Set(lines.filter { $0.hasPrefix("--") && $0.hasSuffix("--") })

        for line in lines where line.hasPrefix("--") && !line.hasSuffix("--") {
            let boundary = String(line.dropFirst(2))
            guard !boundary.isEmpty, boundary.utf8.count <= 200,
                  closingLines.contains("--\(boundary)--") else {
                continue
            }
            return boundary
        }
        return nil
    }

    private static func isAttachment(_ headers: [String: String]) -> Bool {
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        return disposition.hasPrefix("attachment")
            || parameter(named: "filename", in: disposition) != nil
            || parameter(named: "name", in: headers["content-type"] ?? "") != nil
    }

    private static func multipartParts(in data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var cursor = data.startIndex
        var partStart: Data.Index?
        var reachedClosingBoundary = false

        while cursor < data.endIndex,
              let range = data.range(of: delimiter, options: [], in: cursor..<data.endIndex) {
            if let partStart {
                var partEnd = range.lowerBound
                if partEnd >= 2, data[partEnd - 2] == 13, data[partEnd - 1] == 10 {
                    partEnd -= 2
                } else if partEnd >= 1, data[partEnd - 1] == 10 {
                    partEnd -= 1
                }
                if partStart < partEnd {
                    parts.append(Data(data[partStart..<partEnd]))
                }
            }

            let afterDelimiter = range.upperBound
            guard afterDelimiter < data.endIndex else {
                reachedClosingBoundary = true
                break
            }
            if data[afterDelimiter] == 45,
               afterDelimiter + 1 < data.endIndex,
               data[afterDelimiter + 1] == 45 {
                reachedClosingBoundary = true
                break
            }

            var nextPartStart = afterDelimiter
            if nextPartStart + 1 < data.endIndex,
               data[nextPartStart] == 13, data[nextPartStart + 1] == 10 {
                nextPartStart += 2
            } else if data[nextPartStart] == 10 {
                nextPartStart += 1
            }
            partStart = nextPartStart
            cursor = afterDelimiter
        }

        if !reachedClosingBoundary, let partStart, partStart < data.endIndex {
            parts.append(Data(data[partStart...]))
        }
        return parts
    }

    private static func parameter(named name: String, in value: String) -> String? {
        let parameters = contentTypeParameters(in: value)
        if let direct = parameters[name.lowercased()] {
            return decodeParameterValue(direct)
        }

        var continuedValue = ""
        var hasContinuation = false
        for index in 0..<16 {
            guard let segment = parameters["\(name.lowercased())*\(index)"]
                    ?? parameters["\(name.lowercased())*\(index)*"] else {
                if index == 0 { return nil }
                break
            }
            hasContinuation = true
            if index == 0, let charsetSeparator = segment.range(of: "''") {
                continuedValue += String(segment[charsetSeparator.upperBound...])
            } else {
                continuedValue += segment
            }
        }
        guard hasContinuation else { return nil }
        return decodeParameterValue(continuedValue)
    }

    private static func parameterNames(in value: String) -> [String] {
        contentTypeParameters(in: value).keys.sorted()
    }

    private static func contentTypeParameters(in value: String) -> [String: String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\", inQuotes {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                current.append(character)
                inQuotes.toggle()
            } else if character == ";", !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let parameterValue = segment[segment.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            parameters[name] = parameterValue
        }
        return parameters
    }

    private static func decodeParameterValue(_ value: String) -> String {
        var decoded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if decoded.first == "\"", decoded.last == "\"", decoded.count >= 2 {
            decoded.removeFirst()
            decoded.removeLast()
            decoded = decoded.replacingOccurrences(of: #"\\(["\\])"#, with: "$1")
        }
        return decoded.removingPercentEncoding ?? decoded
    }

    private static func decodeHeader(_ value: String?, name: String, maximumLength: Int) throws -> String? {
        guard let value else { return nil }
        let decoded = decodeEncodedWords(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard decoded.utf8.count <= maximumLength else {
            throw OutlookEmailDropError.valueTooLong(name)
        }
        return decoded.isEmpty ? nil : decoded
    }

    private static func decodeEncodedWords(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        ) else { return value }

        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }

        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let charset = source.substring(with: match.range(at: 1))
            let encoding = stringEncoding(for: charset)
            let mode = source.substring(with: match.range(at: 2)).lowercased()
            let payload = source.substring(with: match.range(at: 3))
            let bytes: Data?
            if mode == "b" {
                bytes = Data(base64Encoded: payload)
            } else {
                let normalized = Data(payload.replacingOccurrences(of: "_", with: " ").utf8)
                bytes = decodeQuotedPrintable(normalized)
            }
            result += bytes.flatMap { String(data: $0, encoding: encoding) } ?? source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func stringEncoding(for charset: String?) -> String.Encoding {
        guard let charset else { return .utf8 }
        switch charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "utf-8", "utf8": return String.Encoding.utf8
        case "iso-8859-1", "latin1": return String.Encoding.isoLatin1
        case "windows-1252", "cp1252": return String.Encoding.windowsCP1252
        case "us-ascii", "ascii": return String.Encoding.ascii
        default: return String.Encoding.utf8
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let source = Array(data)
        var bytes: [UInt8] = []
        var index = 0
        while index < source.count {
            if source[index] == 61,
               index + 2 < source.count,
               source[index + 1] == 13, source[index + 2] == 10 {
                index += 3
            } else if source[index] == 61,
                      index + 1 < source.count, source[index + 1] == 10 {
                index += 2
            } else if source[index] == 61,
                      index + 2 < source.count,
                      let high = hexValue(source[index + 1]),
                      let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return Data(bytes)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func htmlToText(_ html: String) -> String {
        var text = replacingRegex(
            html,
            pattern: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: ""
        )
        text = replacingRegex(
            text,
            pattern: #"(?i)<(?:br|hr)\b[^>]*>|</(?:p|div|li|tr|h[1-6]|blockquote|table)\s*>"#,
            with: "\n"
        )
        text = replacingRegex(text, pattern: #"(?i)</?(?:td|th)\b[^>]*>"#, with: " ")
        text = replacingRegex(text, pattern: #"(?s)<!--.*?-->|<[^>]+>"#, with: "")
        return normalizeBody(decodeHTMLEntities(text))
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);"#,
            options: [.caseInsensitive]
        ) else { return value }

        let source = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return value }

        var result = ""
        var cursor = 0
        for match in matches {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = source.substring(with: match.range(at: 1))
            let decoded: String?
            switch entity.lowercased() {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos", "#39": decoded = "'"
            case "nbsp": decoded = " "
            default:
                let value: Int?
                if entity.lowercased().hasPrefix("#x") {
                    value = Int(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    value = Int(entity.dropFirst())
                } else {
                    value = nil
                }
                if let value, value >= 0, value <= 0x10FFFF,
                   let scalar = UnicodeScalar(UInt32(value)) {
                    decoded = String(scalar)
                } else {
                    decoded = nil
                }
            }
            result += decoded ?? source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func normalizeBody(_ value: String) -> String {
        let lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized = lines.joined(separator: "\n")
        let compact = replacingRegex(normalized, pattern: #"\n{3,}"#, with: "\n\n")
        return compact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingRegex(_ value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

private struct ParsedEmailEntity {
    let headers: [String: String]
    let body: Data
}

enum OutlookEmailDropError: LocalizedError, Equatable {
    case invalidEmailFile
    case missingSubject
    case valueTooLong(String)
    case storageUnavailable
    case inboxHasNoStatuses

    var errorDescription: String? {
        switch self {
        case .invalidEmailFile:
            "The dropped file doesn't look like an email message."
        case .missingSubject:
            "The dropped email has no subject."
        case .valueTooLong(let field):
            "The Outlook email \(field) is too long to capture."
        case .storageUnavailable:
            "Choose a TaskTool storage folder before capturing an Outlook message."
        case .inboxHasNoStatuses:
            "The Inbox plan needs at least one status before it can receive tasks."
        }
    }
}

struct OutlookCaptureNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let isError: Bool
}

struct OutlookCaptureNoticeView: View {
    let notice: OutlookCaptureNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .shadow(radius: 8, y: 2)
    }
}
