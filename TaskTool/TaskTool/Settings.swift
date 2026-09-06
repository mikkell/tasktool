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

    init(planOrder: [String] = [], availableTags: [String] = []) {
        self.planOrder = planOrder
        self.availableTags = availableTags
    }
}
