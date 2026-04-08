//
//  TaskStoreTests.swift
//  TaskToolTests
//

import XCTest
@testable import TaskTool

@MainActor
final class TaskStoreTests: XCTestCase {

    var taskStore: TaskStore!
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        taskStore = TaskStore()
        taskStore.storageURL = tempDir
        taskStore.loadAllData()
    }

    override func tearDown() async throws {
        if let d = tempDir, FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.removeItem(at: d)
        }
        taskStore = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Initialisation

    func testTaskStoreCanBeCreated() {
        let store = TaskStore()
        XCTAssertNotNil(store)
        XCTAssertNil(store.storageURL)
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    // MARK: - Plan – create

    func testCreatePlanWritesPlanYaml() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let file = tempDir.appendingPathComponent("Work/plan.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCreatePlanAddsToPlansArray() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        XCTAssertEqual(taskStore.plans.count, 1)
        XCTAssertEqual(taskStore.plans.first?.name, "Work")
    }

    func testCreateMultiplePlans() throws {
        try taskStore.createPlan(Plan(name: "Alpha", color: "blue"))
        try taskStore.createPlan(Plan(name: "Beta", color: "green"))
        try taskStore.createPlan(Plan(name: "Gamma", color: "red"))
        XCTAssertEqual(taskStore.plans.count, 3)
    }

    func testCreatePlanUpdatesSettingsOrder() throws {
        try taskStore.createPlan(Plan(name: "Alpha", color: "blue"))
        try taskStore.createPlan(Plan(name: "Beta", color: "green"))
        XCTAssertEqual(taskStore.settings.planOrder, ["Alpha", "Beta"])
    }

    func testCreatePlanAssignsIncrementingOrder() throws {
        try taskStore.createPlan(Plan(name: "First", color: "blue"))
        try taskStore.createPlan(Plan(name: "Second", color: "green"))
        let sorted = taskStore.plans.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map { $0.name }, ["First", "Second"])
    }

    // MARK: - Plan – update

    func testUpdatePlanWritesChangesToFile() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)

        var updated = plan
        updated.color = "purple"
        updated.description = "Updated"
        try taskStore.updatePlan(updated)

        let content = try String(contentsOf: tempDir.appendingPathComponent("Work/plan.yaml"))
        XCTAssertTrue(content.contains("purple"))
        XCTAssertTrue(content.contains("Updated"))
    }

    func testUpdatePlanReflectsInMemory() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        var updated = plan
        updated.color = "orange"
        try taskStore.updatePlan(updated)
        XCTAssertEqual(taskStore.plans.first(where: { $0.id == plan.id })?.color, "orange")
    }

    // MARK: - Plan – rename

    func testRenamePlanRenamesFolderOnDisk() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.renamePlan(plan, to: "NewName")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("OldName").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("NewName").path))
    }

    func testRenamePlanUpdatesInMemoryPlanName() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.renamePlan(plan, to: "NewName")
        XCTAssertNotNil(taskStore.plans.first(where: { $0.name == "NewName" }))
        XCTAssertNil(taskStore.plans.first(where: { $0.name == "OldName" }))
    }

    func testRenamePlanUpdatesTaskPlanField() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "My Task", plan: "OldName", status: "To Do")
        try taskStore.createTask(task)

        try taskStore.renamePlan(plan, to: "NewName")
        XCTAssertEqual(taskStore.tasks.first?.plan, "NewName")
    }

    func testRenamePlanMovesTaskFilesToNewFolder() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.createTask(Task(title: "My Task", plan: "OldName", status: "To Do"))

        try taskStore.renamePlan(plan, to: "NewName")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("NewName/my-task.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("OldName/my-task.md").path))
    }

    func testRenamePlanUpdatesSettingsPlanOrder() throws {
        let plan = Plan(name: "Alpha", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.renamePlan(plan, to: "Renamed")
        XCTAssertTrue(taskStore.settings.planOrder.contains("Renamed"))
        XCTAssertFalse(taskStore.settings.planOrder.contains("Alpha"))
    }

    // MARK: - Plan – delete

    func testDeletePlanRemovesFolderFromDisk() throws {
        let plan = Plan(name: "DeleteMe", color: "red")
        try taskStore.createPlan(plan)
        let folderPath = tempDir.appendingPathComponent("DeleteMe").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderPath))

        try taskStore.deletePlan(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderPath))
    }

    func testDeletePlanRemovesFromPlansArray() throws {
        let plan = Plan(name: "GoneNow", color: "red")
        try taskStore.createPlan(plan)
        try taskStore.deletePlan(plan)
        XCTAssertEqual(taskStore.plans.count, 0)
    }

    func testDeletePlanRemovesItsTasksFromArray() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.createTask(Task(title: "A task", plan: "Work", status: "To Do"))
        XCTAssertEqual(taskStore.tasks.count, 1)

        try taskStore.deletePlan(plan)
        XCTAssertEqual(taskStore.tasks.count, 0)
    }

    func testDeletePlanRemovesFromSettingsPlanOrder() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.deletePlan(plan)
        XCTAssertFalse(taskStore.settings.planOrder.contains("Work"))
    }

    // MARK: - Task – create

    func testCreateTaskWritesMarkdownFile() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "Do something", plan: "Work", status: "To Do"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/do-something.md").path))
    }

    func testCreateTaskAddsToTasksArray() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "Task A", plan: "Work", status: "To Do"))
        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertEqual(taskStore.tasks.first?.title, "Task A")
    }

    func testCreateTaskInCorrectPlanFolder() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createPlan(Plan(name: "Personal", color: "green"))
        try taskStore.createTask(Task(title: "Buy milk", plan: "Personal", status: "To Do"))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Personal/buy-milk.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/buy-milk.md").path))
    }

    func testCreateTaskInNonExistentPlanThrows() {
        XCTAssertThrowsError(
            try taskStore.createTask(Task(title: "Ghost", plan: "NoSuchPlan", status: "To Do"))
        )
    }

    func testCreateTaskFileContainsFrontmatter() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Frontmatter Task", plan: "Work", status: "In Progress",
                        tags: ["tag1"], body: "Body content")
        try taskStore.createTask(task)

        let content = try String(contentsOf: tempDir.appendingPathComponent("Work/frontmatter-task.md"))
        XCTAssertTrue(content.contains("status: In Progress"))
        XCTAssertTrue(content.contains("- tag1"))
        XCTAssertTrue(content.contains("# Frontmatter Task"))
        XCTAssertTrue(content.contains("Body content"))
    }

    func testCreateTaskFilenameCollisionKeepsBothFiles() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "Duplicate Task", plan: "Work", status: "To Do"))
        try taskStore.createTask(Task(title: "Duplicate Task", plan: "Work", status: "In Progress"))

        XCTAssertEqual(taskStore.tasks.count, 2)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: tempDir.appendingPathComponent("Work").path)
        let mdFiles = files.filter { $0.hasSuffix(".md") }
        XCTAssertEqual(mdFiles.count, 2, "Both tasks must get distinct files — no overwrite")
    }

    func testCreateTaskWithEmojiTitleDoesNotCreateHiddenFile() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "🎉🚀💫", plan: "Work", status: "To Do"))

        let files = try FileManager.default.contentsOfDirectory(
            atPath: tempDir.appendingPathComponent("Work").path)
        let mdFiles = files.filter { $0.hasSuffix(".md") }
        XCTAssertEqual(mdFiles.count, 1)
        XCTAssertFalse(mdFiles.first!.hasPrefix("."), "Emoji title must not produce a hidden .md file")
    }

    // MARK: - Task – update

    func testUpdateTaskStatusWritesToFile() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "My Task", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var updated = task; updated.status = "Done"
        try taskStore.updateTask(updated)

        let content = try String(contentsOf: tempDir.appendingPathComponent("Work/my-task.md"))
        XCTAssertTrue(content.contains("status: Done"))
    }

    func testUpdateTaskStatusReflectsInMemory() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Status Task", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var updated = task; updated.status = "In Progress"
        try taskStore.updateTask(updated)

        XCTAssertEqual(taskStore.tasks.first?.status, "In Progress")
    }

    func testUpdateTaskMoveToNewPlan_NewFileExists() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createPlan(Plan(name: "Personal", color: "green"))
        let task = Task(title: "Move Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var moved = task; moved.plan = "Personal"
        try taskStore.updateTask(moved)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Personal/move-me.md").path))
    }

    func testUpdateTaskMoveToNewPlan_OldFileGone() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createPlan(Plan(name: "Personal", color: "green"))
        let task = Task(title: "Move Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var moved = task; moved.plan = "Personal"
        try taskStore.updateTask(moved)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/move-me.md").path))
    }

    func testUpdateTaskMoveToNewPlan_InMemoryPlanUpdated() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createPlan(Plan(name: "Personal", color: "green"))
        let task = Task(title: "Move Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var moved = task; moved.plan = "Personal"
        try taskStore.updateTask(moved)

        XCTAssertEqual(taskStore.tasks.first?.plan, "Personal")
    }

    func testUpdateTaskTitleRenamesFile() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Old Title", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var renamed = task; renamed.title = "New Title"
        try taskStore.updateTask(renamed)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/new-title.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/old-title.md").path))
    }

    func testUpdateTaskSetsUpdatedTimestamp() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let oneHourAgo = Date(timeIntervalSinceNow: -3600)
        let task = Task(id: UUID(), title: "Timestamp Task", plan: "Work",
                        status: "To Do", updated: oneHourAgo)
        try taskStore.createTask(task)

        var updated = task; updated.status = "Done"
        try taskStore.updateTask(updated)

        let stored = taskStore.tasks.first(where: { $0.id == task.id })
        XCTAssertNotNil(stored)
        XCTAssertGreaterThan(stored!.updated, oneHourAgo)
    }

    // MARK: - Task – delete

    func testDeleteTaskRemovesFileFromDisk() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Delete Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)
        let file = tempDir.appendingPathComponent("Work/delete-me.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try taskStore.deleteTask(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteTaskRemovesFromTasksArray() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Delete Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)
        XCTAssertEqual(taskStore.tasks.count, 1)

        try taskStore.deleteTask(task)
        XCTAssertEqual(taskStore.tasks.count, 0)
    }

    func testDeleteNonExistentTaskFileThrows() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let phantom = Task(title: "Never Written", plan: "Work", status: "To Do")
        taskStore.tasks.append(phantom)  // stale in-memory reference
        XCTAssertThrowsError(try taskStore.deleteTask(phantom))
    }

    // MARK: - Archive

    func testArchiveTasksMovesFileToArchivedSubfolder() throws {
        let plan = Plan(name: "Work", color: "blue", statuses: [
            Plan.TaskStatus(name: "To Do", color: "gray", order: 0),
            Plan.TaskStatus(name: "Done", color: "green", order: 1)
        ])
        try taskStore.createPlan(plan)
        let task = Task(title: "Archive Me", plan: "Work", status: "Done")
        try taskStore.createTask(task)

        try taskStore.archiveDoneTasks(for: plan, tasks: [task])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/Archived/archive-me.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/archive-me.md").path))
    }

    func testArchiveTasksRemovesFromTasksArray() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Done task", plan: "Work", status: "Done")
        try taskStore.createTask(task)
        XCTAssertEqual(taskStore.tasks.count, 1)

        try taskStore.archiveDoneTasks(for: plan, tasks: [task])
        XCTAssertEqual(taskStore.tasks.count, 0)
    }

    func testArchiveCreatesArchivedFolderIfMissing() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Done work", plan: "Work", status: "Done")
        try taskStore.createTask(task)

        try taskStore.archiveDoneTasks(for: plan, tasks: [task])

        let archivePath = tempDir.appendingPathComponent("Work/Archived").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath))
    }

    // MARK: - Persistence / loadAllData

    func testLoadAllDataLoadsSavedPlans() throws {
        try taskStore.createPlan(Plan(name: "Persist", color: "green"))

        let fresh = TaskStore()
        fresh.storageURL = tempDir
        fresh.loadAllData()

        XCTAssertEqual(fresh.plans.count, 1)
        XCTAssertEqual(fresh.plans.first?.name, "Persist")
    }

    func testLoadAllDataLoadsSavedTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Loaded Task", plan: "Work", status: "In Progress",
                        tags: ["tag1"], body: "body text")
        try taskStore.createTask(task)

        let fresh = TaskStore()
        fresh.storageURL = tempDir
        fresh.loadAllData()

        XCTAssertEqual(fresh.tasks.count, 1)
        let loaded = fresh.tasks.first!
        XCTAssertEqual(loaded.title, "Loaded Task")
        XCTAssertEqual(loaded.status, "In Progress")
        XCTAssertEqual(loaded.tags, ["tag1"])
        XCTAssertEqual(loaded.body, "body text")
    }

    func testLoadAllDataPreservesPlanOrder() throws {
        try taskStore.createPlan(Plan(name: "Zeta", color: "blue"))
        try taskStore.createPlan(Plan(name: "Alpha", color: "green"))
        try taskStore.createPlan(Plan(name: "Mid", color: "red"))

        let fresh = TaskStore()
        fresh.storageURL = tempDir
        fresh.loadAllData()

        let names = fresh.plans.sorted { $0.order < $1.order }.map { $0.name }
        XCTAssertEqual(names, ["Zeta", "Alpha", "Mid"])
    }

    func testLoadAllDataSkipsDirectoriesWithoutPlanYaml() throws {
        // Stray directory with no plan.yaml — must not appear as a plan
        let strayDir = tempDir.appendingPathComponent("StrayFolder")
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)

        taskStore.loadAllData()

        XCTAssertFalse(taskStore.plans.contains(where: { $0.name == "StrayFolder" }))
    }

    func testLoadAllDataDoesNotLoadArchivedTasksAsPlanTasks() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Done work", plan: "Work", status: "Done")
        try taskStore.createTask(task)
        try taskStore.archiveDoneTasks(for: plan, tasks: [task])

        let fresh = TaskStore()
        fresh.storageURL = tempDir
        fresh.loadAllData()

        // Archived task should not show up, and "Archived" should not be a plan
        XCTAssertEqual(fresh.tasks.count, 0)
        XCTAssertFalse(fresh.plans.contains(where: { $0.name == "Archived" }))
    }

    // MARK: - Settings

    func testSaveAndLoadSettings() throws {
        taskStore.settings = Settings(planOrder: ["X", "Y", "Z"])
        try taskStore.saveSettings()

        let fresh = TaskStore()
        fresh.storageURL = tempDir
        fresh.loadAllData()

        XCTAssertEqual(fresh.settings.planOrder, ["X", "Y", "Z"])
    }

    func testSettingsFileCreatedOnFirstLoad() {
        let settingsPath = tempDir.appendingPathComponent("settings.yaml").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsPath))
    }
}

