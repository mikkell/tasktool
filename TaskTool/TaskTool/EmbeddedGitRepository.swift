#if canImport(libgit2)
import Foundation
import libgit2

private final class GitCallbackContext {
    let remote: GitHubRemote?
    let token: String?
    var usedCredential = false
    var rejected = false

    init(remote: GitHubRemote?, token: String?) {
        self.remote = remote
        self.token = token
    }
}

/// Serializes Git operations. The caller must also suspend TaskStore writes and its
/// watcher while applying a sync.
actor EmbeddedGitRepository {
    private static let runtime = git_libgit2_init()
    private let pointer: OpaquePointer
    private let directory: URL
    private let github: GitHubRemote?
    private let localRemote: URL?
    private let credentials: GitHubTokenStore?
    private let manager = FileManager.default

    private struct Transaction: Codable {
        let oldHead: String
        let newHead: String
        let before: [String: GitSyncFile]
        let after: [String: GitSyncFile]
    }

    private init(pointer: OpaquePointer, directory: URL, github: GitHubRemote?, localRemote: URL?, credentials: GitHubTokenStore?) {
        self.pointer = pointer
        self.directory = directory
        self.github = github
        self.localRemote = localRemote
        self.credentials = credentials
    }

    deinit { git_repository_free(pointer) }

    static func open(at directory: URL, remote: GitHubRemote, credentials: GitHubTokenStore) throws -> EmbeddedGitRepository {
        guard runtime >= 0 else { throw GitSyncError.operation("initialize", runtime) }
        var repository: OpaquePointer?
        try check(git_repository_open(&repository, directory.path), "open repository")
        guard let repository else { throw GitSyncError.operation("open repository", -1) }
        guard git_repository_is_bare(repository) == 0,
              let workdir = git_repository_workdir(repository),
              URL(fileURLWithPath: String(cString: workdir)).resolvingSymlinksInPath().standardizedFileURL
                == directory.resolvingSymlinksInPath().standardizedFileURL else {
            git_repository_free(repository)
            throw GitSyncError.unsupportedFile(directory.path)
        }
        return EmbeddedGitRepository(pointer: repository, directory: directory, github: remote, localRemote: nil, credentials: credentials)
    }

    func hasPendingApplication() throws -> Bool {
        try manager.fileExists(atPath: journal.path) || reference("refs/tasktool/pending") != nil
    }

    func validateForUse() throws {
        try ready()
        let remote = try origin()
        git_remote_free(remote)
        let current = try workingFiles(tracked: files())
        _ = try GitSyncFiles.reconcile(base: current, local: current, remote: current)
    }

    static func clone(from remote: GitHubRemote, to directory: URL, credentials: GitHubTokenStore) throws -> EmbeddedGitRepository {
        try clone(source: remote.url.absoluteString, to: directory, github: remote, localRemote: nil, credentials: credentials)
    }

    // Local remotes are an explicit test seam, never accepted by GitHubRemote.
    static func cloneLocal(from remote: URL, to directory: URL) throws -> EmbeddedGitRepository {
        guard remote.isFileURL else { throw GitHubCredentialError.invalidRemote }
        return try clone(source: remote.path, to: directory, github: nil, localRemote: remote, credentials: nil)
    }

    static func initializeBare(at directory: URL) throws {
        guard runtime >= 0 else { throw GitSyncError.operation("initialize", runtime) }
        var repository: OpaquePointer?
        try check(git_repository_init(&repository, directory.path, 1), "initialize")
        defer { git_repository_free(repository) }
        try check(git_repository_set_head(repository, "refs/heads/main"), "set initial branch")
    }

    private static func clone(
        source: String, to directory: URL, github: GitHubRemote?, localRemote: URL?, credentials: GitHubTokenStore?
    ) throws -> EmbeddedGitRepository {
        guard runtime >= 0 else { throw GitSyncError.operation("initialize", runtime) }
        guard directory.isFileURL, !FileManager.default.fileExists(atPath: directory.path) else {
            throw GitSyncError.unsupportedFile(directory.path)
        }
        let context = GitCallbackContext(remote: github, token: try github.flatMap { try credentials?.token(for: $0) })
        var options = git_clone_options()
        try check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)), "clone options")
        options.fetch_opts.callbacks = callbacks(context)
        options.fetch_opts.follow_redirects = GIT_REMOTE_REDIRECT_NONE
        var repository: OpaquePointer?
        try withExtendedLifetime(context) {
            try check(git_clone(&repository, source, directory.path, &options), "clone")
        }
        guard let repository else { throw GitSyncError.operation("clone", -1) }
        if git_repository_head_unborn(repository) == 1 {
            try check(git_repository_set_head(repository, "refs/heads/main"), "set initial branch")
        }
        return EmbeddedGitRepository(pointer: repository, directory: directory, github: github, localRemote: localRemote, credentials: credentials)
    }

    func head() throws -> String? { try reference("refs/heads/main") }

    func files(at revision: String? = nil) throws -> [String: GitSyncFile] {
        guard let revision = try revision ?? head() else { return [:] }
        var id = try Self.oid(revision)
        var commit: OpaquePointer?
        try Self.check(git_commit_lookup(&commit, pointer, &id), "read commit")
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try Self.check(git_commit_tree(&tree, commit), "read tree")
        defer { git_tree_free(tree) }
        var result: [String: GitSyncFile] = [:]
        try read(tree: tree, prefix: "", into: &result)
        try GitSyncFiles.validatePaths(result)
        return result
    }

    func commitWorkingCopy(message: String) throws {
        try ready()
        let oldHead = try head()
        let original = try files()
        let current = try workingFiles(tracked: original)
        // Reject malformed or unsupported task data before adding it to sync history.
        _ = try GitSyncFiles.reconcile(base: current, local: current, remote: current)
        if current == original, oldHead != nil { return }
        let newHead = try createCommit(files: current, parents: oldHead.map { [$0] } ?? [], message: message)
        guard try workingFiles(tracked: original) == current else { throw GitSyncError.dirtyWorkingCopy }
        try updateHead(from: oldHead, to: newHead)
        try writeIndex(for: newHead)
    }

    func fetch() throws {
        try ready()
        let remote = try origin()
        defer { git_remote_free(remote) }
        let context = try callbackContext()
        var options = git_fetch_options()
        try Self.check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)), "fetch options")
        options.callbacks = Self.callbacks(context)
        options.follow_redirects = GIT_REMOTE_REDIRECT_NONE
        try withExtendedLifetime(context) {
            try Self.check(git_remote_fetch(remote, nil, &options, nil), "fetch")
        }
    }

    func push() throws {
        try ready()
        let remote = try origin()
        defer { git_remote_free(remote) }
        let context = try callbackContext()
        var options = git_push_options()
        try Self.check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)), "push options")
        options.callbacks = Self.callbacks(context)
        let spec = strdup("refs/heads/main:refs/heads/main")
        defer { free(spec) }
        var strings = [spec]
        let code = withExtendedLifetime(context) {
            strings.withUnsafeMutableBufferPointer { buffer in
                var specs = git_strarray(strings: buffer.baseAddress, count: 1)
                return git_remote_push(remote, &specs, &options)
            }
        }
        if context.rejected || code == GIT_ENONFASTFORWARD.rawValue { throw GitSyncError.pushRejected }
        try Self.check(code, "push")
    }

    func synchronize() throws {
        try ready()
        let original = try files()
        try requireClean(original)
        try fetch()
        guard let localHead = try head() else { throw GitSyncError.wrongBranch }
        guard let remoteHead = try reference("refs/remotes/origin/main") else {
            _ = try GitSyncFiles.reconcile(base: original, local: original, remote: original)
            try push()
            return
        }
        if localHead == remoteHead { return }
        var left = try Self.oid(localHead)
        var right = try Self.oid(remoteHead)
        var ancestor = git_oid()
        try Self.check(git_merge_base(&ancestor, pointer, &left, &right), "find common ancestor")
        let base = try files(at: Self.text(ancestor))
        let remoteFiles = try files(at: remoteHead)
        let merged = try GitSyncFiles.reconcile(base: base, local: original, remote: remoteFiles)
        if Self.text(ancestor) == remoteHead && merged == original {
            try push()
            return
        }
        let newHead = try createCommit(files: merged, parents: [localHead, remoteHead], message: "Sync TaskTool data")
        try requireClean(original)
        guard try head() == localHead else { throw GitSyncError.dirtyWorkingCopy }
        let transaction = Transaction(oldHead: localHead, newHead: newHead, before: original, after: merged)
        var pendingID = try Self.oid(newHead)
        var pending: OpaquePointer?
        try Self.check(git_reference_create(&pending, pointer, "refs/tasktool/pending", &pendingID, 0, "Prepare TaskTool sync"), "retain pending commit")
        git_reference_free(pending)
        try JSONEncoder().encode(transaction).write(to: journal, options: [])
        try apply(transaction)
        try push()
    }

    /// Resumes a recorded application, but refuses to overwrite bytes that no longer
    /// match either committed version. Both commits remain in Git for manual recovery.
    func resumePendingApplication() throws {
        let transaction: Transaction
        if let data = try? Data(contentsOf: journal),
           let decoded = try? JSONDecoder().decode(Transaction.self, from: data) {
            transaction = decoded
        } else {
            guard let newHead = try reference("refs/tasktool/pending") else { throw GitSyncError.recoveryRequired }
            var id = try Self.oid(newHead)
            var commit: OpaquePointer?
            try Self.check(git_commit_lookup(&commit, pointer, &id), "read pending commit")
            defer { git_commit_free(commit) }
            guard let parent = git_commit_parent_id(commit, 0) else { throw GitSyncError.recoveryRequired }
            let oldHead = Self.text(parent.pointee)
            transaction = try Transaction(oldHead: oldHead, newHead: newHead, before: files(at: oldHead), after: files(at: newHead))
        }
        try apply(transaction)
    }

    private var journal: URL {
        URL(fileURLWithPath: String(cString: git_repository_path(pointer)))
            .appendingPathComponent("tasktool-sync-pending.json")
    }

    private func apply(_ transaction: Transaction) throws {
        try GitSyncFiles.validatePaths(transaction.before)
        try GitSyncFiles.validatePaths(transaction.after)
        guard try files(at: transaction.oldHead) == transaction.before,
              try files(at: transaction.newHead) == transaction.after else {
            throw GitSyncError.recoveryRequired
        }
        let currentHead = try head()
        guard currentHead == transaction.oldHead || currentHead == transaction.newHead else {
            throw GitSyncError.dirtyWorkingCopy
        }
        let current = try workingFiles(tracked: transaction.before.merging(transaction.after) { _, new in new })
        let paths = Set(transaction.before.keys).union(transaction.after.keys)
        guard Set(current.keys).isSubset(of: paths) else { throw GitSyncError.dirtyWorkingCopy }
        for path in paths {
            guard current[path] == transaction.before[path] || current[path] == transaction.after[path] else {
                throw GitSyncError.localFileChanged(path)
            }
        }
        // Write destinations before removing source paths (renames and plan moves).
        for path in transaction.after.keys.sorted() {
            let destination = try safeURL(path)
            let actual = try file(at: destination)
            if actual == transaction.after[path] { continue }
            guard actual == transaction.before[path] else { throw GitSyncError.localFileChanged(path) }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try transaction.after[path]!.data.write(to: destination, options: [])
            try manager.setAttributes([.posixPermissions: Int(transaction.after[path]!.mode & 0o777)], ofItemAtPath: destination.path)
        }
        for path in transaction.before.keys.sorted() where transaction.after[path] == nil {
            let destination = try safeURL(path)
            guard let actual = try file(at: destination) else { continue }
            guard actual == transaction.before[path] else { throw GitSyncError.localFileChanged(path) }
            try manager.removeItem(at: destination)
        }
        guard try workingFiles(tracked: transaction.after) == transaction.after else {
            throw GitSyncError.dirtyWorkingCopy
        }
        if currentHead != transaction.newHead { try updateHead(from: transaction.oldHead, to: transaction.newHead) }
        try writeIndex(for: transaction.newHead)
        let code = git_reference_remove(pointer, "refs/tasktool/pending")
        if code != GIT_ENOTFOUND.rawValue { try Self.check(code, "clear pending commit") }
        if manager.fileExists(atPath: journal.path) { try manager.removeItem(at: journal) }
    }

    private func ready() throws {
        guard !manager.fileExists(atPath: journal.path), try reference("refs/tasktool/pending") == nil else {
            throw GitSyncError.recoveryRequired
        }
        guard git_repository_state(pointer) == GIT_REPOSITORY_STATE_NONE.rawValue else {
            throw GitSyncError.dirtyWorkingCopy
        }
        var reference: OpaquePointer?
        try Self.check(git_reference_lookup(&reference, pointer, "HEAD"), "read HEAD")
        defer { git_reference_free(reference) }
        guard let target = git_reference_symbolic_target(reference), String(cString: target) == "refs/heads/main" else {
            throw GitSyncError.wrongBranch
        }
    }

    private func requireClean(_ original: [String: GitSyncFile]) throws {
        guard try workingFiles(tracked: original) == original else { throw GitSyncError.dirtyWorkingCopy }
        var index: OpaquePointer?
        try Self.check(git_repository_index(&index, pointer), "read index")
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) == 0 else { throw GitSyncError.dirtyWorkingCopy }
        if let head = try head() {
            var id = git_oid()
            try Self.check(git_index_write_tree_to(&id, index, pointer), "read staged tree")
            var commitID = try Self.oid(head)
            var commit: OpaquePointer?
            try Self.check(git_commit_lookup(&commit, pointer, &commitID), "read HEAD commit")
            defer { git_commit_free(commit) }
            guard git_oid_equal(&id, git_commit_tree_id(commit)) == 1 else { throw GitSyncError.dirtyWorkingCopy }
        }
    }

    private func origin() throws -> OpaquePointer {
        var remote: OpaquePointer?
        try Self.check(git_remote_lookup(&remote, pointer, "origin"), "read remote")
        guard let remote, let url = git_remote_url(remote) else { throw GitSyncError.changedRemote }
        let expected = github?.url.absoluteString ?? localRemote?.path
        let fetchURL = String(cString: url)
        let pushURL = git_remote_pushurl(remote).map { String(cString: $0) } ?? fetchURL
        guard fetchURL == expected, pushURL == expected else {
            git_remote_free(remote)
            throw GitSyncError.changedRemote
        }
        var config: OpaquePointer?
        do {
            try Self.check(git_repository_config(&config, pointer), "open config")
            defer { git_config_free(config) }
            try Self.check(git_config_set_string(config, "http.followRedirects", "false"), "disable redirects")
            try Self.check(git_config_set_bool(config, "http.sslVerify", 1), "require TLS verification")
        } catch {
            git_remote_free(remote)
            throw error
        }
        return remote
    }

    private func callbackContext() throws -> GitCallbackContext {
        GitCallbackContext(remote: github, token: try github.flatMap { try credentials?.token(for: $0) })
    }

    private static func callbacks(_ context: GitCallbackContext) -> git_remote_callbacks {
        var result = git_remote_callbacks()
        git_remote_init_callbacks(&result, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        result.payload = Unmanaged.passUnretained(context).toOpaque()
        result.credentials = { output, url, _, allowed, payload in
            guard let payload, let url else { return GIT_EAUTH.rawValue }
            let context = Unmanaged<GitCallbackContext>.fromOpaque(payload).takeUnretainedValue()
            guard !context.usedCredential, let remote = context.remote, let token = context.token,
                  remote.acceptsCredentialURL(String(cString: url)),
                  allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else { return GIT_EAUTH.rawValue }
            context.usedCredential = true
            return git_credential_userpass_plaintext_new(output, "x-access-token", token)
        }
        result.push_update_reference = { _, status, payload in
            if let status, let payload {
                _ = status
                Unmanaged<GitCallbackContext>.fromOpaque(payload).takeUnretainedValue().rejected = true
            }
            return 0
        }
        result.certificate_check = { _, valid, host, payload in
            guard valid == 1, let host, let payload else { return GIT_ECERTIFICATE.rawValue }
            let context = Unmanaged<GitCallbackContext>.fromOpaque(payload).takeUnretainedValue()
            guard context.remote != nil, String(cString: host).lowercased() == "github.com" else {
                return GIT_ECERTIFICATE.rawValue
            }
            return 0
        }
        return result
    }

    private func reference(_ name: String) throws -> String? {
        var id = git_oid()
        let code = git_reference_name_to_id(&id, pointer, name)
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EUNBORNBRANCH.rawValue { return nil }
        try Self.check(code, "read reference")
        return Self.text(id)
    }

    private func createCommit(files: [String: GitSyncFile], parents: [String], message: String) throws -> String {
        var index: OpaquePointer?
        try Self.check(git_index_new(&index), "create index")
        defer { git_index_free(index) }
        for path in files.keys.sorted() {
            let file = files[path]!
            var id = git_oid()
            try file.data.withUnsafeBytes {
                try Self.check(git_blob_create_from_buffer(&id, pointer, $0.baseAddress, $0.count), "write blob")
            }
            try path.withCString {
                var entry = git_index_entry()
                entry.path = $0
                entry.mode = file.mode
                entry.id = id
                try Self.check(git_index_add(index, &entry), "write index entry")
            }
        }
        var treeID = git_oid()
        try Self.check(git_index_write_tree_to(&treeID, index, pointer), "write tree")
        var tree: OpaquePointer?
        try Self.check(git_tree_lookup(&tree, pointer, &treeID), "read new tree")
        defer { git_tree_free(tree) }
        var signature: UnsafeMutablePointer<git_signature>?
        try Self.check(git_signature_now(&signature, "TaskTool", "tasktool@localhost"), "create signature")
        defer { git_signature_free(signature) }
        var parentPointers: [OpaquePointer?] = []
        defer { parentPointers.forEach { git_commit_free($0) } }
        for parent in parents {
            var id = try Self.oid(parent)
            var commit: OpaquePointer?
            try Self.check(git_commit_lookup(&commit, pointer, &id), "read parent")
            parentPointers.append(commit)
        }
        var id = git_oid()
        try parentPointers.withUnsafeMutableBufferPointer {
            try Self.check(git_commit_create(&id, pointer, nil, signature, signature, nil, message, tree, $0.count, $0.baseAddress), "write commit")
        }
        return Self.text(id)
    }

    private func updateHead(from old: String?, to new: String) throws {
        var newID = try Self.oid(new)
        let oldID = try old.map(Self.oid)
        var reference: OpaquePointer?
        defer { git_reference_free(reference) }
        let code: Int32
        if var oldID {
            code = git_reference_create_matching(&reference, pointer, "refs/heads/main", &newID, 1, &oldID, "TaskTool sync")
        } else {
            code = git_reference_create(&reference, pointer, "refs/heads/main", &newID, 0, "TaskTool initial tasks")
        }
        try Self.check(code, "update branch")
    }

    private func writeIndex(for revision: String) throws {
        var id = try Self.oid(revision)
        var commit: OpaquePointer?
        try Self.check(git_commit_lookup(&commit, pointer, &id), "read applied commit")
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try Self.check(git_commit_tree(&tree, commit), "read applied tree")
        defer { git_tree_free(tree) }
        var index: OpaquePointer?
        try Self.check(git_repository_index(&index, pointer), "open index")
        defer { git_index_free(index) }
        try Self.check(git_index_read_tree(index, tree), "update index")
        try Self.check(git_index_write(index), "save index")
    }

    private func read(tree: OpaquePointer?, prefix: String, into result: inout [String: GitSyncFile]) throws {
        for position in 0..<git_tree_entrycount(tree) {
            guard let entry = git_tree_entry_byindex(tree, position), let name = git_tree_entry_name(entry),
                  let id = git_tree_entry_id(entry) else { throw GitSyncError.unsupportedFile(prefix) }
            let path = prefix + String(cString: name)
            if git_tree_entry_type(entry) == GIT_OBJECT_TREE {
                var child: OpaquePointer?
                try Self.check(git_tree_lookup(&child, pointer, id), "read subtree")
                defer { git_tree_free(child) }
                try read(tree: child, prefix: path + "/", into: &result)
            } else {
                guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { throw GitSyncError.unsupportedFile(path) }
                var blob: OpaquePointer?
                try Self.check(git_blob_lookup(&blob, pointer, id), "read blob")
                defer { git_blob_free(blob) }
                let size = Int(git_blob_rawsize(blob))
                let data = size == 0 ? Data() : Data(bytes: git_blob_rawcontent(blob)!, count: size)
                result[path] = GitSyncFile(data: data, mode: git_tree_entry_filemode(entry).rawValue)
            }
        }
    }

    private func workingFiles(tracked: [String: GitSyncFile]) throws -> [String: GitSyncFile] {
        var result: [String: GitSyncFile] = [:]
        func walk(_ folder: URL, prefix: String) throws {
            for url in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                if prefix.isEmpty && url.lastPathComponent == ".git" { continue }
                let path = prefix + url.lastPathComponent
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                var ignored: Int32 = 0
                try Self.check(git_ignore_path_is_ignored(&ignored, pointer, path), "check ignored path")
                if ignored == 1 && tracked[path] == nil && !tracked.keys.contains(where: { $0.hasPrefix(path + "/") }) { continue }
                guard values.isSymbolicLink != true else { throw GitSyncError.unsupportedFile(path) }
                if values.isDirectory == true {
                    try walk(url, prefix: path + "/")
                } else {
                    result[path] = try file(at: url)
                }
            }
        }
        try walk(directory, prefix: "")
        try GitSyncFiles.validatePaths(result)
        return result
    }

    private func safeURL(_ path: String) throws -> URL {
        var url = directory
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            do {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw GitSyncError.unsupportedFile(path)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            }
        }
        return url
    }

    private func file(at url: URL) throws -> GitSyncFile? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitSyncError.unsupportedFile(url.lastPathComponent) }
        let permissions = attributes[.posixPermissions] as? Int ?? 0o644
        return GitSyncFile(data: try Data(contentsOf: url), mode: permissions & 0o111 == 0 ? 0o100644 : 0o100755)
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        // Do not surface server messages, which may contain authentication material.
        guard code >= 0 else { throw GitSyncError.operation(operation, code) }
    }

    private static func oid(_ value: String) throws -> git_oid {
        var id = git_oid()
        try check(git_oid_fromstr(&id, value), "parse revision")
        return id
    }

    private static func text(_ value: git_oid) -> String {
        var id = value
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, buffer.count, &id)
        return String(cString: buffer)
    }
}
#endif
