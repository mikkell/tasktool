//
//  TaskCreationTests.swift
//  TaskToolTests
//
//  Created by GitHub Copilot CLI on 28/01/2026.
//

import XCTest
@testable import TaskTool

@MainActor
final class TaskCreationTests: XCTestCase {
    var taskStore: TaskStore!
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create a temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Initialize TaskStore
        taskStore = TaskStore()
        taskStore.setStorageLocation(tempDirectory)
    }
    
    override func tearDown() async throws {
        // Clean up temporary directory
        if FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        taskStore = nil
        tempDirectory = nil
        
        try await super.tearDown()
    }
    
    func testTaskIsCreatedInSelectedPlan() throws {
        // Given: Multiple plans exist
        let workPlan = Plan(name: "Work", color: "blue", order: 0)
        let personalPlan = Plan(name: "Personal", color: "green", order: 1)
        
        print("🧪 Creating Work plan...")
        try taskStore.createPlan(workPlan)
        print("🧪 Creating Personal plan...")
        try taskStore.createPlan(personalPlan)
        
        // Verify plans are created
        print("🧪 Plans in store: \(taskStore.plans.map { $0.name })")
        XCTAssertEqual(taskStore.plans.count, 2)
        
        // When: A task is created for the "Personal" plan (not the first one)
        let task = Task(
            title: "Buy groceries",
            plan: personalPlan.name,
            status: "To Do"
        )
        
        print("🧪 Creating task with plan: '\(task.plan)'")
        try taskStore.createTask(task)
        print("🧪 Task created. Tasks in store: \(taskStore.tasks.count)")
        
        // Then: The task should be in the "Personal" plan
        XCTAssertEqual(taskStore.tasks.count, 1)
        let createdTask = taskStore.tasks.first!
        print("🧪 Created task plan: '\(createdTask.plan)', expected: 'Personal'")
        XCTAssertEqual(createdTask.plan, "Personal", "Task should be created in the selected 'Personal' plan, not in 'Work'")
        XCTAssertEqual(createdTask.title, "Buy groceries")
        
        // Verify the file is in the correct folder
        let personalFolder = tempDirectory.appendingPathComponent("Personal")
        let taskFile = personalFolder.appendingPathComponent(task.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taskFile.path), "Task file should exist in Personal folder")
        
        // Verify the file is NOT in the wrong folder
        let workFolder = tempDirectory.appendingPathComponent("Work")
        let wrongTaskFile = workFolder.appendingPathComponent(task.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongTaskFile.path), "Task file should NOT exist in Work folder")
    }
    
    func testTaskCreatedInCorrectPlanWhenMultiplePlansExist() throws {
        // Given: Three plans with different orders
        let plan1 = Plan(name: "First", color: "blue", order: 0)
        let plan2 = Plan(name: "Second", color: "green", order: 1)
        let plan3 = Plan(name: "Third", color: "red", order: 2)
        
        try taskStore.createPlan(plan1)
        try taskStore.createPlan(plan2)
        try taskStore.createPlan(plan3)
        
        // When: Tasks are created in different plans
        let task1 = TaskTool.Task(title: "Task in First", plan: "First", status: "To Do")
        let task2 = TaskTool.Task(title: "Task in Third", plan: "Third", status: "To Do")
        let task3 = TaskTool.Task(title: "Another task in Second", plan: "Second", status: "To Do")
        
        try taskStore.createTask(task1)
        try taskStore.createTask(task2)
        try taskStore.createTask(task3)
        
        // Then: Each task should be in its correct plan
        XCTAssertEqual(taskStore.tasks.count, 3)
        
        let firstPlanTasks = taskStore.tasks.filter { $0.plan == "First" }
        XCTAssertEqual(firstPlanTasks.count, 1)
        XCTAssertEqual(firstPlanTasks.first?.title, "Task in First")
        
        let secondPlanTasks = taskStore.tasks.filter { $0.plan == "Second" }
        XCTAssertEqual(secondPlanTasks.count, 1)
        XCTAssertEqual(secondPlanTasks.first?.title, "Another task in Second")
        
        let thirdPlanTasks = taskStore.tasks.filter { $0.plan == "Third" }
        XCTAssertEqual(thirdPlanTasks.count, 1)
        XCTAssertEqual(thirdPlanTasks.first?.title, "Task in Third")
    }
    
    func testTaskCreatedWithDefaultStatusFromPlan() throws {
        // Given: A plan with custom statuses
        var customPlan = Plan(name: "Custom", color: "purple", order: 0)
        customPlan.statuses = [
            Plan.TaskStatus(name: "Backlog", color: "gray", order: 0),
            Plan.TaskStatus(name: "Active", color: "blue", order: 1),
            Plan.TaskStatus(name: "Complete", color: "green", order: 2)
        ]
        
        try taskStore.createPlan(customPlan)
        
        // When: A task is created with the first status of the plan
        let task = TaskTool.Task(
            title: "New Feature",
            plan: customPlan.name,
            status: customPlan.statuses.first!.name
        )
        
        try taskStore.createTask(task)
        
        // Then: The task should have the correct status
        XCTAssertEqual(taskStore.tasks.count, 1)
        let createdTask = taskStore.tasks.first!
        XCTAssertEqual(createdTask.plan, "Custom")
        XCTAssertEqual(createdTask.status, "Backlog")
    }
}
