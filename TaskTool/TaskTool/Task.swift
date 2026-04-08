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
    
    init(
        id: UUID = UUID(),
        title: String,
        plan: String,
        status: String = "todo",  // Default status
        dueDate: Date? = nil,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        body: String = ""
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
    }
    
    var fileName: String {
        let slug = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        // Fall back to a portion of the UUID so the file is never named ".md" (hidden)
        let safeSlug = slug.isEmpty ? id.uuidString.lowercased().prefix(8).description : slug
        return "\(safeSlug).md"
    }
}
