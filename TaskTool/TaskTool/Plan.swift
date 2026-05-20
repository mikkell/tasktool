//
//  Plan.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation

struct Plan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var created: Date
    var description: String
    var statuses: [TaskStatus]
    var order: Int
    
    struct TaskStatus: Identifiable, Codable, Hashable {
        var id: UUID
        var name: String
        var color: String
        var order: Int
        
        init(id: UUID = UUID(), name: String, color: String, order: Int) {
            self.id = id
            self.name = name
            self.color = color
            self.order = order
        }

        var isDoneStatus: Bool {
            name.lowercased().contains("done")
        }
    }
    
    init(
        id: UUID = UUID(),
        name: String,
        color: String = "blue",
        created: Date = Date(),
        description: String = "",
        statuses: [TaskStatus] = Plan.defaultStatuses(),
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.created = created
        self.description = description
        self.statuses = statuses
        self.order = order
    }
    
    static func defaultStatuses() -> [TaskStatus] {
        [
            TaskStatus(name: "To Do", color: "gray", order: 0),
            TaskStatus(name: "In Progress", color: "blue", order: 1),
            TaskStatus(name: "Done", color: "green", order: 2)
        ]
    }
    
    var folderName: String {
        name
    }
}
