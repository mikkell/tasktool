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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(taskStore)
                .font(.system(.body, design: .default))
                .onAppear {
                    taskStore.loadStoredLocation()
                    taskStore.setAutoSyncActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    taskStore.setAutoSyncActive(phase == .active)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Remove default "New Window" command
            }
        }

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(taskStore)
        }
    }
}
