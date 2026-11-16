import SwiftUI
import TaskToolCore

struct PhoneNewTaskView: View {
    @EnvironmentObject private var store: MobileTaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var planID: UUID
    @State private var status: String
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var draft = MobileTaskBody()
    @State private var showingError = false
    @State private var editorID = UUID()

    init(plan: MobilePlan) {
        _planID = State(initialValue: plan.id)
        _status = State(initialValue: plan.statuses.first ?? "")
    }

    private var selectedPlan: MobilePlan? {
        store.plans.first { $0.id == planID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("newTaskTitle")
                    Picker("Plan", selection: $planID) {
                        ForEach(store.plans) { plan in
                            Text(plan.name).tag(plan.id)
                        }
                    }
                    Picker("Status", selection: $status) {
                        ForEach(selectedPlan?.statuses ?? [], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                Section("Due Date") {
                    Toggle("Set due date", isOn: $hasDueDate)
                        .tint(.blue)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }
                PhoneTaskBodyEditor(draft: $draft, notesMinimumHeight: 160, notesAccessibilityLabel: "New task notes")
            }
            .disabled(!store.canEdit)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _Concurrency.Task {
                            if await store.createTask(
                                title: title, planID: planID, status: status,
                                dueDate: hasDueDate ? dueDate : nil, body: draft.markdown
                            ) {
                                dismiss()
                            } else {
                                showingError = true
                            }
                        }
                    }
                    .disabled(!store.canEdit || !draft.isValid || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              selectedPlan?.statuses.contains(status) != true)
                    .accessibilityIdentifier("createTask")
                }
            }
            .onChange(of: planID) { _, _ in
                status = selectedPlan?.statuses.first ?? ""
            }
            .alert("Could Not Create Task", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(store.message)\nYour draft is still open.")
            }
        }
        .interactiveDismissDisabled(store.isBusy || !title.isEmpty || !draft.markdown.isEmpty)
        .onAppear { store.setAutoSyncEditor(editorID, isOpen: true) }
        .onDisappear { store.setAutoSyncEditor(editorID, isOpen: false) }
    }
}
