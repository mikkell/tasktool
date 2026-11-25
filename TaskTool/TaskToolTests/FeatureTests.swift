//
//  FeatureTests.swift
//  TaskToolTests
//

import XCTest
@testable import TaskTool

final class FeatureTests: XCTestCase {

    // MARK: - Priority & Recurrence YAML Roundtrip

    func testPriorityAndRecurrenceRoundtrip() throws {
        let task = Task(
            title: "Weekly Review",
            plan: "Work",
            status: "To Do",
            priority: .high,
            recurrence: .weekly,
            tags: ["routine"],
            body: "- [ ] Check backlog"
        )

        let serialized = MarkdownParser.serializeTask(task)
        XCTAssertTrue(serialized.contains("priority: high"))
        XCTAssertTrue(serialized.contains("recurrence: weekly"))

        let parsed = try MarkdownParser.parseTask(from: serialized, plan: "Work")
        XCTAssertEqual(parsed.priority, .high)
        XCTAssertEqual(parsed.recurrence, .weekly)
    }

    func testNilPriorityAndRecurrenceOmittedFromYaml() throws {
        let task = Task(title: "Plain Task", plan: "Work", status: "To Do")
        let serialized = MarkdownParser.serializeTask(task)

        XCTAssertFalse(serialized.contains("priority:"))
        XCTAssertFalse(serialized.contains("recurrence:"))

        let parsed = try MarkdownParser.parseTask(from: serialized, plan: "Work")
        XCTAssertNil(parsed.priority)
        XCTAssertNil(parsed.recurrence)
    }

    // MARK: - Recurrence Date Calculation

    func testWeekdaysRecurrenceSkipsWeekend() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-11-27 is a Friday
        let friday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 9))!
        let next = TaskRecurrence.weekdays.nextDueDate(from: friday, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: next)

        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 11)
        XCTAssertEqual(comps.day, 30) // Monday
        XCTAssertEqual(comps.weekday, 2)
    }

    func testWeeklyAndMonthlyRecurrenceDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 12))!

        let weekly = TaskRecurrence.weekly.nextDueDate(from: start, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: weekly), 22)

        let monthly = TaskRecurrence.monthly.nextDueDate(from: start, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: monthly), 2)
        XCTAssertEqual(calendar.component(.day, from: monthly), 15)
    }

    // MARK: - Auto-Spawning Recurring Tasks on Done

    @MainActor
    func testCompletingRecurringTaskSpawnsNextOccurrenceAndResetsCheckboxes() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskToolRecurringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = TaskStore()
        store.storageURL = tempDir
        store.loadAllData()

        try store.createPlan(Plan(name: "Work", color: "blue"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dueDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))!

        var task = Task(
            title: "Standup Prep",
            plan: "Work",
            status: "In Progress",
            priority: .medium,
            recurrence: .weekly,
            dueDate: dueDate,
            tags: ["team"],
            body: "- [x] Gather updates\n- [X] Review blockers\n\nNotes stay intact"
        )
        try store.createTask(task)

        task.status = "Done"
        try store.updateTask(task)

        XCTAssertEqual(store.tasks.count, 2, "Completing a recurring task should spawn the next occurrence")
        let spawned = try XCTUnwrap(store.tasks.first(where: { $0.id != task.id }))
        XCTAssertEqual(spawned.title, "Standup Prep")
        XCTAssertEqual(spawned.status, "To Do")
        XCTAssertEqual(spawned.priority, .medium)
        XCTAssertEqual(spawned.recurrence, .weekly)
        XCTAssertEqual(spawned.tags, ["team"])
        XCTAssertEqual(spawned.body, "- [ ] Gather updates\n- [ ] Review blockers\n\nNotes stay intact")
        XCTAssertEqual(spawned.dueDate, TaskRecurrence.weekly.nextDueDate(from: dueDate))

        // Moving the completed task back and forth should not spawn a duplicate while an active occurrence exists.
        var completedAgain = try XCTUnwrap(store.tasks.first(where: { $0.id == task.id }))
        completedAgain.status = "In Progress"
        try store.updateTask(completedAgain)
        completedAgain.status = "Done"
        try store.updateTask(completedAgain)
        XCTAssertEqual(store.tasks.count, 2)
    }

    // MARK: - Board Filtering

    func testBoardFilterMatchesTagsPriorityDueDatesAndStalePings() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: now)!

        let overdueHigh = Task(
            title: "Fix prod",
            plan: "Work",
            status: "In Progress",
            priority: .high,
            recurrence: .weekly,
            dueDate: yesterday,
            tags: ["urgent", "backend"],
            pingHistory: [fourDaysAgo]
        )

        var filter = TaskBoardFilter()
        filter.selectedTags = ["URGENT"]
        filter.selectedPriorities = [.high]
        filter.dueDateFilter = .overdue
        filter.recurringOnly = true
        filter.stalePingOnly = true

        XCTAssertTrue(filter.matches(
            overdueHigh,
            effectiveDueDate: overdueHigh.dueDate,
            isDone: false,
            now: now,
            stalePingDays: 3,
            calendar: calendar
        ))

        // Done tasks should not match overdue or stale-ping filters.
        XCTAssertFalse(filter.matches(
            overdueHigh,
            effectiveDueDate: overdueHigh.dueDate,
            isDone: true,
            now: now,
            stalePingDays: 3,
            calendar: calendar
        ))
    }

    // MARK: - Notification Planning

    func testNotificationPlannerSchedulesDueAndStalePingRemindersAndSkipsDone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 8, minute: 0))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let plan = Plan(name: "Work")
        let activeTask = Task(
            title: "Ship release",
            plan: "Work",
            status: "In Progress",
            priority: .high,
            dueDate: tomorrow,
            pingHistory: [yesterday]
        )
        let doneTask = Task(
            title: "Already done",
            plan: "Work",
            status: "Done",
            dueDate: tomorrow,
            pingHistory: [yesterday]
        )

        var prefs = NotificationPreferences(
            isEnabled: false,
            notifyDueTasks: true,
            reminderHour: 9,
            reminderMinute: 0,
            notifyStalePings: true,
            stalePingDays: 3
        )

        XCTAssertTrue(
            NotificationPlanner.buildNotifications(
                tasks: [activeTask, doneTask],
                plans: [plan],
                preferences: prefs,
                now: now,
                calendar: calendar
            ).isEmpty
        )

        prefs.isEnabled = true
        let specs = NotificationPlanner.buildNotifications(
            tasks: [activeTask, doneTask],
            plans: [plan],
            preferences: prefs,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(specs.count, 2)
        XCTAssertTrue(specs.contains(where: { $0.identifier == "tasktool.due.\(activeTask.id.uuidString)" && $0.title == "Due Today: Ship release" }))
        XCTAssertTrue(specs.contains(where: { $0.identifier == "tasktool.ping.\(activeTask.id.uuidString)" && $0.title == "Follow-up Reminder: Ship release" }))
    }
}
