//
//  TaskCreationTests.swift
//  TaskToolTests
//

import XCTest
@testable import TaskTool

@MainActor
final class TaskCreationTests: XCTestCase {
    var taskStore: TaskStore!
    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        taskStore = TaskStore()
        // Bypass the security-scoped resource guard that is only relevant in the
        // sandboxed production app, not in the unit-test environment.
        taskStore.storageURL = tempDirectory
        taskStore.loadAllData()
    }

    override func tearDown() async throws {
        if let dir = tempDirectory, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        taskStore = nil
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testTaskIsCreatedInSelectedPlan() throws {
        let workPlan = Plan(name: "Work", color: "blue", order: 0)
        let personalPlan = Plan(name: "Personal", color: "green", order: 1)
        try taskStore.createPlan(workPlan)
        try taskStore.createPlan(personalPlan)
        XCTAssertEqual(taskStore.plans.count, 2)

        let task = Task(title: "Buy groceries", plan: "Personal", status: "To Do")
        try taskStore.createTask(task)

        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertEqual(taskStore.tasks.first?.plan, "Personal")
        XCTAssertEqual(taskStore.tasks.first?.title, "Buy groceries")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDirectory.appendingPathComponent("Personal/buy-groceries.md").path
            ), "Task file should exist in Personal folder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDirectory.appendingPathComponent("Work/buy-groceries.md").path
            ), "Task file should NOT exist in Work folder"
        )
    }

    func testTaskCreatedInCorrectPlanWhenMultiplePlansExist() throws {
        try taskStore.createPlan(Plan(name: "First", color: "blue", order: 0))
        try taskStore.createPlan(Plan(name: "Second", color: "green", order: 1))
        try taskStore.createPlan(Plan(name: "Third", color: "red", order: 2))

        try taskStore.createTask(Task(title: "Task in First", plan: "First", status: "To Do"))
        try taskStore.createTask(Task(title: "Task in Third", plan: "Third", status: "To Do"))
        try taskStore.createTask(Task(title: "Another in Second", plan: "Second", status: "To Do"))

        XCTAssertEqual(taskStore.tasks.count, 3)
        XCTAssertEqual(taskStore.tasks.filter { $0.plan == "First" }.count, 1)
        XCTAssertEqual(taskStore.tasks.filter { $0.plan == "Second" }.count, 1)
        XCTAssertEqual(taskStore.tasks.filter { $0.plan == "Third" }.count, 1)
        XCTAssertEqual(taskStore.tasks.first(where: { $0.plan == "Second" })?.title, "Another in Second")
    }

    func testTaskCreatedWithDefaultStatusFromPlan() throws {
        var customPlan = Plan(name: "Custom", color: "purple", order: 0)
        customPlan.statuses = [
            Plan.TaskStatus(name: "Backlog", color: "gray", order: 0),
            Plan.TaskStatus(name: "Active", color: "blue", order: 1),
            Plan.TaskStatus(name: "Complete", color: "green", order: 2)
        ]
        try taskStore.createPlan(customPlan)

        let task = Task(title: "New Feature", plan: "Custom",
                        status: customPlan.statuses.sorted { $0.order < $1.order }.first!.name)
        try taskStore.createTask(task)

        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertEqual(taskStore.tasks.first?.status, "Backlog")
    }
}

