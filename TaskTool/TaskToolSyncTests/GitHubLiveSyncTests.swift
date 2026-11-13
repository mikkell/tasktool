import XCTest
@testable import TaskToolCore

final class GitHubLiveSyncTests: XCTestCase {
    func testPrivateGitHubRoundTripAndConflictSafety() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TASKTOOL_GITHUB_VALIDATION_ALLOW_PUSH"] == "1",
              let remoteURL = environment["TASKTOOL_GITHUB_VALIDATION_REMOTE"] else {
            throw XCTSkip("Opt-in only: requires a disposable private GitHub repository and a token already saved by the app.")
        }
        let remote = try GitHubRemote(remoteURL)
        let credentials = KeychainGitHubTokenStore()
        let token = try credentials.token(for: remote)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskToolGitHubValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: root)
            } else {
                print("Validation checkouts retained at \(root.path)")
            }
        }
        let macURL = root.appendingPathComponent("mac")
        let phoneURL = root.appendingPathComponent("phone")
        let mac = GitSyncClient()
        try await mac.clone(remoteURL: remote.url.absoluteString, to: macURL, token: token)
        let inspected = try EmbeddedGitRepository.open(at: macURL, remote: remote, credentials: credentials)
        let initialFiles = try await inspected.files()
        let planName = "Sync Validation"
        let taskPath = "\(planName)/example.md"
        let attachmentPath = "\(planName)/attachments/probe.bin"
        let markerPath = ".tasktool-sync-validation"
        let marker = Data("Synthetic TaskTool GitHub sync validation only.\n".utf8)
        let allowedPaths: Set<String> = [
            "README.md", "settings.yaml", markerPath, "\(planName)/plan.yaml", taskPath, attachmentPath
        ]
        let isBootstrap = Set(initialFiles.keys).isSubset(of: ["README.md", "settings.yaml"])
        guard Set(initialFiles.keys).isSubset(of: allowedPaths),
              isBootstrap || initialFiles[markerPath]?.data == marker else {
            XCTFail("Refusing to modify a repository containing data other than this validation fixture.")
            return
        }
        let (initialSnapshot, _) = try GitSyncFiles.decode(initialFiles)
        var settings = initialSnapshot.settings ?? Settings()
        if !settings.planOrder.contains(planName) { settings.planOrder.append(planName) }
        var task = Task(title: "Synthetic sync validation", plan: planName, status: "To Do", body: "Synthetic baseline")
        try write(marker, path: markerPath, at: macURL)
        try write(Data(MarkdownParser.serializePlan(Plan(name: planName)).utf8), path: "\(planName)/plan.yaml", at: macURL)
        try write(Data(MarkdownParser.serializeSettings(settings).utf8), path: "settings.yaml", at: macURL)
        try write(task, path: taskPath, at: macURL)
        try await mac.sync()

        let phone = GitSyncClient()
        try await phone.clone(remoteURL: remote.url.absoluteString, to: phoneURL, token: token)
        var phoneTask = task
        task.status = "In Progress"
        phoneTask.body = "Synthetic offline phone notes"
        let binary = Data([0, 255, 1, 2, 0, 128])
        try write(task, path: taskPath, at: macURL)
        try write(phoneTask, path: taskPath, at: phoneURL)
        try write(binary, path: attachmentPath, at: phoneURL)
        try await mac.sync()
        try await phone.sync()
        try await mac.sync()
        let merged = try readTask(path: taskPath, plan: planName, at: macURL)
        XCTAssertEqual(merged.id, task.id)
        XCTAssertEqual(merged.status, "In Progress")
        XCTAssertEqual(merged.body, phoneTask.body)
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent(attachmentPath)), binary)
        let phoneRepository = try EmbeddedGitRepository.open(at: phoneURL, remote: remote, credentials: credentials)
        let macFiles = try await inspected.files()
        let phoneFiles = try await phoneRepository.files()
        XCTAssertEqual(macFiles, phoneFiles)
        // Reopening must use the saved Keychain credential without receiving the token again.
        let reopened = GitSyncClient()
        try await reopened.open(remoteURL: remote.url.absoluteString, at: macURL)
        let beforeNoOpSync = try await inspected.head()
        try await reopened.sync()
        let afterNoOpSync = try await inspected.head()
        XCTAssertEqual(beforeNoOpSync, afterNoOpSync)
        var localConflict = merged
        var remoteConflict = merged
        localConflict.body = "Synthetic conflicting Mac notes"
        remoteConflict.body = "Synthetic conflicting phone notes"
        try write(localConflict, path: taskPath, at: macURL)
        try write(remoteConflict, path: taskPath, at: phoneURL)
        let localBytes = try Data(contentsOf: macURL.appendingPathComponent(taskPath))
        try await phone.sync()
        do {
            try await reopened.sync()
            XCTFail("Expected a same-field conflict, not a last-writer-wins merge.")
        } catch let failure as GitSyncFailure {
            XCTAssertTrue(failure.conflicts.contains { $0.hasSuffix(": body") })
            XCTAssertFalse(failure.requiresRecovery)
        }
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent(taskPath)), localBytes)
        let committedLocalFiles = try await inspected.files()
        XCTAssertEqual(committedLocalFiles[taskPath]?.data, localBytes)

        let verificationURL = root.appendingPathComponent("verification")
        let verification = GitSyncClient()
        try await verification.clone(remoteURL: remote.url.absoluteString, to: verificationURL, token: token)
        XCTAssertEqual(try readTask(path: taskPath, plan: planName, at: verificationURL).body, remoteConflict.body)
        XCTAssertEqual(try Data(contentsOf: verificationURL.appendingPathComponent(attachmentPath)), binary)
        completed = testRun?.failureCount == 0
    }

    private func write(_ task: Task, path: String, at directory: URL) throws {
        try write(Data(MarkdownParser.serializeTask(task).utf8), path: path, at: directory)
    }

    private func write(_ data: Data, path: String, at directory: URL) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func readTask(path: String, plan: String, at directory: URL) throws -> Task {
        try MarkdownParser.parseTask(from: String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8), plan: plan)
    }
}
