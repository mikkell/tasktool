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
        await store.sync()
        let syncs = await service.syncs
        XCTAssertEqual(syncs, 1)
        await service.resumeSync()
        await syncing.value
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.tasks.first?.body, task.body)
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
    private var pauseSync = false
    private var started: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    private(set) var syncs = 0

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
    func failOpen() { openFails = true }
    func failSyncWithRecovery() { syncFails = true }
    func pauseNextSync() { pauseSync = true }
    func waitForSync() async {
        if syncs > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func resumeSync() { paused?.resume(); paused = nil }
}
