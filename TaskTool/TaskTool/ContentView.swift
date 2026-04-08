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
                        ForEach(taskStore.plans.sorted(by: { $0.order < $1.order }), id: \.id) { plan in
                            NavigationLink(value: plan) {
                                HStack {
                                    Circle()
                                        .fill(Color.from(string: plan.color))
                                        .frame(width: 12, height: 12)
                                    Text(plan.name)
                                }
                            }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
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
                            print("📝 Moving plan from \(from) to \(to)")
                            var sortedPlans = taskStore.plans.sorted(by: { $0.order < $1.order })
                            print("📋 Sorted plans before move: \(sortedPlans.map { "\($0.name): \($0.order)" })")
                            
                            // Move the plans
                            sortedPlans.move(fromOffsets: from, toOffset: to)
                            
                            // Now reassign order based on new positions
                            for (index, _) in sortedPlans.enumerated() {
                                sortedPlans[index].order = index
                            }
                            
                            print("📋 Sorted plans after move: \(sortedPlans.map { "\($0.name): \($0.order)" })")
                            
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
                            try taskStore.deletePlan(plan)
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
                                print("🔄 Task status changed from '\(originalTask.status)' to '\(firstStatus.name)'")
                            }
                        }
                        
                        do {
                            try taskStore.updateTask(task)
                            print("📦 Task '\(task.title)' moved to plan '\(targetPlan.name)'")
                        } catch {
                            // Revert in-memory state so the UI stays consistent with disk
                            taskStore.tasks[taskIndex] = originalTask
                            print("❌ Failed to move task '\(task.title)': \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        return true
    }
}

struct PlanDetailView: View {
    let planId: UUID
    @EnvironmentObject var taskStore: TaskStore
    @State private var showingNewTask = false
    @State private var showingEditStatuses = false
    @State private var showingArchiveConfirmation = false
    
    var plan: Plan? {
        taskStore.plans.first(where: { $0.id == planId })
    }
    
    var planTasks: [Task] {
        guard let plan = plan else { return [] }
        return taskStore.tasks.filter { $0.plan == plan.name }
    }
    
    func tasks(for status: Plan.TaskStatus) -> [Task] {
        planTasks.filter { $0.status == status.name }
    }
    
    var doneStatusName: String? {
        plan?.statuses.first(where: { $0.name.lowercased().contains("done") })?.name
    }
    
    var doneTasks: [Task] {
        guard let doneStatus = doneStatusName else { return [] }
        return planTasks.filter { $0.status == doneStatus }
    }
    
    var body: some View {
        if let plan = plan {
            HStack(spacing: 20) {
                ForEach(plan.statuses.sorted(by: { $0.order < $1.order })) { status in
                    KanbanColumn(
                        title: status.name,
                        tasks: tasks(for: status),
                        color: Color.from(string: status.color),
                        statusName: status.name,
                        plan: plan
                    )
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: taskStore.tasks.map { "\($0.id)-\($0.status)" }.joined())
            .padding()
            .navigationTitle(plan.name)
            .toolbar {
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
            print("❌ Failed to archive tasks: \(error.localizedDescription)")
        }
    }
}

struct KanbanColumn: View {
    let title: String
    let tasks: [Task]
    let color: Color
    let statusName: String
    let plan: Plan
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
            }
            .padding()
            .background(color)
            
            Divider()
            
            // Task list
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(task: task)
                            .transition(.asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .scale.combined(with: .opacity)
                            ))
                            .onTapGesture {
                                selectedTask = task
                            }
                            .onDrag {
                                NSItemProvider(object: task.id.uuidString as NSString)
                            }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: tasks.map { $0.id })
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(isTargeted ? color.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
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
                            print("❌ Failed to update status for '\(task.title)': \(error.localizedDescription)")
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
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Image(systemName: "calendar")
                        .font(.caption)
                    Text(dueDate, style: .date)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
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
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
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
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Task")
                .font(.title)
            
            Form {
                LabeledContent("Task Title") {
                    TextField("", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                
                LabeledContent("Description") {
                    TextEditor(text: $taskBody)
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                
                LabeledContent("Tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("", text: $tagInput)
                                .textFieldStyle(.roundedBorder)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                )
                            Button("Add") {
                                let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty && !tags.contains(trimmed) {
                                    tags.append(trimmed)
                                    tagInput = ""
                                }
                            }
                        }
                        
                        if !tags.isEmpty {
                            HStack {
                                ForEach(tags, id: \.self) { tag in
                                    HStack {
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
                    }
                }
                
                Toggle("Due Date", isOn: $hasDueDate)
                    .onChange(of: hasDueDate) { _, newValue in
                        if newValue && dueDate == nil {
                            dueDate = Date()
                        } else if !newValue {
                            dueDate = nil
                        }
                    }
                if hasDueDate {
                    DatePicker("Date", selection: Binding($dueDate, default: Date()), displayedComponents: .date)
                }
            }
            .padding()
            
            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    // Use the first status from the plan as the default
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
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
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
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Task")
                .font(.title)
            
            Form {
                LabeledContent("Task Title") {
                    TextField("", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                
                LabeledContent("Description") {
                    TextEditor(text: $taskBody)
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                
                LabeledContent("Tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("", text: $tagInput)
                                .textFieldStyle(.roundedBorder)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                                )
                            Button("Add") {
                                let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty && !tags.contains(trimmed) {
                                    tags.append(trimmed)
                                    tagInput = ""
                                }
                            }
                        }
                        
                        if !tags.isEmpty {
                            HStack {
                                ForEach(tags, id: \.self) { tag in
                                    HStack {
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
                    }
                }
                
                Toggle("Due Date", isOn: $hasDueDate)
                    .onChange(of: hasDueDate) { _, newValue in
                        if newValue && dueDate == nil {
                            dueDate = Date()
                        } else if !newValue {
                            dueDate = nil
                        }
                    }
                if hasDueDate {
                    DatePicker("Date", selection: Binding($dueDate, default: Date()), displayedComponents: .date)
                }
            }
            .padding()
            
            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
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
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
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

struct TaskDetailView: View {
    let task: Task
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskStore: TaskStore
    @State private var editedTask: Task
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var newTag = ""
    @State private var hasDueDate: Bool
    
    var plan: Plan? {
        taskStore.plans.first(where: { $0.name == editedTask.plan })
    }
    
    init(task: Task) {
        self.task = task
        _editedTask = State(initialValue: task)
        _hasDueDate = State(initialValue: task.dueDate != nil)
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
                    }
                    
                    // Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.headline)
                        if let plan = plan {
                            Picker("Status", selection: $editedTask.status) {
                                ForEach(plan.statuses.sorted(by: { $0.order < $1.order })) { status in
                                    Text(status.name).tag(status.name)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    
                    // Body
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)
                        TextEditor(text: $editedTask.body)
                            .frame(minHeight: 150)
                            .border(Color.secondary.opacity(0.2))
                    }
                    
                    // Tags
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.headline)
                        
                        if !editedTask.tags.isEmpty {
                            HStack {
                                ForEach(editedTask.tags, id: \.self) { tag in
                                    HStack {
                                        Text(tag)
                                        Button(action: { 
                                            editedTask.tags.removeAll { $0 == tag }
                                        }) {
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
                            TextField("Add tag", text: $newTag)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                let trimmed = newTag.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty && !editedTask.tags.contains(trimmed) {
                                    editedTask.tags.append(trimmed)
                                    newTag = ""
                                }
                            }
                        }
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
                            DatePicker("Date", selection: Binding($editedTask.dueDate, default: Date()), displayedComponents: .date)
                        }
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
                        try taskStore.deleteTask(task)
                        dismiss()
                    } catch {
                        errorMessage = "Failed to delete: \(error.localizedDescription)"
                        showError = true
                    }
                }
                
                Spacer()
                
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    saveAndClose()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(editedTask.title.isEmpty)
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
            List {
                ForEach(editedStatuses.indices, id: \.self) { index in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        
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
                        
                        Button(action: {
                            editedStatuses.remove(at: index)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(editedStatuses.count <= 1)
                    }
                }
                .onMove { from, to in
                    editedStatuses.move(fromOffsets: from, toOffset: to)
                    updateOrder()
                }
                
                Button(action: addStatus) {
                    Label("Add Status", systemImage: "plus.circle")
                }
            }
            .listStyle(.inset)
            
            Divider()
            
            // Footer
            HStack {
                if showError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                    
                    Spacer()
                }
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    saveStatuses()
                }
                .keyboardShortcut("s", modifiers: [.command])
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
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    savePlan()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
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
                try taskStore.renamePlan(plan, to: name)
                // After renaming, update the other properties
                if var renamedPlan = taskStore.plans.first(where: { $0.id == plan.id }) {
                    renamedPlan.description = description
                    renamedPlan.color = color
                    try taskStore.updatePlan(renamedPlan)
                }
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

#Preview {
    ContentView()
        .environmentObject(TaskStore())
}
