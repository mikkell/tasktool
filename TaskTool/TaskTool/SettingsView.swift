//
//  SettingsView.swift
//  TaskTool
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            CLISettingsTab()
                .tabItem { Label("CLI", systemImage: "terminal") }
        }
        .frame(width: 480)
        .fixedSize()
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var taskStore: TaskStore
    @State private var showingFolderPicker = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Storage Folder") {
                    HStack {
                        Text(taskStore.storageURL?.abbreviatingWithTildeInPath ?? "Not set")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { showFolderPicker() }
                    }
                }

                if let url = taskStore.storageURL {
                    LabeledContent("") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minHeight: 120)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                taskStore.setStorageLocation(url)
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
}

// MARK: - CLI

struct CLISettingsTab: View {
    @EnvironmentObject var taskStore: TaskStore
    @State private var copied = false

    private var storageURL: URL? { taskStore.storageURL }

    /// Derives the bin/ path from the storage folder (../bin relative to storage root).
    private var binPath: String? {
        storageURL?
            .deletingLastPathComponent()
            .appendingPathComponent("bin")
            .path
    }

    private var shellSnippet: String {
        var lines: [String] = []
        if let bin = binPath {
            lines.append("export PATH=\"\(bin):$PATH\"")
        }
        if let storage = storageURL?.path {
            lines.append("export TASKTOOL_DIR=\"\(storage)\"")
        }
        return lines.isEmpty ? "# Set a storage folder in General first." : lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add the following to your **~/.zshrc** (or ~/.bashrc) to use the `tt` command from any terminal:")
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topTrailing) {
                ScrollView {
                    Text(shellSnippet)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(height: 80)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shellSnippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .padding(6)
            }

            Divider()

            Text("Example usage:")
                .font(.headline)

            Text("""
tt new "Fix login bug" --plan TaskTool --tags "bug,auth"
tt new "Write release notes" --due 2026-06-01
tt list
tt list --plan TaskTool --status "In Progress"
tt plans
""")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if storageURL == nil {
                Label("Set a storage folder in General to generate your shell snippet.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding()
        .frame(minHeight: 260)
    }
}

// MARK: - Helpers

private extension URL {
    var abbreviatingWithTildeInPath: String {
        (self.path as NSString).abbreviatingWithTildeInPath
    }
}
