//
//  MarkdownParser.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation
import Yams

struct MarkdownParser {

    // Shared across all parse/serialize calls — ISO8601DateFormatter is relatively expensive
    // to instantiate and is not mutated after creation, so a single instance is safe to reuse.
    private static let iso8601Formatter = ISO8601DateFormatter()

    static func parseTask(from content: String, plan: String) throws -> Task {
        let components = splitFrontmatter(content)
        guard let frontmatter = components.frontmatter else {
            throw ParsingError.missingFrontmatter
        }
        
        // Use Yams to parse frontmatter
        guard let metadata = try? Yams.load(yaml: frontmatter) as? [String: Any] else {
            throw ParsingError.invalidFormat
        }
        
        let title = extractTitle(from: components.body)
        let body = extractBody(from: components.body)
        
        let id = metadata["id"] as? String ?? UUID().uuidString
        let status = metadata["status"] as? String ?? "To Do"
        let tags = metadata["tags"] as? [String] ?? []
        let bundledTaskIDs = (metadata["bundled_task_ids"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
        let parentBundleID = (metadata["parent_bundle_id"] as? String).flatMap { UUID(uuidString: $0) }
        let order = metadata["order"] as? Int ?? 0
        
        let dateFormatter = iso8601Formatter
        // Yams may parse ISO8601 timestamps as native Date objects rather than Strings.
        // The helper handles both cases so date fields round-trip correctly.
        func parseDate(_ key: String, fallback: Date = Date()) -> Date {
            if let s = metadata[key] as? String { return dateFormatter.date(from: s) ?? fallback }
            if let d = metadata[key] as? Date   { return d }
            return fallback
        }
        func parseDateOptional(_ key: String) -> Date? {
            if let s = metadata[key] as? String { return dateFormatter.date(from: s) }
            if let d = metadata[key] as? Date   { return d }
            return nil
        }
        let created = parseDate("created")
        let updated = parseDate("updated")
        let dueDate = parseDateOptional("due_date")
        let completedAt = parseDateOptional("completed_at")
        
        return Task(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            plan: plan,
            status: status,
            dueDate: dueDate,
            tags: tags,
            created: created,
            updated: updated,
            completedAt: completedAt,
            body: body,
            bundledTaskIDs: bundledTaskIDs,
            parentBundleID: parentBundleID,
            order: order
        )
    }
    
    static func serializeTask(_ task: Task) -> String {
        let dateFormatter = iso8601Formatter
        
        var frontmatter = """
        ---
        id: \(task.id.uuidString)
        type: task
        plan: \(task.plan)
        status: \(task.status)
        order: \(task.order)
        """
        
        if let dueDate = task.dueDate {
            frontmatter += "\ndue_date: \(dateFormatter.string(from: dueDate))"
        }

        if let completedAt = task.completedAt {
            frontmatter += "\ncompleted_at: \(dateFormatter.string(from: completedAt))"
        }
        
        if !task.tags.isEmpty {
            frontmatter += "\ntags:"
            for tag in task.tags {
                frontmatter += "\n  - \(tag)"
            }
        }
        
        if !task.bundledTaskIDs.isEmpty {
            frontmatter += "\nbundled_task_ids:"
            for bundledID in task.bundledTaskIDs {
                frontmatter += "\n  - \(bundledID.uuidString)"
            }
        }
        
        if let parentBundleID = task.parentBundleID {
            frontmatter += "\nparent_bundle_id: \(parentBundleID.uuidString)"
        }
        
        frontmatter += """
        
        created: \(dateFormatter.string(from: task.created))
        updated: \(dateFormatter.string(from: task.updated))
        ---
        """
        
        return frontmatter + "\n# \(task.title)\n\n\(task.body)"
    }
    
    static func parsePlan(from content: String, name: String) throws -> Plan {
        // Use Yams to parse plan YAML
        guard let metadata = try? Yams.load(yaml: content) as? [String: Any] else {
            throw ParsingError.invalidFormat
        }
        
        let id = (metadata["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        let color = metadata["color"] as? String ?? "blue"
        let description = metadata["description"] as? String ?? ""
        
        let dateFormatter = iso8601Formatter
        let created: Date
        if let s = metadata["created"] as? String { created = dateFormatter.date(from: s) ?? Date() }
        else if let d = metadata["created"] as? Date { created = d }
        else { created = Date() }
        
        // Parse statuses
        var statuses: [Plan.TaskStatus] = []
        if let statusesArray = metadata["statuses"] as? [[String: Any]] {
            for (index, statusDict) in statusesArray.enumerated() {
                let statusId = (statusDict["id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
                let statusName = statusDict["name"] as? String ?? "Status"
                let statusColor = statusDict["color"] as? String ?? "gray"
                let statusOrder = statusDict["order"] as? Int ?? index
                
                statuses.append(Plan.TaskStatus(
                    id: statusId,
                    name: statusName,
                    color: statusColor,
                    order: statusOrder
                ))
            }
        } else {
            statuses = Plan.defaultStatuses()
        }
        
        return Plan(
            id: id,
            name: name,
            color: color,
            created: created,
            description: description,
            statuses: statuses,
            order: 0  // Default order, will be overridden by settings.yaml
        )
    }
    
    static func serializePlan(_ plan: Plan) -> String {
        let dateFormatter = iso8601Formatter
        
        var yaml = """
        # Plan: \(plan.name)
        id: \(plan.id.uuidString)
        name: \(yamlQuote(plan.name))
        color: \(plan.color)
        created: \(dateFormatter.string(from: plan.created))
        description: \(yamlQuote(plan.description))
        statuses:
        
        """
        // Don't write order to file - it's managed in settings.yaml
        
        for status in plan.statuses.sorted(by: { $0.order < $1.order }) {
            yaml += """
              - id: \(status.id.uuidString)
                name: \(yamlQuote(status.name))
                color: \(status.color)
                order: \(status.order)
            
            """
        }
        
        return yaml
    }
    
    // MARK: - Private Helpers
    
    private static func splitFrontmatter(_ content: String) -> (frontmatter: String?, body: String) {
        let pattern = #"^---\s*\n(.*?)\n---\s*\n(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) else {
            return (nil, content)
        }
        
        let frontmatter = String(content[Range(match.range(at: 1), in: content)!])
        let body = String(content[Range(match.range(at: 2), in: content)!])
        
        return (frontmatter, body)
    }
    
    private static func extractTitle(from body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return "Untitled Task"
    }
    
    private static func extractBody(from body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        var foundTitle = false
        var bodyLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                foundTitle = true
                continue
            }
            if foundTitle {
                bodyLines.append(line)
            }
        }
        
        return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Wraps a string in double quotes if it contains characters that would break YAML parsing.
    /// Escapes any existing double-quotes inside the string.
    private static func yamlQuote(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(":")
            || value.contains("#")
            || value.contains("\"")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || value.hasPrefix("-")
            || value.hasPrefix("{")
            || value.hasPrefix("[")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    
    enum ParsingError: Error {
        case missingFrontmatter
        case invalidFormat
    }
    
    // MARK: - Settings Parsing
    
    static func parseSettings(from content: String) throws -> Settings {
        // Use Yams to parse settings YAML
        guard let metadata = try? Yams.load(yaml: content) as? [String: Any] else {
            throw ParsingError.invalidFormat
        }
        let planOrder = metadata["plan_order"] as? [String] ?? []
        let availableTags = metadata["available_tags"] as? [String] ?? []
        let overviewSelectedPlanNames = metadata["overview_selected_plan_names"] as? [String]
        let overviewFocusDate: String?
        if let string = metadata["overview_focus_date"] as? String {
            overviewFocusDate = string
        } else if let date = metadata["overview_focus_date"] as? Date {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            overviewFocusDate = formatter.string(from: date)
        } else {
            overviewFocusDate = nil
        }
        let overviewFocusNote = metadata["overview_focus_note"] as? String ?? ""
        let overviewFocusTaskIDs = metadata["overview_focus_task_ids"] as? [String] ?? []
        
        return Settings(
            planOrder: planOrder,
            availableTags: availableTags,
            overviewSelectedPlanNames: overviewSelectedPlanNames,
            overviewFocusDate: overviewFocusDate,
            overviewFocusNote: overviewFocusNote,
            overviewFocusTaskIDs: overviewFocusTaskIDs
        )
    }
    
    static func serializeSettings(_ settings: Settings) -> String {
        var yaml = "# TaskTool Settings\n"
        yaml += "plan_order:\n"
        
        for planName in settings.planOrder {
            yaml += "  - \(yamlQuote(planName))\n"
        }
        
        yaml += "available_tags:\n"
        
        for tag in settings.availableTags {
            yaml += "  - \(yamlQuote(tag))\n"
        }

        if let selectedPlanNames = settings.overviewSelectedPlanNames {
            if selectedPlanNames.isEmpty {
                yaml += "overview_selected_plan_names: []\n"
            } else {
                yaml += "overview_selected_plan_names:\n"
                for planName in selectedPlanNames {
                    yaml += "  - \(yamlQuote(planName))\n"
                }
            }
        }

        if let focusDate = settings.overviewFocusDate {
            yaml += "overview_focus_date: \(focusDate)\n"
        }
        if !settings.overviewFocusNote.isEmpty {
            let normalizedNote = settings.overviewFocusNote
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            if normalizedNote.contains("\n") {
                yaml += "overview_focus_note: |-\n"
                for line in normalizedNote.components(separatedBy: "\n") {
                    yaml += "  \(line)\n"
                }
            } else {
                yaml += "overview_focus_note: \(yamlQuote(normalizedNote))\n"
            }
        }
        if !settings.overviewFocusTaskIDs.isEmpty {
            yaml += "overview_focus_task_ids:\n"
            for taskID in settings.overviewFocusTaskIDs {
                yaml += "  - \(yamlQuote(taskID))\n"
            }
        }
        
        return yaml
    }
}
