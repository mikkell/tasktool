//
//  Task.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation

enum TaskPriority: String, Codable, CaseIterable, Hashable, Comparable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var colorName: String {
        switch self {
        case .low: return "gray"
        case .medium: return "orange"
        case .high: return "red"
        }
    }

    var symbolName: String {
        switch self {
        case .low: return "arrow.down"
        case .medium: return "minus"
        case .high: return "exclamationmark"
        }
    }

    private var rank: Int {
        switch self {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum TaskRecurrence: String, Codable, CaseIterable, Hashable {
    case daily
    case weekdays
    case weekly
    case biweekly
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// Computes the next due date after `referenceDate` according to this recurrence cadence.
    func nextDueDate(from referenceDate: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
        case .weekdays:
            // Advance at least 1 day, skipping Saturday (7) and Sunday (1) in Gregorian calendar.
            var candidate = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
            while calendar.isDateInWeekend(candidate) {
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { break }
                candidate = next
            }
            return candidate
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: referenceDate) ?? referenceDate
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: referenceDate) ?? referenceDate
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: referenceDate) ?? referenceDate
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: referenceDate) ?? referenceDate
        }
    }
}

struct Task: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var plan: String
    var status: String  // Changed from TaskStatus enum to String
    var priority: TaskPriority?
    var recurrence: TaskRecurrence?
    var dueDate: Date?
    var tags: [String]
    var created: Date
    var updated: Date
    var completedAt: Date?
    var pingHistory: [Date]?
    var body: String
    /// IDs of tasks bundled inside this task, when this task acts as a bundle "container" card
    /// created by drag-dropping one task onto another. Empty for ordinary, non-bundle tasks.
    var bundledTaskIDs: [UUID]
    /// The bundle container task's ID, if this task currently lives inside a bundle. Bundled
    /// tasks are hidden from the Kanban board (only their container card is shown) and share
    /// the container's `plan`/`status` — see `TaskStore.bundleTask(_:onto:)`.
    var parentBundleID: UUID?
    /// Manual sort position within this task's plan/status column, lowest first. Defaults to 0
    /// for tasks that haven't been explicitly reordered yet — ties are broken by array order
    /// (stable sort), which for newly created tasks means "most recently added last". Only
    /// tasks within the same plan/status are compared against each other; see
    /// `TaskStore.reorderTask(_:before:)`.
    var order: Int

    /// True when this task is a bundle container (holds one or more other tasks).
    var isBundle: Bool { !bundledTaskIDs.isEmpty }
    var lastPingAt: Date? { pingHistory?.max() }

    init(
        id: UUID = UUID(),
        title: String,
        plan: String,
        status: String = "todo",  // Default status
        priority: TaskPriority? = nil,
        recurrence: TaskRecurrence? = nil,
        dueDate: Date? = nil,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        completedAt: Date? = nil,
        pingHistory: [Date]? = nil,
        body: String = "",
        bundledTaskIDs: [UUID] = [],
        parentBundleID: UUID? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.plan = plan
        self.status = status
        self.priority = priority
        self.recurrence = recurrence
        self.dueDate = dueDate
        self.tags = tags
        self.created = created
        self.updated = updated
        self.completedAt = completedAt
        self.pingHistory = pingHistory
        self.body = body
        self.bundledTaskIDs = bundledTaskIDs
        self.parentBundleID = parentBundleID
        self.order = order
    }
    
    // Precompiled once and reused across all `fileName` computations — NSRegularExpression
    // compilation is non-trivial and `replacingOccurrences(options: .regularExpression)`
    // would otherwise recompile the pattern on every single call.
    private static let nonSlugCharsRegex = try! NSRegularExpression(pattern: "[^a-z0-9-]")
    private static let repeatedDashesRegex = try! NSRegularExpression(pattern: "-+")

    var fileName: String {
        let lowered = title.lowercased().replacingOccurrences(of: " ", with: "-")

        let noSpecialCharsRange = NSRange(lowered.startIndex..., in: lowered)
        let noSpecialChars = Task.nonSlugCharsRegex.stringByReplacingMatches(
            in: lowered, options: [], range: noSpecialCharsRange, withTemplate: ""
        )

        let collapsedRange = NSRange(noSpecialChars.startIndex..., in: noSpecialChars)
        let collapsed = Task.repeatedDashesRegex.stringByReplacingMatches(
            in: noSpecialChars, options: [], range: collapsedRange, withTemplate: "-"
        )

        let slug = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // Fall back to a portion of the UUID so the file is never named ".md" (hidden)
        let safeSlug = slug.isEmpty ? id.uuidString.lowercased().prefix(8).description : slug
        return "\(safeSlug).md"
    }
}
