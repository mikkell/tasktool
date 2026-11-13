import Foundation

public struct GitSyncFailure: LocalizedError {
    public let message: String
    public let conflicts: [String]
    public let requiresRecovery: Bool
    public var errorDescription: String? { message }

    public init(message: String, conflicts: [String] = [], requiresRecovery: Bool = false) {
        self.message = message
        self.conflicts = conflicts
        self.requiresRecovery = requiresRecovery
    }

    init(_ error: Error, pendingApplication: Bool = false) {
        var details: [String] = []
        var recovery = pendingApplication
        let message: String
        switch error {
        case GitHubCredentialError.invalidRemote:
            message = "Enter an HTTPS GitHub repository URL without credentials, query parameters or fragments."
        case GitHubCredentialError.emptyToken, GitHubCredentialError.missingToken:
            message = "Enter a fine-grained GitHub token with Contents read/write access to this repository."
        case GitHubCredentialError.keychain(let status):
            message = "Keychain access failed (\(status))."
        case GitSyncError.conflicts(let conflicts):
            message = "Sync needs conflict resolution. Both committed versions remain in Git."
            details = conflicts.map { "\(String(describing: $0.entity)): \($0.field)" }.sorted()
        case GitSyncError.fileConflict(let path):
            message = "Conflicting file changes: \(path). Both committed versions remain in Git."
        case GitSyncError.recoveryRequired, GitSyncError.localFileChanged:
            message = "An interrupted sync needs recovery. Recovery will not overwrite unexpected local changes."
            recovery = true
        case GitSyncError.dirtyWorkingCopy:
            message = "Local files or staged changes changed during sync. Save your edits and retry."
        case GitSyncError.wrongBranch:
            message = "Git sync currently requires the main branch."
        case GitSyncError.changedRemote:
            message = "The checkout's remote does not match its configured GitHub repository."
        case GitSyncError.invalidMetadata(let path), GitSyncError.unsupportedFile(let path):
            message = "Sync cannot safely process \(path). Check its format, IDs and file type."
        case GitSyncError.pushRejected:
            message = "Another device pushed first. Your local commit is safe; sync again."
        case GitSyncError.operation(let operation, let code):
            message = "\(operation.capitalized) failed (Git error \(code)). Check connectivity and repository permissions."
        default:
            message = "Git sync failed. Check storage access and retry. Committed data remains in Git."
        }
        self.init(message: message, conflicts: details, requiresRecovery: recovery)
    }
}

/// Public bridge between the app and the shared core's internal models.
public actor GitSyncClient {
    private var repository: EmbeddedGitRepository?
    private var remote: GitHubRemote?
    private let tokens = KeychainGitHubTokenStore()

    public init() {}

    public static func canonicalRemoteURL(_ value: String) throws -> String {
        do { return try GitHubRemote(value).url.absoluteString }
        catch { throw GitSyncFailure(error) }
    }

    public func clone(remoteURL: String, to directory: URL, token: String) async throws {
        do {
            let target = try GitHubRemote(remoteURL)
            try tokens.save(token, for: target)
            let cloned = try EmbeddedGitRepository.clone(from: target, to: directory, credentials: tokens)
            try await cloned.validateForUse()
            repository = cloned
            remote = target
        } catch {
            throw GitSyncFailure(error)
        }
    }

    public func open(remoteURL: String, at directory: URL) async throws {
        do {
            let target = try GitHubRemote(remoteURL)
            let opened = try EmbeddedGitRepository.open(at: directory, remote: target, credentials: tokens)
            repository = opened
            remote = target
            try await opened.validateForUse()
        } catch {
            throw await failure(error)
        }
    }

    public func sync() async throws {
        do {
            guard let repository else { throw GitSyncError.wrongBranch }
            try await repository.commitWorkingCopy(message: "Save TaskTool edits")
            try await repository.synchronize()
        } catch {
            throw await failure(error)
        }
    }

    public func recover() async throws {
        do {
            guard let repository else { throw GitSyncError.recoveryRequired }
            try await repository.resumePendingApplication()
            try await repository.validateForUse()
        } catch {
            throw await failure(error)
        }
    }

    public func updateToken(_ token: String) throws {
        do {
            guard let remote else { throw GitHubCredentialError.invalidRemote }
            try tokens.save(token, for: remote)
        } catch { throw GitSyncFailure(error) }
    }

    public func disconnect() throws {
        do {
            if let remote { try tokens.remove(for: remote) }
            repository = nil
            remote = nil
        } catch { throw GitSyncFailure(error) }
    }

    private func failure(_ error: Error) async -> GitSyncFailure {
        let pending = (try? await repository?.hasPendingApplication()) ?? false
        return GitSyncFailure(error, pendingApplication: pending)
    }
}
