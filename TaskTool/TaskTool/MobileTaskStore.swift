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

public struct MobileTaskBody {
    public struct Subtask: Identifiable, Equatable {
        public let id = UUID()
        public var title: String
        public var isCompleted: Bool
    }

    public var subtasks: [Subtask]
    public var notes: String
    public var newSubtaskTitle = ""
    private let originalBody: String
    private let originalSubtasks: [Subtask]
    private let originalNotes: String

    public init(_ body: String = "") {
        var subtasks: [Subtask] = []
        var noteLines: [String] = []
        var fence: (marker: Character, length: Int)?
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                let run = trimmed.prefix { $0 == current.marker }
                if run.count >= current.length && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                noteLines.append(line)
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix { $0 == marker }.count
                if length >= 3 {
                    fence = (marker, length)
                    noteLines.append(line)
                    continue
                }
            }
            if (line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ")),
               !line.dropFirst(6).trimmingCharacters(in: .whitespaces).isEmpty {
                subtasks.append(Subtask(title: String(line.dropFirst(6)), isCompleted: line.hasPrefix("- [x] ")))
            } else {
                noteLines.append(line)
            }
        }
        let notes = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtasks = subtasks
        self.notes = notes
        originalBody = body
        originalSubtasks = subtasks
        originalNotes = notes
    }

    public var canAddSubtask: Bool { Self.validTitle(newSubtaskTitle) }

    public var isValid: Bool {
        subtasks.allSatisfy { Self.validTitle($0.title) } &&
            (newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || canAddSubtask)
    }

    public mutating func addSubtask() {
        guard canAddSubtask else { return }
        subtasks.append(Subtask(title: newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines), isCompleted: false))
        newSubtaskTitle = ""
    }

    public var markdown: String {
        var draft = self
        draft.addSubtask()
        // Opening an editor or changing only the plan/status must not reformat notes.
        if draft.subtasks == originalSubtasks && notes == originalNotes { return originalBody }
        let lines = draft.subtasks.map { "- [\($0.isCompleted ? "x" : " ")] \($0.title)" }
        return [lines.joined(separator: "\n"), notes].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.rangeOfCharacter(from: .newlines) == nil
    }
}

protocol MobileGitService: Actor {
    func clone(remoteURL: String, to directory: URL, token: String) async throws
    func open(remoteURL: String, at directory: URL) async throws
    func sync() async throws
    func recover() async throws
    func updateToken(_ token: String) async throws
    func mobileSnapshot() async throws -> RepositorySyncSnapshot
    func saveMobileTask(_ expected: Task, planID: UUID?, status: String, dueDate: Date?, body: String) async throws
    func createMobileTask(title: String, planID: UUID, status: String?, dueDate: Date?, body: String) async throws
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
    private var openEditors: Set<UUID> = []
    private lazy var autoSync = AutoSyncScheduler(
        canSync: { [weak self] in
            guard let self else { return false }
            return self.canEdit && self.openEditors.isEmpty
        },
        sync: { [weak self] in await self?.sync() }
    )

    public func setAutoSyncActive(_ active: Bool) {
        autoSync.setActive(active)
    }

    public func setAutoSyncEditor(_ id: UUID, isOpen: Bool) {
        if isOpen { openEditors.insert(id) } else { openEditors.remove(id) }
    }

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
            autoSync.setPaused(false)
            autoSync.requestSync()
            message = "Connected. Automatic sync is enabled while the app is active."
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
            autoSync.requestSync()
            message = "Local tasks ready. Automatic sync will catch up when online."
        } catch { show(error) }
    }

    public func sync() async {
        guard canEdit else { return }
        autoSync.recordSyncAttempt()
        begin("Syncing...")
        defer { isBusy = false }
        do {
            try await client.sync()
            try await reload()
            autoSync.setPaused(false)
            message = "Synced successfully."
        } catch { show(error) }
    }

    @discardableResult
    public func save(_ task: MobileTask, planID: UUID? = nil, status: String, dueDate: Date?, body: String) async -> Bool {
        guard canEdit else { return false }
        begin("Saving locally...", clearConflicts: false)
        defer { isBusy = false }
        do {
            try await client.saveMobileTask(task.value, planID: planID, status: status, dueDate: dueDate, body: body)
            try await reload()
            didSaveLocally()
            return true
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    public func createTask(
        title: String, planID: UUID, status: String? = nil, dueDate: Date? = nil, body: String = ""
    ) async -> Bool {
        guard canEdit else { return false }
        begin("Creating task locally...", clearConflicts: false)
        defer { isBusy = false }
        do {
            try await client.createMobileTask(title: title, planID: planID, status: status, dueDate: dueDate, body: body)
            try await reload()
            didSaveLocally()
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func didSaveLocally() {
        autoSync.recordEdit()
        message = autoSync.isPaused
            ? "Saved on this device. Automatic sync is paused; resolve conflicts before using Sync Now."
            : "Saved on this device. Automatic sync will share your edits."
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
            autoSync.setPaused(false)
            autoSync.requestSync()
            message = "Recovered local tasks. Sync again when online."
        } catch { show(error) }
    }

    public func updateToken(_ token: String) async {
        guard isConfigured, !isBusy else { return }
        begin("Updating token...", clearConflicts: false)
        defer { isBusy = false }
        do {
            try await client.updateToken(token)
            autoSync.requestSync()
            message = "Token updated."
        } catch { show(error) }
    }

    private func begin(_ message: String, clearConflicts: Bool = true) {
        isBusy = true
        self.message = message
        if clearConflicts { conflicts = [] }
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
        if !failure.conflicts.isEmpty || failure.requiresRecovery { autoSync.setPaused(true) }
    }
}
