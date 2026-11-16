import XCTest
@testable import TaskToolCore

@MainActor
final class AutoSyncSchedulerTests: XCTestCase {
    func testForegroundAndFiveMinutePollingStopWhileInactive() async {
        var now = Date(timeIntervalSince1970: 0)
        var attempts = 0
        let scheduler = AutoSyncScheduler(now: { now }, runsTimer: false, canSync: { true }) {
            attempts += 1
        }
        scheduler.setActive(true)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        now.addTimeInterval(299)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        now.addTimeInterval(1)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 2)
        scheduler.setActive(false)
        now.addTimeInterval(600)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 2)
        scheduler.setActive(true)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 3)
    }

    func testRepeatedEditsDebounceAndDelayAnOtherwiseDuePoll() async {
        var now = Date(timeIntervalSince1970: 0)
        var attempts = 0
        let scheduler = AutoSyncScheduler(now: { now }, runsTimer: false, canSync: { true }) {
            attempts += 1
        }
        scheduler.setActive(true)
        scheduler.recordEdit()
        now.addTimeInterval(4)
        scheduler.recordEdit()
        await scheduler.runDueSync()
        now.addTimeInterval(4)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 0)
        now.addTimeInterval(1)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        now.addTimeInterval(5)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
    }

    func testBusyOrOpenEditorRetainsPendingWorkAndConflictPauseRequiresExplicitResume() async {
        var now = Date(timeIntervalSince1970: 0)
        var eligible = false
        var attempts = 0
        let scheduler = AutoSyncScheduler(now: { now }, runsTimer: false, canSync: { eligible }) {
            attempts += 1
        }
        scheduler.setActive(true)
        scheduler.recordEdit()
        now.addTimeInterval(10)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 0)
        eligible = true
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        scheduler.setPaused(true)
        scheduler.recordEdit()
        now.addTimeInterval(600)
        scheduler.setActive(false)
        scheduler.setActive(true)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        scheduler.setPaused(false)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 2)
    }

    func testFailedAttemptWaitsForNextPollRatherThanRetryingEveryTick() async {
        var now = Date(timeIntervalSince1970: 0)
        var attempts = 0
        let scheduler = AutoSyncScheduler(now: { now }, runsTimer: false, canSync: { true }) {
            attempts += 1
        }
        scheduler.setActive(true)
        scheduler.recordEdit()
        now.addTimeInterval(5)
        await scheduler.runDueSync()
        for _ in 0..<299 {
            now.addTimeInterval(1)
            await scheduler.runDueSync()
        }
        XCTAssertEqual(attempts, 1)
        now.addTimeInterval(1)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 2)
        scheduler.recordEdit()
        scheduler.recordSyncAttempt()
        now.addTimeInterval(5)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 2, "A manual attempt also clears the edit-triggered attempt.")
    }

    func testNoOverlappingAttemptsEvenIfForegroundChangesDuringSync() async {
        var now = Date(timeIntervalSince1970: 0)
        var attempts = 0
        var resume: CheckedContinuation<Void, Never>?
        var started: CheckedContinuation<Void, Never>?
        let scheduler = AutoSyncScheduler(now: { now }, runsTimer: false, canSync: { true }) {
            attempts += 1
            await withCheckedContinuation {
                resume = $0
                started?.resume()
                started = nil
            }
        }
        scheduler.setActive(true)
        var first: _Concurrency.Task<Void, Never>?
        await withCheckedContinuation { continuation in
            started = continuation
            first = _Concurrency.Task { await scheduler.runDueSync() }
        }
        now.addTimeInterval(600)
        scheduler.setActive(false)
        scheduler.setActive(true)
        await scheduler.runDueSync()
        XCTAssertEqual(attempts, 1)
        resume?.resume()
        await first?.value
    }

    func testBinaryFileConflictPausesLikeSemanticConflicts() {
        let failure = GitSyncFailure(GitSyncError.fileConflict("Work/attachments/photo.png"))
        XCTAssertEqual(failure.conflicts, ["Work/attachments/photo.png"])
    }
}
