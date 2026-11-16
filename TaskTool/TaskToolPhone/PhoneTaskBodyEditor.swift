import SwiftUI
import TaskToolCore

struct PhoneTaskBodyEditor: View {
    @Binding var draft: MobileTaskBody
    let notesMinimumHeight: CGFloat
    let notesAccessibilityLabel: String
    @FocusState private var newSubtaskFocused: Bool

    var body: some View {
        Section {
            ForEach($draft.subtasks) { $subtask in
                let id = subtask.id
                HStack {
                    Button {
                        subtask.isCompleted.toggle()
                    } label: {
                        Image(systemName: subtask.isCompleted ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(subtask.isCompleted ? Color.accentColor : .secondary)
                    .accessibilityLabel("Mark \(subtask.title) \(subtask.isCompleted ? "incomplete" : "complete")")

                    TextField("Sub-task", text: $subtask.title)
                        .strikethrough(subtask.isCompleted)
                        .accessibilityLabel("Sub-task title")

                    Button("Delete sub-task", systemImage: "minus.circle", role: .destructive) {
                        draft.subtasks.removeAll { $0.id == id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(subtask.title)")
                }
            }
            HStack {
                TextField("New sub-task", text: $draft.newSubtaskTitle)
                    .focused($newSubtaskFocused)
                    .submitLabel(.done)
                    .onSubmit { addSubtask() }
                    .accessibilityIdentifier("newSubtaskTitle")
                Button("Add", systemImage: "plus") { addSubtask() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!draft.canAddSubtask)
                    .accessibilityLabel("Add sub-task")
            }
            if !draft.isValid {
                Text("Sub-tasks need a title on a single line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Sub-tasks")
                Spacer()
                if !draft.subtasks.isEmpty {
                    Text("\(draft.subtasks.filter(\.isCompleted).count)/\(draft.subtasks.count)")
                }
            }
        }
        Section("Notes (Markdown)") {
            PhoneMarkdownNotesEditor(
                text: $draft.notes, minimumHeight: notesMinimumHeight,
                accessibilityLabel: notesAccessibilityLabel
            )
        }
    }

    private func addSubtask() {
        draft.addSubtask()
        newSubtaskFocused = true
    }
}
