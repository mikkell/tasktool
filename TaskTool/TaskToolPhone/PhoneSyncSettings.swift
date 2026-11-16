import SwiftUI
import TaskToolCore

struct PhoneSyncSettings: View {
    @EnvironmentObject private var store: MobileTaskStore
    @State private var remoteURL = ""
    @State private var token = ""

    var body: some View {
        Form {
            Section("Private GitHub Repository") {
                if let remote = store.remoteURL {
                    Text(remote).textSelection(.enabled)
                } else {
                    TextField("https://github.com/owner/task-data.git", text: $remoteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("repositoryURL")
                }
                Text("Use a dedicated task-data repository on its main branch, not the TaskTool source repository. Files stay in this app's local checkout. Sync is manual.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Authentication") {
                SecureField("Fine-grained personal access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("githubToken")
                Text("Grant Contents read/write access to this repository only. The token stays in this device's Keychain; it is not synced from your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.isConfigured ? "Update Token" : "Connect Repository") {
                    let enteredToken = token
                    token = ""
                    _Concurrency.Task {
                        if store.isConfigured {
                            await store.updateToken(enteredToken)
                        } else {
                            await store.connect(remoteURL: remoteURL, token: enteredToken)
                        }
                    }
                }
                .disabled(store.isBusy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (!store.isConfigured && remoteURL.isEmpty))
            }
            Section("Status") {
                if store.isBusy { ProgressView() }
                Text(store.message).textSelection(.enabled)
                ForEach(Array(store.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Text(conflict).font(.caption).textSelection(.enabled)
                }
                if !store.conflicts.isEmpty {
                    Text("Both versions are retained in this device's Git history. Conflict editing is not yet available on iPhone. Keep this app installed and its checkout intact until the conflict is resolved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.needsRecovery {
                    Button("Recover Interrupted Sync") {
                        _Concurrency.Task { await store.recover() }
                    }
                    .disabled(store.isBusy)
                } else if store.storageUnavailable {
                    Button("Reopen Local Repository") {
                        _Concurrency.Task { await store.reopen() }
                    }
                    .disabled(store.isBusy)
                }
                if store.isConfigured {
                    Button("Sync Now") {
                        _Concurrency.Task { await store.sync() }
                    }
                    .disabled(!store.canEdit)
                }
            }
        }
    }
}
