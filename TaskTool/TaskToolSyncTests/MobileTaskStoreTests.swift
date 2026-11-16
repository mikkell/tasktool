import XCTest
@testable import TaskToolCore

@MainActor
final class MobileTaskStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!
    private var service: MobileServiceStub!
    private var store: MobileTaskStore!

    override func setUp() async throws {
        suite = "TaskToolMobileTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        service = MobileServiceStub()
        store = MobileTaskStore(client: service, defaults: defaults, repositoriesURL: root)
    }

    override func tearDown() async throws {
        store?.setAutoSyncActive(false)
        store = nil
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testConnectLoadsCustomStatusesAndSkipsArchivedTasksWithoutSyncing() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.plans.map(\.name), ["Second", "First"])
        XCTAssertEqual(store.plans.last?.statuses, ["Queued", "Finished"])
        XCTAssertEqual(store.tasks.map(\.title), ["Active"])
        let syncs = await service.syncs
        XCTAssertEqual(syncs, 0)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "placeholder" })
    }

    func testRestoringLocalCheckoutNeverFetchesAndMissingCheckoutLocksEditing() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let restored = MobileTaskStore(client: service, defaults: defaults, repositoriesURL: root)
        XCTAssertFalse(restored.canEdit)
        await restored.restoreIfNeeded()
        XCTAssertTrue(restored.canEdit)
        let syncs = await service.syncs
        XCTAssertEqual(syncs, 0)
        await service.failOpen()
        await restored.reopen()
        XCTAssertTrue(restored.storageUnavailable)
        XCTAssertFalse(restored.canEdit)
        let saved = await restored.save(try XCTUnwrap(restored.tasks.first), status: "Finished", body: "Blocked")
        XCTAssertFalse(saved)
    }

    func testInterruptedSyncLocksEditingUntilRecovery() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        await service.failSyncWithRecovery()
        await store.sync()
        XCTAssertTrue(store.needsRecovery)
        XCTAssertFalse(store.canEdit)
        let plan = try XCTUnwrap(store.plans.first)
        let created = await store.createTask(title: "Blocked", planID: plan.id)
        XCTAssertFalse(created)
        let creations = await service.creations
        XCTAssertEqual(creations, 0)
        await store.recover()
        XCTAssertFalse(store.needsRecovery)
        XCTAssertTrue(store.canEdit)
    }

    func testSaveDoesNotSyncAndKeepsDraftOnFailure() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let task = try XCTUnwrap(store.tasks.first)
        let success = await store.save(task, status: "Finished", body: "Offline notes")
        XCTAssertTrue(success)
        XCTAssertEqual(store.tasks.first?.body, "Offline notes")
        let syncs = await service.syncs
        XCTAssertEqual(syncs, 0)
        let staleSave = await store.save(task, status: "Queued", body: "Stale draft")
        XCTAssertFalse(staleSave)
        XCTAssertEqual(store.tasks.first?.body, "Offline notes")
    }

    func testSyncDisablesSaveAndSecondSyncUntilFinished() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let task = try XCTUnwrap(store.tasks.first)
        await service.pauseNextSync()
        let syncing = _Concurrency.Task { await store.sync() }
        await service.waitForSync()
        XCTAssertFalse(store.canEdit)
        let saved = await store.save(task, status: "Finished", body: "Blocked")
        XCTAssertFalse(saved)
        let plan = try XCTUnwrap(store.plans.first)
        let created = await store.createTask(title: "Blocked", planID: plan.id)
        XCTAssertFalse(created)
        let creations = await service.creations
        XCTAssertEqual(creations, 0)
        await store.sync()
        let syncs = await service.syncs
        XCTAssertEqual(syncs, 1)
        await service.resumeSync()
        await syncing.value
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.tasks.first?.body, task.body)
    }

    func testAutomaticSyncDefersWhileEditorIsOpenAndSyncsSavedNotesAfterClosing() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let task = try XCTUnwrap(store.tasks.first)
        let editorID = UUID()
        store.setAutoSyncEditor(editorID, isOpen: true)
        store.setAutoSyncActive(true)
        let saved = await store.save(task, status: "Finished", body: "Offline draft")
        XCTAssertTrue(saved)
        try await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
        let whileEditing = await service.syncs
        XCTAssertEqual(whileEditing, 0)
        store.setAutoSyncEditor(editorID, isOpen: false)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await service.syncs > 0 && !store.isBusy { break }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
        }
        let afterClosing = await service.syncs
        XCTAssertEqual(afterClosing, 1)
        XCTAssertEqual(store.tasks.first?.body, "Offline draft")
        XCTAssertEqual(store.message, "Synced successfully.")
    }

    func testConflictPausesAutomaticSyncAcrossEditsAndForegroundUntilManualSuccess() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        await service.setConflict(true)
        await store.sync()
        XCTAssertFalse(store.conflicts.isEmpty)
        let task = try XCTUnwrap(store.tasks.first)
        let saved = await store.save(task, status: task.status, body: "Retained offline")
        XCTAssertTrue(saved)
        XCTAssertFalse(store.conflicts.isEmpty)
        XCTAssertTrue(store.message.contains("paused"))
        store.setAutoSyncActive(true)
        try await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
        let pausedAttempts = await service.syncs
        XCTAssertEqual(pausedAttempts, 1)
        await service.setConflict(false)
        await store.sync()
        XCTAssertTrue(store.conflicts.isEmpty)
        store.setAutoSyncActive(false)
        store.setAutoSyncActive(true)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await service.syncs >= 3 && !store.isBusy { break }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
        }
        let resumedAttempts = await service.syncs
        XCTAssertEqual(resumedAttempts, 3)
    }

    func testCreatingTaskReloadsFieldsAndSchedulesSyncAfterEditorCloses() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let plan = try XCTUnwrap(store.plans.first { $0.name == "First" })
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let editorID = UUID()
        store.setAutoSyncEditor(editorID, isOpen: true)
        store.setAutoSyncActive(true)
        let created = await store.createTask(
            title: "Phone task", planID: plan.id, status: "Finished", dueDate: dueDate, body: "- [ ] Offline notes"
        )
        XCTAssertTrue(created)
        let task = try XCTUnwrap(store.tasks.first { $0.title == "Phone task" })
        XCTAssertEqual(task.plan, plan.name)
        XCTAssertEqual(task.status, "Finished")
        XCTAssertEqual(task.dueDate, dueDate)
        XCTAssertEqual(task.body, "- [ ] Offline notes")
        try await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
        let beforeClosing = await service.syncs
        XCTAssertEqual(beforeClosing, 0)
        store.setAutoSyncEditor(editorID, isOpen: false)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await service.syncs > 0 && !store.isBusy { break }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
        }
        let afterClosing = await service.syncs
        XCTAssertEqual(afterClosing, 1)
    }

    func testFailedCreationLeavesExistingTasksUntouched() async throws {
        await store.connect(remoteURL: "https://github.com/example/tasks", token: "placeholder")
        let plan = try XCTUnwrap(store.plans.first)
        let before = store.tasks
        await service.failCreation()
        let created = await store.createTask(title: "Retained draft", planID: plan.id)
        XCTAssertFalse(created)
        XCTAssertEqual(store.tasks, before)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.message, "Could not write task")
    }
}

private actor MobileServiceStub: MobileGitService {
    private var snapshot = RepositorySyncSnapshot(
        tasks: [
            TaskSyncSnapshot(task: Task(title: "Active", plan: "First", status: "Queued"), path: "First/active.md"),
            TaskSyncSnapshot(task: Task(title: "Archived", plan: "First", status: "Finished"), path: "First/Archived/archived.md")
        ],
        plans: [
            Plan(name: "First", statuses: [
                Plan.TaskStatus(name: "Queued", color: "gray", order: 0),
                Plan.TaskStatus(name: "Finished", color: "green", order: 1)
            ]),
            Plan(name: "Second")
        ],
        settings: Settings(planOrder: ["Second", "First"])
    )
    private var openFails = false
    private var syncFails = false
    private var hasConflict = false
    private var creationFails = false
    private var pauseSync = false
    private var started: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    private(set) var syncs = 0
    private(set) var creations = 0

    func clone(remoteURL: String, to directory: URL, token: String) {}
    func open(remoteURL: String, at directory: URL) throws {
        if openFails { throw GitSyncFailure(message: "Missing checkout") }
    }
    func sync() async throws {
        syncs += 1
        started?.resume()
        started = nil
        if pauseSync { await withCheckedContinuation { paused = $0 } }
        if syncFails { throw GitSyncFailure(message: "Interrupted", requiresRecovery: true) }
        if hasConflict { throw GitSyncFailure(message: "Conflict", conflicts: ["task: body"]) }
    }
    func recover() { syncFails = false }
    func updateToken(_ token: String) {}
    func mobileSnapshot() -> RepositorySyncSnapshot { snapshot }
    func saveMobileTask(_ expected: Task, status: String, body: String) throws {
        guard let index = snapshot.tasks.firstIndex(where: { $0.task == expected }) else {
            throw GitSyncFailure(message: "Draft is stale")
        }
        snapshot.tasks[index].task.status = status
        snapshot.tasks[index].task.body = body
    }
    func createMobileTask(title: String, planID: UUID, status: String?, dueDate: Date?, body: String) throws {
        creations += 1
        if creationFails { throw GitSyncFailure(message: "Could not write task") }
        guard let plan = snapshot.plans.first(where: { $0.id == planID }),
              let status = status ?? plan.statuses.sorted(by: { $0.order < $1.order }).first?.name else {
            throw GitSyncError.missingPlan
        }
        let task = Task(title: title, plan: plan.name, status: status, dueDate: dueDate, body: body)
        snapshot.tasks.append(TaskSyncSnapshot(task: task, path: "\(plan.name)/\(task.fileName)"))
    }
    func failOpen() { openFails = true }
    func failSyncWithRecovery() { syncFails = true }
    func setConflict(_ value: Bool) { hasConflict = value }
    func failCreation() { creationFails = true }
    func pauseNextSync() { pauseSync = true }
    func waitForSync() async {
        if syncs > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func resumeSync() { paused?.resume(); paused = nil }
}
