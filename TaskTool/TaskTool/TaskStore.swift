//
//  TaskStore.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation
import Combine

@MainActor
class TaskStore: ObservableObject {
    @Published var plans: [Plan] = []
    @Published var tasks: [Task] = []
    @Published var storageURL: URL?
    @Published var settings: Settings = Settings()
    
    private let fileManager = FileManager.default
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var isSaving = false  // Flag to prevent reload during save
    
    func setStorageLocation(_ url: URL) {
        print("📍 setStorageLocation called with: \(url.path)")
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            print("❌ Failed to access security-scoped resource")
            return
        }
        
        print("✅ Successfully accessed security-scoped resource")
        
        self.storageURL = url
        
        // Save bookmark for future access
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "storageLocationBookmark")
            print("✅ Saved security-scoped bookmark")
        } catch {
            print("❌ Failed to create bookmark: \(error)")
        }
        
        loadAllData()
        startWatching()
    }
    
    func loadStoredLocation() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "storageLocationBookmark") else {
            return
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to access stored location")
                return
            }
            
            self.storageURL = url
            loadAllData()
            startWatching()
        } catch {
            print("Failed to resolve bookmark: \(error)")
        }
    }
    
    func loadAllData() {
        guard let storageURL = storageURL else { return }
        
        plans = []
        tasks = []
        
        // Load settings first
        loadSettings()
        
        guard let planFolders = try? fileManager.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for planFolder in planFolders {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: planFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            
            let planName = planFolder.lastPathComponent
            
            let planFile = planFolder.appendingPathComponent("plan.yaml")
            if let plan = loadPlan(from: planFile, name: planName) {
                plans.append(plan)
            }
            
            loadTasks(from: planFolder, planName: planName)
        }
        
        // Apply order from settings
        applyPlanOrder()
    }
    
    private func loadSettings() {
        guard let storageURL = storageURL else { return }
        let settingsFile = storageURL.appendingPathComponent("settings.yaml")
        
        print("📁 Loading settings from: \(settingsFile.path)")
        
        if fileManager.fileExists(atPath: settingsFile.path),
           let content = try? String(contentsOf: settingsFile, encoding: .utf8),
           let loadedSettings = try? MarkdownParser.parseSettings(from: content) {
            settings = loadedSettings
            print("✅ Settings loaded: \(settings.planOrder)")
        } else {
            // Create default settings file if it doesn't exist
            settings = Settings()
            print("📝 Creating default settings file")
            try? saveSettings()
        }
    }
    
    func saveSettings() throws {
        guard let storageURL = storageURL else { return }
        let settingsFile = storageURL.appendingPathComponent("settings.yaml")
        let content = MarkdownParser.serializeSettings(settings)
        print("💾 Saving settings: \(settings.planOrder)")
        
        isSaving = true
        try content.write(to: settingsFile, atomically: true, encoding: .utf8)
        
        // Add a small delay to ensure file watcher doesn't reload immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isSaving = false
        }
        
        print("✅ Settings saved to: \(settingsFile.path)")
    }
    
    private func applyPlanOrder() {
        print("📊 applyPlanOrder called")
        print("📊 Settings planOrder: \(settings.planOrder)")
        print("📊 Current plans before ordering: \(plans.map { "\($0.name): \($0.order)" })")
        
        // Create a dictionary for quick lookup
        var planDict: [String: Plan] = [:]
        for plan in plans {
            planDict[plan.name] = plan
        }
        
        // Reorder based on settings
        var orderedPlans: [Plan] = []
        var assignedOrder = 0
        
        // First, add plans that are in the settings order
        for planName in settings.planOrder {
            if var plan = planDict[planName] {
                plan.order = assignedOrder
                orderedPlans.append(plan)
                planDict.removeValue(forKey: planName)
                assignedOrder += 1
            }
        }
        
        // Then, add any remaining plans (new ones not in settings yet)
        for (_, var plan) in planDict.sorted(by: { $0.value.created < $1.value.created }) {
            plan.order = assignedOrder
            orderedPlans.append(plan)
            assignedOrder += 1
        }
        
        plans = orderedPlans
        print("📊 Plans after ordering: \(plans.map { "\($0.name): \($0.order)" })")
    }
    
    private func loadPlan(from url: URL, name: String) -> Plan? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let plan = try? MarkdownParser.parsePlan(from: content, name: name) else {
            return Plan(name: name)
        }
        return plan
    }
    
    private func loadTasks(from planFolder: URL, planName: String) {
        guard let taskFiles = try? fileManager.contentsOfDirectory(
            at: planFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for taskFile in taskFiles where taskFile.pathExtension == "md" && taskFile.lastPathComponent != "plan.yaml" {
            if let content = try? String(contentsOf: taskFile, encoding: .utf8),
               let task = try? MarkdownParser.parseTask(from: content, plan: planName) {
                tasks.append(task)
            }
        }
    }
    
    func createPlan(_ plan: Plan) throws {
        print("📝 createPlan called for: \(plan.name)")
        guard let storageURL = storageURL else {
            print("❌ storageURL is nil")
            return
        }
        
        print("📂 Storage URL: \(storageURL.path)")
        
        // Assign order based on current plan count
        var newPlan = plan
        newPlan.order = plans.count
        
        let planFolder = storageURL.appendingPathComponent(newPlan.folderName)
        print("📁 Creating folder at: \(planFolder.path)")
        
        try fileManager.createDirectory(at: planFolder, withIntermediateDirectories: true)
        print("✅ Folder created successfully")
        
        let planFile = planFolder.appendingPathComponent("plan.yaml")
        let content = MarkdownParser.serializePlan(newPlan)
        
        print("📄 Writing plan.yaml to: \(planFile.path)")
        try content.write(to: planFile, atomically: true, encoding: .utf8)
        print("✅ Plan file written successfully")
        
        plans.append(newPlan)
        
        // Update settings with new plan order
        settings.planOrder.append(newPlan.name)
        try saveSettings()
        
        print("✅ Plan added to plans array. Total plans: \(plans.count)")
    }
    
    func updatePlan(_ plan: Plan) throws {
        guard let storageURL = storageURL else { return }
        
        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        let planFile = planFolder.appendingPathComponent("plan.yaml")
        
        let content = MarkdownParser.serializePlan(plan)
        try content.write(to: planFile, atomically: true, encoding: .utf8)
        
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        }
    }
    
    func deletePlan(_ plan: Plan) throws {
        guard let storageURL = storageURL else { return }
        
        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        try fileManager.removeItem(at: planFolder)
        
        plans.removeAll { $0.id == plan.id }
        tasks.removeAll { $0.plan == plan.name }
        
        // Update settings
        settings.planOrder.removeAll { $0 == plan.name }
        try saveSettings()
    }
    
    func renamePlan(_ plan: Plan, to newName: String) throws {
        guard let storageURL = storageURL else { return }
        
        let oldPlanFolder = storageURL.appendingPathComponent(plan.folderName)
        let newPlanFolder = storageURL.appendingPathComponent(newName)
        
        // Rename the folder
        try fileManager.moveItem(at: oldPlanFolder, to: newPlanFolder)
        
        // Update the plan object
        var updatedPlan = plan
        updatedPlan.name = newName
        
        // Update the plan.yaml file
        let planFile = newPlanFolder.appendingPathComponent("plan.yaml")
        let content = MarkdownParser.serializePlan(updatedPlan)
        try content.write(to: planFile, atomically: true, encoding: .utf8)
        
        // Update in-memory array
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = updatedPlan
        }
        
        // Update all tasks that belong to this plan
        for (index, task) in tasks.enumerated() where task.plan == plan.name {
            var updatedTask = task
            updatedTask.plan = newName
            tasks[index] = updatedTask
            
            // Update task file
            let taskFile = newPlanFolder.appendingPathComponent(task.fileName)
            let taskContent = MarkdownParser.serializeTask(updatedTask)
            try? taskContent.write(to: taskFile, atomically: true, encoding: .utf8)
        }
        
        // Update settings
        if let index = settings.planOrder.firstIndex(of: plan.name) {
            settings.planOrder[index] = newName
            try saveSettings()
        }
    }
    
    func createTask(_ task: Task) throws {
        print("📝 createTask called for: \(task.title)")
        guard let storageURL = storageURL else {
            print("❌ storageURL is nil")
            return
        }
        
        let planFolder = storageURL.appendingPathComponent(task.plan)
        print("📂 Plan folder: \(planFolder.path)")
        
        // Check if plan folder exists
        guard fileManager.fileExists(atPath: planFolder.path) else {
            print("❌ Plan folder doesn't exist: \(planFolder.path)")
            throw NSError(domain: "TaskStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plan folder '\(task.plan)' does not exist"])
        }
        
        let taskFile = planFolder.appendingPathComponent(task.fileName)
        print("📄 Creating task file: \(taskFile.path)")
        
        let content = MarkdownParser.serializeTask(task)
        print("📝 Task content length: \(content.count) characters")
        
        try content.write(to: taskFile, atomically: true, encoding: .utf8)
        print("✅ Task file written successfully")
        
        tasks.append(task)
        print("✅ Task added to tasks array. Total tasks: \(tasks.count)")
    }
    
    func updateTask(_ task: Task) throws {
        guard let storageURL = storageURL else { return }
        
        // Find the old task to check if filename or plan changed
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            print("❌ Task not found in tasks array")
            return
        }
        
        let oldTask = tasks[index]
        let oldPlanFolder = storageURL.appendingPathComponent(oldTask.plan)
        let newPlanFolder = storageURL.appendingPathComponent(task.plan)
        let oldTaskFile = oldPlanFolder.appendingPathComponent(oldTask.fileName)
        let newTaskFile = newPlanFolder.appendingPathComponent(task.fileName)
        
        var updatedTask = task
        updatedTask.updated = Date()
        
        let content = MarkdownParser.serializeTask(updatedTask)
        
        // If plan changed, move the file to the new plan folder
        if oldTask.plan != task.plan {
            print("📦 Moving task from '\(oldTask.plan)' to '\(task.plan)'")
            
            // Delete old file
            if fileManager.fileExists(atPath: oldTaskFile.path) {
                try fileManager.removeItem(at: oldTaskFile)
                print("🗑️ Deleted old task file")
            }
            
            // Write to new plan folder
            try content.write(to: newTaskFile, atomically: true, encoding: .utf8)
            print("✅ Task moved to new plan")
        } else {
            // If filename changed (due to title change), delete old file
            if oldTask.fileName != task.fileName && fileManager.fileExists(atPath: oldTaskFile.path) {
                try fileManager.removeItem(at: oldTaskFile)
            }
            
            // Write to the new/current filename
            try content.write(to: newTaskFile, atomically: true, encoding: .utf8)
        }
        
        // Update in-memory array
        tasks[index] = updatedTask
    }
    
    func deleteTask(_ task: Task) throws {
        guard let storageURL = storageURL else { return }
        
        let planFolder = storageURL.appendingPathComponent(task.plan)
        let taskFile = planFolder.appendingPathComponent(task.fileName)
        
        try fileManager.removeItem(at: taskFile)
        
        tasks.removeAll { $0.id == task.id }
    }
    
    func archiveDoneTasks(for plan: Plan, tasks doneTasks: [Task]) throws {
        guard let storageURL = storageURL else { return }
        
        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        let archiveFolder = planFolder.appendingPathComponent("Archived")
        
        // Create archive folder if it doesn't exist
        if !fileManager.fileExists(atPath: archiveFolder.path) {
            try fileManager.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
            print("📁 Created archive folder at: \(archiveFolder.path)")
        }
        
        // Move each done task to the archive folder
        for task in doneTasks {
            let currentFile = planFolder.appendingPathComponent(task.fileName)
            let archivedFile = archiveFolder.appendingPathComponent(task.fileName)
            
            if fileManager.fileExists(atPath: currentFile.path) {
                try fileManager.moveItem(at: currentFile, to: archivedFile)
                print("📦 Archived: \(task.title)")
            }
            
            // Remove from in-memory array
            tasks.removeAll { $0.id == task.id }
        }
        
        print("✅ Archived \(doneTasks.count) task(s)")
    }
    
    private func startWatching() {
        guard let storageURL = storageURL else { return }
        
        stopWatching()
        
        let descriptor = open(storageURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .extend],
            queue: DispatchQueue.main
        )
        
        source.setEventHandler { [weak self] in
            guard let self = self, !self.isSaving else { return }
            print("📂 File system change detected, reloading...")
            self.loadAllData()
        }
        
        source.setCancelHandler {
            close(descriptor)
        }
        
        source.resume()
        fileWatcher = source
    }
    
    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }
}
