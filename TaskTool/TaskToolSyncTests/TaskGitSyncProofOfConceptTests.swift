#if os(macOS)
import XCTest
@testable import TaskToolCore

/// Test-only transport: no Git subprocesses are added to the application.
final class TaskGitSyncProofOfConceptTests: XCTestCase {
    private var root: URL!
    private var origin: URL!
    private var mac: URL!
    private var phone: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskToolGitSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        origin = root.appendingPathComponent("origin.git")
        mac = root.appendingPathComponent("mac")
        phone = root.appendingPathComponent("phone")
        try git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
        try git(["clone", origin.path, mac.path], in: root)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testOfflineEditsRenameAndPushRaceReconcileThroughRealGit() throws {
        let original = Task(title: "Example", plan: "Work", status: "To Do", body: "Original")
        try seed(original)

        var macTask = original
        macTask.title = "Renamed"
        macTask.plan = "Personal"
        macTask.status = "In Progress"
        try write(macTask, path: "Personal/renamed.md", in: mac)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("Work/example.md"))
        try commit("Offline Mac edit", in: mac)

        var phoneTask = original
        phoneTask.body = "Offline phone edit"
        try write(phoneTask, path: "Work/example.md", in: phone)
        try commit("Offline phone edit", in: phone)
        try git(["push", "origin", "main"], in: phone)
        XCTAssertThrowsError(try git(["push", "origin", "main"], in: mac))

        // A fetch-only interruption leaves both the local edit and commit durable.
        let localHead = try git(["rev-parse", "HEAD"], in: mac)
        try git(["fetch", "origin"], in: mac)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: mac), localHead)
        XCTAssertEqual(try snapshots("HEAD", in: mac).first?.task.body, "Original")

        try reconcileAndCommit(in: mac)

        // Another writer wins the race after reconciliation but before our push.
        phoneTask.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        try write(phoneTask, path: "Work/example.md", in: phone)
        try commit("Phone changes during sync", in: phone)
        try git(["push", "origin", "main"], in: phone)
        XCTAssertThrowsError(try git(["push", "origin", "main"], in: mac))
        try reconcileAndCommit(in: mac)
        try git(["push", "origin", "main"], in: mac)
        try git(["pull", "--ff-only"], in: phone)

        let macSnapshots = try snapshots("HEAD", in: mac)
        XCTAssertEqual(macSnapshots, try snapshots("HEAD", in: phone))
        let merged = try XCTUnwrap(macSnapshots.first)
        XCTAssertEqual(merged.task.id, original.id)
        XCTAssertEqual(merged.path, "Personal/renamed.md")
        XCTAssertEqual(merged.task.status, "In Progress")
        XCTAssertEqual(merged.task.body, "Offline phone edit")
        XCTAssertEqual(merged.task.dueDate, phoneTask.dueDate)
        XCTAssertEqual(try git(["status", "--porcelain"], in: mac), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent("Work/example.md").path))
    }

    func testConflictLeavesBothGitVersionsAndWorkingCopyUntouched() throws {
        let original = Task(title: "Example", plan: "Work", status: "To Do", body: "Original")
        try seed(original)
        var local = original
        local.body = "Mac text"
        try write(local, path: "Work/example.md", in: mac)
        try commit("Mac text", in: mac)
        var remote = original
        remote.body = "Phone text"
        try write(remote, path: "Work/example.md", in: phone)
        try commit("Phone text", in: phone)
        try git(["push", "origin", "main"], in: phone)

        let head = try git(["rev-parse", "HEAD"], in: mac)
        let before = try String(contentsOf: mac.appendingPathComponent("Work/example.md"), encoding: .utf8)
        try git(["fetch", "origin"], in: mac)
        let result = try reconciliation(in: mac)
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.conflicts.first?.field, "body")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: mac), head)
        XCTAssertEqual(try String(contentsOf: mac.appendingPathComponent("Work/example.md"), encoding: .utf8), before)
        XCTAssertEqual(try snapshots("origin/main", in: mac).first?.task.body, "Phone text")
        XCTAssertEqual(try git(["status", "--porcelain"], in: mac), "")
    }

    func testDeleteVersusRemoteEditPreservesHistoryAndBlocksReconciliation() throws {
        let original = Task(title: "Example", plan: "Work", status: "To Do", body: "Original")
        try seed(original)
        try FileManager.default.removeItem(at: mac.appendingPathComponent("Work/example.md"))
        try commit("Delete on Mac", in: mac)
        var remote = original
        remote.body = "Phone edit while offline"
        try write(remote, path: "Work/example.md", in: phone)
        try commit("Edit on phone", in: phone)
        try git(["push", "origin", "main"], in: phone)
        try git(["fetch", "origin"], in: mac)
        let result = try reconciliation(in: mac)
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.conflicts.first?.field, "deletion")
        XCTAssertTrue(try snapshots("HEAD", in: mac).isEmpty)
        XCTAssertEqual(try snapshots("origin/main", in: mac).first?.task.body, remote.body)
        XCTAssertEqual(try snapshots("HEAD~1", in: mac).first?.task.body, original.body)
    }

    func testPlanAndSettingsEditsReconcileTogetherAcrossClones() throws {
        try seed(Task(title: "Example", plan: "Work", status: "To Do"))
        var local = try repositorySnapshot("HEAD", in: mac)
        var remote = try repositorySnapshot("HEAD", in: phone)
        let localIndex = try XCTUnwrap(local.plans.firstIndex { $0.name == "Work" })
        let remoteIndex = try XCTUnwrap(remote.plans.firstIndex { $0.name == "Work" })
        local.plans[localIndex].color = "purple"
        local.settings?.availableTags = ["urgent"]
        remote.plans[remoteIndex].description = "Phone description"
        remote.settings?.overviewFocusNote = "Phone focus"
        try writeMetadata(local, in: mac)
        try commit("Offline Mac metadata", in: mac)
        try writeMetadata(remote, in: phone)
        try commit("Offline phone metadata", in: phone)
        try git(["push", "origin", "main"], in: phone)
        try reconcileAndCommit(in: mac)
        try git(["push", "origin", "main"], in: mac)
        try git(["pull", "--ff-only"], in: phone)
        let merged = try repositorySnapshot("HEAD", in: mac)
        XCTAssertEqual(merged, try repositorySnapshot("HEAD", in: phone))
        let plan = try XCTUnwrap(merged.plans.first { $0.name == "Work" })
        XCTAssertEqual(plan.color, "purple")
        XCTAssertEqual(plan.description, "Phone description")
        XCTAssertEqual(merged.settings?.availableTags, ["urgent"])
        XCTAssertEqual(merged.settings?.overviewFocusNote, "Phone focus")
    }

    func testSettingsConflictBlocksOtherwiseIndependentTaskEditWithoutWriting() throws {
        try seed(Task(title: "Example", plan: "Work", status: "To Do"))
        var local = try repositorySnapshot("HEAD", in: mac)
        var remote = try repositorySnapshot("HEAD", in: phone)
        local.settings?.availableTags = ["mac"]
        local.tasks[0].task.body = "Unsynced Mac task edit"
        remote.settings?.availableTags = ["phone"]
        try writeMetadata(local, in: mac)
        try write(local.tasks[0].task, path: local.tasks[0].path, in: mac)
        try commit("Mac changes", in: mac)
        try writeMetadata(remote, in: phone)
        try commit("Phone tags", in: phone)
        try git(["push", "origin", "main"], in: phone)
        let before = try repositorySnapshot("HEAD", in: mac)
        let head = try git(["rev-parse", "HEAD"], in: mac)
        XCTAssertThrowsError(try reconcileAndCommit(in: mac))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: mac), head)
        XCTAssertEqual(try repositorySnapshot("HEAD", in: mac), before)
        XCTAssertEqual(try git(["status", "--porcelain"], in: mac), "")
        XCTAssertEqual(try repositorySnapshot("origin/main", in: mac).settings?.availableTags, ["phone"])
    }

    private func seed(_ task: Task) throws {
        try write(task, path: "Work/example.md", in: mac)
        for name in ["Work", "Personal"] {
            let folder = mac.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MarkdownParser.serializePlan(Plan(name: name))
                .write(to: folder.appendingPathComponent("plan.yaml"), atomically: false, encoding: .utf8)
        }
        try MarkdownParser.serializeSettings(Settings(planOrder: ["Work", "Personal"]))
            .write(to: mac.appendingPathComponent("settings.yaml"), atomically: false, encoding: .utf8)
        try commit("Initial tasks", in: mac)
        try git(["push", "origin", "main"], in: mac)
        try git(["clone", origin.path, phone.path], in: root)
    }

    private func write(_ task: Task, path: String, in repository: URL) throws {
        let file = repository.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MarkdownParser.serializeTask(task).write(to: file, atomically: false, encoding: .utf8)
    }

    private func commit(_ message: String, in repository: URL) throws {
        try git(["add", "--all"], in: repository)
        try git(["commit", "-m", message], in: repository)
    }

    private func snapshots(_ revision: String, in repository: URL) throws -> [TaskSyncSnapshot] {
        let files = try git(["ls-tree", "-rz", "--name-only", revision], in: repository)
        return try files.split(separator: "\0").filter { $0.hasSuffix(".md") }.map { file in
            let path = String(file)
            let content = try git(["show", "\(revision):\(path)"], in: repository)
            let plan = String(file.split(separator: "/")[0])
            return TaskSyncSnapshot(task: try MarkdownParser.parseTask(from: content, plan: plan), path: path)
        }
    }

    private func repositorySnapshot(_ revision: String, in repository: URL) throws -> RepositorySyncSnapshot {
        let files = try git(["ls-tree", "-rz", "--name-only", revision], in: repository)
            .split(separator: "\0").map(String.init)
        let settings: Settings?
        if files.contains("settings.yaml") {
            settings = try MarkdownParser.parseSettings(from: git(["show", "\(revision):settings.yaml"], in: repository))
        } else {
            settings = nil
        }
        let plans = try files.filter {
            $0.split(separator: "/").count == 2 && $0.hasSuffix("/plan.yaml")
        }.map { path -> Plan in
            let name = String(path.split(separator: "/")[0])
            var plan = try MarkdownParser.parsePlan(
                from: git(["show", "\(revision):\(path)"], in: repository), name: name
            )
            plan.order = settings?.planOrder.firstIndex(of: name) ?? Int.max
            return plan
        }
        return RepositorySyncSnapshot(tasks: try snapshots(revision, in: repository), plans: plans, settings: settings)
    }

    private func writeMetadata(_ snapshot: RepositorySyncSnapshot, in repository: URL) throws {
        for plan in snapshot.plans {
            let folder = repository.appendingPathComponent(plan.name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MarkdownParser.serializePlan(plan)
                .write(to: folder.appendingPathComponent("plan.yaml"), atomically: false, encoding: .utf8)
        }
        if let settings = snapshot.settings {
            try MarkdownParser.serializeSettings(settings)
                .write(to: repository.appendingPathComponent("settings.yaml"), atomically: false, encoding: .utf8)
        }
    }

    private func reconciliation(in repository: URL) throws -> RepositorySyncMergeResult {
        let ancestor = try git(["merge-base", "HEAD", "origin/main"], in: repository)
        return try RepositorySyncMerge.reconcile(
            base: repositorySnapshot(ancestor, in: repository),
            local: repositorySnapshot("HEAD", in: repository),
            remote: repositorySnapshot("origin/main", in: repository)
        )
    }

    private func reconcileAndCommit(in repository: URL) throws {
        try git(["fetch", "origin"], in: repository)
        let result = try reconciliation(in: repository)
        guard result.canApply else {
            throw ProofError.conflict
        }
        // The harness uses a merge commit to retain ancestry, but installs the
        // semantic result rather than accepting Git's line-based task merge.
        try git(["merge", "-s", "ours", "--no-commit", "origin/main"], in: repository)
        let original = try repositorySnapshot("HEAD", in: repository)
        for snapshot in original.tasks {
            try FileManager.default.removeItem(at: repository.appendingPathComponent(snapshot.path))
        }
        for plan in original.plans {
            try FileManager.default.removeItem(at: repository.appendingPathComponent("\(plan.name)/plan.yaml"))
        }
        if original.settings != nil {
            try FileManager.default.removeItem(at: repository.appendingPathComponent("settings.yaml"))
        }
        for snapshot in result.snapshot.tasks {
            try write(snapshot.task, path: snapshot.path, in: repository)
        }
        try writeMetadata(result.snapshot, in: repository)
        try commit("Reconcile task snapshots", in: repository)
    }

    private enum ProofError: Error {
        case git(Int32, String)
        case conflict
    }

    @discardableResult
    private func git(_ arguments: [String], in repository: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repository
        process.arguments = [
            "-c", "user.name=TaskTool Sync Test",
            "-c", "user.email=sync-test@example.invalid",
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null"
        ] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProofError.git(process.terminationStatus, String(decoding: errorData, as: UTF8.self))
        }
        // Trim only Git's final newline, preserving task body whitespace.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
#endif
