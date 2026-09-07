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

/// A transient, undoable delete action surfaced as a toast (see `TaskStore.pendingUndo`).
/// The toast auto-dismisses after a few seconds; tapping "Undo" before then runs `undo`.
struct PendingUndo: Identifiable {
    let id = UUID()
    let message: String
    let undo: () -> Void
}

@MainActor
class TaskStore: ObservableObject {
    @Published var plans: [Plan] = []
    @Published var tasks: [Task] = []
    @Published var storageURL: URL?
    @Published var settings: Settings = Settings()
    @Published var pendingUndo: PendingUndo?
    
    private let fileManager = FileManager.default
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var planWatchers: [String: DispatchSourceFileSystemObject] = [:]  // keyed by plan folder name
    private var isSaving = false  // Flag to prevent reload during save
    private var pendingUndoDismissWorkItem: DispatchWorkItem?
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

    /// Deletes a plan (and all its tasks) and offers a temporary "Undo" toast (see
    /// `pendingUndo`) that restores the plan folder, its `plan.yaml`, and every task file
    /// exactly as they were.
    func deletePlanWithUndo(_ plan: Plan) throws {
        let planTasks = tasks.filter { $0.plan == plan.name }
        try deletePlan(plan)
        offerUndo(message: "Deleted plan \"\(plan.name)\"") { [weak self] in
            try? self?.restorePlan(plan, tasks: planTasks)
        }
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

        try? registerTags(task.tags)
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

        try? registerTags(updatedTask.tags)
    }

    /// Adds any tags not already present in the global tag registry (`settings.availableTags`),
    /// so they become available for reuse on other tasks. Comparison is case-insensitive to
    /// avoid near-duplicate entries like "Bug" and "bug"; the first-seen casing wins.
    func registerTags(_ tags: [String]) throws {
        let existingLowercased = Set(settings.availableTags.map { $0.lowercased() })
        let newTags = tags.filter { !$0.isEmpty && !existingLowercased.contains($0.lowercased()) }
        guard !newTags.isEmpty else { return }

        settings.availableTags.append(contentsOf: newTags)
        settings.availableTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        try saveSettings()
    }

    /// Renames a tag across the global registry and every task that currently uses it.
    func renameGlobalTag(from oldName: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        if let index = settings.availableTags.firstIndex(of: oldName) {
            settings.availableTags.remove(at: index)
        }
        if !settings.availableTags.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            settings.availableTags.append(trimmed)
        }
        settings.availableTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        try applyToAllTasks(containingTag: oldName) { task in
            var updated = task
            updated.tags = updated.tags.map { $0 == oldName ? trimmed : $0 }
            // Collapse accidental duplicates (e.g. task already had both old and new name).
            var seen = Set<String>()
            updated.tags = updated.tags.filter { seen.insert($0.lowercased()).inserted }
            return updated
        }

        try saveSettings()
    }

    /// Removes a tag from the global registry and from every task that currently uses it.
    func deleteGlobalTag(_ name: String) throws {
        settings.availableTags.removeAll { $0 == name }

        try applyToAllTasks(containingTag: name) { task in
            var updated = task
            updated.tags.removeAll { $0 == name }
            return updated
        }

        try saveSettings()
    }

    /// Applies `transform` to every in-memory task that has `tag`, rewriting each task file
    /// in place (no plan/filename change is expected here) and updating the in-memory array.
    private func applyToAllTasks(containingTag tag: String, transform: (Task) -> Task) throws {
        guard let storageURL = storageURL else { return }

        for (index, task) in tasks.enumerated() where task.tags.contains(tag) {
            let updatedTask = transform(task)
            guard updatedTask.tags != task.tags else { continue }

            let planFolder = storageURL.appendingPathComponent(updatedTask.plan)
            let taskFile = resolveTaskFile(for: task, in: planFolder)
                ?? planFolder.appendingPathComponent(task.fileName)

            markSaving()
            let content = MarkdownParser.serializeTask(updatedTask)
            try content.write(to: taskFile, atomically: false, encoding: .utf8)

            tasks[index] = updatedTask
        }
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

    /// Deletes a task and offers a temporary "Undo" toast (see `pendingUndo`) that
    /// re-creates the task file exactly as it was.
    func deleteTaskWithUndo(_ task: Task) throws {
        try deleteTask(task)
        offerUndo(message: "Deleted \"\(task.title)\"") { [weak self] in
            try? self?.restoreTask(task)
        }
    }

    /// Deletes multiple tasks (e.g. from a multi-select bulk action) and offers a single
    /// "Undo" toast that restores all of them. Continues past per-task failures so one bad
    /// file doesn't block deletion of the rest; the first error encountered (if any) is
    /// rethrown after every task has been attempted.
    func deleteTasksWithUndo(_ tasksToDelete: [Task]) throws {
        guard !tasksToDelete.isEmpty else { return }

        var firstError: Error?
        var deleted: [Task] = []
        for task in tasksToDelete {
            do {
                try deleteTask(task)
                deleted.append(task)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if !deleted.isEmpty {
            let message = deleted.count == 1
                ? "Deleted \"\(deleted[0].title)\""
                : "Deleted \(deleted.count) tasks"
            offerUndo(message: message) { [weak self] in
                for task in deleted {
                    try? self?.restoreTask(task)
                }
            }
        }

        if let firstError { throw firstError }
    }

    /// Moves multiple tasks to a different plan in one action (e.g. from a multi-select bulk
    /// action). Mirrors the single-task drag-to-plan behavior in `ContentView`: if the target
    /// plan doesn't have a status matching the task's current one, the task is mapped to the
    /// target plan's first status. Continues past per-task failures; the first error (if any)
    /// is rethrown after every task has been attempted.
    func moveTasks(_ tasksToMove: [Task], toPlan targetPlan: Plan) throws {
        var firstError: Error?
        let sortedTargetStatuses = targetPlan.statuses.sorted { $0.order < $1.order }

        for task in tasksToMove {
            guard task.plan != targetPlan.name else { continue }

            var updated = task
            updated.plan = targetPlan.name

            let hasMatchingStatus = targetPlan.statuses.contains { $0.name == task.status }
            if !hasMatchingStatus, let firstStatus = sortedTargetStatuses.first {
                updated.status = firstStatus.name
            }

            do {
                try updateTask(updated)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
    }

    /// Moves multiple tasks to a different status column within their current plan in one
    /// action (e.g. from a multi-select bulk action). Continues past per-task failures; the
    /// first error (if any) is rethrown after every task has been attempted.
    func moveTasks(_ tasksToMove: [Task], toStatus statusName: String) throws {
        var firstError: Error?

        for task in tasksToMove {
            guard task.status != statusName else { continue }

            var updated = task
            updated.status = statusName

            do {
                try updateTask(updated)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
    }

    /// Shows a transient "Undo" toast (auto-dismissing after a few seconds) offering to
    /// reverse a just-performed delete via `action`.
    private func offerUndo(message: String, action: @escaping () -> Void) {
        pendingUndoDismissWorkItem?.cancel()

        let toast = PendingUndo(message: message, undo: action)
        pendingUndo = toast

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingUndo?.id == toast.id else { return }
            self.pendingUndo = nil
        }
        pendingUndoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    /// Dismisses the current undo toast immediately (e.g. after the user taps "Undo").
    func dismissPendingUndo() {
        pendingUndoDismissWorkItem?.cancel()
        pendingUndoDismissWorkItem = nil
        pendingUndo = nil
    }

    /// Re-creates a previously deleted task file exactly as it was. No-ops if the owning
    /// plan folder no longer exists (e.g. the plan itself was also deleted in the meantime).
    private func restoreTask(_ task: Task) throws {
        guard let storageURL = storageURL else { return }

        let planFolder = storageURL.appendingPathComponent(task.plan)
        guard fileManager.fileExists(atPath: planFolder.path) else { return }

        let taskFile = planFolder.appendingPathComponent(task.fileName)
        markSaving()
        let content = MarkdownParser.serializeTask(task)
        try content.write(to: taskFile, atomically: false, encoding: .utf8)

        if !tasks.contains(where: { $0.id == task.id }) {
            tasks.append(task)
        }
    }

    /// Re-creates a previously deleted plan folder (`plan.yaml` plus every task file) exactly
    /// as it was, restoring its original position in `settings.planOrder`. No-ops if a plan
    /// with the same folder name already exists (e.g. a new plan was created in its place).
    private func restorePlan(_ plan: Plan, tasks tasksToRestore: [Task]) throws {
        guard let storageURL = storageURL else { return }

        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        guard !fileManager.fileExists(atPath: planFolder.path) else { return }

        markSaving()
        try fileManager.createDirectory(at: planFolder, withIntermediateDirectories: true)

        let planFile = planFolder.appendingPathComponent("plan.yaml")
        let content = MarkdownParser.serializePlan(plan)
        try content.write(to: planFile, atomically: false, encoding: .utf8)

        if !plans.contains(where: { $0.id == plan.id }) {
            plans.append(plan)
        }

        for task in tasksToRestore {
            let taskFile = planFolder.appendingPathComponent(task.fileName)
            let taskContent = MarkdownParser.serializeTask(task)
            try? taskContent.write(to: taskFile, atomically: false, encoding: .utf8)
            if !tasks.contains(where: { $0.id == task.id }) {
                tasks.append(task)
            }
        }

        if !settings.planOrder.contains(plan.name) {
            let insertIndex = min(plan.order, settings.planOrder.count)
            settings.planOrder.insert(plan.name, at: insertIndex)
            try saveSettings()
        }

        if fileWatcher != nil, let watcher = makeDirectoryWatcher(for: planFolder) {
            planWatchers[plan.folderName] = watcher
        }
    }
    
    /// Copies a dropped file (e.g. an image dragged onto an open task) into the plan's
    /// shared `attachments` folder, so it can be referenced from any task in that plan via
    /// a stable relative path. Returns the relative path (e.g. "attachments/photo.png") to
    /// embed as `![](relativePath)` in the task's markdown body.
    /// If a file with the same name already exists, the first 8 chars of a fresh UUID are
    /// appended so the new file never overwrites or collides with an unrelated one.
    func importAttachment(from sourceURL: URL, planName: String) throws -> String {
        let (_, destinationFile) = try attachmentDestination(forFileNamed: sourceURL.lastPathComponent, planName: planName)

        // Dropped file URLs from another process (e.g. Finder) may be security-scoped;
        // this is a no-op (returns false) for plain local URLs, so it's safe either way.
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        markSaving()
        try fileManager.copyItem(at: sourceURL, to: destinationFile)

        return "attachments/\(destinationFile.lastPathComponent)"
    }

    /// Writes raw image data (e.g. pasted from the clipboard, which has no source file)
    /// into the plan's shared `attachments` folder under `suggestedFileName`. Returns the
    /// relative path to embed as `![](relativePath)` in the task's markdown body.
    func importAttachment(data: Data, suggestedFileName: String, planName: String) throws -> String {
        let (_, destinationFile) = try attachmentDestination(forFileNamed: suggestedFileName, planName: planName)

        markSaving()
        try data.write(to: destinationFile, options: .atomic)

        return "attachments/\(destinationFile.lastPathComponent)"
    }

    /// Resolves (and creates if needed) the plan's `attachments` folder, and computes a
    /// collision-free destination file URL for `fileName` within it.
    private func attachmentDestination(forFileNamed fileName: String, planName: String) throws -> (folder: URL, file: URL) {
        guard let storageURL = storageURL else {
            throw NSError(domain: "TaskStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "No storage location set"])
        }
        let planFolder = storageURL.appendingPathComponent(planName)
        guard fileManager.fileExists(atPath: planFolder.path) else {
            throw NSError(domain: "TaskStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Plan folder '\(planName)' does not exist"])
        }

        let attachmentsFolder = planFolder.appendingPathComponent("attachments")
        if !fileManager.fileExists(atPath: attachmentsFolder.path) {
            try fileManager.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)
        }

        var destinationFile = attachmentsFolder.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationFile.path) {
            let base = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let uniqueName = ext.isEmpty
                ? "\(base)-\(UUID().uuidString.prefix(8))"
                : "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
            destinationFile = attachmentsFolder.appendingPathComponent(uniqueName)
        }

        return (attachmentsFolder, destinationFile)
    }
    
    /// Archives the given tasks (typically ones in a "Done" status) by moving their files into
    /// `Archived/` inside the plan's folder. If `subfolder` is non-empty (e.g. a user-chosen
    /// name like "2026-09-07" for the current date), tasks are grouped into
    /// `Archived/<subfolder>/` instead, so an entire archiving batch (e.g. "all tasks done this
    /// week") can be reviewed together later. `subfolder` is sanitized to strip path separators
    /// and other characters that aren't safe as a single folder name.
    func archiveDoneTasks(for plan: Plan, tasks doneTasks: [Task], subfolder: String = "") throws {
        guard let storageURL = storageURL else { return }
        
        let planFolder = storageURL.appendingPathComponent(plan.folderName)
        var archiveFolder = planFolder.appendingPathComponent("Archived")

        let sanitizedSubfolder = Self.sanitizeFolderName(subfolder)
        if !sanitizedSubfolder.isEmpty {
            archiveFolder = archiveFolder.appendingPathComponent(sanitizedSubfolder)
        }
        
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
            var archivedFile = archiveFolder.appendingPathComponent(task.fileName)

            // Avoid clobbering a same-named file already archived in this subfolder.
            if fileManager.fileExists(atPath: archivedFile.path) {
                let base = (task.fileName as NSString).deletingPathExtension
                archivedFile = archiveFolder.appendingPathComponent("\(base)-\(task.id.uuidString.prefix(8)).md")
            }
            
            if fileManager.fileExists(atPath: currentFile.path) {
                try fileManager.moveItem(at: currentFile, to: archivedFile)
                debugLog("📦 Archived: \(task.title)")
            }
            
            // Remove from in-memory array
            tasks.removeAll { $0.id == task.id }
        }
        
        debugLog("✅ Archived \(doneTasks.count) task(s)")
    }
    
    /// Strips path separators and other characters unsafe for a single filesystem folder name
    /// component (e.g. from user-provided archive subfolder names), trimming whitespace too.
    private static func sanitizeFolderName(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:")
        let cleaned = name.components(separatedBy: disallowed).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
