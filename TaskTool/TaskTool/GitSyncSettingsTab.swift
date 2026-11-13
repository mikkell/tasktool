import SwiftUI

struct GitSyncSettingsTab: View {
    @EnvironmentObject var taskStore: TaskStore
    @State private var remoteURL = ""
    @State private var token = ""
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            Section("Repository") {
                if let remote = taskStore.gitRemoteURL {
                    Text(remote)
                        .textSelection(.enabled)
                    Text("Tasks are stored in an app-managed checkout, separate from your previous folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let directory = taskStore.storageURL {
                        Button("Show Checkout in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                        }
                        .disabled(taskStore.isSyncing)
                    }
                } else {
                    TextField("https://github.com/owner/task-data.git", text: $remoteURL)
                    Text("Connect to a dedicated private task-data repository on its main branch. Your current folder will not be imported or modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            await taskStore.configureGitSync(remoteURL: remoteURL, token: token)
                            token = ""
                        }
                    }
                    .disabled(remoteURL.isEmpty || token.isEmpty || taskStore.isSyncing)
                }
            }
            Section("Status") {
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
    }
}
