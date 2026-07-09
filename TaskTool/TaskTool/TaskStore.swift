//
//  TaskStore.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import Foundation
import Combine

/// Debug-only logging. The `@autoclosure` defers string interpolation so the
/// (sometimes expensive, e.g. array-mapping) message is never built in Release builds.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

@MainActor
class TaskStore: ObservableObject {
    @Published var plans: [Plan] = []
    @Published var tasks: [Task] = []
    @Published var storageURL: URL?
    @Published var settings: Settings = Settings()
    
    private let fileManager = FileManager.default
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var planWatchers: [String: DispatchSourceFileSystemObject] = [:]  // keyed by plan folder name
    private var isSaving = false  // Flag to prevent reload during save
    private var reloadDebounceWork: DispatchWorkItem?  // Debounce rapid file system events
    private var savingWorkItem: DispatchWorkItem?  // Single cancellable timer for isSaving reset
    
    func setStorageLocation(_ url: URL) {
        debugLog("📍 setStorageLocation called with: \(url.path)")
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            debugLog("❌ Failed to access security-scoped resource")
            return
        }
        
        debugLog("✅ Successfully accessed security-scoped resource")
        
        self.storageURL = url
        
        // Save bookmark for future access
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "storageLocationBookmark")
            debugLog("✅ Saved security-scoped bookmark")
        } catch {
            debugLog("❌ Failed to create bookmark: \(error)")
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
                debugLog("Failed to access stored location")
                return
            }
            
            if isStale {
                // Bookmark is stale (e.g. volume remounted, file moved). Refresh it.
                debugLog("⚠️ Bookmark is stale, refreshing...")
                if let freshData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(freshData, forKey: "storageLocationBookmark")
                    debugLog("✅ Refreshed security-scoped bookmark")
                }
            }
            
            self.storageURL = url
            loadAllData()
            startWatching()
        } catch {
            debugLog("Failed to resolve bookmark: \(error)")
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
            
            // Only treat directories that have a plan.yaml as plans.
            // Stray folders (.git, backups, etc.) are silently skipped.
            guard fileManager.fileExists(atPath: planFile.path) else { continue }
            
            if let plan = loadPlan(from: planFile, name: planName) {
                plans.append(plan)
            }
            
            loadTasks(from: planFolder, planName: planName)
        }
        
        // Apply order from settings
        applyPlanOrder()

        // Deduplicate tasks that share a UUID.  When the same task appears in multiple plan
        // folders (e.g. a cloud-sync conflict after a rename), prefer the copy whose plan is
        // listed in settings.planOrder ("canonical"). Fall back to newest `updated` as a
        // tie-breaker when both (or neither) copies are canonical.
        let canonicalPlanNames = Set(settings.planOrder)
        var seen: [UUID: Task] = [:]
        var movedAwayFrom = Set<String>()   // plan names whose tasks were displaced by a canonical copy

        for task in tasks {
            if let existing = seen[task.id] {
                let taskCanonical     = canonicalPlanNames.contains(task.plan)
                let existingCanonical = canonicalPlanNames.contains(existing.plan)
                // Canonical always beats non-canonical; tie-break on newest `updated`.
                let preferNew = taskCanonical != existingCanonical
                    ? taskCanonical
                    : task.updated > existing.updated
                if preferNew {
                    movedAwayFrom.insert(existing.plan)
                    seen[task.id] = task
                } else {
                    movedAwayFrom.insert(task.plan)
                }
            } else {
                seen[task.id] = task
            }
        }
        if seen.count != tasks.count {
            debugLog("⚠️ Deduplicated \(tasks.count - seen.count) task(s) with duplicate UUIDs")
            tasks = Array(seen.values)
        }

        // Remove non-canonical plans whose tasks were entirely absorbed by canonical equivalents.
        // This collapses ghost folders left behind by cloud-sync conflicts after a rename or
        // delete, while keeping genuinely new external plans (empty or with unique tasks).
        if !canonicalPlanNames.isEmpty {
            plans = plans.filter { canonicalPlanNames.contains($0.name) || !movedAwayFrom.contains($0.name) }
        }

        // Keep plan-level directory watchers in sync with the current plan list.
        updatePlanWatchers()
    }
    
    private func loadSettings() {
        guard let storageURL = storageURL else { return }
        let settingsFile = storageURL.appendingPathComponent("settings.yaml")
        
        debugLog("📁 Loading settings from: \(settingsFile.path)")
        
        if fileManager.fileExists(atPath: settingsFile.path),
           let content = try? String(contentsOf: settingsFile, encoding: .utf8),
           let loadedSettings = try? MarkdownParser.parseSettings(from: content) {
            settings = loadedSettings
            debugLog("✅ Settings loaded: \(settings.planOrder)")
        } else {
            // Create default settings file if it doesn't exist
            settings = Settings()
            debugLog("📝 Creating default settings file")
            try? saveSettings()
        }
    }
    
    func saveSettings() throws {
        guard let storageURL = storageURL else { return }
        let settingsFile = storageURL.appendingPathComponent("settings.yaml")
        let content = MarkdownParser.serializeSettings(settings)
        debugLog("💾 Saving settings: \(settings.planOrder)")
        
        markSaving()
        try content.write(to: settingsFile, atomically: false, encoding: .utf8)
        
        debugLog("✅ Settings saved to: \(settingsFile.path)")
    }
    
    /// Suppresses file-watcher reloads for 2.5 s — long enough for OneDrive to finish syncing.
    /// Each call cancels the previous timer, so consecutive saves extend the window correctly.
    private func markSaving() {
        isSaving = true
        // Cancel any reload that was queued before this write started.
        reloadDebounceWork?.cancel()
        reloadDebounceWork = nil
        // Cancel the previous reset timer and start a fresh one from now.
        savingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isSaving = false
        }
        savingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    
    private func applyPlanOrder() {
        debugLog("📊 applyPlanOrder called")
        debugLog("📊 Settings planOrder: \(settings.planOrder)")
        debugLog("📊 Current plans before ordering: \(plans.map { "\($0.name): \($0.order)" })")
        
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
        debugLog("📊 Plans after ordering: \(plans.map { "\($0.name): \($0.order)" })")
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
        debugLog("📝 createPlan called for: \(plan.name)")
        guard let storageURL = storageURL else {
            debugLog("❌ storageURL is nil")
            return
        }
        
        debugLog("📂 Storage URL: \(storageURL.path)")
        
        // Assign order based on current plan count
        var newPlan = plan
        newPlan.order = plans.count
        
        let planFolder = storageURL.appendingPathComponent(newPlan.folderName)
        debugLog("📁 Creating folder at: \(planFolder.path)")
        
        try fileManager.createDirectory(at: planFolder, withIntermediateDirectories: true)
        debugLog("✅ Folder created successfully")
        
        let planFile = planFolder.appendingPathComponent("plan.yaml")
        let content = MarkdownParser.serializePlan(newPlan)
        
        debugLog("📄 Writing plan.yaml to: \(planFile.path)")
        markSaving()
        try content.write(to: planFile, atomically: false, encoding: .utf8)
        debugLog("✅ Plan file written successfully")
        
        plans.append(newPlan)
        
        // Start watching the new plan directory right away so external task changes are detected.
        if fileWatcher != nil,
           let watcher = makeDirectoryWatcher(for: storageURL.appendingPathComponent(newPlan.folderName)) {
            planWatchers[newPlan.folderName] = watcher
        }
        
        // Update settings with new plan order
        settings.planOrder.append(newPlan.name)
        try saveSettings()
        
        debugLog("✅ Plan added to plans array. Total plans: \(plans.count)")
    }
    
    func updatePlan(_ plan: Plan) throws {
        guard let storageURL = storageURL else { return }

        // Build a rename map: oldStatusName → newStatusName for any status whose
        // name changed (matched by UUID so adds/deletes are not confused with renames).
        let oldPlan = plans.first(where: { $0.id == plan.id })
        let oldStatusNames: [UUID: String] = Dictionary(
            uniqueKeysWithValues: (oldPlan?.statuses ?? []).map { ($0.id, $0.name) }
        )
        let renames: [String: String] = plan.statuses.reduce(into: [:]) { result, status in
            if let oldName = oldStatusNames[status.id], oldName != status.name {
                result[oldName] = status.name
            }
        }

        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        let planFile = planFolder.appendingPathComponent("plan.yaml")

        let content = MarkdownParser.serializePlan(plan)
        markSaving()
        try content.write(to: planFile, atomically: false, encoding: .utf8)

        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = plan
        }

        // Migrate tasks whose status matches a renamed column.
        if !renames.isEmpty {
            for index in tasks.indices where tasks[index].plan == plan.name {
                if let newStatus = renames[tasks[index].status] {
                    var updated = tasks[index]
                    updated.status = newStatus
                    updated.updated = Date()
                    let taskFile = planFolder.appendingPathComponent(updated.fileName)
                    let taskContent = MarkdownParser.serializeTask(updated)
                    try? taskContent.write(to: taskFile, atomically: false, encoding: .utf8)
                    tasks[index] = updated
                }
            }
        }
    }
    
    func deletePlan(_ plan: Plan) throws {
        guard let storageURL = storageURL else { return }
        
        // Cancel the plan directory watcher before removing the folder.
        planWatchers[plan.folderName]?.cancel()
        planWatchers.removeValue(forKey: plan.folderName)
        
        markSaving()
        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        try fileManager.removeItem(at: planFolder)
        
        plans.removeAll { $0.id == plan.id }
        tasks.removeAll { $0.plan == plan.name }
        
        // Update settings
        settings.planOrder.removeAll { $0 == plan.name }
        try saveSettings()
    }
    
    /// Rename a plan's folder and write all updated properties in a single operation.
    /// `updatedPlan` must have the new `name` (and any other changed fields) already set.
    func renamePlan(_ plan: Plan, to updatedPlan: Plan) throws {
        guard let storageURL = storageURL else { return }

        let oldName = plan.name
        let newName = updatedPlan.name
        let oldPlanFolder = storageURL.appendingPathComponent(oldName)
        let newPlanFolder = storageURL.appendingPathComponent(newName)

        // Rename the folder on disk.
        markSaving()
        try fileManager.moveItem(at: oldPlanFolder, to: newPlanFolder)

        // Write plan.yaml with all updated fields in one shot.
        let planFile = newPlanFolder.appendingPathComponent("plan.yaml")
        let content = MarkdownParser.serializePlan(updatedPlan)
        try content.write(to: planFile, atomically: false, encoding: .utf8)

        // Update in-memory plans array.
        if let index = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[index] = updatedPlan
        }

        // Migrate tasks: update their plan field and rewrite task files.
        for (index, task) in tasks.enumerated() where task.plan == oldName {
            var updatedTask = task
            updatedTask.plan = newName
            tasks[index] = updatedTask

            let taskFile = newPlanFolder.appendingPathComponent(task.fileName)
            let taskContent = MarkdownParser.serializeTask(updatedTask)
            try? taskContent.write(to: taskFile, atomically: false, encoding: .utf8)
        }

        // Update settings.yaml plan order.
        if let index = settings.planOrder.firstIndex(of: oldName) {
            settings.planOrder[index] = newName
            try saveSettings()
        }

        // Replace the plan folder watcher under the new name.
        // The old file descriptor may still follow the inode after the rename,
        // but re-opening the new path is cleaner and more reliable.
        planWatchers[oldName]?.cancel()
        planWatchers.removeValue(forKey: oldName)
        if fileWatcher != nil,
           let watcher = makeDirectoryWatcher(for: newPlanFolder) {
            planWatchers[newName] = watcher
        }
    }
    
    func createTask(_ task: Task) throws {
        debugLog("📝 createTask called for: \(task.title)")
        guard let storageURL = storageURL else {
            debugLog("❌ storageURL is nil")
            return
        }
        
        let planFolder = storageURL.appendingPathComponent(task.plan)
        debugLog("📂 Plan folder: \(planFolder.path)")
        
        // Check if plan folder exists
        guard fileManager.fileExists(atPath: planFolder.path) else {
            debugLog("❌ Plan folder doesn't exist: \(planFolder.path)")
            throw NSError(domain: "TaskStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plan folder '\(task.plan)' does not exist"])
        }
        
        var taskFile = planFolder.appendingPathComponent(task.fileName)
        
        // If a file with this name already exists (two tasks with identical titles),
        // append the first 8 chars of the UUID to keep both tasks on disk.
        if fileManager.fileExists(atPath: taskFile.path) {
            let base = (task.fileName as NSString).deletingPathExtension
            let uniqueName = "\(base)-\(task.id.uuidString.prefix(8)).md"
            taskFile = planFolder.appendingPathComponent(uniqueName)
            debugLog("⚠️ Filename collision detected, using: \(uniqueName)")
        }
        
        debugLog("📄 Creating task file: \(taskFile.path)")
        
        let content = MarkdownParser.serializeTask(task)
        debugLog("📝 Task content length: \(content.count) characters")
        
        markSaving()
        try content.write(to: taskFile, atomically: false, encoding: .utf8)
        debugLog("✅ Task file written successfully")

        // Guard against duplicating a task that was already added to memory
        // (e.g. if the file-watcher fired and loadAllData ran while we were writing).
        if !tasks.contains(where: { $0.id == task.id }) {
            tasks.append(task)
        }
        debugLog("✅ Task added to tasks array. Total tasks: \(tasks.count)")
    }

    func updateTask(_ task: Task) throws {
        guard let storageURL = storageURL else { return }
        
        // Find the old task to check if filename or plan changed
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            debugLog("❌ Task not found in tasks array")
            return
        }
        
        let oldTask = tasks[index]
        let oldPlanFolder = storageURL.appendingPathComponent(oldTask.plan)
        let newPlanFolder = storageURL.appendingPathComponent(task.plan)
        let oldTaskFile = resolveTaskFile(for: oldTask, in: oldPlanFolder)
            ?? oldPlanFolder.appendingPathComponent(oldTask.fileName)
        let newTaskFile = newPlanFolder.appendingPathComponent(task.fileName)
        
        var updatedTask = task
        updatedTask.updated = Date()
        
        let content = MarkdownParser.serializeTask(updatedTask)
        
        markSaving()
        
        if oldTask.plan != task.plan {
            debugLog("📦 Moving task from '\(oldTask.plan)' to '\(task.plan)'")
            
            // Write to new location FIRST — if this fails, old file is preserved
            try content.write(to: newTaskFile, atomically: false, encoding: .utf8)
            debugLog("✅ Task written to new plan")
            
            // Only delete old file after new file is confirmed on disk
            if fileManager.fileExists(atPath: oldTaskFile.path) {
                try fileManager.removeItem(at: oldTaskFile)
                debugLog("🗑️ Deleted old task file")
            }
        } else {
            // Write to the new/current filename first
            try content.write(to: newTaskFile, atomically: false, encoding: .utf8)
            
            // If filename changed (due to title change), delete old file only after new one is written
            if oldTask.fileName != task.fileName && fileManager.fileExists(atPath: oldTaskFile.path) {
                try fileManager.removeItem(at: oldTaskFile)
            }
        }
        
        // Update in-memory array
        tasks[index] = updatedTask
    }
    
    /// Resolves the actual on-disk URL for a task file.
    /// First tries the computed `task.fileName`. If that file doesn't exist (e.g. the slug was
    /// generated from a title that had trailing whitespace, producing a trailing-dash filename),
    /// falls back to scanning the plan folder for a `.md` file that contains the task's UUID.
    private func resolveTaskFile(for task: Task, in folder: URL) -> URL? {
        let computed = folder.appendingPathComponent(task.fileName)
        if fileManager.fileExists(atPath: computed.path) { return computed }

        // Fallback: find by UUID (handles slug mismatches from trailing spaces, etc.)
        let uuidString = task.id.uuidString.uppercased()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return nil }
        for url in contents where url.pathExtension == "md" {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               content.contains(uuidString) {
                return url
            }
        }
        return nil
    }

    func deleteTask(_ task: Task) throws {
        guard let storageURL = storageURL else { return }

        let planFolder = storageURL.appendingPathComponent(task.plan)
        guard let taskFile = resolveTaskFile(for: task, in: planFolder) else {
            // File is already gone — still remove from memory
            tasks.removeAll { $0.id == task.id }
            return
        }

        markSaving()
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
            debugLog("📁 Created archive folder at: \(archiveFolder.path)")
        }
        
        // Move each done task to the archive folder
        markSaving()
        for task in doneTasks {
            let currentFile = resolveTaskFile(for: task, in: planFolder)
                ?? planFolder.appendingPathComponent(task.fileName)
            let archivedFile = archiveFolder.appendingPathComponent(task.fileName)
            
            if fileManager.fileExists(atPath: currentFile.path) {
                try fileManager.moveItem(at: currentFile, to: archivedFile)
                debugLog("📦 Archived: \(task.title)")
            }
            
            // Remove from in-memory array
            tasks.removeAll { $0.id == task.id }
        }
        
        debugLog("✅ Archived \(doneTasks.count) task(s)")
    }
    
    private func startWatching() {
        guard let storageURL = storageURL else { return }
        
        stopWatching()
        
        fileWatcher = makeDirectoryWatcher(for: storageURL)
        updatePlanWatchers()
    }
    
    private func stopWatching() {
        reloadDebounceWork?.cancel()
        reloadDebounceWork = nil
        fileWatcher?.cancel()
        fileWatcher = nil
        for watcher in planWatchers.values { watcher.cancel() }
        planWatchers.removeAll()
    }

    /// Creates a `DispatchSourceFileSystemObject` that watches `url` for any write,
    /// delete, or extend event and debounces them into a single `loadAllData()` call.
    private func makeDirectoryWatcher(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .extend],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self = self, !self.isSaving else { return }

            // Debounce: cancel any pending reload and schedule a new one after 1.5 s.
            // This prevents multiple rapid sync events from hammering loadAllData().
            self.reloadDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isSaving else { return }
                debugLog("📂 File system change detected, reloading...")
                self.loadAllData()
            }
            self.reloadDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        source.setCancelHandler {
            close(descriptor)
        }

        source.resume()
        return source
    }

    /// Adds watchers for plan folders that don't have one yet, and removes watchers
    /// for plan folders that no longer exist.  No-ops when the root watcher is inactive
    /// (e.g. in unit tests where startWatching() is never called).
    private func updatePlanWatchers() {
        guard fileWatcher != nil, let storageURL = storageURL else { return }

        let currentFolderNames = Set(plans.map { $0.folderName })

        // Remove watchers for plans that have been deleted or renamed.
        let staleNames = planWatchers.keys.filter { !currentFolderNames.contains($0) }
        for folderName in staleNames {
            planWatchers[folderName]?.cancel()
            planWatchers.removeValue(forKey: folderName)
        }

        // Add watchers for plans that don't have one yet.
        for plan in plans where planWatchers[plan.folderName] == nil {
            let planFolder = storageURL.appendingPathComponent(plan.folderName)
            if let watcher = makeDirectoryWatcher(for: planFolder) {
                planWatchers[plan.folderName] = watcher
            }
        }
    }
}
