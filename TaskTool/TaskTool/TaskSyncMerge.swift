import Foundation

/// A task and its repository-relative location, including archived tasks.
struct TaskSyncSnapshot: Equatable {
    var task: Task
    var path: String
}

struct TaskSyncConflict: Equatable {
    let taskID: UUID
    let field: String
}

struct TaskSyncMergeResult {
    let snapshots: [TaskSyncSnapshot]
    let conflicts: [TaskSyncConflict]
    var canApply: Bool { conflicts.isEmpty }
}

enum TaskSyncMergeError: Error {
    case duplicateID(UUID)
    case invalidPath(String)
}

/// Reconciles snapshots without changing either working copy. Callers must not apply
/// any result with conflicts; the original snapshots remain available for resolution.
enum TaskSyncMerge {
    static func reconcile(
        base: [TaskSyncSnapshot],
        local: [TaskSyncSnapshot],
        remote: [TaskSyncSnapshot]
    ) throws -> TaskSyncMergeResult {
        let ancestors = try index(base)
        let ours = try index(local)
        let theirs = try index(remote)
        let ids = Set(ancestors.keys).union(ours.keys).union(theirs.keys)
        var merged: [TaskSyncSnapshot] = []
        var conflicts: [TaskSyncConflict] = []

        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let ancestor = ancestors[id]
            let left = ours[id]
            let right = theirs[id]

            if left == right {
                if let left { merged.append(left) }
            } else if left == ancestor {
                if let right { merged.append(right) }
            } else if right == ancestor {
                if let left { merged.append(left) }
            } else if let ancestor, let left, let right {
                var result = left
                func merge<Value: Equatable>(
                    _ field: String, _ original: Value, _ local: Value, _ remote: Value
                ) -> Value {
                    if local == remote || remote == original { return local }
                    if local == original { return remote }
                    conflicts.append(TaskSyncConflict(taskID: id, field: field))
                    return local
                }
                result.path = merge("path", ancestor.path, left.path, right.path)
                result.task.title = merge("title", ancestor.task.title, left.task.title, right.task.title)
                result.task.plan = merge("plan", ancestor.task.plan, left.task.plan, right.task.plan)
                result.task.status = merge("status", ancestor.task.status, left.task.status, right.task.status)
                result.task.dueDate = merge("dueDate", ancestor.task.dueDate, left.task.dueDate, right.task.dueDate)
                result.task.tags = merge("tags", ancestor.task.tags, left.task.tags, right.task.tags)
                result.task.created = merge("created", ancestor.task.created, left.task.created, right.task.created)
                result.task.completedAt = merge("completedAt", ancestor.task.completedAt, left.task.completedAt, right.task.completedAt)
                result.task.pingHistory = merge("pingHistory", ancestor.task.pingHistory, left.task.pingHistory, right.task.pingHistory)
                result.task.body = merge("body", ancestor.task.body, left.task.body, right.task.body)
                result.task.bundledTaskIDs = merge("bundledTaskIDs", ancestor.task.bundledTaskIDs, left.task.bundledTaskIDs, right.task.bundledTaskIDs)
                result.task.parentBundleID = merge("parentBundleID", ancestor.task.parentBundleID, left.task.parentBundleID, right.task.parentBundleID)
                result.task.order = merge("order", ancestor.task.order, left.task.order, right.task.order)
                result.task.updated = max(left.task.updated, right.task.updated)
                merged.append(result)
            } else {
                conflicts.append(TaskSyncConflict(
                    taskID: id,
                    field: ancestor == nil ? "concurrentCreation" : "deletion"
                ))
            }
        }

        var paths: [String: UUID] = [:]
        for snapshot in merged {
            // Treat case-only differences as collisions for default macOS/iOS volumes.
            let path = snapshot.path.precomposedStringWithCanonicalMapping.lowercased()
            if let otherID = paths[path] {
                conflicts.append(TaskSyncConflict(taskID: otherID, field: "pathCollision"))
                conflicts.append(TaskSyncConflict(taskID: snapshot.task.id, field: "pathCollision"))
            }
            paths[path] = snapshot.task.id
        }
        return TaskSyncMergeResult(
            snapshots: merged.sorted { $0.path < $1.path },
            conflicts: conflicts
        )
    }

    private static func index(_ snapshots: [TaskSyncSnapshot]) throws -> [UUID: TaskSyncSnapshot] {
        var indexed: [UUID: TaskSyncSnapshot] = [:]
        for snapshot in snapshots {
            let components = snapshot.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !snapshot.path.contains("\\"), !snapshot.path.contains("\0"),
                  components.count >= 2,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }),
                  snapshot.path.hasSuffix(".md") else {
                throw TaskSyncMergeError.invalidPath(snapshot.path)
            }
            guard indexed.updateValue(snapshot, forKey: snapshot.task.id) == nil else {
                throw TaskSyncMergeError.duplicateID(snapshot.task.id)
            }
        }
        return indexed
    }
}
