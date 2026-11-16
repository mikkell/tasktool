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

    func testMobileOfflineEditsPreserveMetadataAndRejectStaleDrafts() async throws {
        let (mac, _, _) = try await seed()
        let initial = try await mac.mobileSnapshot()
        var richTask = try XCTUnwrap(initial.tasks.first?.task)
        richTask.tags = ["Important", "offline: test"]
        richTask.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        richTask.pingHistory = [Date(timeIntervalSince1970: 1_700_000_000)]
        try write(Data(MarkdownParser.serializeTask(richTask).utf8), path: "Work/example.md", at: macURL)
        let before = try await mac.mobileSnapshot()
        let task = try XCTUnwrap(before.tasks.first?.task)
        let head = try await mac.head()
        try await mac.saveMobileTask(task, status: "Done", dueDate: task.dueDate, body: "Offline notes")
        let after = try await mac.mobileSnapshot()
        let updated = try XCTUnwrap(after.tasks.first?.task)
        XCTAssertEqual(updated.status, "Done")
        XCTAssertEqual(updated.body, "Offline notes")
        XCTAssertEqual(updated.id, task.id)
        XCTAssertEqual(updated.created, task.created)
        XCTAssertNotNil(updated.completedAt)
        XCTAssertEqual(updated.tags, task.tags)
        XCTAssertEqual(updated.dueDate, task.dueDate)
        XCTAssertEqual(updated.pingHistory, task.pingHistory)
        let afterHead = try await mac.head()
        XCTAssertEqual(afterHead, head)
        do {
            try await mac.saveMobileTask(task, status: "To Do", dueDate: task.dueDate, body: "Stale notes")
            XCTFail("Expected stale draft rejection")
        } catch GitSyncError.dirtyWorkingCopy {}
        do {
            try await mac.saveMobileTask(updated, status: "Invalid status", dueDate: updated.dueDate, body: "Notes")
            XCTFail("Expected unknown status rejection")
        } catch GitSyncError.invalidMetadata {}
        let onDisk = try await mac.mobileSnapshot()
        XCTAssertEqual(onDisk.tasks.first?.task, updated)
    }

    func testMobileDueDateOnlyEditsCanBeSetChangedClearedAndSynced() async throws {
        let (mac, phone, _) = try await seed()
        let initial = try await mac.mobileSnapshot()
        let original = try XCTUnwrap(initial.tasks.first?.task)
        let head = try await mac.head()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await mac.saveMobileTask(original, status: original.status, dueDate: firstDate, body: original.body)
        let firstSnapshot = try await mac.mobileSnapshot()
        let dated = try XCTUnwrap(firstSnapshot.tasks.first?.task)
        XCTAssertEqual(dated.dueDate, firstDate)
        let revisedDate = firstDate.addingTimeInterval(86_400)
        try await mac.saveMobileTask(dated, status: dated.status, dueDate: revisedDate, body: dated.body)
        let revisedSnapshot = try await mac.mobileSnapshot()
        let revised = try XCTUnwrap(revisedSnapshot.tasks.first?.task)
        XCTAssertEqual(revised.dueDate, revisedDate)
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.status, original.status)
        XCTAssertEqual(revised.body, original.body)
        XCTAssertEqual(revised.created, original.created)
        let afterHead = try await mac.head()
        XCTAssertEqual(afterHead, head, "Due-date edits must be saved offline without committing or pushing.")
        do {
            try await mac.saveMobileTask(original, status: original.status, dueDate: nil, body: original.body)
            XCTFail("Expected stale due-date draft rejection")
        } catch GitSyncError.dirtyWorkingCopy {}
        try await mac.commitWorkingCopy(message: "Change task due date")
        try await mac.synchronize()
        try await phone.synchronize()
        let onPhone = try await phone.mobileSnapshot()
        let received = try XCTUnwrap(onPhone.tasks.first?.task)
        XCTAssertEqual(received.dueDate, revisedDate)
        try await phone.saveMobileTask(received, status: received.status, dueDate: nil, body: received.body)
        let cleared = try await phone.mobileSnapshot()
        XCTAssertNil(try XCTUnwrap(cleared.tasks.first?.task).dueDate)
        try await phone.commitWorkingCopy(message: "Clear task due date")
        try await phone.synchronize()
        try await mac.synchronize()
        let onMac = try await mac.mobileSnapshot()
        XCTAssertNil(try XCTUnwrap(onMac.tasks.first?.task).dueDate)
    }

    func testMobileCreationRoutesToSelectedPlanAndSyncsCustomStatusesAndDueDate() async throws {
        let (mac, phone, _) = try await seed()
        let plan = Plan(name: "Personal", statuses: [
            Plan.TaskStatus(name: "Doing", color: "blue", order: 1),
            Plan.TaskStatus(name: "Queued", color: "gray", order: 0),
            Plan.TaskStatus(name: "Done", color: "green", order: 2)
        ])
        try write(Data(MarkdownParser.serializePlan(plan).utf8), path: "Personal/plan.yaml", at: macURL)
        let originalHead = try await mac.head()
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await mac.createMobileTask(title: "  Default status  ", planID: plan.id)
        try await mac.createMobileTask(
            title: "Custom status", planID: plan.id, status: "Doing", dueDate: dueDate, body: "- [ ] Offline notes\n\n## Details"
        )
        try await mac.createMobileTask(title: "Completed task", planID: plan.id, status: "Done")
        let local = try await mac.mobileSnapshot()
        let defaultTask = try XCTUnwrap(local.tasks.first { $0.task.title == "Default status" })
        XCTAssertEqual(defaultTask.task.status, "Queued")
        XCTAssertEqual(defaultTask.path, "Personal/default-status.md")
        XCTAssertNil(defaultTask.task.dueDate)
        let custom = try XCTUnwrap(local.tasks.first { $0.task.title == "Custom status" })
        XCTAssertEqual(custom.path, "Personal/custom-status.md")
        XCTAssertEqual(custom.task.plan, "Personal")
        XCTAssertEqual(custom.task.status, "Doing")
        XCTAssertEqual(custom.task.dueDate, dueDate)
        XCTAssertEqual(custom.task.body, "- [ ] Offline notes\n\n## Details")
        XCTAssertEqual(custom.task.created, custom.task.updated)
        XCTAssertNil(custom.task.completedAt)
        XCTAssertNotNil(local.tasks.first { $0.task.title == "Completed task" }?.task.completedAt)
        let afterCreationHead = try await mac.head()
        XCTAssertEqual(afterCreationHead, originalHead, "Offline creation must not commit or push.")
        let remoteBeforeSync = try await phone.mobileSnapshot()
        XCTAssertFalse(remoteBeforeSync.tasks.contains { $0.task.id == custom.task.id })
        try await mac.commitWorkingCopy(message: "Create offline phone tasks")
        try await mac.synchronize()
        try await phone.synchronize()
        let received = try await phone.mobileSnapshot()
        XCTAssertEqual(received.tasks.first { $0.task.id == custom.task.id }, custom)
    }

    func testMobilePlanMovePreservesMetadataAvoidsCollisionsAndSyncsSubtasks() async throws {
        let (mac, phone, _) = try await seed()
        let plan = Plan(name: "Personal", statuses: [
            Plan.TaskStatus(name: "Queued", color: "gray", order: 0),
            Plan.TaskStatus(name: "Done", color: "green", order: 1)
        ])
        let existing = Task(title: "Example", plan: plan.name, status: "Done", order: 7)
        try write(Data(MarkdownParser.serializePlan(plan).utf8), path: "Personal/plan.yaml", at: macURL)
        let existingBytes = Data(MarkdownParser.serializeTask(existing).utf8)
        try write(existingBytes, path: "Personal/example.md", at: macURL)
        let initial = try await mac.mobileSnapshot()
        var richTask = try XCTUnwrap(initial.tasks.first { $0.task.plan == "Work" }?.task)
        richTask.tags = ["Important"]
        richTask.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        richTask.pingHistory = [Date(timeIntervalSince1970: 1_700_000_000)]
        richTask.body = "- [ ] First\n- [x] Second\n\n**Notes**"
        try write(Data(MarkdownParser.serializeTask(richTask).utf8), path: "Work/example.md", at: macURL)
        let before = try await mac.mobileSnapshot()
        let original = try XCTUnwrap(before.tasks.first { $0.task.id == richTask.id }?.task)
        let head = try await mac.head()
        var draft = MobileTaskBody(original.body)
        draft.subtasks[0].isCompleted = true
        try await mac.saveMobileTask(original, planID: plan.id, status: "Done", dueDate: original.dueDate, body: draft.markdown)
        let after = try await mac.mobileSnapshot()
        let moved = try XCTUnwrap(after.tasks.first { $0.task.id == original.id })
        XCTAssertEqual(moved.path, "Personal/example-\(original.id.uuidString.lowercased().prefix(8)).md")
        XCTAssertEqual(moved.task.plan, "Personal")
        XCTAssertEqual(moved.task.status, "Done")
        XCTAssertEqual(moved.task.order, 8)
        XCTAssertEqual(moved.task.body, "- [x] First\n- [x] Second\n\n**Notes**")
        XCTAssertEqual(moved.task.created, original.created)
        XCTAssertEqual(moved.task.tags, original.tags)
        XCTAssertEqual(moved.task.dueDate, original.dueDate)
        XCTAssertEqual(moved.task.pingHistory, original.pingHistory)
        XCTAssertNotNil(moved.task.completedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: macURL.appendingPathComponent("Work/example.md").path))
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Personal/example.md")), existingBytes)
        let afterHead = try await mac.head()
        XCTAssertEqual(afterHead, head, "Moving and checking subtasks must remain offline until sync.")
        try await mac.commitWorkingCopy(message: "Move phone task and complete subtask")
        try await mac.synchronize()
        try await phone.synchronize()
        let received = try await phone.mobileSnapshot()
        XCTAssertEqual(received.tasks.first { $0.task.id == original.id }, moved)
    }

    func testMobilePlanMoveRejectsMissingPlansInvalidStatusesAndStaleDrafts() async throws {
        let (mac, _, _) = try await seed()
        let plan = Plan(name: "Personal", statuses: [Plan.TaskStatus(name: "Queued", color: "gray", order: 0)])
        try write(Data(MarkdownParser.serializePlan(plan).utf8), path: "Personal/plan.yaml", at: macURL)
        let before = try await mac.mobileSnapshot()
        let task = try XCTUnwrap(before.tasks.first?.task)
        do {
            try await mac.saveMobileTask(task, planID: UUID(), status: "Queued", dueDate: task.dueDate, body: task.body)
            XCTFail("Expected missing plan rejection")
        } catch GitSyncError.missingPlan {}
        do {
            try await mac.saveMobileTask(task, planID: plan.id, status: "To Do", dueDate: task.dueDate, body: task.body)
            XCTFail("Expected destination status validation")
        } catch GitSyncError.invalidMetadata {}
        let after = try await mac.mobileSnapshot()
        XCTAssertEqual(after, before)
        var changed = task
        changed.body = "External edit"
        let changedBytes = Data(MarkdownParser.serializeTask(changed).utf8)
        try write(changedBytes, path: "Work/example.md", at: macURL)
        do {
            try await mac.saveMobileTask(task, planID: plan.id, status: "Queued", dueDate: task.dueDate, body: "Stale edit")
            XCTFail("Expected stale draft rejection")
        } catch GitSyncError.dirtyWorkingCopy {}
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/example.md")), changedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: macURL.appendingPathComponent("Personal/example.md").path))
    }

    func testMobilePlanMoveKeepsSourceWhenDestinationIsIgnoredAndSamePlanSaveIsANoop() async throws {
        let (mac, _, _) = try await seed()
        let plan = Plan(name: "Personal")
        try write(Data(MarkdownParser.serializePlan(plan).utf8), path: "Personal/plan.yaml", at: macURL)
        try write(Data("Personal/*.md\n".utf8), path: ".gitignore", at: macURL)
        let before = try await mac.mobileSnapshot()
        let task = try XCTUnwrap(before.tasks.first?.task)
        let workPlan = try XCTUnwrap(before.plans.first { $0.name == "Work" })
        let originalBytes = try Data(contentsOf: macURL.appendingPathComponent("Work/example.md"))
        try await mac.saveMobileTask(task, planID: workPlan.id, status: task.status, dueDate: task.dueDate, body: task.body)
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/example.md")), originalBytes)
        do {
            try await mac.saveMobileTask(task, planID: plan.id, status: task.status, dueDate: task.dueDate, body: task.body)
            XCTFail("Expected ignored destination rejection")
        } catch GitSyncError.unsupportedFile("Personal/example.md") {}
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/example.md")), originalBytes)
        let after = try await mac.mobileSnapshot()
        XCTAssertEqual(after, before)
    }

    func testMobileCreationAvoidsDuplicateSlugsAndUsesUUIDForEmptySlugs() async throws {
        let (mac, _, original) = try await seed()
        let snapshot = try await mac.mobileSnapshot()
        let plan = try XCTUnwrap(snapshot.plans.first)
        let originalBytes = try Data(contentsOf: macURL.appendingPathComponent("Work/example.md"))
        try await mac.createMobileTask(title: "Example", planID: plan.id)
        try await mac.createMobileTask(title: "EXAMPLE", planID: plan.id)
        try await mac.createMobileTask(title: "\u{1F4DD}", planID: plan.id)
        let created = try await mac.mobileSnapshot()
        XCTAssertEqual(created.tasks.count, 4)
        XCTAssertEqual(Set(created.tasks.map { $0.path.lowercased() }).count, 4)
        XCTAssertEqual(try Data(contentsOf: macURL.appendingPathComponent("Work/example.md")), originalBytes)
        XCTAssertEqual(created.tasks.first { $0.task.id == original.id }, snapshot.tasks.first { $0.task.id == original.id })
        let duplicates = created.tasks.filter { $0.task.title.lowercased() == "example" && $0.task.id != original.id }
        for duplicate in duplicates {
            XCTAssertEqual(duplicate.path, "Work/example-\(duplicate.task.id.uuidString.lowercased().prefix(8)).md")
        }
        XCTAssertEqual(duplicates.map(\.task.order).sorted(), [1, 2])
        let emoji = try XCTUnwrap(created.tasks.first { $0.task.title == "\u{1F4DD}" })
        XCTAssertEqual(emoji.path, "Work/\(emoji.task.id.uuidString.lowercased().prefix(8)).md")
    }

    func testMobileCreationRejectsInvalidInputsWithoutWritingFiles() async throws {
        let (mac, _, _) = try await seed()
        let before = try await mac.mobileSnapshot()
        let plan = try XCTUnwrap(before.plans.first)
        for title in [" \n ", "First line\nSecond line"] {
            do {
                try await mac.createMobileTask(title: title, planID: plan.id)
                XCTFail("Expected invalid title rejection")
            } catch GitSyncError.invalidTaskTitle {}
        }
        do {
            try await mac.createMobileTask(title: "Missing plan", planID: UUID())
            XCTFail("Expected missing plan rejection")
        } catch GitSyncError.missingPlan {}
        do {
            try await mac.createMobileTask(title: "Wrong status", planID: plan.id, status: "Not a status")
            XCTFail("Expected unknown status rejection")
        } catch GitSyncError.invalidTaskStatus {}
        let after = try await mac.mobileSnapshot()
        XCTAssertEqual(after, before)
    }

    func testMobileCreationDoesNotWriteTasksThatGitWouldIgnore() async throws {
        let (mac, _, _) = try await seed()
        let snapshot = try await mac.mobileSnapshot()
        let plan = try XCTUnwrap(snapshot.plans.first)
        try write(Data("Work/ignored.md\n".utf8), path: ".gitignore", at: macURL)
        do {
            try await mac.createMobileTask(title: "Ignored", planID: plan.id)
            XCTFail("Expected ignored-file rejection")
        } catch GitSyncError.unsupportedFile("Work/ignored.md") {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: macURL.appendingPathComponent("Work/ignored.md").path))
    }

    func testMobileBundleNotesAreEditableButStatusChangesAreRejected() async throws {
        let (mac, _, original) = try await seed()
        let bundleID = UUID()
        var child = original
        child.parentBundleID = bundleID
        let sibling = Task(title: "Sibling", plan: "Work", status: "To Do", parentBundleID: bundleID)
        let bundle = Task(id: bundleID, title: "Bundle", plan: "Work", status: "To Do", bundledTaskIDs: [child.id, sibling.id])
        for task in [child, sibling, bundle] {
            try write(Data(MarkdownParser.serializeTask(task).utf8), path: "Work/\(task.fileName)", at: macURL)
        }
        let otherPlan = Plan(name: "Personal")
        try write(Data(MarkdownParser.serializePlan(otherPlan).utf8), path: "Personal/plan.yaml", at: macURL)
        let snapshot = try await mac.mobileSnapshot()
        let loaded = try XCTUnwrap(snapshot.tasks.first(where: { $0.task.id == child.id })?.task)
        do {
            try await mac.saveMobileTask(loaded, status: "Done", dueDate: loaded.dueDate, body: loaded.body)
            XCTFail("Expected bundle status change rejection")
        } catch GitSyncError.invalidMetadata {}
        for id in [child.id, bundle.id] {
            let bundled = try XCTUnwrap(snapshot.tasks.first { $0.task.id == id }?.task)
            do {
                try await mac.saveMobileTask(bundled, planID: otherPlan.id, status: bundled.status, dueDate: bundled.dueDate, body: bundled.body)
                XCTFail("Expected bundle plan change rejection")
            } catch GitSyncError.invalidMetadata {}
        }
        try await mac.saveMobileTask(loaded, status: loaded.status, dueDate: loaded.dueDate, body: "Child notes")
        let after = try await mac.mobileSnapshot()
        XCTAssertEqual(after.tasks.first(where: { $0.task.id == child.id })?.task.body, "Child notes")
        XCTAssertEqual(after.tasks.first(where: { $0.task.id == bundle.id })?.task.bundledTaskIDs, bundle.bundledTaskIDs)
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
