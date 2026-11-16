import SwiftUI
import TaskToolCore

struct PhoneContentView: View {
    @EnvironmentObject private var store: MobileTaskStore
    @State private var showingSettings = false
    @State private var newTaskPlan: MobilePlan?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if store.isConfigured {
                    List {
                        if store.plans.isEmpty {
                            ContentUnavailableView(
                                "No Plans", systemImage: "list.bullet.rectangle",
                                description: Text("Sync a repository containing TaskTool plans and tasks. Create plans on your Mac.")
                            )
                        }
                        ForEach(store.plans) { plan in
                            NavigationLink {
                                PhonePlanView(planID: plan.id)
                            } label: {
                                HStack {
                                    Text(plan.name)
                                    Spacer()
                                    Text("\(store.tasks.filter { $0.plan == plan.name }.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    PhoneSyncSettings()
                }
            }
            .navigationTitle("TaskTool")
            .toolbar {
                if store.isConfigured {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Task", systemImage: "plus") {
                            newTaskPlan = store.plans.first { !$0.statuses.isEmpty }
                        }
                        .disabled(!store.canEdit || store.plans.allSatisfy { $0.statuses.isEmpty })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.isConfigured {
                    HStack {
                        if store.isBusy { ProgressView() }
                        Text(store.message)
                            .font(.caption)
                            .lineLimit(4)
                        Spacer()
                        Button("Sync Now") {
                            _Concurrency.Task { await store.sync() }
                        }
                        .disabled(!store.canEdit)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    PhoneSyncSettings()
                        .navigationTitle("Git Sync")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
            .sheet(item: $newTaskPlan) { plan in
                PhoneNewTaskView(plan: plan)
            }
        }
        .task {
            await store.restoreIfNeeded()
            store.setAutoSyncActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            store.setAutoSyncActive(phase == .active)
        }
    }
}

private struct PhonePlanView: View {
    @EnvironmentObject private var store: MobileTaskStore
    let planID: UUID
    @State private var showingNewTask = false

    var body: some View {
        Group {
            if let plan = store.plans.first(where: { $0.id == planID }) {
                List {
                    ForEach(plan.statuses, id: \.self) { status in
                        Section(status) {
                            let tasks = store.tasks.filter { $0.plan == plan.name && $0.status == status }
                            if tasks.isEmpty {
                                Text("No tasks").foregroundStyle(.secondary)
                            }
                            ForEach(tasks) { task in
                                NavigationLink {
                                    PhoneTaskEditor(task: task, plan: plan)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.title)
                                        if task.isBundled {
                                            Label("Bundled task", systemImage: "square.stack")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let date = task.dueDate {
                                            Text(date, style: .date)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(plan.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Task", systemImage: "plus") { showingNewTask = true }
                            .disabled(!store.canEdit || plan.statuses.isEmpty)
                    }
                }
                .sheet(isPresented: $showingNewTask) {
                    PhoneNewTaskView(plan: plan)
                }
            } else {
                ContentUnavailableView("Plan Unavailable", systemImage: "folder")
            }
        }
    }
}

private struct PhoneTaskEditor: View {
    @EnvironmentObject private var store: MobileTaskStore
    @Environment(\.dismiss) private var dismiss
    let task: MobileTask
    let originalPlanID: UUID
    @State private var planID: UUID
    @State private var status: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var draft: MobileTaskBody
    @State private var showingError = false
    @State private var editorID = UUID()

    init(task: MobileTask, plan: MobilePlan) {
        self.task = task
        originalPlanID = plan.id
        _planID = State(initialValue: plan.id)
        _status = State(initialValue: task.status)
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
        _draft = State(initialValue: MobileTaskBody(task.body))
    }

    private var selectedPlan: MobilePlan? {
        store.plans.first { $0.id == planID }
    }

    private var selectedDueDate: Date? {
        hasDueDate ? dueDate : nil
    }

    var body: some View {
        Form {
            Section {
                Text(task.title).font(.headline)
                Picker("Plan", selection: $planID) {
                    ForEach(store.plans) { plan in
                        Text(plan.name).tag(plan.id)
                    }
                }
                .disabled(task.isBundled)
                Picker("Status", selection: $status) {
                    ForEach(selectedPlan?.statuses ?? [], id: \.self) { Text($0).tag($0) }
                }
                .disabled(task.isBundled)
                if task.isBundled {
                    Text("Move bundled tasks and change their statuses on your Mac. Notes and sub-tasks can be edited here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Due Date") {
                Toggle("Set due date", isOn: $hasDueDate)
                    .tint(.blue)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                }
            }
            PhoneTaskBodyEditor(draft: $draft, notesMinimumHeight: 240, notesAccessibilityLabel: "Task notes")
        }
        .disabled(!store.canEdit)
        .onAppear { store.setAutoSyncEditor(editorID, isOpen: true) }
        .onDisappear { store.setAutoSyncEditor(editorID, isOpen: false) }
        .navigationTitle("Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(
            planID != originalPlanID || status != task.status ||
                selectedDueDate != task.dueDate || draft.markdown != task.body
        )
        .onChange(of: planID) { _, _ in
            if selectedPlan?.statuses.contains(status) != true {
                status = selectedPlan?.statuses.first ?? ""
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    _Concurrency.Task {
                        if await store.save(
                            task, planID: planID, status: status, dueDate: selectedDueDate, body: draft.markdown
                        ) {
                            dismiss()
                        } else {
                            showingError = true
                        }
                    }
                }
                .disabled(!store.canEdit || !draft.isValid || selectedPlan?.statuses.contains(status) != true)
            }
        }
        .alert("Could Not Save", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(store.message)\nYour draft is still open. If the task changed during sync, copy your notes before reopening it.")
        }
    }
}
