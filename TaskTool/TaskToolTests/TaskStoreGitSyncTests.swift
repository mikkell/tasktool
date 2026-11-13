import XCTest
import TaskToolCore
@testable import TaskTool

@MainActor
final class TaskStoreGitSyncTests: XCTestCase {
    private var root: URL!
    private var original: URL!
    private var repositories: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var service: MockGitService!
    private var store: TaskStore!
    private var task: TaskTool.Task!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskToolGitAppTests-\(UUID().uuidString)")
        original = root.appendingPathComponent("original")
        repositories = root.appendingPathComponent("repositories")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defaultsName = "TaskToolGitAppTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        task = TaskTool.Task(title: "Example", plan: "Work", status: "To Do")
        let plan = TaskTool.Plan(name: "Work")
        service = MockGitService(files: [
            "Work/plan.yaml": Data(TaskTool.MarkdownParser.serializePlan(plan).utf8),
            "Work/example.md": Data(TaskTool.MarkdownParser.serializeTask(task).utf8),
            "settings.yaml": Data(TaskTool.MarkdownParser.serializeSettings(TaskTool.Settings(planOrder: ["Work"])).utf8)
        ])
        store = TaskStore(gitClient: service, defaults: defaults, gitRepositoriesURL: repositories)
        store.storageURL = original
        store.loadAllData()
    }

    override func tearDown() async throws {
        store = nil
        service = nil
        if let root { try FileManager.default.removeItem(at: root) }
        if let defaultsName { defaults.removePersistentDomain(forName: defaultsName) }
    }

    func testConnectingSwitchesToManagedCloneWithoutChangingOriginalFolder() async throws {
        try store.createPlan(TaskTool.Plan(name: "Original"))
        let before = try Data(contentsOf: original.appendingPathComponent("Original/plan.yaml"))
        await connect()
        XCTAssertEqual(store.gitRemoteURL, "https://github.com/example/task-data.git")
        XCTAssertEqual(store.plans.first?.name, "Work")
        XCTAssertEqual(store.tasks.first?.id, task.id)
        XCTAssertTrue(store.storageURL!.path.hasPrefix(repositories.path + "/"))
        XCTAssertNotNil(defaults.string(forKey: "gitSyncRepositoryID"))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("Original/plan.yaml")), before)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "test-placeholder" })
    }

    func testSyncBlocksWritesAndReloadsUntilOperationFinishes() async throws {
        await connect()
        await service.pauseNextSync()
        let syncing = _Concurrency.Task { await store.syncGit() }
        await service.waitUntilSyncStarts()
        XCTAssertTrue(store.isSyncing)
        XCTAssertFalse(store.canEditStorage)
        let folder = try XCTUnwrap(store.storageURL)
        XCTAssertThrowsError(try store.createPlan(TaskTool.Plan(name: "Blocked")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Blocked").path))
        XCTAssertThrowsError(try store.registerTags(["blocked"]))
        XCTAssertFalse(store.settings.availableTags.contains("blocked"))
        XCTAssertThrowsError(try store.importAttachment(data: Data([1]), suggestedFileName: "blocked.bin", planName: "Work"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Work/attachments").path))
        var changed = task!
        changed.title = "External edit while paused"
        try TaskTool.MarkdownParser.serializeTask(changed)
            .write(to: folder.appendingPathComponent("Work/example.md"), atomically: false, encoding: .utf8)
        store.loadAllData()
        XCTAssertEqual(store.tasks.first?.title, "Example")
        await service.resumeSync()
        await syncing.value
        XCTAssertTrue(store.canEditStorage)
        XCTAssertEqual(store.tasks.first?.title, changed.title)
        XCTAssertEqual(store.gitSyncMessage, "Synced successfully.")
    }

    func testRecoveryLocksEditingUntilExplicitRecoveryCompletes() async throws {
        await connect()
        await service.setSyncError(GitSyncFailure(message: "Recovery needed", requiresRecovery: true))
        await store.syncGit()
        XCTAssertTrue(store.needsGitRecovery)
        XCTAssertFalse(store.canEditStorage)
        XCTAssertThrowsError(try store.deleteTask(task))
        XCTAssertEqual(store.tasks.count, 1)
        await store.recoverGitSync()
        XCTAssertFalse(store.needsGitRecovery)
        XCTAssertTrue(store.canEditStorage)
        let recoveries = await service.recoveries
        XCTAssertEqual(recoveries, 1)
    }

    func testFailedRestoreDoesNotCreateSettingsOrAllowWritesInUnavailableCheckout() async throws {
        let id = UUID().uuidString
        defaults.set(id, forKey: "gitSyncRepositoryID")
        defaults.set("https://github.com/example/task-data.git", forKey: "gitSyncRemoteURL")
        await service.setOpenError(GitSyncFailure(message: "Missing checkout"))
        await store.restoreGitSync()
        XCTAssertTrue(store.gitStorageUnavailable)
        XCTAssertFalse(store.canEditStorage)
        XCTAssertThrowsError(try store.saveSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositories.appendingPathComponent("\(id)/settings.yaml").path))
        await store.disconnectGitSync()
        XCTAssertNil(store.gitRemoteURL)
        XCTAssertTrue(store.canEditStorage)
    }

    func testDisconnectRetainsCheckoutAndClearsOnlyGitConfiguration() async throws {
        await connect()
        let checkout = try XCTUnwrap(store.storageURL)
        defaults.set("keep", forKey: "unrelatedPreference")
        await store.disconnectGitSync()
        XCTAssertNil(store.gitRemoteURL)
        XCTAssertNil(defaults.string(forKey: "gitSyncRepositoryID"))
        XCTAssertEqual(defaults.string(forKey: "unrelatedPreference"), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Work/example.md").path))
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1)
    }

    private func connect() async {
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder")
    }
}

private actor MockGitService: TaskStoreGitService {
    private let files: [String: Data]
    private var syncError: GitSyncFailure?
    private var openError: GitSyncFailure?
    private var pauseSync = false
    private var syncStarted = false
    private var started: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    private(set) var recoveries = 0
    private(set) var disconnects = 0

    init(files: [String: Data]) { self.files = files }

    func clone(remoteURL: String, to directory: URL, token: String) throws {
        for (path, data) in files {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    func open(remoteURL: String, at directory: URL) throws {
        if let openError { throw openError }
    }

    func sync() async throws {
        syncStarted = true
        started?.resume()
        started = nil
        if pauseSync {
            await withCheckedContinuation { paused = $0 }
        }
        if let syncError { throw syncError }
    }

    func recover() { recoveries += 1 }
    func updateToken(_ token: String) {}
    func disconnect() { disconnects += 1 }
    func setSyncError(_ error: GitSyncFailure) { syncError = error }
    func setOpenError(_ error: GitSyncFailure) { openError = error }
    func pauseNextSync() { pauseSync = true }
    func resumeSync() { paused?.resume(); paused = nil }
    func waitUntilSyncStarts() async {
        if syncStarted { return }
        await withCheckedContinuation { started = $0 }
    }
}
