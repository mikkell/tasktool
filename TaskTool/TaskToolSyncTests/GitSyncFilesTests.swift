import XCTest
@testable import TaskToolCore

final class GitSyncFilesTests: XCTestCase {
    func testSyncSerializationQuotesTaskMetadataAndPreservesBinaryData() throws {
        var plan = Plan(name: "Work: Team")
        plan.statuses[0].name = "To: Do"
        let task = Task(title: "Example", plan: plan.name, status: plan.statuses[0].name, tags: ["tag: x", "#urgent"])
        let binary = GitSyncFile(data: Data([0, 255, 0, 128]))
        let files = [
            "\(plan.name)/plan.yaml": GitSyncFile(data: Data(MarkdownParser.serializePlan(plan).utf8)),
            "\(plan.name)/example.md": GitSyncFile(data: Data(MarkdownParser.serializeTask(task).utf8)),
            "\(plan.name)/attachments/image.bin": binary
        ]
        let result = try GitSyncFiles.reconcile(base: files, local: files, remote: files)
        let (snapshot, _) = try GitSyncFiles.decode(result)
        XCTAssertEqual(snapshot.tasks.first?.task.plan, plan.name)
        XCTAssertEqual(snapshot.tasks.first?.task.status, task.status)
        XCTAssertEqual(snapshot.tasks.first?.task.tags, task.tags)
        XCTAssertEqual(result["\(plan.name)/attachments/image.bin"], binary)
    }

    func testMissingUUIDAndUnknownFieldsFailInsteadOfLosingMetadata() throws {
        let task = Task(title: "Example", plan: "Work", status: "To Do")
        let original = MarkdownParser.serializeTask(task)
        for text in [
            original.replacingOccurrences(of: "id: \(task.id.uuidString)\n", with: ""),
            original.replacingOccurrences(of: "type: task", with: "type: task\nfuture_field: important")
        ] {
            XCTAssertThrowsError(try GitSyncFiles.decode(["Work/example.md": .init(data: Data(text.utf8))]))
        }
    }

    func testUnchangedMetadataKeepsCommentsFormattingAndFileMode() throws {
        let task = Task(title: "Example", plan: "Work", status: "To Do")
        let plan = Plan(name: "Work")
        let data = Data(MarkdownParser.serializeTask(task)
            .replacingOccurrences(of: "type: task", with: "# Keep this comment\ntype: task").utf8)
        let files = [
            "Work/plan.yaml": GitSyncFile(data: Data(MarkdownParser.serializePlan(plan).utf8)),
            "Work/example.md": GitSyncFile(data: data, mode: 0o100755)
        ]
        let result = try GitSyncFiles.reconcile(base: files, local: files, remote: files)
        XCTAssertEqual(result, files)
    }

    func testConflictingBinaryEditsAndSymlinksAreRejected() throws {
        let path = "Work/attachments/image.bin"
        XCTAssertThrowsError(try GitSyncFiles.reconcile(
            base: [path: .init(data: Data([0]))],
            local: [path: .init(data: Data([1]))],
            remote: [path: .init(data: Data([2]))]
        ))
        XCTAssertThrowsError(try GitSyncFiles.decode(["Work/link": .init(data: Data("outside".utf8), mode: 0o120000)]))
    }
}
