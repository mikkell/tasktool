import XCTest
@testable import TaskToolCore

final class MobileTaskBodyTests: XCTestCase {
    func testOpeningOrRevertingAnEditorPreservesExactMarkdown() {
        let body = "\r\n## Notes\r\n\r\nKeep **formatting** and [links](https://example.com).\r\n\r\n- [ ] First\r\n- [x] Second\r\n"
        var draft = MobileTaskBody(body)
        XCTAssertEqual(draft.subtasks.map(\.title), ["First", "Second"])
        XCTAssertEqual(draft.subtasks.map(\.isCompleted), [false, true])
        XCTAssertEqual(draft.markdown, body)
        draft.subtasks[0].isCompleted.toggle()
        draft.subtasks[0].isCompleted.toggle()
        XCTAssertEqual(draft.markdown, body)
    }

    func testSubtasksCanBeCompletedRenamedRemovedAndAddedWithNotesPreserved() {
        var draft = MobileTaskBody("- [ ] First\n- [x] Second\n\n## Notes\n**Keep me**")
        draft.subtasks[0].isCompleted = true
        draft.subtasks[0].title = "Renamed"
        draft.subtasks.remove(at: 1)
        draft.newSubtaskTitle = "  Added  "
        draft.addSubtask()
        XCTAssertEqual(draft.newSubtaskTitle, "")
        XCTAssertEqual(draft.markdown, "- [x] Renamed\n- [ ] Added\n\n## Notes\n**Keep me**")
        let reopened = MobileTaskBody(draft.markdown)
        XCTAssertEqual(reopened.subtasks.map(\.title), ["Renamed", "Added"])
        XCTAssertEqual(reopened.subtasks.map(\.isCompleted), [true, false])
        XCTAssertEqual(reopened.notes, "## Notes\n**Keep me**")
    }

    func testSavingIncludesAPendingSubtaskAndRejectsEmptyOrMultilineTitles() {
        var draft = MobileTaskBody()
        draft.newSubtaskTitle = "Save without tapping plus"
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.markdown, "- [ ] Save without tapping plus")
        draft.addSubtask()
        draft.subtasks[0].title = " \t "
        XCTAssertFalse(draft.isValid)
        draft.subtasks[0].title = "Valid"
        draft.newSubtaskTitle = "First\nSecond"
        XCTAssertFalse(draft.isValid)
        XCTAssertFalse(draft.canAddSubtask)
        draft.addSubtask()
        XCTAssertEqual(draft.subtasks.count, 1)
    }

    func testCodeExamplesAndNestedCheckboxesRemainNotes() {
        let body = """
        ```markdown
        - [ ] Code example
        ````
        ~~~text
        - [x] Another example
        ~~~
          - [ ] Nested checkbox
        - [ ] Real subtask
        """
        var draft = MobileTaskBody(body)
        XCTAssertEqual(draft.subtasks.map(\.title), ["Real subtask"])
        XCTAssertTrue(draft.notes.contains("- [ ] Code example"))
        XCTAssertTrue(draft.notes.contains("- [x] Another example"))
        XCTAssertTrue(draft.notes.contains("  - [ ] Nested checkbox"))
        XCTAssertEqual(draft.markdown, body)
        draft.subtasks[0].isCompleted = true
        let reopened = MobileTaskBody(draft.markdown)
        XCTAssertEqual(reopened.subtasks.map(\.title), ["Real subtask"])
        XCTAssertEqual(reopened.notes, draft.notes)
    }
}
