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
    private var access: MockCheckoutAccess!

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
        access = MockCheckoutAccess()
        store = TaskStore(gitClient: service, defaults: defaults, gitRepositoriesURL: repositories, checkoutAccess: access)
        store.storageURL = original
        store.loadAllData()
    }

    override func tearDown() async throws {
        store?.setAutoSyncActive(false)
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

    func testExternalConnectionRestoresBookmarkAndDisconnectRetainsFiles() async throws {
        let parent = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder", checkoutParent: parent)
        let directory = parent.appendingPathComponent("task-data", isDirectory: true)
        XCTAssertEqual(store.storageURL, directory)
        XCTAssertTrue(store.hasExternalGitCheckout)
        XCTAssertEqual(store.tasks.first?.id, task.id)
        XCTAssertEqual(access.starts, [parent])
        XCTAssertTrue(access.stops.isEmpty)
        let reopened = TaskStore(gitClient: service, defaults: defaults, gitRepositoriesURL: repositories, checkoutAccess: access)
        await reopened.restoreGitSync()
        XCTAssertEqual(reopened.storageURL, directory)
        XCTAssertTrue(reopened.canEditStorage)
        XCTAssertEqual(reopened.tasks.first?.id, task.id)
        await reopened.disconnectGitSync()
        XCTAssertFalse(reopened.hasExternalGitCheckout)
        XCTAssertNil(defaults.string(forKey: "gitSyncCheckoutName"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Work/example.md").path))
        XCTAssertEqual(access.stops, [parent])
    }

    func testRelocationRetainsUnsyncedFilesAndOldCheckoutAndReopensAtNewLocation() async throws {
        await connect()
        let source = try XCTUnwrap(store.storageURL)
        var edited = try XCTUnwrap(store.tasks.first)
        edited.body = "Unsynced notes"
        try store.updateTask(edited)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let marker = Data("History marker".utf8)
        try marker.write(to: source.appendingPathComponent(".git/HEAD"))
        let parent = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await store.relocateGitCheckout(to: parent)
        let destination = parent.appendingPathComponent("task-data", isDirectory: true)
        XCTAssertEqual(store.storageURL, destination)
        XCTAssertEqual(store.tasks.first?.body, "Unsynced notes")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".git/HEAD")), marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Work/example.md").path))
        XCTAssertEqual(store.gitRemoteURL, "https://github.com/example/task-data.git")
        let relocated = await service.relocations
        let syncs = await service.syncs
        XCTAssertEqual(relocated, 1)
        XCTAssertEqual(syncs, 0)
        let reopened = TaskStore(gitClient: service, defaults: defaults, gitRepositoriesURL: repositories, checkoutAccess: access)
        await reopened.restoreGitSync()
        XCTAssertEqual(reopened.storageURL, destination)
        XCTAssertEqual(reopened.tasks.first?.body, "Unsynced notes")
    }

    func testRelocationRefusesExistingDestinationAndKeepsCurrentConfigurationOnFailure() async throws {
        await connect()
        let source = try XCTUnwrap(store.storageURL)
        let parent = root.appendingPathComponent("external")
        let existing = parent.appendingPathComponent("task-data")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("Keep".utf8).write(to: existing.appendingPathComponent("notes.txt"))
        await store.relocateGitCheckout(to: parent)
        XCTAssertEqual(store.storageURL, source)
        XCTAssertFalse(store.hasExternalGitCheckout)
        XCTAssertTrue(store.gitSyncMessage.contains("already exists"))
        XCTAssertEqual(try String(contentsOf: existing.appendingPathComponent("notes.txt"), encoding: .utf8), "Keep")
        let relocations = await service.relocations
        XCTAssertEqual(relocations, 0)
        let anotherParent = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: anotherParent, withIntermediateDirectories: true)
        await service.failRelocation()
        await store.relocateGitCheckout(to: anotherParent)
        XCTAssertEqual(store.storageURL, source)
        XCTAssertFalse(store.hasExternalGitCheckout)
        XCTAssertTrue(store.canEditStorage)
        XCTAssertEqual(access.stops, [parent, anotherParent])
    }

    func testRelocationRemainsAvailableWhenRestoredMetadataNeedsExternalRepair() async throws {
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder", checkoutParent: root)
        let source = try XCTUnwrap(store.storageURL)
        let invalid = Data("---\nplan: Old name\n---\n# Keep this task\n".utf8)
        try invalid.write(to: source.appendingPathComponent("Work/invalid.md"))
        await service.setOpenError(GitSyncFailure(message: "Invalid task metadata"))
        await store.restoreGitSync()
        XCTAssertFalse(store.canEditStorage)
        XCTAssertTrue(store.canRelocateGitCheckout)
        XCTAssertEqual(access.starts.count - access.stops.count, 1)
        let parent = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await store.relocateGitCheckout(to: parent)
        let destination = parent.appendingPathComponent("task-data", isDirectory: true)
        XCTAssertEqual(store.storageURL, destination)
        XCTAssertTrue(store.canEditStorage)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Work/invalid.md")), invalid)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Work/invalid.md")), invalid)
        XCTAssertEqual(access.starts.count - access.stops.count, 1)
    }

    func testExternalFolderAccessFailuresDoNotCloneOrOverwriteSavedConfiguration() async throws {
        access.allowed = false
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder", checkoutParent: root)
        XCTAssertNil(store.gitRemoteURL)
        XCTAssertEqual(store.storageURL, original)
        XCTAssertNil(defaults.string(forKey: "gitSyncRepositoryID"))
        XCTAssertTrue(store.gitSyncMessage.contains("denied"))
        access.allowed = true
        access.bookmarkFails = true
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder", checkoutParent: root)
        XCTAssertNil(store.gitRemoteURL)
        XCTAssertEqual(store.storageURL, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("task-data").path))
        XCTAssertEqual(access.stops, [root])
    }

    func testStaleExternalBookmarkIsRefreshedAndAccessDenialLocksEditing() async throws {
        await store.configureGitSync(remoteURL: "https://github.com/example/task-data", token: "test-placeholder", checkoutParent: root)
        access.stale = true
        let bookmarkCount = access.bookmarks
        await store.restoreGitSync()
        XCTAssertTrue(store.canEditStorage)
        XCTAssertEqual(access.bookmarks, bookmarkCount + 1)
        access.allowed = false
        await store.restoreGitSync()
        XCTAssertFalse(store.canEditStorage)
        XCTAssertTrue(store.gitStorageUnavailable)
        XCTAssertNotNil(defaults.data(forKey: "gitSyncCheckoutBookmark"))
        XCTAssertThrowsError(try store.createPlan(TaskTool.Plan(name: "Blocked")))
    }

    func testRelocationIsBlockedDuringSyncRecoveryAndOpenEditors() async throws {
        await connect()
        let editorID = UUID()
        store.setAutoSyncEditor(editorID, isOpen: true)
        await store.relocateGitCheckout(to: root)
        store.setAutoSyncEditor(editorID, isOpen: false)
        await service.pauseNextSync()
        let syncing = _Concurrency.Task { await store.syncGit() }
        await service.waitUntilSyncStarts()
        await store.relocateGitCheckout(to: root)
        await service.setSyncError(GitSyncFailure(message: "Recovery needed", requiresRecovery: true))
        await service.resumeSync()
        await syncing.value
        await store.relocateGitCheckout(to: root)
        let relocations = await service.relocations
        XCTAssertEqual(relocations, 0)
        XCTAssertTrue(access.starts.isEmpty)
    }

    func testAutomaticSyncFollowsCreationAndEditsWithoutReloadLoop() async throws {
        await connect()
        store.setAutoSyncActive(true)
        try await waitForSyncCount(1)
        let created = TaskTool.Task(title: "Automatic", plan: "Work", status: "To Do")
        try store.createTask(created)
        try await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
        var edited = created
        edited.body = "Updated before debounce expires"
        try store.updateTask(edited)
        try await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
        let beforeDeadline = await service.syncs
        XCTAssertEqual(beforeDeadline, 1)
        try await waitForSyncCount(2)
        store.loadAllData()
        try await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
        let afterReload = await service.syncs
        XCTAssertEqual(afterReload, 2, "Reloading settings after a sync must not create a sync loop.")
        store.setAutoSyncActive(false)
        try store.updateTask(edited)
        try await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
        let afterInactiveEdit = await service.syncs
        XCTAssertEqual(afterInactiveEdit, 2)
    }

    private func waitForSyncCount(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await service.syncs >= expected && !store.isSyncing { return }
            try await _Concurrency.Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for automatic sync \(expected)")
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
    private var directory: URL?
    private var relocationFails = false
    private var started: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    private(set) var recoveries = 0
    private(set) var disconnects = 0
    private(set) var syncs = 0
    private(set) var relocations = 0

    init(files: [String: Data]) { self.files = files }

    func clone(remoteURL: String, to directory: URL, token: String) throws {
        for (path, data) in files {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        self.directory = directory
    }

    func open(remoteURL: String, at directory: URL) throws {
        if let openError { throw openError }
        self.directory = directory
    }

    func relocate(from source: URL, to destination: URL, remoteURL: String) throws {
        relocations += 1
        if relocationFails { throw GitSyncFailure(message: "Copy failed") }
        try FileManager.default.copyItem(at: source, to: destination)
        directory = destination
    }

    func sync() async throws {
        syncs += 1
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
    func failRelocation() { relocationFails = true }
    func pauseNextSync() { pauseSync = true }
    func resumeSync() { paused?.resume(); paused = nil }
    func waitUntilSyncStarts() async {
        if syncStarted { return }
        await withCheckedContinuation { started = $0 }
    }
}

private final class MockCheckoutAccess: GitCheckoutFolderAccess {
    var allowed = true
    var stale = false
    var bookmarkFails = false
    var starts: [URL] = []
    var stops: [URL] = []
    var bookmarks = 0

    func start(_ url: URL) -> Bool { starts.append(url); return allowed }
    func stop(_ url: URL) { stops.append(url) }
    func bookmark(_ url: URL) throws -> Data {
        bookmarks += 1
        if bookmarkFails { throw TaskStoreError.checkoutAccessDenied }
        return Data(url.path.utf8)
    }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), stale)
    }
}
