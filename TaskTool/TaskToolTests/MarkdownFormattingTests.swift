//
//  MarkdownFormattingTests.swift
//  TaskToolTests
//

import XCTest
import SwiftUI
@testable import TaskTool

final class MarkdownFormattingTests: XCTestCase {

    /// Builds a `TextSelection` covering `substring` in `text` (must be the first occurrence).
    private func selection(of substring: String, in text: String) -> TextSelection {
        guard let range = text.range(of: substring) else {
            XCTFail("substring not found")
            return TextSelection(insertionPoint: text.startIndex)
        }
        return TextSelection(range: range)
    }

    // MARK: - Adding formatting

    func testWrapSelectionAddsBoldMarkers() {
        var text = "hello world"
        var selection: TextSelection? = self.selection(of: "hello", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        XCTAssertEqual(text, "**hello** world")
    }

    func testWrapSelectionSelectsInnerTextAfterAdding() throws {
        var text = "hello world"
        var selection: TextSelection? = self.selection(of: "hello", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        let indices = try XCTUnwrap(selection?.indices)
        guard case .selection(let range) = indices else {
            return XCTFail("expected a single selection range")
        }
        XCTAssertEqual(String(text[range]), "hello")
    }

    // MARK: - Removing formatting (toggle off)

    func testWrapSelectionRemovesMarkersWhenTheySurroundSelection() {
        var text = "**hello** world"
        var selection: TextSelection? = self.selection(of: "hello", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        XCTAssertEqual(text, "hello world")
    }

    func testWrapSelectionRemovesMarkersWhenSelectionIncludesThem() {
        var text = "**hello** world"
        var selection: TextSelection? = self.selection(of: "**hello**", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        XCTAssertEqual(text, "hello world")
    }

    func testWrapSelectionTogglesBackAndForth() {
        var text = "hello world"
        var selection: TextSelection? = self.selection(of: "hello", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")
        XCTAssertEqual(text, "**hello** world")

        // Re-select just the inner text (as the selection would be left after wrapping)
        // and apply the same shortcut again — it should remove the formatting.
        selection = self.selection(of: "hello", in: text)
        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")
        XCTAssertEqual(text, "hello world")
    }

    func testWrapSelectionDoesNotRemoveDifferentMarkers() {
        // Surrounding markers are italic ("*"), but the shortcut being pressed is bold ("**").
        // There's only one marker character available on each side, not enough to match the
        // two-character bold prefix/suffix, so bold formatting is added rather than removed.
        var text = "*hello* world"
        var selection: TextSelection? = self.selection(of: "hello", in: text)

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        XCTAssertEqual(text, "***hello*** world")
    }

    // MARK: - Empty selection (cursor only)

    func testWrapSelectionWithNoSelectionInsertsMarkersAtCursor() {
        var text = "hello world"
        var selection: TextSelection? = nil

        MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")

        XCTAssertEqual(text, "hello world****")
    }
}
