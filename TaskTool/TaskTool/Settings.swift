//
//  Settings.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 27/01/2026.
//

import Foundation

struct Habit: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var completedDates: [String] // Day keys formatted yyyy-MM-dd

    init(id: String = UUID().uuidString, name: String, completedDates: [String] = []) {
        self.id = id
        self.name = name
        self.completedDates = completedDates
    }
}

struct Settings: Codable, Equatable {
    var planOrder: [String] // Array of plan names in display order
    var availableTags: [String] // Global registry of tags, reusable across all tasks
    var overviewSelectedPlanNames: [String]?
    var overviewFocusDate: String?
    var overviewFocusNote: String
    var overviewFocusTaskIDs: [String]
    var habits: [Habit]

    init(
        planOrder: [String] = [],
        availableTags: [String] = [],
        overviewSelectedPlanNames: [String]? = nil,
        overviewFocusDate: String? = nil,
        overviewFocusNote: String = "",
        overviewFocusTaskIDs: [String] = [],
        habits: [Habit] = []
    ) {
        self.planOrder = planOrder
        self.availableTags = availableTags
        self.overviewSelectedPlanNames = overviewSelectedPlanNames
        self.overviewFocusDate = overviewFocusDate
        self.overviewFocusNote = overviewFocusNote
        self.overviewFocusTaskIDs = overviewFocusTaskIDs
        self.habits = habits
    }
}
