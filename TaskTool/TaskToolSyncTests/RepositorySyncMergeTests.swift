import XCTest
@testable import TaskToolCore

final class RepositorySyncMergeTests: XCTestCase {
    private func fixture() -> RepositorySyncSnapshot {
        let work = Plan(name: "Work")
        let personal = Plan(name: "Personal")
        let task = Task(title: "Example", plan: work.name, status: work.statuses[0].name)
        return RepositorySyncSnapshot(
            tasks: [TaskSyncSnapshot(task: task, path: "Work/example.md")],
            plans: [work, personal],
            settings: Settings(planOrder: ["Work", "Personal"], habits: [
                Habit(id: "walk", name: "Walk"), Habit(id: "read", name: "Read")
            ])
        )
    }

    func testIndependentPlanStatusSettingsAndHabitFieldsMerge() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans[0].color = "purple"
        local.plans[0].statuses[0].color = "orange"
        local.plans[0].order = 99
        local.settings?.availableTags = ["urgent"]
        local.settings?.habits[0].name = "Morning walk"
        remote.plans[0].description = "Edited on phone"
        remote.plans[0].statuses[1].color = "pink"
        remote.settings?.overviewFocusNote = "Today's focus"
        remote.settings?.habits[0].completedDates = ["2026-11-13"]
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertTrue(result.canApply, "\(result.conflicts)")
        let work = try XCTUnwrap(result.snapshot.plans.first { $0.name == "Work" })
        XCTAssertEqual(work.color, "purple")
        XCTAssertEqual(work.description, "Edited on phone")
        XCTAssertEqual(work.statuses.first { $0.id == base.plans[0].statuses[0].id }?.color, "orange")
        XCTAssertEqual(work.statuses.first { $0.id == base.plans[0].statuses[1].id }?.color, "pink")
        XCTAssertEqual(work.order, 0)
        XCTAssertEqual(result.snapshot.settings?.availableTags, ["urgent"])
        XCTAssertEqual(result.snapshot.settings?.overviewFocusNote, "Today's focus")
        XCTAssertEqual(result.snapshot.settings?.habits[0].name, "Morning walk")
        XCTAssertEqual(result.snapshot.settings?.habits[0].completedDates, ["2026-11-13"])
    }

    func testRenamePlanCombinesWithRemoteTaskAndPlanEdits() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans[0].name = "Office"
        local.tasks[0].task.plan = "Office"
        local.tasks[0].path = "Office/example.md"
        local.settings?.planOrder = ["Office", "Personal"]
        remote.tasks[0].task.body = "Phone notes"
        remote.plans[0].description = "Phone description"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertTrue(result.canApply, "\(result.conflicts)")
        XCTAssertEqual(result.snapshot.tasks[0].task.body, "Phone notes")
        XCTAssertEqual(result.snapshot.tasks[0].path, "Office/example.md")
        XCTAssertEqual(result.snapshot.plans[0].description, "Phone description")
        XCTAssertEqual(result.snapshot.settings?.planOrder, ["Office", "Personal"])
    }

    func testOverlappingFieldsAndListsAreConflictsNotLastWriterWins() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans[0].color = "red"
        remote.plans[0].color = "green"
        local.settings?.availableTags = ["local"]
        remote.settings?.availableTags = ["remote"]
        local.settings?.habits[0].completedDates = ["2026-11-12"]
        remote.settings?.habits[0].completedDates = ["2026-11-13"]
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .plan(base.plans[0].id), field: "color")))
        XCTAssertTrue(result.conflicts.contains(.init(entity: .settings, field: "availableTags")))
        XCTAssertTrue(result.conflicts.contains(.init(entity: .habit("walk"), field: "completedDates")))
        XCTAssertEqual(local.settings?.availableTags, ["local"])
        XCTAssertEqual(remote.settings?.availableTags, ["remote"])
    }

    func testIndependentHabitEditsMergeButDeleteVersusEditConflicts() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.settings?.habits[0].completedDates = ["2026-11-12"]
        remote.settings?.habits[1].completedDates = ["2026-11-13"]
        let merged = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertTrue(merged.canApply)
        XCTAssertEqual(merged.snapshot.settings?.habits.map(\.completedDates), [["2026-11-12"], ["2026-11-13"]])
        local.settings?.habits.remove(at: 1)
        let conflict = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(conflict.canApply)
        XCTAssertTrue(conflict.conflicts.contains(.init(entity: .habit("read"), field: "deletion")))
    }

    func testFocusRolloverDoesNotSilentlyReuseOfflineNotesFromAnotherDay() throws {
        var base = fixture()
        base.settings?.overviewFocusDate = "2026-11-12"
        var local = base
        var remote = base
        local.settings?.overviewFocusDate = "2026-11-13"
        remote.settings?.overviewFocusNote = "Offline note for November 12"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .settings, field: "overviewFocus")))
    }

    func testDeletedPlanCannotAcquireANewRemoteTask() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans.remove(at: 0)
        local.tasks = []
        local.settings?.planOrder = ["Personal"]
        let task = Task(title: "New", plan: "Work", status: "To Do")
        remote.tasks.append(.init(task: task, path: "Work/new.md"))
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(task.id), field: "missingPlan")))
    }

    func testDeletedStatusCannotReceiveRemoteTaskMove() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans[0].statuses.removeAll { $0.name == "In Progress" }
        remote.tasks[0].task.status = "In Progress"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(base.tasks[0].task.id), field: "missingStatus")))
    }

    func testPlanDeletionVersusEditAndSettingsDeletionVersusEditConflict() throws {
        let base = fixture()
        var local = base
        var remote = base
        local.plans.remove(at: 1)
        local.settings = nil
        remote.plans[1].description = "Edited"
        remote.settings?.overviewFocusNote = "Edited"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .plan(base.plans[1].id), field: "deletion")))
        XCTAssertTrue(result.conflicts.contains(.init(entity: .settings, field: "deletion")))
    }

    func testCaseInsensitivePlanCollisionsAndPathMismatchBlockApply() throws {
        let base = fixture()
        var local = base
        var remote = base
        remote.plans.append(Plan(name: "work"))
        local.tasks[0].path = "Personal/example.md"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .plan(base.plans[0].id), field: "nameCollision")))
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(base.tasks[0].task.id), field: "planPathMismatch")))
    }

    func testConcurrentBundleAndChildMoveCannotCreateBrokenRelationships() throws {
        var base = fixture()
        let child = Task(title: "Child", plan: "Work", status: "To Do")
        base.tasks.append(.init(task: child, path: "Work/child.md"))
        var local = base
        var remote = base
        local.tasks[0].task.bundledTaskIDs = [child.id]
        local.tasks[1].task.parentBundleID = base.tasks[0].task.id
        remote.tasks[1].task.plan = "Personal"
        remote.tasks[1].path = "Personal/child.md"
        let result = try RepositorySyncMerge.reconcile(base: base, local: local, remote: remote)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(child.id), field: "invalidBundle")))
    }

    func testTaskPathCannotUseMetadataOrAnotherTaskFileAsADirectory() throws {
        let base = fixture()
        var invalid = base
        invalid.tasks[0].path = "Work/plan.yaml/example.md"
        var result = try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .plan(base.plans[0].id), field: "pathCollision")))
        invalid = base
        let task = Task(title: "Child", plan: "Work", status: "To Do")
        invalid.tasks.append(.init(task: task, path: "Work/example.md/child.md"))
        result = try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(task.id), field: "pathCollision")))
    }

    func testBundleCycleIsRejectedEvenWhenBothSidesAgree() throws {
        var base = fixture()
        let child = Task(title: "Child", plan: "Work", status: "To Do")
        base.tasks.append(.init(task: child, path: "Work/child.md"))
        var cyclic = base
        cyclic.tasks[0].task.bundledTaskIDs = [child.id]
        cyclic.tasks[0].task.parentBundleID = child.id
        cyclic.tasks[1].task.bundledTaskIDs = [base.tasks[0].task.id]
        cyclic.tasks[1].task.parentBundleID = base.tasks[0].task.id
        let result = try RepositorySyncMerge.reconcile(base: base, local: cyclic, remote: cyclic)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .task(child.id), field: "bundleCycle")))
    }

    func testDuplicateMetadataIDsAreRejectedAndInvalidPlanOrderBlocksApply() throws {
        let base = fixture()
        var invalid = base
        invalid.plans.append(base.plans[0])
        XCTAssertThrowsError(try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base))
        invalid = base
        invalid.plans[0].statuses.append(base.plans[0].statuses[0])
        XCTAssertThrowsError(try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base))
        invalid = base
        invalid.settings?.habits.append(base.settings!.habits[0])
        XCTAssertThrowsError(try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base))
        invalid = base
        invalid.settings?.planOrder = ["Missing"]
        let result = try RepositorySyncMerge.reconcile(base: base, local: invalid, remote: base)
        XCTAssertFalse(result.canApply)
        XCTAssertTrue(result.conflicts.contains(.init(entity: .settings, field: "invalidPlanOrder")))
    }
}
