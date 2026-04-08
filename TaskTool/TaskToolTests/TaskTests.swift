//
//  TaskTests.swift
//  TaskToolTests
//
//  Created by Mikkel Lund Lindemark on 23/01/2026.
//

import XCTest
@testable import TaskTool

final class TaskTests: XCTestCase {
    
    func testTaskInitialization() {
        let task = Task(
            title: "Test Task",
            plan: "My Plan",
            status: "To Do"
        )
        
        XCTAssertEqual(task.title, "Test Task")
        XCTAssertEqual(task.plan, "My Plan")
        XCTAssertEqual(task.status, "To Do")
        XCTAssertTrue(task.tags.isEmpty)
        XCTAssertTrue(task.body.isEmpty)
        XCTAssertNil(task.dueDate)
        XCTAssertNotNil(task.created)
        XCTAssertNotNil(task.updated)
    }
    
    func testTaskWithFullDetails() {
        let dueDate = Date()
        let task = Task(
            title: "Complete Project",
            plan: "Work",
            status: "In Progress",
            dueDate: dueDate,
            tags: ["urgent", "frontend"],
            body: "This is a detailed description"
        )
        
        XCTAssertEqual(task.title, "Complete Project")
        XCTAssertEqual(task.plan, "Work")
        XCTAssertEqual(task.status, "In Progress")
        XCTAssertEqual(task.dueDate, dueDate)
        XCTAssertEqual(task.tags.count, 2)
        XCTAssertTrue(task.tags.contains("urgent"))
        XCTAssertTrue(task.tags.contains("frontend"))
        XCTAssertEqual(task.body, "This is a detailed description")
    }
    
    func testTaskFileName() {
        let task = Task(title: "My Important Task", plan: "Work", status: "To Do")
        XCTAssertEqual(task.fileName, "my-important-task.md")
    }
    
    func testTaskFileNameWithSpecialCharacters() {
        let task = Task(title: "Fix Bug #123: Error in API", plan: "Work", status: "To Do")
        XCTAssertEqual(task.fileName, "fix-bug-123-error-in-api.md")
    }
    
    func testTaskFileNameNormalization() {
        let task = Task(title: "Task   With    Multiple   Spaces", plan: "Work", status: "To Do")
        let fileName = task.fileName
        // Should normalize multiple spaces to single hyphens
        XCTAssertTrue(fileName.contains("task") && fileName.contains("with") && fileName.hasSuffix(".md"))
    }
    
    func testTaskEquality() {
        let id = UUID()
        let task1 = Task(id: id, title: "Task A", plan: "Plan A", status: "To Do")
        let task2 = Task(id: id, title: "Task A", plan: "Plan A", status: "To Do")
        
        XCTAssertEqual(task1.id, task2.id)
        XCTAssertEqual(task1.title, task2.title)
    }
    
    func testTaskIdentifiability() {
        let task1 = Task(title: "Task 1", plan: "Plan", status: "To Do")
        let task2 = Task(title: "Task 2", plan: "Plan", status: "To Do")
        XCTAssertNotEqual(task1.id, task2.id)
    }
    
    func testTaskFileNameEmptySlugFallsBackToUUID() {
        // Title made entirely of emoji → slug is empty → must not produce ".md"
        let task = Task(title: "🎉🚀💫", plan: "Work", status: "To Do")
        XCTAssertNotEqual(task.fileName, ".md", "Empty slug must fall back to UUID, not produce a hidden file")
        XCTAssertTrue(task.fileName.hasSuffix(".md"))
        XCTAssertFalse(task.fileName.hasPrefix("."))
    }

    func testTaskFileNameAllSpecialCharsFallsBackToUUID() {
        let task = Task(title: "!!!###$$$", plan: "Work", status: "To Do")
        XCTAssertNotEqual(task.fileName, ".md")
        XCTAssertFalse(task.fileName.hasPrefix("."))
    }

    func testTaskFileNameOnlySpacesFallsBackToUUID() {
        let task = Task(title: "   ", plan: "Work", status: "To Do")
        XCTAssertNotEqual(task.fileName, ".md")
        XCTAssertFalse(task.fileName.hasPrefix("."))
    }
}
