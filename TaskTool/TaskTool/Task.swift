//
//  Task.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation

struct Task: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var plan: String
    var status: String  // Changed from TaskStatus enum to String
    var dueDate: Date?
    var tags: [String]
    var created: Date
    var updated: Date
    var body: String
    /// IDs of tasks bundled inside this task, when this task acts as a bundle "container" card
    /// created by drag-dropping one task onto another. Empty for ordinary, non-bundle tasks.
    var bundledTaskIDs: [UUID]
    /// The bundle container task's ID, if this task currently lives inside a bundle. Bundled
    /// tasks are hidden from the Kanban board (only their container card is shown) and share
    /// the container's `plan`/`status` — see `TaskStore.bundleTask(_:onto:)`.
    var parentBundleID: UUID?

    /// True when this task is a bundle container (holds one or more other tasks).
    var isBundle: Bool { !bundledTaskIDs.isEmpty }

    init(
        id: UUID = UUID(),
        title: String,
        plan: String,
        status: String = "todo",  // Default status
        dueDate: Date? = nil,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        body: String = "",
        bundledTaskIDs: [UUID] = [],
        parentBundleID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.plan = plan
        self.status = status
        self.dueDate = dueDate
        self.tags = tags
        self.created = created
        self.updated = updated
        self.body = body
        self.bundledTaskIDs = bundledTaskIDs
        self.parentBundleID = parentBundleID
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
