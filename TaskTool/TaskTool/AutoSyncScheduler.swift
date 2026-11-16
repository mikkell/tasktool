import Foundation

/// Foreground-only scheduling; stores remain responsible for serializing file access.
@MainActor
public final class AutoSyncScheduler {
    private let canSync: () -> Bool
    private let sync: () async -> Void
    private let now: () -> Date
    private let runsTimer: Bool
    private var timer: _Concurrency.Task<Void, Never>?
    private var isActive = false
    public private(set) var isPaused = false
    private var isRunning = false
    private var editDeadline: Date?
    private var nextPoll: Date?

    public convenience init(canSync: @escaping () -> Bool, sync: @escaping () async -> Void) {
        self.init(now: Date.init, runsTimer: true, canSync: canSync, sync: sync)
    }

    init(now: @escaping () -> Date, runsTimer: Bool, canSync: @escaping () -> Bool, sync: @escaping () async -> Void) {
        self.now = now
        self.runsTimer = runsTimer
        self.canSync = canSync
        self.sync = sync
    }

    deinit { timer?.cancel() }

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.cancel()
        timer = nil
        guard active else { return }
        requestSync()
        guard runsTimer else { return }
        timer = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                await self?.runDueSync()
                do {
                    try await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000)
                } catch { return }
            }
        }
    }

    public func requestSync() {
        nextPoll = now()
    }

    public func recordEdit() {
        editDeadline = now().addingTimeInterval(5)
    }

    public func recordSyncAttempt() {
        editDeadline = nil
        nextPoll = now().addingTimeInterval(300)
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func runDueSync() async {
        guard isActive, !isPaused, !isRunning, canSync() else { return }
        let current = now()
        if let editDeadline, current < editDeadline { return }
        guard editDeadline != nil || nextPoll.map({ current >= $0 }) == true else { return }
        recordSyncAttempt()
        isRunning = true
        defer { isRunning = false }
        await sync()
    }
}
