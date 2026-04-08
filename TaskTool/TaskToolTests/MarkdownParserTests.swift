//
//  MarkdownParserTests.swift
//  TaskToolTests
//

import XCTest
@testable import TaskTool

final class MarkdownParserTests: XCTestCase {

    // MARK: - Task parsing

    func testParseSimpleTask() throws {
        let markdown = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        type: task
        plan: Work
        status: To Do
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # Simple Task

        Task description
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertEqual(task.title, "Simple Task")
        XCTAssertEqual(task.plan, "Work")
        XCTAssertEqual(task.status, "To Do")
        XCTAssertEqual(task.body, "Task description")
        XCTAssertTrue(task.tags.isEmpty)
        XCTAssertNil(task.dueDate)
    }

    func testParseTaskWithTags() throws {
        let markdown = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        type: task
        plan: Work
        status: In Progress
        tags:
          - urgent
          - frontend
          - bug
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # Task with tags

        Description
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertEqual(task.title, "Task with tags")
        XCTAssertEqual(task.tags.count, 3)
        XCTAssertTrue(task.tags.contains("urgent"))
        XCTAssertTrue(task.tags.contains("frontend"))
        XCTAssertTrue(task.tags.contains("bug"))
    }

    func testParseTaskWithDueDate() throws {
        let markdown = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        type: task
        plan: Work
        status: To Do
        due_date: 2026-02-01T00:00:00Z
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # Task with due date
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertEqual(task.title, "Task with due date")
        XCTAssertNotNil(task.dueDate)
    }

    func testParseTaskPreservesUUID() throws {
        let knownID = "12345678-1234-1234-1234-123456789012"
        let markdown = """
        ---
        id: \(knownID)
        type: task
        plan: Work
        status: To Do
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # ID Test
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertEqual(task.id.uuidString.lowercased(), knownID.lowercased())
    }

    func testParseTaskMissingFrontmatterThrows() {
        let markdown = "# Task without frontmatter\n\nBody content"
        XCTAssertThrowsError(try MarkdownParser.parseTask(from: markdown, plan: "Work"))
    }

    func testParseTaskMultilineBody() throws {
        let markdown = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        type: task
        plan: Work
        status: To Do
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # Multiline Task

        First paragraph.

        Second paragraph.

        - [ ] Item 1
        - [x] Item 2
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertTrue(task.body.contains("First paragraph"))
        XCTAssertTrue(task.body.contains("Second paragraph"))
        XCTAssertTrue(task.body.contains("Item 1"))
        XCTAssertTrue(task.body.contains("Item 2"))
    }

    func testParseTaskEmptyBodyIsAllowed() throws {
        let markdown = """
        ---
        id: 12345678-1234-1234-1234-123456789012
        type: task
        plan: Work
        status: To Do
        created: 2026-01-23T10:00:00Z
        updated: 2026-01-23T10:00:00Z
        ---
        # Empty Body Task
        """
        let task = try MarkdownParser.parseTask(from: markdown, plan: "Work")
        XCTAssertEqual(task.title, "Empty Body Task")
        XCTAssertTrue(task.body.isEmpty)
    }

    // MARK: - Task serialization

    func testSerializeTask() {
        let task = Task(title: "Test Task", plan: "Work", status: "To Do",
                        tags: ["test", "demo"], body: "This is the task body")
        let markdown = MarkdownParser.serializeTask(task)
        XCTAssertTrue(markdown.contains("# Test Task"))
        XCTAssertTrue(markdown.contains("plan: Work"))
        XCTAssertTrue(markdown.contains("status: To Do"))
        XCTAssertTrue(markdown.contains("- test"))
        XCTAssertTrue(markdown.contains("- demo"))
        XCTAssertTrue(markdown.contains("This is the task body"))
    }

    func testSerializeTaskIncludesDueDate() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 15
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let dueDate = Calendar(identifier: .gregorian).date(from: comps)!

        let task = Task(title: "Deadline Task", plan: "Work", status: "To Do", dueDate: dueDate)
        let markdown = MarkdownParser.serializeTask(task)
        XCTAssertTrue(markdown.contains("due_date:"))
        XCTAssertTrue(markdown.contains("2026-06-15"))
    }

    func testSerializeTaskOmitsDueDateWhenNil() {
        let task = Task(title: "No Date", plan: "Work", status: "To Do")
        let markdown = MarkdownParser.serializeTask(task)
        XCTAssertFalse(markdown.contains("due_date:"))
    }

    func testSerializeTaskOmitsTagsWhenEmpty() {
        let task = Task(title: "No Tags", plan: "Work", status: "To Do")
        let markdown = MarkdownParser.serializeTask(task)
        XCTAssertFalse(markdown.contains("tags:"))
    }

    // MARK: - Task roundtrip

    func testRoundtripTask() throws {
        let original = Task(id: UUID(), title: "Roundtrip Task", plan: "Work",
                            status: "In Progress", tags: ["alpha", "beta"],
                            body: "Some body content")
        let serialized = MarkdownParser.serializeTask(original)
        let parsed = try MarkdownParser.parseTask(from: serialized, plan: "Work")

        XCTAssertEqual(parsed.id, original.id)
        XCTAssertEqual(parsed.title, original.title)
        XCTAssertEqual(parsed.status, original.status)
        XCTAssertEqual(parsed.tags.sorted(), original.tags.sorted())
        XCTAssertEqual(parsed.body, original.body)
    }

    func testRoundtripTaskWithDueDate() throws {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 20
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let dueDate = Calendar(identifier: .gregorian).date(from: comps)!

        let original = Task(title: "Dated Task", plan: "Work", status: "To Do", dueDate: dueDate)
        let parsed = try MarkdownParser.parseTask(from: MarkdownParser.serializeTask(original), plan: "Work")
        XCTAssertNotNil(parsed.dueDate)
    }

    // MARK: - Plan parsing

    func testParsePlan() throws {
        let yaml = """
        # Plan: My Plan
        id: 12345678-1234-1234-1234-123456789012
        name: My Plan
        color: blue
        created: 2026-01-23T10:00:00Z
        description: Plan description
        statuses:
          - id: 87654321-4321-4321-4321-210987654321
            name: To Do
            color: gray
            order: 0
          - id: 87654321-4321-4321-4321-210987654322
            name: Done
            color: green
            order: 1
        """
        let plan = try MarkdownParser.parsePlan(from: yaml, name: "My Plan")
        XCTAssertEqual(plan.name, "My Plan")
        XCTAssertEqual(plan.color, "blue")
        XCTAssertEqual(plan.description, "Plan description")
        XCTAssertEqual(plan.statuses.count, 2)
        let sorted = plan.statuses.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted[0].name, "To Do")
        XCTAssertEqual(sorted[1].name, "Done")
    }

    func testParsePlanUsesDefaultStatusesWhenMissing() throws {
        let yaml = """
        id: 12345678-1234-1234-1234-123456789012
        name: Bare Plan
        color: red
        created: 2026-01-23T10:00:00Z
        description: ""
        """
        let plan = try MarkdownParser.parsePlan(from: yaml, name: "Bare Plan")
        XCTAssertEqual(plan.statuses.count, 3)
    }

    func testParsePlanInvalidYamlThrows() {
        XCTAssertThrowsError(try MarkdownParser.parsePlan(from: "{ bad: yaml: ::", name: "Bad"))
    }

    // MARK: - Plan serialization

    func testSerializePlan() {
        let plan = Plan(name: "Test Plan", color: "purple", description: "A test plan", order: 1)
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("name: Test Plan"))
        XCTAssertTrue(yaml.contains("color: purple"))
        XCTAssertTrue(yaml.contains("description: A test plan"))
        XCTAssertTrue(yaml.contains("statuses:"))
    }

    func testSerializePlanOmitsOrderField() {
        let plan = Plan(name: "Work", color: "blue", order: 5)
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertFalse(yaml.contains("order: 5"), "Plan order must not be written to plan.yaml")
    }

    // MARK: - Plan roundtrip

    func testRoundtripPlan() throws {
        let original = Plan(id: UUID(), name: "Roundtrip Plan", color: "green",
                            description: "Testing roundtrip",
                            statuses: [
                                Plan.TaskStatus(name: "Open", color: "blue", order: 0),
                                Plan.TaskStatus(name: "Closed", color: "gray", order: 1)
                            ], order: 0)
        let serialized = MarkdownParser.serializePlan(original)
        let parsed = try MarkdownParser.parsePlan(from: serialized, name: original.name)

        XCTAssertEqual(parsed.id, original.id)
        XCTAssertEqual(parsed.name, original.name)
        XCTAssertEqual(parsed.color, original.color)
        XCTAssertEqual(parsed.description, original.description)
        XCTAssertEqual(parsed.statuses.count, original.statuses.count)
        let parsedSorted = parsed.statuses.sorted { $0.order < $1.order }
        let originalSorted = original.statuses.sorted { $0.order < $1.order }
        XCTAssertEqual(parsedSorted.map { $0.name }, originalSorted.map { $0.name })
    }

    // MARK: - YAML quoting

    func testYamlQuotingAppliedForColonInPlanName() {
        let plan = Plan(name: "Work: Projects", color: "blue", description: "desc")
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("name: \"Work: Projects\""),
                      "Name containing colon must be double-quoted")
    }

    func testYamlQuotingAppliedForHashInDescription() {
        let plan = Plan(name: "Work", color: "blue", description: "# Heading")
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("description: \"# Heading\""),
                      "Description starting with # must be double-quoted")
    }

    func testYamlQuotingAppliedForEmptyDescription() {
        let plan = Plan(name: "Work", color: "blue", description: "")
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("description: \"\""),
                      "Empty string must be double-quoted")
    }

    func testYamlQuotingNotAppliedForNormalStrings() {
        let plan = Plan(name: "Work", color: "blue", description: "A normal description")
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("name: Work"))
        XCTAssertTrue(yaml.contains("description: A normal description"))
    }

    func testQuotedPlanNameSurvivesRoundtrip() throws {
        let plan = Plan(name: "Feature: Auth", color: "blue", description: "# Important")
        let yaml = MarkdownParser.serializePlan(plan)
        let parsed = try MarkdownParser.parsePlan(from: yaml, name: "Feature: Auth")
        XCTAssertEqual(parsed.description, "# Important")
    }

    func testYamlQuotingAppliedForStatusNameWithColon() {
        let plan = Plan(name: "Work", color: "blue", statuses: [
            Plan.TaskStatus(name: "Ready: Review", color: "blue", order: 0)
        ])
        let yaml = MarkdownParser.serializePlan(plan)
        XCTAssertTrue(yaml.contains("name: \"Ready: Review\""))
    }

    func testYamlQuotingForSettingsPlanOrder() {
        let settings = Settings(planOrder: ["Normal", "Has: Colon"])
        let yaml = MarkdownParser.serializeSettings(settings)
        XCTAssertTrue(yaml.contains("- Normal"))
        XCTAssertTrue(yaml.contains("- \"Has: Colon\""))
    }

    // MARK: - Settings parsing

    func testParseSettings() throws {
        let yaml = """
        # TaskTool Settings
        plan_order:
          - Work
          - Personal
          - Ideas
        """
        let settings = try MarkdownParser.parseSettings(from: yaml)
        XCTAssertEqual(settings.planOrder, ["Work", "Personal", "Ideas"])
    }

    func testParseEmptySettings() throws {
        let yaml = "# TaskTool Settings\nplan_order:\n"
        let settings = try MarkdownParser.parseSettings(from: yaml)
        XCTAssertTrue(settings.planOrder.isEmpty)
    }

    func testSerializeSettings() {
        let settings = Settings(planOrder: ["Alpha", "Beta", "Gamma"])
        let yaml = MarkdownParser.serializeSettings(settings)
        XCTAssertTrue(yaml.contains("plan_order:"))
        XCTAssertTrue(yaml.contains("Alpha"))
        XCTAssertTrue(yaml.contains("Beta"))
        XCTAssertTrue(yaml.contains("Gamma"))
    }

    func testRoundtripSettings() throws {
        let original = Settings(planOrder: ["Work", "Personal", "Side Projects"])
        let serialized = MarkdownParser.serializeSettings(original)
        let parsed = try MarkdownParser.parseSettings(from: serialized)
        XCTAssertEqual(parsed.planOrder, original.planOrder)
    }
}
