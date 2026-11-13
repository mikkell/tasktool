import XCTest
@testable import TaskToolCore

final class EmbeddedGitRepositoryTests: XCTestCase {
    private var root: URL!
    private var origin: URL!
    private var macURL: URL!
    private var phoneURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskToolEmbeddedGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        origin = root.appendingPathComponent("origin.git")
        macURL = root.appendingPathComponent("mac")
        phoneURL = root.appendingPathComponent("phone")
        try EmbeddedGitRepository.initializeBare(at: origin)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func seed() async throws -> (EmbeddedGitRepository, EmbeddedGitRepository, Task) {
        let mac = try EmbeddedGitRepository.cloneLocal(from: origin, to: macURL)
        let task = Task(title: "Example", plan: "Work", status: "To Do", body: "Original")
        try write(Data(MarkdownParser.serializeTask(task).utf8), path: "Work/example.md", at: macURL)
        try write(Data(MarkdownParser.serializePlan(Plan(name: "Work")).utf8), path: "Work/plan.yaml", at: macURL)
        try write(Data(MarkdownParser.serializeSettings(Settings(planOrder: ["Work"])).utf8), path: "settings.yaml", at: macURL)
        try await mac.commitWorkingCopy(message: "Initial tasks")
        try await mac.push()
        let phone = try EmbeddedGitRepository.cloneLocal(from: origin, to: phoneURL)
        return (mac, phone, task)
    }

    func testEmbeddedCloneCommitFetchMergeAndPushPreserveMetadataAndBinaryFiles() async throws {
        let (mac, phone, task) = try await seed()
        var local = task
        var remote = task
        local.status = "In Progress"
        remote.body = "Offline phone notes"
        try write(Data(MarkdownParser.serializeTask(local).utf8), path: "Work/example.md", at: macURL)
        let binary = Data([0, 255, 1, 2, 0, 128])
        try write(binary, path: "Work/attachments/photo.bin", at: phoneURL)
        try write(Data(MarkdownParser.serializeTask(remote).utf8), path: "Work/example.md", at: phoneURL)
        var settings = Settings(planOrder: ["Work"])
        settings.overviewFocusNote = "Phone focus"
        try write(Data(MarkdownParser.serializeSettings(settings).utf8), path: "settings.yaml", at: phoneURL)
        try await mac.commitWorkingCopy(message: "Offline Mac edit")
        try await phone.commitWorkingCopy(message: "Offline phone edit")
        try await phone.push()
        try await mac.synchronize()
        try await phone.synchronize()
        let macFiles = try await mac.files()
        let phoneFiles = try await phone.files()
        XCTAssertEqual(macFiles, phoneFiles)
        XCTAssertEqual(macFiles["Work/attachments/photo.bin"]?.data, binary)
        let (snapshot, _) = try GitSyncFiles.decode(macFiles)
        XCTAssertEqual(snapshot.tasks.first?.task.status, "In Progress")
        XCTAssertEqual(snapshot.tasks.first?.task.body, "Offline phone notes")
        XCTAssertEqual(snapshot.settings?.overviewFocusNote, "Phone focus")
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/attachments/photo.bin")), binary)
    }

    func testNonFastForwardPushIsRejectedAndSyncCanRetryWithoutForcePush() async throws {
        let (mac, phone, task) = try await seed()
        var local = task
        var remote = task
        local.status = "In Progress"
        remote.body = "Phone edit"
        try write(Data(MarkdownParser.serializeTask(local).utf8), path: "Work/example.md", at: macURL)
        try write(Data(MarkdownParser.serializeTask(remote).utf8), path: "Work/example.md", at: phoneURL)
        try await mac.commitWorkingCopy(message: "Mac")
        try await phone.commitWorkingCopy(message: "Phone")
        try await phone.push()
        do {
            try await mac.push()
            XCTFail("Expected push rejection")
        } catch GitSyncError.pushRejected {}
        try await mac.synchronize()
        let (merged, _) = try GitSyncFiles.decode(await mac.files())
        XCTAssertEqual(merged.tasks.first?.task.status, "In Progress")
        XCTAssertEqual(merged.tasks.first?.task.body, "Phone edit")
    }

    func testDirtyWorkingCopyAndConflictsDoNotOverwriteLocalEdits() async throws {
        let (mac, phone, task) = try await seed()
        let head = try await mac.head()
        var local = task
        local.body = "Uncommitted edit"
        let file = macURL.appendingPathComponent("Work/example.md")
        let data = Data(MarkdownParser.serializeTask(local).utf8)
        try write(data, path: "Work/example.md", at: macURL)
        do {
            try await mac.synchronize()
            XCTFail("Expected dirty working copy")
        } catch GitSyncError.dirtyWorkingCopy {}
        XCTAssertEqual(try Data(contentsOf: file), data)
        let after = try await mac.head()
        XCTAssertEqual(after, head)
        try await mac.commitWorkingCopy(message: "Local notes")
        var remote = task
        remote.body = "Conflicting phone notes"
        try write(Data(MarkdownParser.serializeTask(remote).utf8), path: "Work/example.md", at: phoneURL)
        try await phone.commitWorkingCopy(message: "Remote notes")
        try await phone.push()
        do {
            try await mac.synchronize()
            XCTFail("Expected semantic conflict")
        } catch GitSyncError.conflicts(let conflicts) {
            XCTAssertTrue(conflicts.contains { $0.field == "body" })
        }
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: macURL.appendingPathComponent(".git/tasktool-sync-pending.json").path))
    }

    func testInterruptedApplicationResumesFromCommittedVersions() async throws {
        let (mac, phone, task) = try await seed()
        let before = try await mac.files()
        let oldHead = try await requiredHead(mac)
        var remote = task
        remote.body = "Remote edit"
        try write(Data(MarkdownParser.serializeTask(remote).utf8), path: "Work/example.md", at: phoneURL)
        try write(Data([0, 1, 2]), path: "Work/attachments/new.bin", at: phoneURL)
        try await phone.commitWorkingCopy(message: "Remote update")
        try await phone.push()
        try await mac.fetch()
        let newHead = try await requiredHead(phone)
        let after = try await mac.files(at: newHead)
        let journal = Journal(oldHead: oldHead, newHead: newHead, before: before, after: after)
        try JSONEncoder().encode(journal).write(to: macURL.appendingPathComponent(".git/tasktool-sync-pending.json"))
        // Simulate termination after one destination was written, before branch/index update.
        try write(after["Work/example.md"]!.data, path: "Work/example.md", at: macURL)
        do {
            try await mac.synchronize()
            XCTFail("Expected recovery requirement")
        } catch GitSyncError.recoveryRequired {}
        try await mac.resumePendingApplication()
        let actualHead = try await mac.head()
        XCTAssertEqual(actualHead, newHead)
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/attachments/new.bin")), Data([0, 1, 2]))
        try await mac.synchronize()
    }

    func testRecoveryRefusesEditsMadeAfterAnInterruptedApplication() async throws {
        let (mac, phone, task) = try await seed()
        let before = try await mac.files()
        let oldHead = try await requiredHead(mac)
        var remote = task
        remote.body = "Remote edit"
        try write(Data(MarkdownParser.serializeTask(remote).utf8), path: "Work/example.md", at: phoneURL)
        try await phone.commitWorkingCopy(message: "Remote")
        try await phone.push()
        try await mac.fetch()
        let newHead = try await requiredHead(phone)
        let after = try await mac.files(at: newHead)
        try JSONEncoder().encode(Journal(oldHead: oldHead, newHead: newHead, before: before, after: after))
            .write(to: macURL.appendingPathComponent(".git/tasktool-sync-pending.json"))
        let unsaved = Data("New external edit".utf8)
        try write(unsaved, path: "Work/example.md", at: macURL)
        do {
            try await mac.resumePendingApplication()
            XCTFail("Expected changed-file rejection")
        } catch GitSyncError.localFileChanged("Work/example.md") {}
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/example.md")), unsaved)
        let actualHead = try await mac.head()
        XCTAssertEqual(actualHead, oldHead)
    }

    func testChangedRemoteAndWorkingCopySymlinksAreRejected() async throws {
        let (mac, _, _) = try await seed()
        let outside = root.appendingPathComponent("outside.txt")
        try Data("Untouched".utf8).write(to: outside)
        let link = macURL.appendingPathComponent("Work/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            try await mac.commitWorkingCopy(message: "Must not follow links")
            XCTFail("Expected symlink rejection")
        } catch GitSyncError.unsupportedFile("Work/link") {}
        XCTAssertEqual(try Data(contentsOf: outside), Data("Untouched".utf8))
        try FileManager.default.removeItem(at: link)
        let config = macURL.appendingPathComponent(".git/config")
        let text = try String(contentsOf: config, encoding: .utf8)
        try text.replacingOccurrences(of: origin.path, with: "https://github.com.evil.invalid/example/tasks.git")
            .write(to: config, atomically: false, encoding: .utf8)
        do {
            try await mac.fetch()
            XCTFail("Expected remote mismatch")
        } catch GitSyncError.changedRemote {}
    }

    private struct Journal: Codable {
        let oldHead: String
        let newHead: String
        let before: [String: GitSyncFile]
        let after: [String: GitSyncFile]
    }

    private func requiredHead(_ repository: EmbeddedGitRepository) async throws -> String {
        let value = try await repository.head()
        return try XCTUnwrap(value)
    }

    private func write(_ data: Data, path: String, at directory: URL) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [])
    }
}
