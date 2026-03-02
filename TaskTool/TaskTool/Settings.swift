//
//  Settings.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 27/01/2026.
//

import Foundation

struct Settings: Codable {
    var planOrder: [String] // Array of plan names in display order
    
    init(planOrder: [String] = []) {
        self.planOrder = planOrder
    }
}
