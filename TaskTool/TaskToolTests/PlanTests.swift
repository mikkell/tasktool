//
//  PlanTests.swift
//  TaskToolTests
//
//  Created by Mikkel Lund Lindemark on 23/01/2026.
//

import XCTest
@testable import TaskTool

final class PlanTests: XCTestCase {
    
    func testPlanInitialization() {
        let plan = Plan(name: "Test Plan", color: "blue")
        
        XCTAssertEqual(plan.name, "Test Plan")
        XCTAssertEqual(plan.color, "blue")
        XCTAssertEqual(plan.description, "")
        XCTAssertEqual(plan.order, 0)
        XCTAssertEqual(plan.statuses.count, 3) // Default statuses
    }
    
    func testPlanDefaultStatuses() {
        let statuses = Plan.defaultStatuses()
        
        XCTAssertEqual(statuses.count, 3)
        XCTAssertEqual(statuses[0].name, "To Do")
        XCTAssertEqual(statuses[0].color, "gray")
        XCTAssertEqual(statuses[0].order, 0)
        
        XCTAssertEqual(statuses[1].name, "In Progress")
        XCTAssertEqual(statuses[1].color, "blue")
        XCTAssertEqual(statuses[1].order, 1)
        
        XCTAssertEqual(statuses[2].name, "Done")
        XCTAssertEqual(statuses[2].color, "green")
        XCTAssertEqual(statuses[2].order, 2)
    }
    
    func testPlanFolderName() {
        let plan = Plan(name: "My Project", color: "red")
        XCTAssertEqual(plan.folderName, "My Project")
    }
    
    func testPlanCustomStatuses() {
        let customStatuses = [
            Plan.TaskStatus(name: "Backlog", color: "gray", order: 0),
            Plan.TaskStatus(name: "Active", color: "blue", order: 1),
            Plan.TaskStatus(name: "Review", color: "orange", order: 2),
            Plan.TaskStatus(name: "Completed", color: "green", order: 3)
        ]
        
        let plan = Plan(name: "Custom Plan", statuses: customStatuses)
        
        XCTAssertEqual(plan.statuses.count, 4)
        XCTAssertEqual(plan.statuses[0].name, "Backlog")
        XCTAssertEqual(plan.statuses[3].name, "Completed")
    }
    
    func testTaskStatusEquality() {
        let id = UUID()
        let status1 = Plan.TaskStatus(id: id, name: "To Do", color: "gray", order: 0)
        let status2 = Plan.TaskStatus(id: id, name: "To Do", color: "gray", order: 0)
        
        XCTAssertEqual(status1.id, status2.id)
        XCTAssertEqual(status1.name, status2.name)
    }
    
    func testPlanEquality() {
        let id = UUID()
        let plan1 = Plan(id: id, name: "Plan A", color: "blue")
        let plan2 = Plan(id: id, name: "Plan A", color: "blue")
        
        XCTAssertEqual(plan1.id, plan2.id)
        XCTAssertEqual(plan1.name, plan2.name)
    }
}
