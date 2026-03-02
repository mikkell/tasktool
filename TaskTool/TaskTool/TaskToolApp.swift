//
//  TaskToolApp.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import SwiftUI

@main
struct TaskToolApp: App {
    @StateObject private var taskStore = TaskStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(taskStore)
                .font(.system(.body, design: .default))
                .onAppear {
                    taskStore.loadStoredLocation()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove default "New Window" command
            }
        }
    }
}
