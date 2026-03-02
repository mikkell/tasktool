//
//  TaskStoreTests.swift
//  TaskToolTests
//
//  Created by Mikkel Lund Lindemark on 23/01/2026.
//

import XCTest
@testable import TaskTool

@MainActor
final class TaskStoreTests: XCTestCase {
    
    func testTaskStoreCanBeCreated() async throws {
        let taskStore = TaskStore()
        XCTAssertNotNil(taskStore)
    }
}
