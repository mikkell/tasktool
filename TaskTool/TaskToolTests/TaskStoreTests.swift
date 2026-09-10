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
        var updated = plan; updated.name = "NewName"
        try taskStore.renamePlan(plan, to: updated)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("OldName").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("NewName").path))
    }

    func testRenamePlanUpdatesInMemoryPlanName() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        var updated = plan; updated.name = "NewName"
        try taskStore.renamePlan(plan, to: updated)
        XCTAssertNotNil(taskStore.plans.first(where: { $0.name == "NewName" }))
        XCTAssertNil(taskStore.plans.first(where: { $0.name == "OldName" }))
    }

    func testRenamePlanUpdatesTaskPlanField() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "My Task", plan: "OldName", status: "To Do")
        try taskStore.createTask(task)

        var updated = plan; updated.name = "NewName"
        try taskStore.renamePlan(plan, to: updated)
        XCTAssertEqual(taskStore.tasks.first?.plan, "NewName")
    }

    func testRenamePlanMovesTaskFilesToNewFolder() throws {
        let plan = Plan(name: "OldName", color: "blue")
        try taskStore.createPlan(plan)
        try taskStore.createTask(Task(title: "My Task", plan: "OldName", status: "To Do"))

        var updated = plan; updated.name = "NewName"
        try taskStore.renamePlan(plan, to: updated)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("NewName/my-task.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("OldName/my-task.md").path))
    }

    func testRenamePlanUpdatesSettingsPlanOrder() throws {
        let plan = Plan(name: "Alpha", color: "blue")
        try taskStore.createPlan(plan)
        var updated = plan; updated.name = "Renamed"
        try taskStore.renamePlan(plan, to: updated)
        XCTAssertTrue(taskStore.settings.planOrder.contains("Renamed"))
        XCTAssertFalse(taskStore.settings.planOrder.contains("Alpha"))
    }

    func testRenamePlanAlsoUpdatesDescriptionAndColor() throws {
        // Simulates the full UI flow in EditPlanView.savePlan() where rename + property
        // changes are merged into a single renamePlan call.
        let plan = Plan(name: "OldName", color: "blue", description: "old desc")
        try taskStore.createPlan(plan)
        var updated = plan
        updated.name = "NewName"
        updated.color = "green"
        updated.description = "new desc"
        try taskStore.renamePlan(plan, to: updated)

        let saved = taskStore.plans.first(where: { $0.id == plan.id })
        XCTAssertEqual(saved?.name, "NewName")
        XCTAssertEqual(saved?.color, "green")
        XCTAssertEqual(saved?.description, "new desc")

        // Verify plan.yaml on disk contains the new values.
        let yaml = try String(
            contentsOf: tempDir.appendingPathComponent("NewName/plan.yaml"),
            encoding: .utf8)
        XCTAssertTrue(yaml.contains("NewName"))
        XCTAssertTrue(yaml.contains("green"))
        XCTAssertTrue(yaml.contains("new desc"))
    }


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

    // MARK: - Undo delete

    func testDeleteTaskWithUndoSetsPendingUndo() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Delete Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        try taskStore.deleteTaskWithUndo(task)

        XCTAssertEqual(taskStore.tasks.count, 0)
        XCTAssertNotNil(taskStore.pendingUndo)
        XCTAssertTrue(taskStore.pendingUndo?.message.contains("Delete Me") ?? false)
    }

    func testUndoingTaskDeleteRestoresFileAndInMemoryTask() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Delete Me", plan: "Work", status: "To Do", tags: ["urgent"])
        try taskStore.createTask(task)
        let file = tempDir.appendingPathComponent("Work/delete-me.md")

        try taskStore.deleteTaskWithUndo(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        taskStore.pendingUndo?.undo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertEqual(taskStore.tasks.first?.id, task.id)
        XCTAssertEqual(taskStore.tasks.first?.tags, ["urgent"])
    }

    func testDismissPendingUndoClearsIt() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Delete Me", plan: "Work", status: "To Do")
        try taskStore.createTask(task)
        try taskStore.deleteTaskWithUndo(task)
        XCTAssertNotNil(taskStore.pendingUndo)

        taskStore.dismissPendingUndo()
        XCTAssertNil(taskStore.pendingUndo)
    }

    func testDeletePlanWithUndoSetsPendingUndo() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "Task A", plan: "Work", status: "To Do"))

        let plan = taskStore.plans.first { $0.name == "Work" }!
        try taskStore.deletePlanWithUndo(plan)

        XCTAssertTrue(taskStore.plans.isEmpty)
        XCTAssertNotNil(taskStore.pendingUndo)
        XCTAssertTrue(taskStore.pendingUndo?.message.contains("Work") ?? false)
    }

    func testUndoingPlanDeleteRestoresPlanAndTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "Task A", plan: "Work", status: "To Do"))
        try taskStore.createTask(Task(title: "Task B", plan: "Work", status: "In Progress"))

        let plan = taskStore.plans.first { $0.name == "Work" }!
        let planFolder = tempDir.appendingPathComponent("Work")

        try taskStore.deletePlanWithUndo(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFolder.path))

        taskStore.pendingUndo?.undo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: planFolder.appendingPathComponent("plan.yaml").path))
        XCTAssertEqual(taskStore.plans.count, 1)
        XCTAssertEqual(taskStore.tasks.count, 2)
        XCTAssertEqual(Set(taskStore.tasks.map { $0.title }), Set(["Task A", "Task B"]))
        XCTAssertTrue(taskStore.settings.planOrder.contains("Work"))
    }

    // MARK: - Bulk multi-select actions

    func testDeleteTasksWithUndoRemovesAllAndOffersSingleUndo() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let taskA = Task(title: "Task A", plan: "Work", status: "To Do")
        let taskB = Task(title: "Task B", plan: "Work", status: "To Do")
        try taskStore.createTask(taskA)
        try taskStore.createTask(taskB)

        try taskStore.deleteTasksWithUndo([taskA, taskB])

        XCTAssertEqual(taskStore.tasks.count, 0)
        XCTAssertNotNil(taskStore.pendingUndo)
        XCTAssertTrue(taskStore.pendingUndo?.message.contains("2") ?? false)
    }

    func testUndoingBulkDeleteRestoresAllTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let taskA = Task(title: "Task A", plan: "Work", status: "To Do")
        let taskB = Task(title: "Task B", plan: "Work", status: "To Do")
        try taskStore.createTask(taskA)
        try taskStore.createTask(taskB)

        try taskStore.deleteTasksWithUndo([taskA, taskB])
        taskStore.pendingUndo?.undo()

        XCTAssertEqual(taskStore.tasks.count, 2)
        XCTAssertEqual(Set(taskStore.tasks.map { $0.title }), Set(["Task A", "Task B"]))
    }

    func testMoveTasksToPlanUpdatesPlanAndMapsUnmatchedStatus() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createPlan(Plan(name: "Personal", color: "green"))
        let taskA = Task(title: "Task A", plan: "Work", status: "In Progress")
        try taskStore.createTask(taskA)

        let personal = taskStore.plans.first { $0.name == "Personal" }!
        try taskStore.moveTasks([taskA], toPlan: personal)

        let moved = taskStore.tasks.first { $0.id == taskA.id }
        XCTAssertEqual(moved?.plan, "Personal")
        // "In Progress" exists in the default Personal plan statuses, so it should carry over.
        XCTAssertEqual(moved?.status, "In Progress")
    }

    func testMoveTasksToPlanMapsToFirstStatusWhenNoMatch() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        var customPlan = Plan(name: "Custom", color: "green")
        customPlan.statuses = [
            Plan.TaskStatus(name: "Backlog", color: "gray", order: 0),
            Plan.TaskStatus(name: "Shipped", color: "green", order: 1)
        ]
        try taskStore.createPlan(customPlan)

        let taskA = Task(title: "Task A", plan: "Work", status: "In Progress")
        try taskStore.createTask(taskA)

        let target = taskStore.plans.first { $0.name == "Custom" }!
        try taskStore.moveTasks([taskA], toPlan: target)

        let moved = taskStore.tasks.first { $0.id == taskA.id }
        XCTAssertEqual(moved?.plan, "Custom")
        XCTAssertEqual(moved?.status, "Backlog")
    }

    func testMoveTasksToStatusUpdatesAllSelectedTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let taskA = Task(title: "Task A", plan: "Work", status: "To Do")
        let taskB = Task(title: "Task B", plan: "Work", status: "To Do")
        try taskStore.createTask(taskA)
        try taskStore.createTask(taskB)

        try taskStore.moveTasks([taskA, taskB], toStatus: "Done")

        XCTAssertEqual(taskStore.tasks.filter { $0.status == "Done" }.count, 2)
    }

    // MARK: - Task deduplication

    func testLoadAllDataDeduplicatesByUUID() throws {
        // Simulate an OneDrive sync conflict: two .md files in the same plan folder
        // share the same UUID. loadAllData must produce exactly one task entry.
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)

        let sharedID = UUID()
        let older = Task(id: sharedID, title: "Task A", plan: "Work", status: "To Do",
                         updated: Date(timeIntervalSinceNow: -120))
        let newer = Task(id: sharedID, title: "Task A (updated)", plan: "Work", status: "In Progress",
                         updated: Date())

        let planFolder = tempDir.appendingPathComponent("Work")
        try MarkdownParser.serializeTask(older)
            .write(to: planFolder.appendingPathComponent("task-a-old.md"),
                   atomically: false, encoding: .utf8)
        try MarkdownParser.serializeTask(newer)
            .write(to: planFolder.appendingPathComponent("task-a-new.md"),
                   atomically: false, encoding: .utf8)

        taskStore.loadAllData()

        XCTAssertEqual(taskStore.tasks.filter { $0.id == sharedID }.count, 1,
                       "Duplicate UUIDs must be deduplicated on load")
        // The newer (higher `updated`) entry should win.
        XCTAssertEqual(taskStore.tasks.first(where: { $0.id == sharedID })?.status, "In Progress")
    }

    func testLoadAllDataPrefersCanonicalPlanOnDuplicateUUID() throws {
        // Simulate a cloud-sync conflict after a plan rename: both "Work" (stale) and
        // "MyWork" (canonical) folders exist on disk with the same task UUID.
        // The canonical plan's copy must win, and the stale "Work" plan must be removed.
        let canonical = Plan(name: "MyWork", color: "blue")
        try taskStore.createPlan(canonical)

        let sharedID = UUID()
        // Stale copy in old folder – same UUID, older timestamp
        let staleTask = Task(id: sharedID, title: "Task", plan: "Work", status: "To Do",
                             updated: Date(timeIntervalSinceNow: -60))
        // Canonical copy in new folder – same UUID, newer timestamp
        let canonicalTask = Task(id: sharedID, title: "Task", plan: "MyWork", status: "In Progress",
                                 updated: Date())

        // Write stale task into a manually-created "Work" folder (as if cloud sync put it there).
        let staleFolder = tempDir.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: staleFolder, withIntermediateDirectories: true)
        try MarkdownParser.serializePlan(Plan(name: "Work", color: "blue"))
            .write(to: staleFolder.appendingPathComponent("plan.yaml"),
                   atomically: false, encoding: .utf8)
        try MarkdownParser.serializeTask(staleTask)
            .write(to: staleFolder.appendingPathComponent("task.md"),
                   atomically: false, encoding: .utf8)

        // Write canonical task into the canonical "MyWork" folder.
        let canonicalFolder = tempDir.appendingPathComponent("MyWork")
        try MarkdownParser.serializeTask(canonicalTask)
            .write(to: canonicalFolder.appendingPathComponent("task.md"),
                   atomically: false, encoding: .utf8)

        taskStore.loadAllData()

        XCTAssertEqual(taskStore.tasks.filter { $0.id == sharedID }.count, 1,
                       "Duplicate UUID across plans must be deduplicated")
        XCTAssertEqual(taskStore.tasks.first(where: { $0.id == sharedID })?.plan, "MyWork",
                       "Canonical plan must win over stale plan")
        XCTAssertNil(taskStore.plans.first(where: { $0.name == "Work" }),
                     "Stale plan folder must be removed when all its tasks were absorbed by a canonical plan")
    }

    func testCreateTaskDoesNotDuplicateIfAlreadyInMemory() throws {
        // If loadAllData somehow ran between the file write and the tasks.append
        // inside createTask, the task would already be in memory. The guard must
        // prevent a second entry.
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)

        let task = Task(title: "My Task", plan: "Work", status: "To Do")
        try taskStore.createTask(task)
        XCTAssertEqual(taskStore.tasks.filter { $0.id == task.id }.count, 1)

        // Simulate the race: manually add the same task to memory again (as if
        // loadAllData ran concurrently), then call createTask again via a reload.
        taskStore.tasks.append(task)
        XCTAssertEqual(taskStore.tasks.filter { $0.id == task.id }.count, 2,
                       "Pre-condition: we manually created the duplicate")

        // A reload should collapse it back to one entry.
        taskStore.loadAllData()
        XCTAssertEqual(taskStore.tasks.filter { $0.id == task.id }.count, 1,
                       "loadAllData must remove the duplicate")
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

    func testArchiveTasksWithSubfolderMovesFileIntoNamedSubfolder() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Archive Me", plan: "Work", status: "Done")
        try taskStore.createTask(task)

        try taskStore.archiveDoneTasks(for: plan, tasks: [task], subfolder: "2026-09-07")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/Archived/2026-09-07/archive-me.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/Archived/archive-me.md").path))
    }

    func testArchiveTasksSanitizesSubfolderName() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Archive Me", plan: "Work", status: "Done")
        try taskStore.createTask(task)

        try taskStore.archiveDoneTasks(for: plan, tasks: [task], subfolder: "Week 31/2026")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Work/Archived/Week 31-2026/archive-me.md").path))
    }

    func testArchivingTwoBatchesWithSameSubfolderDoesNotOverwrite() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let taskA = Task(title: "Same Name", plan: "Work", status: "Done")
        try taskStore.createTask(taskA)
        try taskStore.archiveDoneTasks(for: plan, tasks: [taskA], subfolder: "2026-09-07")

        // taskA's file has now been moved out of "Work/", so a second task with the exact same
        // title creates the same slug filename with no collision suffix at creation time. Only
        // when it's archived into the SAME subfolder should the archive-time collision guard
        // kick in and avoid overwriting taskA's already-archived file.
        let taskB = Task(title: "Same Name", plan: "Work", status: "Done")
        try taskStore.createTask(taskB)
        try taskStore.archiveDoneTasks(for: plan, tasks: [taskB], subfolder: "2026-09-07")

        let subfolder = tempDir.appendingPathComponent("Work/Archived/2026-09-07")
        let contents = try FileManager.default.contentsOfDirectory(atPath: subfolder.path)
        XCTAssertEqual(contents.count, 2)
    }

    // MARK: - Bundling

    func testBundleTaskCreatesContainerWithBothTasks() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let target = Task(title: "Target", plan: "Work", status: "In Progress")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)

        try taskStore.bundleTask(dragged, onto: target)

        let container = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })
        XCTAssertEqual(container.title, "Bundle: Target")
        XCTAssertEqual(container.plan, "Work")
        XCTAssertEqual(container.status, "In Progress")
        XCTAssertEqual(Set(container.bundledTaskIDs), Set([target.id, dragged.id]))

        let updatedTarget = try XCTUnwrap(taskStore.tasks.first { $0.id == target.id })
        let updatedDragged = try XCTUnwrap(taskStore.tasks.first { $0.id == dragged.id })
        XCTAssertEqual(updatedTarget.parentBundleID, container.id)
        XCTAssertEqual(updatedDragged.parentBundleID, container.id)
        // Dragged task's status/plan are synced to match the container/target.
        XCTAssertEqual(updatedDragged.status, "In Progress")
    }

    func testBundleTaskAddsThirdTaskToExistingBundle() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let target = Task(title: "Target", plan: "Work", status: "To Do")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        let third = Task(title: "Third", plan: "Work", status: "Done")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)
        try taskStore.createTask(third)

        try taskStore.bundleTask(dragged, onto: target)
        let container = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })

        try taskStore.bundleTask(third, onto: container)

        let refreshedContainer = try XCTUnwrap(taskStore.tasks.first { $0.id == container.id })
        XCTAssertEqual(Set(refreshedContainer.bundledTaskIDs), Set([target.id, dragged.id, third.id]))
        let updatedThird = try XCTUnwrap(taskStore.tasks.first { $0.id == third.id })
        XCTAssertEqual(updatedThird.parentBundleID, container.id)
        XCTAssertEqual(updatedThird.status, "To Do")
    }

    func testBundleTaskNoOpsOnSelfDrop() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let task = Task(title: "Solo", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        try taskStore.bundleTask(task, onto: task)

        XCTAssertEqual(taskStore.tasks.count, 1)
        XCTAssertFalse(taskStore.tasks[0].isBundle)
    }

    func testBundleTaskNoOpsWhenDraggingABundleContainer() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let target = Task(title: "Target", plan: "Work", status: "To Do")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)
        try taskStore.bundleTask(dragged, onto: target)
        let bundleContainer = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })

        let other = Task(title: "Other", plan: "Work", status: "To Do")
        try taskStore.createTask(other)

        // Dragging the bundle container itself onto another task should no-op (nesting isn't supported).
        try taskStore.bundleTask(bundleContainer, onto: other)

        let refreshedOther = try XCTUnwrap(taskStore.tasks.first { $0.id == other.id })
        XCTAssertFalse(refreshedOther.isBundle)
        XCTAssertNil(refreshedOther.parentBundleID)
    }

    func testChildTasksReturnsBundledTasksInOrder() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let target = Task(title: "Target", plan: "Work", status: "To Do")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)
        try taskStore.bundleTask(dragged, onto: target)
        let container = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })

        let children = taskStore.childTasks(of: container)

        XCTAssertEqual(children.map(\.id), [target.id, dragged.id])
    }

    func testRemoveTaskFromBundleKeepsBundleWithThreeOrMoreRemaining() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let a = Task(title: "A", plan: "Work", status: "To Do")
        let b = Task(title: "B", plan: "Work", status: "To Do")
        let c = Task(title: "C", plan: "Work", status: "To Do")
        try taskStore.createTask(a)
        try taskStore.createTask(b)
        try taskStore.createTask(c)
        try taskStore.bundleTask(b, onto: a)
        var container = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })
        try taskStore.bundleTask(c, onto: container)
        container = try XCTUnwrap(taskStore.tasks.first { $0.id == container.id })

        let bAfterBundle = try XCTUnwrap(taskStore.tasks.first { $0.id == b.id })
        try taskStore.removeTaskFromBundle(bAfterBundle)

        let refreshedContainer = try XCTUnwrap(taskStore.tasks.first { $0.id == container.id })
        XCTAssertEqual(Set(refreshedContainer.bundledTaskIDs), Set([a.id, c.id]))
        let freedB = try XCTUnwrap(taskStore.tasks.first { $0.id == b.id })
        XCTAssertNil(freedB.parentBundleID)
    }

    func testRemoveTaskFromBundleDissolvesBundleWhenOneTaskRemains() throws {
        let plan = Plan(name: "Work", color: "blue")
        try taskStore.createPlan(plan)
        let target = Task(title: "Target", plan: "Work", status: "To Do")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)
        try taskStore.bundleTask(dragged, onto: target)
        let container = try XCTUnwrap(taskStore.tasks.first { $0.isBundle })

        let refreshedDragged = try XCTUnwrap(taskStore.tasks.first { $0.id == dragged.id })
        try taskStore.removeTaskFromBundle(refreshedDragged)

        // Bundle should have dissolved: container gone, last remaining task freed.
        XCTAssertNil(taskStore.tasks.first { $0.id == container.id })
        let freedTarget = try XCTUnwrap(taskStore.tasks.first { $0.id == target.id })
        XCTAssertNil(freedTarget.parentBundleID)
        XCTAssertFalse(freedTarget.isBundle)
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

    // MARK: - Tags

    func testCreateTaskRegistersNewTagsGlobally() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Fix bug", plan: "Work", status: "To Do", tags: ["bug", "auth"])
        try taskStore.createTask(task)

        XCTAssertEqual(Set(taskStore.settings.availableTags), Set(["bug", "auth"]))
    }

    func testUpdateTaskRegistersNewTagsGlobally() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Fix bug", plan: "Work", status: "To Do")
        try taskStore.createTask(task)

        var updated = task
        updated.tags = ["urgent"]
        try taskStore.updateTask(updated)

        XCTAssertTrue(taskStore.settings.availableTags.contains("urgent"))
    }

    func testRegisterTagsDoesNotDuplicateCaseInsensitively() throws {
        try taskStore.registerTags(["bug"])
        try taskStore.registerTags(["Bug", "auth"])

        XCTAssertEqual(taskStore.settings.availableTags.count, 2)
        XCTAssertTrue(taskStore.settings.availableTags.contains("bug"))
        XCTAssertTrue(taskStore.settings.availableTags.contains("auth"))
    }

    func testRenameGlobalTagUpdatesRegistryAndTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Fix bug", plan: "Work", status: "To Do", tags: ["bug"])
        try taskStore.createTask(task)

        try taskStore.renameGlobalTag(from: "bug", to: "defect")

        XCTAssertFalse(taskStore.settings.availableTags.contains("bug"))
        XCTAssertTrue(taskStore.settings.availableTags.contains("defect"))
        XCTAssertEqual(taskStore.tasks.first?.tags, ["defect"])

        // File on disk should reflect the rename too.
        let file = tempDir.appendingPathComponent("Work/fix-bug.md")
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(content.contains("defect"))
        XCTAssertFalse(content.contains("- bug"))
    }

    func testDeleteGlobalTagRemovesFromRegistryAndTasks() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let task = Task(title: "Fix bug", plan: "Work", status: "To Do", tags: ["bug", "urgent"])
        try taskStore.createTask(task)

        try taskStore.deleteGlobalTag("bug")

        XCTAssertFalse(taskStore.settings.availableTags.contains("bug"))
        XCTAssertEqual(taskStore.tasks.first?.tags, ["urgent"])
    }

    // MARK: - Plan deletion / status preservation

    // MARK: - Plan deletion / status preservation

    /// Regression: renaming a status column must migrate all tasks that had the old name.
    func testRenameStatusMigratesTasksToNewStatusName() throws {
        let original = Plan.TaskStatus(name: "In Progress", color: "blue", order: 1)
        let plan = Plan(name: "Work", color: "blue", statuses: [
            Plan.TaskStatus(name: "To Do", color: "gray", order: 0),
            original,
            Plan.TaskStatus(name: "Done", color: "green", order: 2)
        ])
        try taskStore.createPlan(plan)

        let task = Task(title: "Active task", plan: "Work", status: "In Progress")
        try taskStore.createTask(task)

        // Rename "In Progress" → "Doing" (same UUID, different name)
        var updatedPlan = taskStore.plans.first(where: { $0.name == "Work" })!
        let renamedStatus = Plan.TaskStatus(id: original.id, name: "Doing", color: "blue", order: 1)
        updatedPlan.statuses = [
            Plan.TaskStatus(name: "To Do", color: "gray", order: 0),
            renamedStatus,
            Plan.TaskStatus(name: "Done", color: "green", order: 2)
        ]
        try taskStore.updatePlan(updatedPlan)

        // In-memory task status must reflect the new name
        let inMemory = taskStore.tasks.first(where: { $0.id == task.id })
        XCTAssertEqual(inMemory?.status, "Doing")

        // On-disk task must also reflect the new name
        taskStore.loadAllData()
        let onDisk = taskStore.tasks.first(where: { $0.id == task.id })
        XCTAssertEqual(onDisk?.status, "Doing")
    }

    /// Regression test: saving Plan A's statuses then deleting Plan B must not revert
    /// Plan A's statuses — either in memory or on disk.
    func testDeletePlanDoesNotRevertAnotherPlansStatuses() throws {
        let customStatuses = [
            Plan.TaskStatus(name: "Todo", color: "gray", order: 0),
            Plan.TaskStatus(name: "Doing", color: "blue", order: 1),
            Plan.TaskStatus(name: "Review", color: "orange", order: 2),
            Plan.TaskStatus(name: "Done", color: "green", order: 3)
        ]
        var planA = Plan(name: "Alpha", color: "blue", statuses: Plan.defaultStatuses())
        let planB = Plan(name: "Beta", color: "red")

        try taskStore.createPlan(planA)
        try taskStore.createPlan(planB)

        // Update Plan A with custom statuses and persist them
        planA = taskStore.plans.first(where: { $0.name == "Alpha" })!
        planA.statuses = customStatuses
        try taskStore.updatePlan(planA)

        // Verify statuses are in memory
        XCTAssertEqual(taskStore.plans.first(where: { $0.name == "Alpha" })?.statuses.count, 4)

        // Delete the unrelated plan
        let planBLoaded = taskStore.plans.first(where: { $0.name == "Beta" })!
        try taskStore.deletePlan(planBLoaded)

        // In-memory statuses must be unchanged
        let inMemory = taskStore.plans.first(where: { $0.name == "Alpha" })
        XCTAssertNotNil(inMemory)
        XCTAssertEqual(inMemory?.statuses.count, 4)
        XCTAssertEqual(inMemory?.statuses.map { $0.name }.sorted(), ["Doing", "Done", "Review", "Todo"])

        // Reload from disk to confirm persistence survived the deletion
        taskStore.loadAllData()
        let onDisk = taskStore.plans.first(where: { $0.name == "Alpha" })
        XCTAssertNotNil(onDisk)
        XCTAssertEqual(onDisk?.statuses.count, 4)
        XCTAssertEqual(onDisk?.statuses.map { $0.name }.sorted(), ["Doing", "Done", "Review", "Todo"])
    }

    // MARK: - Reordering (drag-to-reorder within/across columns)

    func testReorderTaskMovesDraggedTaskBeforeTargetWithinSameColumn() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let a = Task(title: "A", plan: "Work", status: "To Do", order: 0)
        let b = Task(title: "B", plan: "Work", status: "To Do", order: 1)
        let c = Task(title: "C", plan: "Work", status: "To Do", order: 2)
        try taskStore.createTask(a)
        try taskStore.createTask(b)
        try taskStore.createTask(c)

        // Drag C to sit right before A: expected order becomes C, A, B.
        try taskStore.reorderTask(c, before: a)

        let ordered = taskStore.tasks
            .filter { $0.plan == "Work" && $0.status == "To Do" }
            .sorted { $0.order < $1.order }
        XCTAssertEqual(ordered.map(\.title), ["C", "A", "B"])
    }

    func testReorderTaskAcrossStatusMovesPlanAndStatusToTargets() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let a = Task(title: "A", plan: "Work", status: "To Do", order: 0)
        let b = Task(title: "B", plan: "Work", status: "In Progress", order: 0)
        try taskStore.createTask(a)
        try taskStore.createTask(b)

        try taskStore.reorderTask(a, before: b)

        let updatedA = try XCTUnwrap(taskStore.tasks.first { $0.id == a.id })
        XCTAssertEqual(updatedA.status, "In Progress")
        let ordered = taskStore.tasks
            .filter { $0.plan == "Work" && $0.status == "In Progress" }
            .sorted { $0.order < $1.order }
        XCTAssertEqual(ordered.map(\.title), ["A", "B"])
    }

    func testReorderTaskNoOpsOnSelfDrop() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let a = Task(title: "A", plan: "Work", status: "To Do", order: 0)
        try taskStore.createTask(a)

        try taskStore.reorderTask(a, before: a)

        XCTAssertEqual(taskStore.tasks.first?.order, 0)
    }

    func testReorderTaskNoOpsWhenEitherTaskIsBundledChild() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let target = Task(title: "Target", plan: "Work", status: "To Do")
        let dragged = Task(title: "Dragged", plan: "Work", status: "To Do")
        try taskStore.createTask(target)
        try taskStore.createTask(dragged)
        try taskStore.bundleTask(dragged, onto: target)
        let bundledChild = try XCTUnwrap(taskStore.tasks.first { $0.id == dragged.id })

        let other = Task(title: "Other", plan: "Work", status: "To Do", order: 5)
        try taskStore.createTask(other)

        // bundledChild is hidden inside a bundle — reordering it directly should no-op.
        try taskStore.reorderTask(bundledChild, before: other)

        let refreshedOther = try XCTUnwrap(taskStore.tasks.first { $0.id == other.id })
        XCTAssertEqual(refreshedOther.order, 5)
    }

    func testNextOrderReturnsOneMoreThanCurrentMax() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        try taskStore.createTask(Task(title: "A", plan: "Work", status: "To Do", order: 0))
        try taskStore.createTask(Task(title: "B", plan: "Work", status: "To Do", order: 3))

        XCTAssertEqual(taskStore.nextOrder(inPlan: "Work", status: "To Do"), 4)
        XCTAssertEqual(taskStore.nextOrder(inPlan: "Work", status: "Done"), 0)
    }

    func testMoveTasksToStatusAppendsToEndOfDestinationColumn() throws {
        try taskStore.createPlan(Plan(name: "Work", color: "blue"))
        let existing = Task(title: "Existing", plan: "Work", status: "Done", order: 0)
        let moving = Task(title: "Moving", plan: "Work", status: "To Do", order: 7)
        try taskStore.createTask(existing)
        try taskStore.createTask(moving)

        try taskStore.moveTasks([moving], toStatus: "Done")

        let updatedMoving = try XCTUnwrap(taskStore.tasks.first { $0.id == moving.id })
        XCTAssertEqual(updatedMoving.status, "Done")
        XCTAssertEqual(updatedMoving.order, 1)
    }
}


