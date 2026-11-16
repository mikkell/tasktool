import Combine
import Foundation

public struct MobilePlan: Identifiable {
    public let id: UUID
    public let name: String
    public let statuses: [String]
}

public struct MobileTask: Identifiable, Equatable {
    let value: Task
    public var id: UUID { value.id }
    public var title: String { value.title }
    public var plan: String { value.plan }
    public var status: String { value.status }
    public var body: String { value.body }
    public var dueDate: Date? { value.dueDate }
    public var isBundled: Bool { value.isBundle || value.parentBundleID != nil }
}

protocol MobileGitService: Actor {
    func clone(remoteURL: String, to directory: URL, token: String) async throws
    func open(remoteURL: String, at directory: URL) async throws
    func sync() async throws
    func recover() async throws
    func updateToken(_ token: String) async throws
    func mobileSnapshot() async throws -> RepositorySyncSnapshot
    func saveMobileTask(_ expected: Task, status: String, body: String) async throws
}

extension GitSyncClient: MobileGitService {}

@MainActor
public final class MobileTaskStore: ObservableObject {
    @Published public private(set) var plans: [MobilePlan] = []
    @Published public private(set) var tasks: [MobileTask] = []
    @Published public private(set) var remoteURL: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var needsRecovery = false
    @Published public private(set) var storageUnavailable = false
    @Published public private(set) var message = "Connect a private GitHub task-data repository to begin."
    @Published public private(set) var conflicts: [String] = []

    public var isConfigured: Bool {
        remoteURL != nil || defaults.string(forKey: "mobileGitRepositoryID") != nil
    }
    public var canEdit: Bool { isConfigured && !isBusy && !needsRecovery && !storageUnavailable }

    private let client: any MobileGitService
    private let defaults: UserDefaults
    private let repositoriesURL: URL
    private var didRestore = false

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(
            client: GitSyncClient(), defaults: .standard,
            repositoriesURL: support.appendingPathComponent("TaskToolMobile/GitRepositories", isDirectory: true)
        )
    }

    init(client: any MobileGitService, defaults: UserDefaults, repositoriesURL: URL) {
        self.client = client
        self.defaults = defaults
        self.repositoriesURL = repositoriesURL
        remoteURL = defaults.string(forKey: "mobileGitRemoteURL")
        storageUnavailable = isConfigured
    }

    public func restoreIfNeeded() async {
        guard !didRestore else { return }
        didRestore = true
        await reopen()
    }

    public func connect(remoteURL: String, token: String) async {
        guard !isBusy, !isConfigured else { return }
        begin("Cloning repository...")
        defer { isBusy = false }
        do {
            let remote = try GitSyncClient.canonicalRemoteURL(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines))
            let id = UUID().uuidString
            let directory = repositoriesURL.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: repositoriesURL, withIntermediateDirectories: true)
            try await client.clone(remoteURL: remote, to: directory, token: token)
            try await reload()
            defaults.set(remote, forKey: "mobileGitRemoteURL")
            defaults.set(id, forKey: "mobileGitRepositoryID")
            self.remoteURL = remote
            storageUnavailable = false
            message = "Connected. Edits are saved offline; sync is manual."
        } catch { show(error) }
    }

    public func reopen() async {
        guard !isBusy, isConfigured else { return }
        begin("Opening local tasks...")
        storageUnavailable = true
        defer { isBusy = false }
        do {
            guard let remote = remoteURL,
                  let id = defaults.string(forKey: "mobileGitRepositoryID"), UUID(uuidString: id) != nil else {
                throw GitSyncFailure(message: "Saved repository configuration is incomplete. Local files have not been changed.")
            }
            try await client.open(remoteURL: remote, at: repositoriesURL.appendingPathComponent(id, isDirectory: true))
            try await reload()
            needsRecovery = false
            storageUnavailable = false
            message = "Local tasks ready. Sync when you are online."
        } catch { show(error) }
    }

    public func sync() async {
        guard canEdit else { return }
        begin("Syncing...")
        defer { isBusy = false }
        do {
            try await client.sync()
            try await reload()
            message = "Synced successfully."
        } catch { show(error) }
    }

    @discardableResult
    public func save(_ task: MobileTask, status: String, body: String) async -> Bool {
        guard canEdit else { return false }
        begin("Saving locally...")
        defer { isBusy = false }
        do {
            try await client.saveMobileTask(task.value, status: status, body: body)
            try await reload()
            message = "Saved on this device. Sync to share your edits."
            return true
        } catch {
            show(error)
            return false
        }
    }

    public func recover() async {
        guard needsRecovery, !isBusy else { return }
        begin("Recovering interrupted sync...")
        defer { isBusy = false }
        do {
            try await client.recover()
            try await reload()
            needsRecovery = false
            storageUnavailable = false
            message = "Recovered local tasks. Sync again when online."
        } catch { show(error) }
    }

    public func updateToken(_ token: String) async {
        guard isConfigured, !isBusy else { return }
        begin("Updating token...")
        defer { isBusy = false }
        do {
            try await client.updateToken(token)
            message = "Token updated."
        } catch { show(error) }
    }

    private func begin(_ message: String) {
        isBusy = true
        self.message = message
        conflicts = []
    }

    private func reload() async throws {
        let snapshot: RepositorySyncSnapshot
        do {
            snapshot = try await client.mobileSnapshot()
        } catch {
            storageUnavailable = true
            throw error
        }
        let order = snapshot.settings?.planOrder ?? []
        plans = snapshot.plans.sorted {
            let left = order.firstIndex(of: $0.name) ?? Int.max
            let right = order.firstIndex(of: $1.name) ?? Int.max
            return left == right ? $0.name < $1.name : left < right
        }.map { MobilePlan(id: $0.id, name: $0.name, statuses: $0.statuses.sorted { $0.order < $1.order }.map(\.name)) }
        tasks = snapshot.tasks.filter { $0.path.split(separator: "/").count == 2 }
            .map { MobileTask(value: $0.task) }
            .sorted {
                $0.value.order == $1.value.order
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : $0.value.order < $1.value.order
            }
    }

    private func show(_ error: Error) {
        let failure = error as? GitSyncFailure ?? GitSyncFailure(error)
        message = failure.message
        conflicts = failure.conflicts
        needsRecovery = needsRecovery || failure.requiresRecovery
    }
}
