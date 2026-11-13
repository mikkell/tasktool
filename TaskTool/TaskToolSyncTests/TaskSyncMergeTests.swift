import XCTest
@testable import TaskToolCore

final class TaskSyncMergeTests: XCTestCase {
    private func snapshot(_ title: String = "Example") -> TaskSyncSnapshot {
        TaskSyncSnapshot(
            task: Task(title: title, plan: "Work", status: "To Do", body: "Original"),
            path: "Work/\(title.lowercased()).md"
        )
    }

    func testIndependentFieldsMergeIncludingUpdatedTimestamp() throws {
        let base = snapshot()
        var local = base
        var remote = base
        local.task.status = "In Progress"
        local.task.updated = base.task.updated.addingTimeInterval(10)
        remote.task.body = "Edited on phone"
        remote.task.updated = base.task.updated.addingTimeInterval(20)
        let result = try TaskSyncMerge.reconcile(base: [base], local: [local], remote: [remote])
        XCTAssertTrue(result.canApply)
        XCTAssertEqual(result.snapshots.first?.task.status, "In Progress")
        XCTAssertEqual(result.snapshots.first?.task.body, "Edited on phone")
        XCTAssertEqual(result.snapshots.first?.task.updated, remote.task.updated)
    }

    func testRenameAndCrossPlanMoveMergeWithRemoteEditByUUID() throws {
        let base = snapshot()
        var local = base
        var remote = base
        local.task.title = "Renamed"
        local.task.plan = "Personal"
        local.path = "Personal/renamed.md"
        remote.task.body = "Remote edit"
        let result = try TaskSyncMerge.reconcile(base: [base], local: [local], remote: [remote])
        XCTAssertTrue(result.canApply)
        XCTAssertEqual(result.snapshots.first?.path, local.path)
        XCTAssertEqual(result.snapshots.first?.task.plan, "Personal")
        XCTAssertEqual(result.snapshots.first?.task.body, remote.task.body)
    }

    func testConflictingBodyRetainsOriginalInputsAndBlocksApply() throws {
        let base = snapshot()
        var local = base
        var remote = base
        local.task.body = "Local"
        remote.task.body = "Remote"
        let result = try TaskSyncMerge.reconcile(base: [base], local: [local], remote: [remote])
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.conflicts, [TaskSyncConflict(taskID: base.task.id, field: "body")])
        XCTAssertEqual(local.task.body, "Local")
        XCTAssertEqual(remote.task.body, "Remote")
    }

    func testDeletionVersusEditConflictsButUnchangedDeletionSucceeds() throws {
        let base = snapshot()
        var remote = base
        remote.task.status = "In Progress"
        let conflict = try TaskSyncMerge.reconcile(base: [base], local: [], remote: [remote])
        XCTAssertFalse(conflict.canApply)
        XCTAssertEqual(conflict.conflicts.first?.field, "deletion")
        let deletion = try TaskSyncMerge.reconcile(base: [base], local: [], remote: [base])
        XCTAssertTrue(deletion.canApply)
        XCTAssertTrue(deletion.snapshots.isEmpty)
    }

    func testIndependentCreationsAndEditsMerge() throws {
        let base = snapshot()
        var local = base
        local.task.body = "Updated"
        let added = snapshot("New")
        let result = try TaskSyncMerge.reconcile(base: [base], local: [local], remote: [base, added])
        XCTAssertTrue(result.canApply)
        XCTAssertEqual(result.snapshots.count, 2)
        XCTAssertEqual(result.snapshots.first { $0.task.id == base.task.id }?.task.body, "Updated")
    }

    func testCaseInsensitivePathCollisionsBlockApply() throws {
        let local = snapshot()
        var remote = snapshot("Other")
        remote.path = "work/EXAMPLE.md"
        let result = try TaskSyncMerge.reconcile(base: [], local: [local], remote: [remote])
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.conflicts.count, 2)
    }

    func testDuplicateIDsAndUnsafePathsAreRejected() throws {
        let task = snapshot()
        XCTAssertThrowsError(try TaskSyncMerge.reconcile(base: [], local: [task, task], remote: []))
        for path in ["/Work/task.md", "../task.md", "Work/../task.md", ".git/task.md", ".GIT/task.md", "Work//task.md", "Work/task\0.md"] {
            var invalid = task
            invalid.path = path
            XCTAssertThrowsError(try TaskSyncMerge.reconcile(base: [], local: [invalid], remote: []))
        }
    }

    func testArchiveMoveCombinesWithRemoteEditWithoutResurrectingActiveTask() throws {
        let base = snapshot()
        var local = base
        var remote = base
        local.path = "Work/Archived/example.md"
        remote.task.body = "Edited before learning about archive"
        let result = try TaskSyncMerge.reconcile(base: [base], local: [local], remote: [remote])
        XCTAssertTrue(result.canApply)
        XCTAssertEqual(result.snapshots.count, 1)
        XCTAssertEqual(result.snapshots.first?.path, local.path)
        XCTAssertEqual(result.snapshots.first?.task.body, remote.task.body)
    }

    func testConcurrentCreationWithSameUUIDConflicts() throws {
        let local = snapshot()
        var remote = local
        remote.task.body = "Different creation"
        let result = try TaskSyncMerge.reconcile(base: [], local: [local], remote: [remote])
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.conflicts.first?.field, "concurrentCreation")
    }
}
