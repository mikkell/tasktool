//
//  Settings.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 27/01/2026.
//

import Foundation

struct Settings: Codable {
    var planOrder: [String] // Array of plan names in display order
    var availableTags: [String] // Global registry of tags, reusable across all tasks
    var overviewSelectedPlanNames: [String]?
    var overviewFocusDate: String?
    var overviewFocusNote: String
    var overviewFocusTaskIDs: [String]

    init(
        planOrder: [String] = [],
        availableTags: [String] = [],
        overviewSelectedPlanNames: [String]? = nil,
        overviewFocusDate: String? = nil,
        overviewFocusNote: String = "",
        overviewFocusTaskIDs: [String] = []
    ) {
        self.planOrder = planOrder
        self.availableTags = availableTags
        self.overviewSelectedPlanNames = overviewSelectedPlanNames
        self.overviewFocusDate = overviewFocusDate
        self.overviewFocusNote = overviewFocusNote
        self.overviewFocusTaskIDs = overviewFocusTaskIDs
    }
}
