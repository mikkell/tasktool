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
}

