import SwiftUI

struct GitSyncSettingsTab: View {
    @EnvironmentObject var taskStore: TaskStore
    @State private var remoteURL = ""
    @State private var token = ""
    @State private var confirmingDisconnect = false
    @State private var checkoutParent: URL?
    @State private var confirmingRelocation = false

    var body: some View {
        Form {
            Section("Repository") {
                if let remote = taskStore.gitRemoteURL {
                    Text(remote)
                        .textSelection(.enabled)
                    Text(taskStore.hasExternalGitCheckout
                         ? "Tasks are stored in your selected checkout folder, accessible to editors and CLI agents."
                         : "Tasks are stored in an app-managed checkout. Relocate it to make the files accessible to editors and CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let directory = taskStore.storageURL {
                        Button("Show Checkout in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                        }
                        .disabled(taskStore.isSyncing)
                        Text(directory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Relocate Checkout…") { confirmingRelocation = true }
                        .disabled(!taskStore.canRelocateGitCheckout)
                } else {
                    TextField("Repository URL", text: $remoteURL, prompt: Text("Repository URL"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Text("Enter the HTTPS URL of a dedicated private GitHub task-data repository on its main branch. Your current folder will not be imported or modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose Checkout Parent Folder…") {
                        checkoutParent = chooseCheckoutParent()
                    }
                    if let checkoutParent {
                        Text("A new repository-named folder will be created inside \(checkoutParent.path).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Use App-Managed Location") { self.checkoutParent = nil }
                    } else {
                        Text("Default: app-managed storage. Choose a local folder for direct editor and CLI access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Authentication") {
                SecureField("Fine-grained personal access token", text: $token)
                Text("Grant Contents read/write access to this repository only. The token is stored in Keychain, never in task files or Git configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if taskStore.gitRemoteURL != nil {
                    Button("Update Token") {
                        _Concurrency.Task {
                            await taskStore.updateGitToken(token)
                            token = ""
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || taskStore.isSyncing)
                } else {
                    Button("Connect Repository") {
                        _Concurrency.Task {
                            await taskStore.configureGitSync(remoteURL: remoteURL, token: token, checkoutParent: checkoutParent)
                            token = ""
                        }
                    }
                    .disabled(remoteURL.isEmpty || token.isEmpty || taskStore.isSyncing)
                }
            }
            Section("Status") {
                Text("While active: sync 5 seconds after edits, every 5 minutes, and on returning to the app. Offline changes retry later. Conflicts pause automatic sync; resolve them before using Sync Now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if taskStore.isSyncing { ProgressView().controlSize(.small) }
                    Text(taskStore.gitSyncMessage)
                }
                if !taskStore.gitSyncConflicts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(taskStore.gitSyncConflicts.enumerated()), id: \.offset) { _, conflict in
                                Text(conflict).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                    Text("Resolve the conflicting versions in the checkout's Git history, commit the resolution, then sync again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if taskStore.gitRemoteURL != nil {
                    HStack {
                        Button("Sync Now") {
                            _Concurrency.Task { await taskStore.syncGit() }
                        }
                        .disabled(!taskStore.canEditStorage)
                        if taskStore.needsGitRecovery {
                            Button("Recover") {
                                _Concurrency.Task { await taskStore.recoverGitSync() }
                            }
                            .disabled(taskStore.isSyncing)
                        } else if taskStore.gitStorageUnavailable {
                            Button("Reopen Repository") {
                                _Concurrency.Task { await taskStore.restoreGitSync() }
                            }
                            .disabled(taskStore.isSyncing)
                        }
                        Button("Disconnect", role: .destructive) {
                            confirmingDisconnect = true
                        }
                        .disabled(taskStore.isSyncing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minHeight: 360)
        .alert("Disconnect Git Sync?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                _Concurrency.Task { await taskStore.disconnectGitSync() }
            }
        } message: {
            Text("Return to your previous storage folder and remove the saved token. The checkout and its local commits are retained. Unsynced tasks are not copied back to the previous folder.")
        }
        .alert("Relocate Git Checkout?", isPresented: $confirmingRelocation) {
            Button("Cancel", role: .cancel) {}
            Button("Choose Parent Folder…") {
                if let parent = chooseCheckoutParent() {
                    _Concurrency.Task { await taskStore.relocateGitCheckout(to: parent) }
                }
            }
        } message: {
            Text("Copy all tasks, unsynced files and Git history to a new repository-named folder, then switch to it. The old checkout is retained as a backup. Pause other editors and Git tools until this finishes. Existing destination folders will not be overwritten. Use a local folder, not OneDrive or iCloud Drive.")
        }
    }

    private func chooseCheckoutParent() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a local parent folder. TaskTool creates a new repository-named folder inside it; existing folders are never overwritten. Avoid OneDrive and iCloud Drive."
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
