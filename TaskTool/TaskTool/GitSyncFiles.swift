import Foundation
import Yams

struct GitSyncFile: Codable, Equatable {
    var data: Data
    var mode: UInt32 = 0o100644
}

enum GitSyncError: Error {
    case operation(String, Int32)
    case unsupportedFile(String)
    case invalidMetadata(String)
    case conflicts([RepositorySyncConflict])
    case fileConflict(String)
    case dirtyWorkingCopy
    case wrongBranch
    case changedRemote
    case pushRejected
    case recoveryRequired
    case localFileChanged(String)
}

enum GitSyncFiles {
    static func validatePaths(_ files: [String: GitSyncFile]) throws {
        var normalized: Set<String> = []
        for (path, file) in files {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.contains("\0"), !path.contains("\\"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }),
                  file.mode == 0o100644 || file.mode == 0o100755 else {
                throw GitSyncError.unsupportedFile(path)
            }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalized.insert(key).inserted else { throw GitSyncError.fileConflict(path) }
        }
        for path in normalized {
            let parts = path.split(separator: "/")
            for end in 1..<parts.count {
                if normalized.contains(parts.prefix(end).joined(separator: "/")) {
                    throw GitSyncError.fileConflict(path)
                }
            }
        }
    }

    static func decode(_ files: [String: GitSyncFile]) throws -> (RepositorySyncSnapshot, Set<String>) {
        try validatePaths(files)
        var plans: [Plan] = []
        var tasks: [TaskSyncSnapshot] = []
        var managed: Set<String> = []
        var settings: Settings?
        for path in files.keys.sorted() {
            let parts = path.split(separator: "/")
            let isPlan = parts.count == 2 && parts[1] == "plan.yaml"
            let isTask = parts.count >= 2 && path.hasSuffix(".md") && parts[1] != "attachments"
            guard isPlan || isTask || path == "settings.yaml" else { continue }
            guard let text = String(data: files[path]!.data, encoding: .utf8) else {
                throw GitSyncError.invalidMetadata(path)
            }
            let yaml: String
            if isTask {
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                guard normalized.hasPrefix("---\n"),
                      let end = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
                    throw GitSyncError.invalidMetadata(path)
                }
                yaml = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound])
            } else {
                yaml = text
            }
            guard let metadata = try Yams.load(yaml: yaml) as? [String: Any] else {
                throw GitSyncError.invalidMetadata(path)
            }
            if isTask {
                try keys(metadata, allowed: [
                    "id", "type", "plan", "status", "order", "due_date", "tags",
                    "created", "updated", "completed_at", "ping_history", "bundled_task_ids", "parent_bundle_id"
                ], path: path)
                guard uuid(metadata["id"]), metadata["type"] as? String == "task",
                      metadata["plan"] as? String == String(parts[0]),
                      metadata["status"] is String,
                      date(metadata["created"]), date(metadata["updated"]) else {
                    throw GitSyncError.invalidMetadata(path)
                }
                for key in ["due_date", "completed_at"] where metadata[key] != nil {
                    guard date(metadata[key]) else { throw GitSyncError.invalidMetadata(path) }
                }
                for key in ["tags", "bundled_task_ids"] where metadata[key] != nil {
                    guard let values = metadata[key] as? [String],
                          key == "tags" || values.allSatisfy({ uuid($0) }) else {
                        throw GitSyncError.invalidMetadata(path)
                    }
                }
                if let parent = metadata["parent_bundle_id"], !uuid(parent) { throw GitSyncError.invalidMetadata(path) }
                if let order = metadata["order"], !(order is Int) { throw GitSyncError.invalidMetadata(path) }
                if let history = metadata["ping_history"] {
                    guard let values = history as? [Any], values.allSatisfy({ date($0, fractional: true) }) else {
                        throw GitSyncError.invalidMetadata(path)
                    }
                }
                tasks.append(.init(task: try MarkdownParser.parseTask(from: text, plan: String(parts[0])), path: path))
            } else if isPlan {
                try keys(metadata, allowed: ["id", "name", "color", "created", "description", "statuses"], path: path)
                guard uuid(metadata["id"]), date(metadata["created"]),
                      metadata["name"] as? String == String(parts[0]),
                      let statuses = metadata["statuses"] as? [[String: Any]] else {
                    throw GitSyncError.invalidMetadata(path)
                }
                for status in statuses {
                    try keys(status, allowed: ["id", "name", "color", "order"], path: path)
                    guard uuid(status["id"]), status["name"] is String,
                          status["order"] is Int, status["color"] is String else {
                        throw GitSyncError.invalidMetadata(path)
                    }
                }
                for key in ["color", "description"] where metadata[key] != nil {
                    guard metadata[key] is String else { throw GitSyncError.invalidMetadata(path) }
                }
                plans.append(try MarkdownParser.parsePlan(from: text, name: String(parts[0])))
            } else {
                try keys(metadata, allowed: [
                    "plan_order", "available_tags", "overview_selected_plan_names", "overview_focus_date",
                    "overview_focus_note", "overview_focus_task_ids", "habits"
                ], path: path)
                for key in ["plan_order", "available_tags", "overview_selected_plan_names", "overview_focus_task_ids"] where metadata[key] != nil {
                    // Empty YAML sequences emitted by the existing serializer load as null.
                    guard metadata[key] is NSNull || metadata[key] is [String] else { throw GitSyncError.invalidMetadata(path) }
                }
                if let note = metadata["overview_focus_note"], !(note is String) { throw GitSyncError.invalidMetadata(path) }
                if let focusDate = metadata["overview_focus_date"], !(focusDate is String) && !(focusDate is Date) {
                    throw GitSyncError.invalidMetadata(path)
                }
                if let rawHabits = metadata["habits"] {
                    guard let habits = rawHabits as? [[String: Any]] else { throw GitSyncError.invalidMetadata(path) }
                    for habit in habits {
                        try keys(habit, allowed: ["id", "name", "completed_dates"], path: path)
                        guard habit["id"] is String, habit["name"] is String,
                              let dates = habit["completed_dates"] as? [String] else {
                            throw GitSyncError.invalidMetadata(path)
                        }
                        guard dates.allSatisfy({ $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }) else {
                            throw GitSyncError.invalidMetadata(path)
                        }
                    }
                }
                settings = try MarkdownParser.parseSettings(from: text)
            }
            managed.insert(path)
        }
        return (RepositorySyncSnapshot(tasks: tasks, plans: plans, settings: settings), managed)
    }

    static func reconcile(
        base: [String: GitSyncFile], local: [String: GitSyncFile], remote: [String: GitSyncFile]
    ) throws -> [String: GitSyncFile] {
        let (ancestor, basePaths) = try decode(base)
        let (ours, localPaths) = try decode(local)
        let (theirs, remotePaths) = try decode(remote)
        let result = try RepositorySyncMerge.reconcile(base: ancestor, local: ours, remote: theirs)
        guard result.canApply else { throw GitSyncError.conflicts(result.conflicts) }
        let managed = basePaths.union(localPaths).union(remotePaths)
        var files: [String: GitSyncFile] = [:]
        for path in Set(base.keys).union(local.keys).union(remote.keys).subtracting(managed) {
            if local[path] == remote[path] || remote[path] == base[path] {
                files[path] = local[path]
            } else if local[path] == base[path] {
                files[path] = remote[path]
            } else {
                throw GitSyncError.fileConflict(path)
            }
        }
        func encode<Value: Equatable>(
            _ value: Value, path: String, candidates: [(Value?, GitSyncFile?)], serialize: (Value) -> String
        ) throws -> GitSyncFile {
            let modes = candidates.map { $0.1?.mode }
            let mode: UInt32?
            if modes[1] == modes[2] || modes[2] == modes[0] {
                mode = modes[1]
            } else if modes[1] == modes[0] {
                mode = modes[2]
            } else {
                throw GitSyncError.fileConflict(path)
            }
            // Preserve comments, formatting and exact timestamps when no rewrite is needed.
            for index in [1, 2, 0] {
                if candidates[index].0 == value, var file = candidates[index].1 {
                    file.mode = mode ?? 0o100644
                    return file
                }
            }
            return GitSyncFile(data: Data(serialize(value).utf8), mode: mode ?? 0o100644)
        }
        let sources = [(ancestor, base), (ours, local), (theirs, remote)]
        for task in result.snapshot.tasks {
            let candidates = sources.map { snapshot, files -> (Task?, GitSyncFile?) in
                let source = snapshot.tasks.first { $0.task.id == task.task.id }
                return (source?.task, source.flatMap { files[$0.path] })
            }
            files[task.path] = try encode(task.task, path: task.path, candidates: candidates, serialize: MarkdownParser.serializeTask)
        }
        for plan in result.snapshot.plans {
            var value = plan
            value.order = 0
            let path = "\(plan.name)/plan.yaml"
            let candidates = sources.map { snapshot, files -> (Plan?, GitSyncFile?) in
                var source = snapshot.plans.first { $0.id == plan.id }
                source?.order = 0
                return (source, source.flatMap { files["\($0.name)/plan.yaml"] })
            }
            files[path] = try encode(value, path: path, candidates: candidates, serialize: MarkdownParser.serializePlan)
        }
        if let settings = result.snapshot.settings {
            files["settings.yaml"] = try encode(
                settings, path: "settings.yaml",
                candidates: sources.map { ($0.0.settings, $0.1["settings.yaml"]) },
                serialize: MarkdownParser.serializeSettings
            )
        }
        try validatePaths(files)
        // Check the exact serialized representation, not just the in-memory models.
        let (roundtrip, _) = try decode(files)
        let validation = try RepositorySyncMerge.reconcile(base: roundtrip, local: roundtrip, remote: roundtrip)
        guard validation.canApply else { throw GitSyncError.conflicts(validation.conflicts) }
        return files
    }

    private static func keys(_ metadata: [String: Any], allowed: Set<String>, path: String) throws {
        guard Set(metadata.keys).isSubset(of: allowed) else { throw GitSyncError.invalidMetadata(path) }
    }

    private static func uuid(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return UUID(uuidString: text) != nil
    }

    private static func date(_ value: Any?, fractional: Bool = false) -> Bool {
        if value is Date { return true }
        guard let text = value as? String else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: text) != nil { return true }
        if fractional { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.date(from: text) != nil
    }
}
