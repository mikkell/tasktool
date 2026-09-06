//
//  ContentView.swift
//  TaskTool
//
//  Created by Mikkel Lund Lindemark on 22/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static func from(string colorName: String) -> Color {
        switch colorName.lowercased() {
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        case "gray": return .gray
        default: return .blue
        }
    }
}

extension Animation {
    /// Lightweight, snappy feedback for momentary interactive states — drag-target
    /// highlights (sidebar rows, Kanban columns) and card hover. Kept short and firmly
    /// damped so it reads as instant response rather than a bouncy flourish.
    static let taskToolQuickFeedback = Animation.spring(response: 0.22, dampingFraction: 0.82)

    /// Layout reflow for task lists — insertion, removal, and reordering when a task
    /// moves between statuses or plans. Slightly slower than `.taskToolQuickFeedback` so
    /// the move/fade transitions stay legible, while still feeling snappy.
    static let taskToolReflow = Animation.spring(response: 0.32, dampingFraction: 0.78)
}

/// Markdown text-formatting helpers shared by every plain-text `TextEditor` (task
/// description/notes fields) so Bold/Italic/Strikethrough keyboard shortcuts behave
/// consistently everywhere.
enum MarkdownFormatting {
    /// Wraps the current selection with `prefix`/`suffix` (e.g. `**` for bold), or — if
    /// nothing is selected — inserts the markers at the cursor so the user can type straight
    /// into them. Handles macOS's multi-range (discontiguous) text selection by wrapping each
    /// selected range independently, then leaves the wrapped (inner) text selected so the same
    /// shortcut can be pressed again right away.
    ///
    /// If the selection is already formatted — either because the markers sit immediately
    /// outside it (e.g. cursor inside `**bold**`) or because the selection itself includes
    /// them (e.g. `**bold**` fully selected) — pressing the same shortcut again removes the
    /// markers instead of adding another layer, so the shortcut acts as a toggle.
    static func wrapSelection(
        in text: inout String,
        selection: inout TextSelection?,
        prefix: String,
        suffix: String
    ) {
        let ranges: [Range<String.Index>]
        if let indices = selection?.indices {
            switch indices {
            case .selection(let range):
                ranges = [range]
            case .multiSelection(let rangeSet):
                ranges = Array(rangeSet.ranges)
            @unknown default:
                ranges = [text.endIndex..<text.endIndex]
            }
        } else {
            ranges = [text.endIndex..<text.endIndex]
        }
        guard !ranges.isEmpty else { return }

        enum Action { case add, remove }

        // Precompute the exact span each edit will replace (which, when unwrapping markers
        // that sit just outside the selection, extends beyond the original selected range)
        // along with the replacement text and whether it's adding or removing formatting.
        var edits: [(editRange: Range<String.Index>, replacement: String, action: Action)] = []

        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let selectedText = String(text[range])

            let outerStart = text.index(range.lowerBound, offsetBy: -prefix.count, limitedBy: text.startIndex)
            let outerEnd = text.index(range.upperBound, offsetBy: suffix.count, limitedBy: text.endIndex)
            let hasOuterMarkers = !prefix.isEmpty && !suffix.isEmpty
                && outerStart != nil && outerEnd != nil
                && text[outerStart!..<range.lowerBound] == prefix
                && text[range.upperBound..<outerEnd!] == suffix

            let hasInnerMarkers = !selectedText.isEmpty
                && selectedText.count >= prefix.count + suffix.count
                && selectedText.hasPrefix(prefix)
                && selectedText.hasSuffix(suffix)

            if hasOuterMarkers, let outerStart, let outerEnd {
                edits.append((outerStart..<outerEnd, selectedText, .remove))
            } else if hasInnerMarkers {
                let innerText = String(selectedText.dropFirst(prefix.count).dropLast(suffix.count))
                edits.append((range, innerText, .remove))
            } else {
                edits.append((range, prefix + selectedText + suffix, .add))
            }
        }

        // Build the new string in one left-to-right pass instead of mutating `text` in place —
        // this avoids invalidating the `String.Index` values of ranges we haven't processed yet.
        var result = ""
        var lastEnd = text.startIndex
        var wrappedRanges: [Range<String.Index>] = []

        for edit in edits {
            result += text[lastEnd..<edit.editRange.lowerBound]
            let insertStart = result.endIndex
            result += edit.replacement
            let insertEnd = result.endIndex

            switch edit.action {
            case .add:
                // Keep only the wrapped (inner) text selected, not the markers, so the same
                // shortcut can be pressed again right away to toggle formatting off.
                let contentStart = result.index(insertStart, offsetBy: prefix.count)
                let contentEnd = result.index(insertEnd, offsetBy: -suffix.count)
                wrappedRanges.append(contentStart..<contentEnd)
            case .remove:
                wrappedRanges.append(insertStart..<insertEnd)
            }

            lastEnd = edit.editRange.upperBound
        }
        result += text[lastEnd...]

        text = result

        if wrappedRanges.count == 1, let only = wrappedRanges.first {
            selection = TextSelection(range: only)
        } else {
            selection = TextSelection(ranges: RangeSet(wrappedRanges))
        }
    }
}

/// Hidden buttons wiring ⌘B / ⌘I / ⌘⇧X to Bold/Italic/Strikethrough Markdown formatting for a
/// given `TextEditor`. Gated on `isActive` (typically that editor's own `@FocusState`) so the
/// shortcuts don't hijack other fields — e.g. a Title `TextField` in the same sheet.
private struct MarkdownFormattingShortcuts: View {
    @Binding var text: String
    @Binding var selection: TextSelection?
    let isActive: Bool

    var body: some View {
        Group {
            Button("") {
                MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "**", suffix: "**")
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("") {
                MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "*", suffix: "*")
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("") {
                MarkdownFormatting.wrapSelection(in: &text, selection: &selection, prefix: "~~", suffix: "~~")
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
        }
        .disabled(!isActive)
        .hidden()
    }
}

/// Standardized Cancel / primary-action button pair used at the bottom of every
/// creation and edit sheet in the app. Always trailing-aligned (macOS HIG convention),
/// with the primary action styled as a prominent blue button so the confirming action
/// is unambiguous at a glance. Callers that need a leading element (e.g. a destructive
/// "Delete" button) should place this inside their own `HStack` after a `Spacer()`.
private struct DialogFooterButtons: View {
    let confirmTitle: String
    var confirmDisabled: Bool = false
    var confirmShortcut: KeyboardShortcut = .defaultAction
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(confirmShortcut)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(confirmDisabled)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A transient "Undo" toast shown after deleting a plan or task, anchored to a corner of
/// the window (see `ContentView`'s `.overlay`). Auto-dismisses after a few seconds via
/// `TaskStore.pendingUndo`'s own timer; this view just renders whatever is currently pending.
private struct UndoToastView: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .lineLimit(1)

            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .shadow(radius: 8, y: 2)
    }
}

struct ContentView: View {
    @EnvironmentObject var taskStore: TaskStore
    @State private var showingFolderPicker = false
    @State private var selectedPlan: Plan?
    @State private var showingNewPlan = false
    @State private var showingNewTask = false
    @State private var editingPlan: Plan?
    @State private var planToDelete: Plan?
    @State private var deleteErrorMessage = ""
    @State private var showingDeleteError = false

    var body: some View {
        if taskStore.storageURL == nil {
            VStack(spacing: 20) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary)
                
                Text("Choose Storage Location")
                    .font(.title)
                
                Text("Select a folder where your tasks and plans will be stored")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Choose Folder") {
                    showFolderPicker()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NavigationSplitView {
                List(selection: $selectedPlan) {
                    Section("Plans") {
                        ForEach(Array(taskStore.plans.sorted(by: { $0.order < $1.order }).enumerated()), id: \.element.id) { index, plan in
                            PlanSidebarRow(plan: plan, shortcutNumber: index < 9 ? index + 1 : nil) { providers in
                                handleTaskDropOnPlan(providers: providers, targetPlan: plan)
                            }
                            .contextMenu {
                                Button("Edit...") {
                                    editingPlan = plan
                                }
                                
                                Divider()
                                
                                Button("Delete", role: .destructive) {
                                    planToDelete = plan
                                }
                            }
                        }
                        .onMove { from, to in
                            debugLog("📝 Moving plan from \(from) to \(to)")
                            var sortedPlans = taskStore.plans.sorted(by: { $0.order < $1.order })
                            debugLog("📋 Sorted plans before move: \(sortedPlans.map { "\($0.name): \($0.order)" })")
                            
                            // Move the plans
                            sortedPlans.move(fromOffsets: from, toOffset: to)
                            
                            // Now reassign order based on new positions
                            for (index, _) in sortedPlans.enumerated() {
                                sortedPlans[index].order = index
                            }
                            
                            debugLog("📋 Sorted plans after move: \(sortedPlans.map { "\($0.name): \($0.order)" })")
                            
                            // Update the in-memory plans array
                            taskStore.plans = sortedPlans
                            
                            // Update settings with new plan order
                            taskStore.settings.planOrder = sortedPlans.map { $0.name }
                            
                            // Save settings to settings.yaml
                            try? taskStore.saveSettings()
                        }
                    }
                    
                    Section {
                        Button(action: { showingNewPlan = true }) {
                            Label("Create Plan", systemImage: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id(taskStore.plans.map { "\($0.order)" }.joined(separator: ","))
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .background(
                    // Hidden buttons wire up ⌘1-⌘9 to jump directly to the plan at that
                    // sidebar position (by current sort order). Plans beyond the 9th don't
                    // get a shortcut, matching the visible number badges in the sidebar.
                    ForEach(1...9, id: \.self) { number in
                        Button("") { selectPlan(atShortcutNumber: number) }
                            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                            .hidden()
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Button("Change Storage Location...") {
                                showFolderPicker()
                            }
                            
                            if let url = taskStore.storageURL {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                                }
                            }
                        } label: {
                            Label("Options", systemImage: "ellipsis.circle")
                        }
                    }
                }
            } detail: {
                if let plan = selectedPlan {
                    PlanDetailView(planId: plan.id)
                } else {
                    Text("Select a plan")
                        .foregroundColor(.secondary)
                }
            }
            .sheet(isPresented: $showingNewPlan) {
                NewPlanView()
            }
            .sheet(item: $editingPlan) { plan in
                EditPlanView(plan: plan)
            }
            .alert("Delete Plan", isPresented: Binding(
                get: { planToDelete != nil },
                set: { if !$0 { planToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) {
                    planToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let plan = planToDelete {
                        do {
                            try taskStore.deletePlanWithUndo(plan)
                            if selectedPlan?.id == plan.id {
                                selectedPlan = nil
                            }
                        } catch {
                            deleteErrorMessage = "Failed to delete '\(plan.name)': \(error.localizedDescription)"
                            showingDeleteError = true
                        }
                        planToDelete = nil
                    }
                }
            } message: {
                if let plan = planToDelete {
                    Text("Are you sure you want to delete '\(plan.name)'? This will delete all tasks in this plan.")
                }
            }
            .alert("Error", isPresented: $showingDeleteError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteErrorMessage)
            }
            .overlay(alignment: .bottomTrailing) {
                if let pendingUndo = taskStore.pendingUndo {
                    UndoToastView(
                        message: pendingUndo.message,
                        onUndo: {
                            pendingUndo.undo()
                            taskStore.dismissPendingUndo()
                        }
                    )
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: taskStore.pendingUndo?.id)
                }
            }
        }
    }
    
    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to store your tasks and plans"
        panel.prompt = "Choose"
        
        if panel.runModal() == .OK, let url = panel.url {
            taskStore.setStorageLocation(url)
        }
    }
    
    /// Selects the plan at sidebar position `number` (1-based, matching the visible ⌘1-⌘9
    /// badges). No-ops if there aren't that many plans.
    private func selectPlan(atShortcutNumber number: Int) {
        let sortedPlans = taskStore.plans.sorted(by: { $0.order < $1.order })
        guard number >= 1, number <= sortedPlans.count else { return }
        selectedPlan = sortedPlans[number - 1]
    }
    
    private func handleTaskDropOnPlan(providers: [NSItemProvider], targetPlan: Plan) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, error in
            guard let data = item as? Data,
                  let taskIdString = String(data: data, encoding: .utf8),
                  let taskId = UUID(uuidString: taskIdString) else {
                return
            }
            
            DispatchQueue.main.async {
                if let taskIndex = taskStore.tasks.firstIndex(where: { $0.id == taskId }) {
                    var task = taskStore.tasks[taskIndex]
                    let originalTask = task
                    
                    // Only update if plan changed
                    if task.plan != targetPlan.name {
                        task.plan = targetPlan.name
                        
                        // Check if the new plan has the task's current status
                        let hasMatchingStatus = targetPlan.statuses.contains { $0.name == task.status }
                        
                        if !hasMatchingStatus {
                            // Map to the first status in the new plan if no match
                            if let firstStatus = targetPlan.statuses.sorted(by: { $0.order < $1.order }).first {
                                task.status = firstStatus.name
                                debugLog("🔄 Task status changed from '\(originalTask.status)' to '\(firstStatus.name)'")
                            }
                        }
                        
                        do {
                            try taskStore.updateTask(task)
                            debugLog("📦 Task '\(task.title)' moved to plan '\(targetPlan.name)'")
                        } catch {
                            // Revert in-memory state so the UI stays consistent with disk
                            taskStore.tasks[taskIndex] = originalTask
                            debugLog("❌ Failed to move task '\(task.title)': \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        return true
    }
}

/// Sidebar row for a plan. Shows a highlighted background and drop indicator
/// when a task is dragged over it, making cross-plan moves obvious.
private struct PlanSidebarRow: View {
    let plan: Plan
    /// 1-9 shortcut number for this plan's position, or nil if beyond the first 9 plans.
    let shortcutNumber: Int?
    let onDrop: ([NSItemProvider]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        NavigationLink(value: plan) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.from(string: plan.color))
                        .frame(width: 18, height: 18)
                    if let shortcutNumber {
                        Text("\(shortcutNumber)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                Text(plan.name)
                Spacer()
                if isTargeted {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(Color.from(string: plan.color))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.from(string: plan.color).opacity(0.18) : Color.clear)
            )
            .animation(.taskToolQuickFeedback, value: isTargeted)
        }
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            onDrop(providers)
        }
    }
}


struct PlanDetailView: View {
    let planId: UUID
    @EnvironmentObject var taskStore: TaskStore
    @State private var showingNewTask = false
    @State private var showingEditStatuses = false
    @State private var showingArchiveConfirmation = false
    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var selectedTaskIDs: Set<UUID> = []
    @State private var showingBulkDeleteConfirm = false
    
    var plan: Plan? {
        taskStore.plans.first(where: { $0.id == planId })
    }
    
    var planTasks: [Task] {
        guard let plan = plan else { return [] }
        return taskStore.tasks.filter { $0.plan == plan.name }
    }
    
    var filteredPlanTasks: [Task] {
        guard !searchText.isEmpty else { return planTasks }
        let query = searchText.lowercased()
        return planTasks.filter { task in
            task.title.lowercased().contains(query) ||
            task.body.lowercased().contains(query) ||
            task.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }
    
    /// Tasks grouped by status name, computed once per render instead of re-filtering
    /// `filteredPlanTasks` from scratch for every Kanban column.
    var tasksGroupedByStatus: [String: [Task]] {
        Dictionary(grouping: filteredPlanTasks, by: { $0.status })
    }

    func tasks(for status: Plan.TaskStatus) -> [Task] {
        tasksGroupedByStatus[status.name] ?? []
    }
    
    var doneStatusName: String? {
        plan?.statuses.first(where: { $0.isDoneStatus })?.name
    }
    
    var doneTasks: [Task] {
        guard let doneStatus = doneStatusName else { return [] }
        return planTasks.filter { $0.status == doneStatus }
    }
    
    var selectedTasksList: [Task] {
        planTasks.filter { selectedTaskIDs.contains($0.id) }
    }
    
    var otherPlansForSelection: [Plan] {
        guard let plan = plan else { return [] }
        return taskStore.plans.filter { $0.id != plan.id }
    }
    
    var body: some View {
        if let plan = plan {
            // `.searchable`/`.searchFocused`/`.toolbar`/`.sheet` are attached to this stable
            // VStack wrapper rather than directly to the GeometryReader below. Chaining them
            // onto a GeometryReader-rooted view is fragile: GeometryReader recomputes its
            // content (and thus re-evaluates those modifiers) on every geometry pass, which is
            // exactly what happens while the search field animates in/out or its text changes
            // — this could intermittently crash or drop the search UI when the field is
            // dismissed or cleared.
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let columnCount = plan.statuses.count
                    let spacing: CGFloat = 20
                    let paddingTotal: CGFloat = 40  // .padding() = 20pt per side
                    let minColWidth: CGFloat = 280
                    let evenWidth = (geo.size.width - paddingTotal - spacing * CGFloat(max(columnCount - 1, 0))) / CGFloat(max(columnCount, 1))
                    let colWidth = max(minColWidth, evenWidth)

                    // Group once per render instead of re-filtering the full task list for every column.
                    let groupedTasks = tasksGroupedByStatus

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(plan.statuses.sorted(by: { $0.order < $1.order })) { status in
                                KanbanColumn(
                                    title: status.name,
                                    tasks: groupedTasks[status.name] ?? [],
                                    color: Color.from(string: status.color),
                                    statusName: status.name,
                                    isDoneColumn: status.isDoneStatus,
                                    plan: plan,
                                    selectedTaskIDs: $selectedTaskIDs
                                )
                                .frame(width: colWidth)
                            }
                        }
                        // Note: no `.animation(value:)` here — each KanbanColumn already
                        // animates its own `tasks` array. Adding a second implicit animation at
                        // this level for the same underlying (search-driven) change caused two
                        // overlapping animated insert/remove passes across every column at once,
                        // which combined with a GeometryReader recomputing layout mid-animation
                        // was the likely source of intermittent crashes when clearing search.
                        .padding()
                        .frame(minWidth: geo.size.width)
                    }
                }
            }
            // Forces SwiftUI to treat this as a fresh view instance whenever the selected plan
            // changes, resetting `@State` (search text, multi-select) instead of carrying stale
            // selection/search state over from a previously-viewed plan.
            .id(plan.id)
            .navigationTitle(plan.name)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search tasks…")
            .searchFocused($isSearchFieldFocused)
            .background(
                // SwiftUI's automatic Cmd-F for `.searchable` can silently fail to fire when the
                // modifier is nested this deep (GeometryReader → NavigationSplitView detail).
                // This hidden button guarantees the shortcut always focuses the search field.
                Button("") { isSearchFieldFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            )
            .toolbar {
                // Bulk-selection actions replace nothing and add no extra row — they live in
                // the same fixed-height toolbar line as the other actions so selecting tasks
                // never pushes the Kanban columns down.
                if !selectedTaskIDs.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Text("\(selectedTaskIDs.count) selected")
                            .foregroundColor(.secondary)
                            .background(.clear)
                    }
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            ForEach(plan.statuses.sorted(by: { $0.order < $1.order })) { status in
                                Button(status.name) { moveSelectedTasks(toStatus: status.name) }
                            }
                        } label: {
                            Label("Move to Status", systemImage: "arrow.right.square")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            ForEach(otherPlansForSelection) { targetPlan in
                                Button(targetPlan.name) { moveSelectedTasks(toPlan: targetPlan) }
                            }
                        } label: {
                            Label("Move to Plan", systemImage: "folder")
                        }
                        .disabled(otherPlansForSelection.isEmpty)
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(role: .destructive, action: { showingBulkDeleteConfirm = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button(action: { selectedTaskIDs.removeAll() }) {
                            Label("Clear Selection", systemImage: "xmark.circle")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingNewTask = true }) {
                        Label("New Task", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { showingEditStatuses = true }) {
                        Label("Edit Statuses", systemImage: "square.grid.3x1.fill.below.line.grid.1x2")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button(action: { showingArchiveConfirmation = true }) {
                        Label("Archive Done", systemImage: "archivebox")
                    }
                    .disabled(doneTasks.isEmpty)
                }
            }
            .sheet(isPresented: $showingNewTask) {
                NewTaskView(plan: plan)
            }
            .sheet(isPresented: $showingEditStatuses) {
                EditStatusesView(plan: plan)
            }
            .alert("Archive Done Tasks", isPresented: $showingArchiveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Archive", role: .destructive) {
                    archiveDoneTasks()
                }
            } message: {
                Text("Archive \(doneTasks.count) completed task\(doneTasks.count == 1 ? "" : "s")? They will be moved to an 'Archived' folder.")
            }
            .alert("Delete \(selectedTaskIDs.count) Task\(selectedTaskIDs.count == 1 ? "" : "s")?", isPresented: $showingBulkDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    bulkDeleteSelectedTasks()
                }
            } message: {
                Text("You can undo this immediately after.")
            }
        } else {
            Text("Plan not found")
                .foregroundColor(.secondary)
        }
    }
    
    private func archiveDoneTasks() {
        guard let plan = plan else { return }
        
        do {
            try taskStore.archiveDoneTasks(for: plan, tasks: doneTasks)
        } catch {
            debugLog("❌ Failed to archive tasks: \(error.localizedDescription)")
        }
    }
    
    private func moveSelectedTasks(toPlan targetPlan: Plan) {
        let tasksToMove = selectedTasksList
        selectedTaskIDs.removeAll()
        do {
            try taskStore.moveTasks(tasksToMove, toPlan: targetPlan)
        } catch {
            debugLog("❌ Failed to move tasks to plan '\(targetPlan.name)': \(error.localizedDescription)")
        }
    }
    
    private func moveSelectedTasks(toStatus statusName: String) {
        let tasksToMove = selectedTasksList
        selectedTaskIDs.removeAll()
        do {
            try taskStore.moveTasks(tasksToMove, toStatus: statusName)
        } catch {
            debugLog("❌ Failed to move tasks to status '\(statusName)': \(error.localizedDescription)")
        }
    }
    
    private func bulkDeleteSelectedTasks() {
        let tasksToDelete = selectedTasksList
        selectedTaskIDs.removeAll()
        do {
            try taskStore.deleteTasksWithUndo(tasksToDelete)
        } catch {
            debugLog("❌ Failed to delete tasks: \(error.localizedDescription)")
        }
    }
}

struct KanbanColumn: View {
    let title: String
    let tasks: [Task]
    let color: Color
    let statusName: String
    let isDoneColumn: Bool
    let plan: Plan
    @Binding var selectedTaskIDs: Set<UUID>
    @State private var selectedTask: Task?
    @State private var isTargeted = false
    @State private var showingNewTask = false
    @EnvironmentObject var taskStore: TaskStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with colored background
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: { showingNewTask = true }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Add task to \(title)")
                
                Text("\(tasks.count)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(12)
                    .contentTransition(.numericText())
            }
            .padding()
            .background(color)
            
            Divider()
            
            // Task list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(
                            task: task,
                            isDone: isDoneColumn,
                            isSelected: selectedTaskIDs.contains(task.id),
                            hasActiveSelection: !selectedTaskIDs.isEmpty,
                            onToggleSelect: {
                                if selectedTaskIDs.contains(task.id) {
                                    selectedTaskIDs.remove(task.id)
                                } else {
                                    selectedTaskIDs.insert(task.id)
                                }
                            }
                        )
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .bottom).combined(with: .opacity)
                            ))
                            .onTapGesture {
                                selectedTask = task
                            }
                            .onDrag {
                                NSItemProvider(object: task.id.uuidString as NSString)
                            }
                    }
                }
                // `tasks` is already Equatable ([Task]); no need to allocate a fresh [UUID] every render.
                .animation(.taskToolReflow, value: tasks)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(isTargeted ? color.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .animation(.taskToolQuickFeedback, value: isTargeted)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? color : Color.gray.opacity(0.3), lineWidth: isTargeted ? 3 : 1)
        )
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(task: task)
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskViewForStatus(plan: plan, statusName: statusName)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { item, error in
            guard let data = item as? Data,
                  let taskIdString = String(data: data, encoding: .utf8),
                  let taskId = UUID(uuidString: taskIdString) else {
                return
            }
            
            DispatchQueue.main.async {
                if let taskIndex = taskStore.tasks.firstIndex(where: { $0.id == taskId }) {
                    var task = taskStore.tasks[taskIndex]
                    
                    // Only update if status changed
                    if task.status != statusName {
                        let originalTask = task
                        task.status = statusName
                        do {
                            try taskStore.updateTask(task)
                        } catch {
                            // Revert in-memory state so the UI stays consistent with disk
                            taskStore.tasks[taskIndex] = originalTask
                            debugLog("❌ Failed to update status for '\(task.title)': \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        return true
    }
}

struct TaskCard: View {
    let task: Task
    var isDone: Bool = false
    var isSelected: Bool = false
    var hasActiveSelection: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    @State private var isHovered = false

    private enum DueUrgency { case overdue, today, tomorrow, upcoming }

    private var dueUrgency: DueUrgency {
        guard let dueDate = task.dueDate else { return .upcoming }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let taskDay = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: today, to: taskDay).day ?? 0
        if days < 0  { return .overdue }
        if days == 0 { return .today }
        if days == 1 { return .tomorrow }
        return .upcoming
    }

    private var cardBackground: Color {
        if isDone {
            return Color.green.opacity(isHovered ? 0.20 : 0.12)
        }
        switch dueUrgency {
        case .overdue, .today: return Color.red.opacity(isHovered ? 0.20 : 0.12)
        case .tomorrow:        return Color.yellow.opacity(isHovered ? 0.28 : 0.18)
        case .upcoming:        return isHovered
                                    ? Color.accentColor.opacity(0.08)
                                    : Color(nsColor: .textBackgroundColor)
        }
    }

    private var dueDateColor: Color {
        if isDone { return .green }
        switch dueUrgency {
        case .overdue, .today: return .red
        case .tomorrow:        return Color(nsColor: .systemOrange)
        case .upcoming:        return .secondary
        }
    }

    private var dueDateIcon: String {
        switch dueUrgency {
        case .overdue:  return "calendar.badge.exclamationmark"
        case .today:    return "calendar.badge.clock"
        case .tomorrow: return "calendar"
        case .upcoming: return "calendar"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("#\(task.id.uuidString.prefix(8))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)

                Spacer()

                if isSelected || hasActiveSelection || isHovered {
                    Button(action: { onToggleSelect?() }) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help(isSelected ? "Deselect task" : "Select task")
                }
            }

            Text(task.title)
                .font(.headline)

            if !task.body.isEmpty {
                Text(task.body)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            if !task.tags.isEmpty {
                HStack {
                    ForEach(task.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            if let dueDate = task.dueDate {
                HStack {
                    Image(systemName: dueDateIcon)
                        .font(.caption)
                    Text(dueDate, style: .date)
                        .font(.caption)
                }
                .foregroundColor(dueDateColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 6 : 2, y: isHovered ? 3 : 1)
        .onHover { hovering in
            withAnimation(.taskToolQuickFeedback) {
                isHovered = hovering
            }
        }
    }
}

struct NewPlanView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var name = ""
    @State private var description = ""
    @State private var color = "blue"
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Plan")
                .font(.title)
            
            Form {
                TextField("Plan Name", text: $name)
                TextField("Description", text: $description)
                Picker("Color", selection: $color) {
                    Text("Blue").tag("blue")
                    Text("Green").tag("green")
                    Text("Red").tag("red")
                    Text("Orange").tag("orange")
                    Text("Purple").tag("purple")
                }
            }
            .padding()
            
            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            DialogFooterButtons(
                confirmTitle: "Create",
                confirmDisabled: name.isEmpty,
                onCancel: { dismiss() },
                onConfirm: {
                    if taskStore.plans.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                        errorMessage = "A plan named '\(name)' already exists"
                        showError = true
                        return
                    }
                    let plan = Plan(name: name, color: color, description: description)
                    do {
                        try taskStore.createPlan(plan)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to create plan: \(error.localizedDescription)"
                        showError = true
                    }
                }
            )
        }
        .padding()
        .frame(width: 400)
    }
}

struct NewTaskView: View {
    let plan: Plan
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var title = ""
    @State private var taskBody = ""
    @State private var taskBodySelection: TextSelection?
    @State private var tags: [String] = []
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var showError = false
    @State private var errorMessage = ""
    @FocusState private var descriptionFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Task")
                .font(.title)

            Grid(horizontalSpacing: 16, verticalSpacing: 20) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Task Title")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow(alignment: .top) {
                    Text("Description")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    TextEditor(text: $taskBody, selection: $taskBodySelection)
                        .frame(height: 100)
                        .focused($descriptionFocused)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(descriptionFocused ? Color.accentColor : Color.gray.opacity(0.5),
                                        lineWidth: descriptionFocused ? 2 : 1)
                        )
                        .background(
                            MarkdownFormattingShortcuts(text: $taskBody, selection: $taskBodySelection, isActive: descriptionFocused)
                        )
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("Tags")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TagInputView(tags: $tags)
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("").gridColumnAlignment(.trailing)
                    Toggle("Due Date", isOn: $hasDueDate)
                        .toggleStyle(.checkbox)
                        .onChange(of: hasDueDate) { _, newValue in
                            if newValue && dueDate == nil {
                                dueDate = Date()
                            } else if !newValue {
                                dueDate = nil
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if hasDueDate {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("").gridColumnAlignment(.trailing)
                        DatePicker("", selection: Binding($dueDate, default: Date()), displayedComponents: .date)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)

            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            DialogFooterButtons(
                confirmTitle: "Create",
                confirmDisabled: title.isEmpty,
                confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
                onCancel: { dismiss() },
                onConfirm: {
                    let defaultStatus = plan.statuses.sorted(by: { $0.order < $1.order }).first?.name ?? "To Do"
                    let task = Task(
                        title: title,
                        plan: plan.name,
                        status: defaultStatus,
                        dueDate: hasDueDate ? dueDate : nil,
                        tags: tags,
                        body: taskBody
                    )
                    do {
                        try taskStore.createTask(task)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to create task: \(error.localizedDescription)"
                        showError = true
                    }
                }
            )
        }
        .padding()
        .frame(width: 500)
    }
}

struct NewTaskViewForStatus: View {
    let plan: Plan
    let statusName: String
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var title = ""
    @State private var taskBody = ""
    @State private var taskBodySelection: TextSelection?
    @State private var tags: [String] = []
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var showError = false
    @State private var errorMessage = ""
    @FocusState private var descriptionFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Task")
                .font(.title)

            Grid(horizontalSpacing: 16, verticalSpacing: 20) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Task Title")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TextField("", text: $title)
                        .autocorrectionDisabled(false)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow(alignment: .top) {
                    Text("Description")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    TextEditor(text: $taskBody, selection: $taskBodySelection)
                        .frame(height: 100)
                        .focused($descriptionFocused)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(descriptionFocused ? Color.accentColor : Color.gray.opacity(0.5),
                                        lineWidth: descriptionFocused ? 2 : 1)
                        )
                        .background(
                            MarkdownFormattingShortcuts(text: $taskBody, selection: $taskBodySelection, isActive: descriptionFocused)
                        )
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("Tags")
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    TagInputView(tags: $tags)
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("").gridColumnAlignment(.trailing)
                    Toggle("Due Date", isOn: $hasDueDate)
                        .toggleStyle(.checkbox)
                        .onChange(of: hasDueDate) { _, newValue in
                            if newValue && dueDate == nil {
                                dueDate = Date()
                            } else if !newValue {
                                dueDate = nil
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if hasDueDate {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("").gridColumnAlignment(.trailing)
                        DatePicker("", selection: Binding($dueDate, default: Date()), displayedComponents: .date)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)

            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            DialogFooterButtons(
                confirmTitle: "Create",
                confirmDisabled: title.isEmpty,
                confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
                onCancel: { dismiss() },
                onConfirm: {
                    let task = Task(
                        title: title,
                        plan: plan.name,
                        status: statusName,
                        dueDate: hasDueDate ? dueDate : nil,
                        tags: tags,
                        body: taskBody
                    )
                    do {
                        try taskStore.createTask(task)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to create task: \(error.localizedDescription)"
                        showError = true
                    }
                }
            )
        }
        .padding()
        .frame(width: 500)
    }
}

extension Binding {
    init(_ source: Binding<Value?>, default defaultValue: Value) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }
}

/// Extracts markdown image references from a body string and displays them
/// as async image previews. Also provides a field to paste new image URLs.
private struct TaskImagesSection: View {
    @Binding var bodyText: String
    /// The plan's on-disk folder, used to resolve relative attachment paths (e.g.
    /// "attachments/photo.png") produced by dropping/pasting a local image onto the task.
    let planFolder: URL?
    /// The plan name, used to import dropped/pasted/browsed images via `TaskStore`.
    let planName: String
    let onChanged: () -> Void
    let onError: (String) -> Void
    @EnvironmentObject var taskStore: TaskStore
    @State private var imageURL = ""
    @State private var isAddingImage = false
    @State private var isDropTargeted = false

    // Captures the link target for any markdown image, whether it's a remote URL
    // (https://...) or a relative path to a locally-imported attachment.
    private static let imageRegex = try? NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^\)]+)\)"#
    )

    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"
    ]

    // Preferred order to request pasted image data in: prefer compact formats over
    // raw TIFF (which is what NSPasteboard commonly offers first for clipboard images).
    private static let pasteImageTypes: [(type: UTType, ext: String)] = [
        (.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.tiff, "tiff")
    ]

    private var imageURLs: [(alt: String, url: URL)] {
        guard let regex = Self.imageRegex else { return [] }
        let range = NSRange(bodyText.startIndex..., in: bodyText)
        return regex.matches(in: bodyText, range: range).compactMap { match in
            guard let altRange = Range(match.range(at: 1), in: bodyText),
                  let pathRange = Range(match.range(at: 2), in: bodyText) else { return nil }
            let rawPath = String(bodyText[pathRange])
            guard let url = Self.resolvedURL(for: rawPath, planFolder: planFolder) else { return nil }
            return (alt: String(bodyText[altRange]), url: url)
        }
    }

    /// Resolves a markdown image target to a loadable URL. Remote links (with a scheme,
    /// e.g. "https://...") are used as-is; anything else is treated as a path relative
    /// to the plan folder, matching how `importAttachment` stores dropped images.
    private static func resolvedURL(for rawPath: String, planFolder: URL?) -> URL? {
        if let url = URL(string: rawPath), url.scheme != nil {
            return url
        }
        return planFolder?.appendingPathComponent(rawPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Images")
                    .font(.headline)
                Spacer()
                Button(action: { isAddingImage.toggle() }) {
                    Label("Add Image", systemImage: "photo.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if isAddingImage {
                // Drag-and-drop, paste (⌘V), and click-to-browse are all scoped to this
                // box — they only become active once the user explicitly opens it, so
                // the rest of the task window never intercepts drops or clipboard pastes.
                Button(action: browseForImage) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title2)
                        Text("Click to browse, drag & drop, or paste (⌘V) an image")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6])
                            )
                    )
                }
                .buttonStyle(.plain)
                .animation(.taskToolQuickFeedback, value: isDropTargeted)
                .dropDestination(for: URL.self) { urls, _ in
                    handleImageDrop(urls)
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }
                .onPasteCommand(of: [.fileURL, .png, .jpeg, .gif, .tiff, .image]) { providers in
                    handlePastedImages(providers)
                }

                HStack {
                    TextField("or paste an image URL: https://example.com/image.png", text: $imageURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = imageURL.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return }
                        if bodyText.isEmpty {
                            bodyText = "![image](\(trimmed))"
                        } else {
                            bodyText += "\n![image](\(trimmed))"
                        }
                        onChanged()
                        imageURL = ""
                        isAddingImage = false
                    }
                    .disabled(imageURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !imageURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(imageURLs, id: \.url) { item in
                            ImageThumbnail(url: item.url, alt: item.alt)
                        }
                    }
                }
            } else if !isAddingImage {
                Text("No images — click \"Add Image\" to browse, drop, or paste one")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Imports any dropped/pasted/browsed image files into the plan's `attachments`
    /// folder and appends a markdown image reference for each to the task's notes.
    /// Returns whether any image was accepted, for use as the drop-destination result.
    @discardableResult
    private func handleImageDrop(_ urls: [URL]) -> Bool {
        let imageURLs = urls.filter { Self.imageFileExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageURLs.isEmpty else { return false }

        for url in imageURLs {
            do {
                let relativePath = try taskStore.importAttachment(from: url, planName: planName)
                let line = "![\(url.deletingPathExtension().lastPathComponent)](\(relativePath))"
                bodyText = bodyText.isEmpty ? line : bodyText + "\n" + line
            } catch {
                onError("Failed to attach image: \(error.localizedDescription)")
            }
        }
        onChanged()
        isAddingImage = false
        return true
    }

    /// Handles ⌘V while the drop-zone box is open: image files copied in Finder come
    /// through as a file URL (imported like a drop); images copied from a browser,
    /// Preview, or a screenshot come through as raw image data with no source file, so
    /// they're written directly into the plan's attachments folder under a generated name.
    private func handlePastedImages(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { handleImageDrop([url]) }
                }
                continue
            }

            guard let match = Self.pasteImageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.type.identifier) }) else {
                continue
            }
            provider.loadDataRepresentation(forTypeIdentifier: match.type.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { importPastedImageData(data, fileExtension: match.ext) }
            }
        }
    }

    private func importPastedImageData(_ data: Data, fileExtension: String) {
        let fileName = "pasted-image-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        do {
            let relativePath = try taskStore.importAttachment(data: data, suggestedFileName: fileName, planName: planName)
            let line = "![Pasted image](\(relativePath))"
            bodyText = bodyText.isEmpty ? line : bodyText + "\n" + line
            onChanged()
            isAddingImage = false
        } catch {
            onError("Failed to attach image: \(error.localizedDescription)")
        }
    }

    /// Opens a standard file picker scoped to image files, for explicitly selecting an
    /// attachment from the filesystem instead of dragging or pasting one.
    private func browseForImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an image to attach to this task"
        panel.prompt = "Attach"

        if panel.runModal() == .OK {
            handleImageDrop(panel.urls)
        }
    }
}

/// Renders a single image thumbnail. Remote URLs load via `AsyncImage` (backed by
/// `URLSession`); local attachment files use `NSImage(contentsOf:)` directly, since
/// `URLSession` — and therefore `AsyncImage` — doesn't support the `file://` scheme.
private struct ImageThumbnail: View {
    let url: URL
    let alt: String
    @State private var localImage: NSImage?
    @State private var localLoadFailed = false

    var body: some View {
        Group {
            if url.isFileURL {
                if let localImage {
                    Image(nsImage: localImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 90)
                        .clipped()
                        .cornerRadius(6)
                } else if localLoadFailed {
                    failurePlaceholder
                } else {
                    ProgressView()
                        .frame(width: 120, height: 90)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                        .task { loadLocalImage() }
                }
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 90)
                            .clipped()
                            .cornerRadius(6)
                    case .failure:
                        failurePlaceholder
                    default:
                        ProgressView()
                            .frame(width: 120, height: 90)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
        }
    }

    private var failurePlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundColor(.secondary)
            Text(alt.isEmpty ? "Image" : alt)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: 120, height: 90)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    private func loadLocalImage() {
        // Loading from disk is cheap enough for thumbnail-sized images that a background
        // hop isn't required, but dispatching keeps the main thread free during the read.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                if let image {
                    localImage = image
                } else {
                    localLoadFailed = true
                }
            }
        }
    }
}

struct TaskDetailView: View {
    let task: Task
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var editedTask: Task
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var hasDueDate: Bool
    @State private var subtasks: [SubTask]
    @State private var bodyNotes: String
    @State private var bodyNotesSelection: TextSelection?
    @State private var newSubtaskTitle = ""
    @FocusState private var subtaskFieldFocused: Bool
    @FocusState private var notesFocused: Bool

    private struct SubTask: Identifiable {
        var id = UUID()
        var title: String
        var isCompleted: Bool
    }

    var plan: Plan? {
        taskStore.plans.first(where: { $0.name == editedTask.plan })
    }

    /// The plan's on-disk folder, used to resolve/import image attachments.
    var planFolder: URL? {
        taskStore.storageURL?.appendingPathComponent(editedTask.plan)
    }

    init(task: Task) {
        self.task = task
        _editedTask = State(initialValue: task)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        let parsed = Self.parseBody(task.body)
        _subtasks = State(initialValue: parsed.subtasks)
        _bodyNotes = State(initialValue: parsed.notes)
    }

    // Split body into subtask lines and everything else.
    private static func parseBody(_ body: String) -> (subtasks: [SubTask], notes: String) {
        var result: [SubTask] = []
        var noteLines: [String] = []
        for line in body.components(separatedBy: .newlines) {
            if line.hasPrefix("- [ ] ") {
                result.append(SubTask(title: String(line.dropFirst(6)), isCompleted: false))
            } else if line.hasPrefix("- [x] ") {
                result.append(SubTask(title: String(line.dropFirst(6)), isCompleted: true))
            } else {
                noteLines.append(line)
            }
        }
        let notes = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (result, notes)
    }

    // Reconstruct body from subtasks + notes whenever either changes.
    private func rebuildBody() {
        let checkboxLines = subtasks.map { $0.isCompleted ? "- [x] \($0.title)" : "- [ ] \($0.title)" }
        var parts: [String] = []
        if !checkboxLines.isEmpty { parts.append(checkboxLines.joined(separator: "\n")) }
        if !bodyNotes.isEmpty    { parts.append(bodyNotes) }
        editedTask.body = parts.joined(separator: "\n\n")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Task Details")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Title
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(.headline)
                        TextField("Task title", text: $editedTask.title)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(false)
                    }
                    
                    // Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.headline)
                        if let plan = plan {
                            let sortedStatuses = plan.statuses.sorted(by: { $0.order < $1.order })
                            if sortedStatuses.count <= 4 {
                                Picker("Status", selection: $editedTask.status) {
                                    ForEach(sortedStatuses) { status in
                                        Text(status.name).tag(status.name)
                                    }
                                }
                                .pickerStyle(.segmented)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                                    ForEach(sortedStatuses) { status in
                                        let isSelected = editedTask.status == status.name
                                        Button(action: { editedTask.status = status.name }) {
                                            Text(status.name)
                                                .font(.subheadline)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 5)
                                                .background(isSelected ? Color.accentColor : Color(nsColor: .controlColor))
                                                .foregroundColor(isSelected ? .white : .primary)
                                                .cornerRadius(6)
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Body / Notes
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes")
                            .font(.headline)
                        TextEditor(text: $bodyNotes, selection: $bodyNotesSelection)
                            .frame(minHeight: 100)
                            .border(Color.secondary.opacity(0.2))
                            .focused($notesFocused)
                            .onChange(of: bodyNotes) { _, _ in rebuildBody() }
                            .autocorrectionDisabled(false)
                            .background(
                                MarkdownFormattingShortcuts(text: $bodyNotes, selection: $bodyNotesSelection, isActive: notesFocused)
                            )
                    }

                    // Images
                    TaskImagesSection(
                        bodyText: $bodyNotes,
                        planFolder: planFolder,
                        planName: editedTask.plan,
                        onChanged: rebuildBody,
                        onError: { message in
                            errorMessage = message
                            showError = true
                        }
                    )

                    // Tags
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.headline)

                        TagInputView(tags: $editedTask.tags)
                    }
                    
                    // Due Date
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Due Date", isOn: $hasDueDate)
                            .font(.headline)
                            .onChange(of: hasDueDate) { _, newValue in
                                if newValue && editedTask.dueDate == nil {
                                    editedTask.dueDate = Date()
                                } else if !newValue {
                                    editedTask.dueDate = nil
                                }
                            }
                        
                        if hasDueDate {
                            HStack {
                                DatePicker("Date", selection: Binding($editedTask.dueDate, default: Date()), displayedComponents: .date)
                                Spacer()
                            }
                        }
                    }
                    
                    // Sub-tasks
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sub-tasks")
                                .font(.headline)
                            Spacer()
                            if !subtasks.isEmpty {
                                let done = subtasks.filter(\.isCompleted).count
                                Text("\(done)/\(subtasks.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !subtasks.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(subtasks.indices, id: \.self) { i in
                                    HStack(spacing: 8) {
                                        Image(systemName: subtasks[i].isCompleted ? "checkmark.square.fill" : "square")
                                            .foregroundColor(subtasks[i].isCompleted ? .accentColor : .secondary)
                                            .font(.body)
                                            .onTapGesture {
                                                subtasks[i].isCompleted.toggle()
                                                rebuildBody()
                                            }

                                        TextField("Sub-task", text: $subtasks[i].title)
                                            .textFieldStyle(.plain)
                                            .strikethrough(subtasks[i].isCompleted, color: .secondary)
                                            .foregroundColor(subtasks[i].isCompleted ? .secondary : .primary)
                                            .onChange(of: subtasks[i].title) { _, _ in rebuildBody() }

                                        Button {
                                            subtasks.remove(at: i)
                                            rebuildBody()
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                        }

                        // Add sub-task row
                        HStack(spacing: 6) {
                            Image(systemName: "square")
                                .foregroundColor(.secondary)
                                .font(.body)
                            TextField("Add sub-task…", text: $newSubtaskTitle)
                                .textFieldStyle(.plain)
                                .focused($subtaskFieldFocused)
                                .onSubmit { commitNewSubtask() }
                            if !newSubtaskTitle.isEmpty {
                                Button("Add") { commitNewSubtask() }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.accentColor)
                                    .font(.caption)
                            }
                        }
                        // Isolates this field's Return-key submission so it doesn't also
                        // trigger the task detail's save-and-close `.onSubmit`.
                        .submitScope()
                        .submitScope(true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                    }

                    // Plan
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plan")
                            .font(.headline)
                        Picker("Plan", selection: $editedTask.plan) {
                            ForEach(taskStore.plans.sorted(by: { $0.order < $1.order })) { plan in
                                Text(plan.name).tag(plan.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: editedTask.plan) { oldValue, newValue in
                            // Check if the new plan has the task's current status
                            if let newPlan = taskStore.plans.first(where: { $0.name == newValue }) {
                                let hasMatchingStatus = newPlan.statuses.contains { $0.name == editedTask.status }
                                
                                if !hasMatchingStatus {
                                    // Map to the first status in the new plan if no match
                                    if let firstStatus = newPlan.statuses.sorted(by: { $0.order < $1.order }).first {
                                        editedTask.status = firstStatus.name
                                    }
                                }
                            }
                        }
                    }
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created: \(task.created, style: .date) at \(task.created, style: .time)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Updated: \(task.updated, style: .date) at \(task.updated, style: .time)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Delete Task", role: .destructive) {
                    do {
                        try taskStore.deleteTaskWithUndo(task)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to delete: \(error.localizedDescription)"
                        showError = true
                    }
                }
                .foregroundStyle(.red)
                
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                DialogFooterButtons(
                    confirmTitle: "Save",
                    confirmDisabled: editedTask.title.isEmpty,
                    confirmShortcut: KeyboardShortcut("s", modifiers: [.command]),
                    onCancel: { dismiss() },
                    onConfirm: { saveAndClose() }
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 600, height: 700)
        .onSubmit {
            if !editedTask.title.isEmpty {
                saveAndClose()
            }
        }
    }
    
    private func commitNewSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        subtasks.append(SubTask(title: trimmed, isCompleted: false))
        newSubtaskTitle = ""
        rebuildBody()
        subtaskFieldFocused = true
    }

    private func saveAndClose() {
        do {
            try taskStore.updateTask(editedTask)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
    }
}

struct EditStatusesView: View {
    let plan: Plan
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var editedStatuses: [Plan.TaskStatus]
    @State private var showError = false
    @State private var errorMessage = ""
    
    init(plan: Plan) {
        self.plan = plan
        _editedStatuses = State(initialValue: plan.statuses.sorted(by: { $0.order < $1.order }))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Statuses")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(editedStatuses.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            // Move up / down
                            VStack(spacing: 2) {
                                Button {
                                    guard index > 0 else { return }
                                    editedStatuses.swapAt(index, index - 1)
                                    updateOrder()
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)

                                Button {
                                    guard index < editedStatuses.count - 1 else { return }
                                    editedStatuses.swapAt(index, index + 1)
                                    updateOrder()
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .disabled(index == editedStatuses.count - 1)
                            }
                            .foregroundColor(.secondary)
                            .frame(width: 20)

                            TextField("Status name", text: $editedStatuses[index].name)
                                .textFieldStyle(.roundedBorder)

                            Picker("Color", selection: $editedStatuses[index].color) {
                                Text("Gray").tag("gray")
                                Text("Blue").tag("blue")
                                Text("Green").tag("green")
                                Text("Red").tag("red")
                                Text("Orange").tag("orange")
                                Text("Purple").tag("purple")
                                Text("Yellow").tag("yellow")
                            }
                            .frame(width: 120)

                            Button {
                                editedStatuses.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(editedStatuses.count <= 1)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(index.isMultiple(of: 2) ? 0 : 0.5))
                        .cornerRadius(6)
                    }

                    Button(action: addStatus) {
                        Label("Add Status", systemImage: "plus.circle")
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
            }
            
            Divider()
            
            // Footer
            HStack {
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                DialogFooterButtons(
                    confirmTitle: "Save",
                    confirmShortcut: KeyboardShortcut("s", modifiers: [.command]),
                    onCancel: { dismiss() },
                    onConfirm: { saveStatuses() }
                )
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 600, height: 500)
    }
    
    private func addStatus() {
        let newOrder = (editedStatuses.map { $0.order }.max() ?? -1) + 1
        let newStatus = Plan.TaskStatus(
            name: "New Status",
            color: "blue",
            order: newOrder
        )
        editedStatuses.append(newStatus)
    }
    
    private func updateOrder() {
        for (index, _) in editedStatuses.enumerated() {
            editedStatuses[index].order = index
        }
    }
    
    private func saveStatuses() {
        var updatedPlan = plan
        updatedPlan.statuses = editedStatuses
        
        do {
            try taskStore.updatePlan(updatedPlan)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
    }
}

struct EditPlanView: View {
    let plan: Plan
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var name: String
    @State private var description: String
    @State private var color: String
    @State private var showError = false
    @State private var errorMessage = ""
    
    init(plan: Plan) {
        self.plan = plan
        _name = State(initialValue: plan.name)
        _description = State(initialValue: plan.description)
        _color = State(initialValue: plan.color)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Plan")
                .font(.title)
            
            Form {
                TextField("Plan Name", text: $name)
                TextField("Description", text: $description)
                Picker("Color", selection: $color) {
                    Text("Blue").tag("blue")
                    Text("Green").tag("green")
                    Text("Red").tag("red")
                    Text("Orange").tag("orange")
                    Text("Purple").tag("purple")
                }
            }
            .padding()
            
            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            DialogFooterButtons(
                confirmTitle: "Save",
                confirmDisabled: name.isEmpty,
                onCancel: { dismiss() },
                onConfirm: { savePlan() }
            )
        }
        .padding()
        .frame(width: 400)
    }
    
    private func savePlan() {
        guard !name.isEmpty else { return }
        
        // Check if name already exists (and it's not the current plan)
        if name != plan.name && taskStore.plans.contains(where: { $0.name == name && $0.id != plan.id }) {
            errorMessage = "A plan with this name already exists"
            showError = true
            return
        }
        
        var updatedPlan = plan
        let nameChanged = updatedPlan.name != name
        updatedPlan.name = name
        updatedPlan.description = description
        updatedPlan.color = color
        
        do {
            if nameChanged {
                // Single operation: rename folder + write all updated fields at once.
                try taskStore.renamePlan(plan, to: updatedPlan)
            } else {
                try taskStore.updatePlan(updatedPlan)
            }
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - Tag Input with Autocomplete

/// A tag entry field that suggests existing tags from the global registry
/// (`TaskStore.settings.availableTags`) as the user types, while still allowing
/// free-form entry of brand-new tags. Newly typed tags are registered globally
/// once the owning task is saved (see `TaskStore.registerTags`).
struct TagInputView: View {
    @Binding var tags: [String]
    @EnvironmentObject var taskStore: TaskStore
    @State private var input = ""

    /// All globally known tags not yet applied to this task, sorted alphabetically. Shown as
    /// clickable chips so a tag can be added without typing it first.
    private var availableTagsNotOnTask: [String] {
        taskStore.settings.availableTags
            .filter { available in !tags.contains { $0.lowercased() == available.lowercased() } }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayoutHStack {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                            Button(action: { tags.removeAll { $0 == tag } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                    }
                }
            }

            HStack {
                TextField("Add tag", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addTag(input) }
                Button("Add") { addTag(input) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // Isolates this field's Return-key submission so it doesn't also
            // trigger an ancestor view's `.onSubmit` (e.g. the task detail's save-and-close).
            .submitScope()

            if !availableTagsNotOnTask.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Existing tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayoutHStack {
                        ForEach(availableTagsNotOnTask, id: \.self) { tag in
                            Button(action: { addTag(tag) }) {
                                Text(tag)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func addTag(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(where: { $0.lowercased() == trimmed.lowercased() }) else {
            input = ""
            return
        }
        tags.append(trimmed)
        input = ""
    }
}

/// Minimal wrapping horizontal layout for tag chips.
struct FlowLayoutHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TaskStore())
}
