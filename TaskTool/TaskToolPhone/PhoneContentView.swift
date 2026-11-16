import SwiftUI
import TaskToolCore

struct PhoneContentView: View {
    @EnvironmentObject private var store: MobileTaskStore
    @State private var showingSettings = false

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
        }
        .task { await store.restoreIfNeeded() }
    }
}

private struct PhonePlanView: View {
    @EnvironmentObject private var store: MobileTaskStore
    let planID: UUID

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
                                    PhoneTaskEditor(task: task, statuses: plan.statuses)
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
    let statuses: [String]
    @State private var status: String
    @State private var bodyText: String
    @State private var showingError = false

    init(task: MobileTask, statuses: [String]) {
        self.task = task
        self.statuses = statuses
        _status = State(initialValue: task.status)
        _bodyText = State(initialValue: task.body)
    }

    var body: some View {
        Form {
            Section {
                Text(task.title).font(.headline)
                Picker("Status", selection: $status) {
                    ForEach(statuses, id: \.self) { Text($0).tag($0) }
                }
                .disabled(task.isBundled)
                if task.isBundled {
                    Text("Change bundle statuses on your Mac. Notes can be edited here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notes (Markdown)") {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 240)
                    .accessibilityLabel("Task notes")
            }
            Section {
                Text("Save writes to this iPhone immediately, even offline. Sync Now shares your changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!store.canEdit)
        .navigationTitle("Edit Task")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(status != task.status || bodyText != task.body)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    _Concurrency.Task {
                        if await store.save(task, status: status, body: bodyText) {
                            dismiss()
                        } else {
                            showingError = true
                        }
                    }
                }
                .disabled(!store.canEdit)
            }
        }
        .alert("Could Not Save", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(store.message)\nYour draft is still open. If the task changed during sync, copy your notes before reopening it.")
        }
    }
}
