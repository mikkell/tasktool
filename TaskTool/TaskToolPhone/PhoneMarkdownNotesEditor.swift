import SwiftUI
import TaskToolCore

struct PhoneMarkdownNotesEditor: View {
    @Binding var text: String
    let minimumHeight: CGFloat
    let accessibilityLabel: String
    @AppStorage("descriptionShowsPreview") private var showsPreview = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        Picker("Notes view", selection: $showsPreview) {
            Text("Markdown").tag(false)
            Text("Preview").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("notesViewMode")
        .onChange(of: showsPreview) { _, preview in
            if preview { notesFocused = false }
        }

        if showsPreview {
            MarkdownPreview(text: text)
                .frame(minHeight: minimumHeight, alignment: .topLeading)
                .accessibilityIdentifier("notesPreview")
        } else {
            TextEditor(text: $text)
                .frame(minHeight: minimumHeight)
                .focused($notesFocused)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}
