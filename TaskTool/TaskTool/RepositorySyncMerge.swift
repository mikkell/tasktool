import Foundation

struct RepositorySyncSnapshot: Equatable {
    var tasks: [TaskSyncSnapshot]
    var plans: [Plan]
    var settings: Settings?
}

enum RepositorySyncEntity: Equatable {
    case task(UUID)
    case plan(UUID)
    case status(planID: UUID, id: UUID)
    case habit(String)
    case settings
}

struct RepositorySyncConflict: Equatable {
    let entity: RepositorySyncEntity
    let field: String
}

struct RepositorySyncMergeResult {
    let snapshot: RepositorySyncSnapshot
    let conflicts: [RepositorySyncConflict]
    var canApply: Bool { conflicts.isEmpty }
}

enum RepositorySyncMergeError: Error {
    case duplicateEntity(RepositorySyncEntity)
}

/// Pure reconciliation only. A conflict anywhere blocks application of the whole
/// repository, including otherwise conflict-free task changes.
enum RepositorySyncMerge {
    static func reconcile(
        base: RepositorySyncSnapshot,
        local: RepositorySyncSnapshot,
        remote: RepositorySyncSnapshot
    ) throws -> RepositorySyncMergeResult {
        let context = RepositoryMergeContext()
        for snapshot in [base, local, remote] {
            for plan in snapshot.plans {
                _ = try context.index(plan.statuses) { .status(planID: plan.id, id: $0) }
            }
            _ = try context.index(snapshot.settings?.habits ?? []) { .habit($0) }
        }
        let tasks = try TaskSyncMerge.reconcile(base: base.tasks, local: local.tasks, remote: remote.tasks)
        context.conflicts += tasks.conflicts.map {
            RepositorySyncConflict(entity: .task($0.taskID), field: $0.field)
        }

        // Plan.order is a projection of settings, never independently merged.
        func unordered(_ plans: [Plan]) -> [Plan] {
            plans.map { plan in
                var copy = plan
                copy.order = 0
                return copy
            }
        }
        var plans = try context.records(
            base: unordered(base.plans), local: unordered(local.plans), remote: unordered(remote.plans),
            entity: { .plan($0) }
        ) { ancestor, left, right in
            var plan = left
            let entity = RepositorySyncEntity.plan(plan.id)
            plan.name = context.field(ancestor.name, left.name, right.name, entity: entity, field: "name")
            plan.color = context.field(ancestor.color, left.color, right.color, entity: entity, field: "color")
            plan.description = context.field(ancestor.description, left.description, right.description, entity: entity, field: "description")
            plan.created = context.field(ancestor.created, left.created, right.created, entity: entity, field: "created")
            plan.statuses = try context.records(
                base: ancestor.statuses, local: left.statuses, remote: right.statuses,
                entity: { .status(planID: plan.id, id: $0) }
            ) { original, ours, theirs in
                var status = ours
                let entity = RepositorySyncEntity.status(planID: plan.id, id: status.id)
                status.name = context.field(original.name, ours.name, theirs.name, entity: entity, field: "name")
                status.color = context.field(original.color, ours.color, theirs.color, entity: entity, field: "color")
                status.order = context.field(original.order, ours.order, theirs.order, entity: entity, field: "order")
                return status
            }.sorted {
                $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
            }
            return plan
        }
        let settings = try context.settings(base: base.settings, local: local.settings, remote: remote.settings)
        for index in plans.indices {
            plans[index].order = settings?.planOrder.firstIndex(of: plans[index].name) ?? Int.max
        }
        plans.sort {
            $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order
        }
        let snapshot = RepositorySyncSnapshot(tasks: tasks.snapshots, plans: plans, settings: settings)
        context.validate(snapshot)
        return RepositorySyncMergeResult(snapshot: snapshot, conflicts: context.conflicts)
    }
}

private final class RepositoryMergeContext {
    var conflicts: [RepositorySyncConflict] = []

    func conflict(_ entity: RepositorySyncEntity, _ field: String) {
        let conflict = RepositorySyncConflict(entity: entity, field: field)
        if !conflicts.contains(conflict) { conflicts.append(conflict) }
    }

    func field<Value: Equatable>(
        _ base: Value, _ local: Value, _ remote: Value,
        entity: RepositorySyncEntity, field: String
    ) -> Value {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        conflict(entity, field)
        return local
    }

    func index<Record: Identifiable>(
        _ records: [Record], entity: (Record.ID) -> RepositorySyncEntity
    ) throws -> [Record.ID: Record] {
        var indexed: [Record.ID: Record] = [:]
        for record in records {
            guard indexed.updateValue(record, forKey: record.id) == nil else {
                throw RepositorySyncMergeError.duplicateEntity(entity(record.id))
            }
        }
        return indexed
    }

    func records<Record: Identifiable & Equatable>(
        base: [Record], local: [Record], remote: [Record],
        entity: (Record.ID) -> RepositorySyncEntity,
        combine: (Record, Record, Record) throws -> Record
    ) throws -> [Record] {
        let ancestors = try index(base, entity: entity)
        let ours = try index(local, entity: entity)
        let theirs = try index(remote, entity: entity)
        let ids = Set(ancestors.keys).union(ours.keys).union(theirs.keys)
        var merged: [Record] = []
        for id in ids.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            let base = ancestors[id]
            let local = ours[id]
            let remote = theirs[id]
            if local == remote {
                if let local { merged.append(local) }
            } else if local == base {
                if let remote { merged.append(remote) }
            } else if remote == base {
                if let local { merged.append(local) }
            } else if let base, let local, let remote {
                merged.append(try combine(base, local, remote))
            } else {
                conflict(entity(id), base == nil ? "concurrentCreation" : "deletion")
            }
        }
        return merged
    }

    func settings(base: Settings?, local: Settings?, remote: Settings?) throws -> Settings? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        guard let base, let local, let remote else {
            conflict(.settings, base == nil ? "concurrentCreation" : "deletion")
            return local
        }
        var result = local
        result.planOrder = field(base.planOrder, local.planOrder, remote.planOrder, entity: .settings, field: "planOrder")
        result.availableTags = field(base.availableTags, local.availableTags, remote.availableTags, entity: .settings, field: "availableTags")
        result.overviewSelectedPlanNames = field(
            base.overviewSelectedPlanNames, local.overviewSelectedPlanNames, remote.overviewSelectedPlanNames,
            entity: .settings, field: "overviewSelectedPlanNames"
        )
        // Do not accidentally attach an offline edit of yesterday's focus to a new day.
        let localFocusChanged = local.overviewFocusNote != base.overviewFocusNote
            || local.overviewFocusTaskIDs != base.overviewFocusTaskIDs
        let remoteFocusChanged = remote.overviewFocusNote != base.overviewFocusNote
            || remote.overviewFocusTaskIDs != base.overviewFocusTaskIDs
        if local.overviewFocusDate != remote.overviewFocusDate
            && ((local.overviewFocusDate != base.overviewFocusDate && remoteFocusChanged)
                || (remote.overviewFocusDate != base.overviewFocusDate && localFocusChanged)) {
            conflict(.settings, "overviewFocus")
        }
        result.overviewFocusDate = field(base.overviewFocusDate, local.overviewFocusDate, remote.overviewFocusDate, entity: .settings, field: "overviewFocusDate")
        result.overviewFocusNote = field(base.overviewFocusNote, local.overviewFocusNote, remote.overviewFocusNote, entity: .settings, field: "overviewFocusNote")
        result.overviewFocusTaskIDs = field(base.overviewFocusTaskIDs, local.overviewFocusTaskIDs, remote.overviewFocusTaskIDs, entity: .settings, field: "overviewFocusTaskIDs")
        result.habits = try records(
            base: base.habits, local: local.habits, remote: remote.habits, entity: { .habit($0) }
        ) { original, ours, theirs in
            var habit = ours
            habit.name = field(original.name, ours.name, theirs.name, entity: .habit(habit.id), field: "name")
            habit.completedDates = field(original.completedDates, ours.completedDates, theirs.completedDates, entity: .habit(habit.id), field: "completedDates")
            return habit
        }
        // Habit display order is stored in the array itself.
        let habitOrder = field(base.habits.map(\.id), local.habits.map(\.id), remote.habits.map(\.id), entity: .settings, field: "habitOrder")
        let positions = Dictionary(uniqueKeysWithValues: habitOrder.enumerated().map { ($0.element, $0.offset) })
        result.habits.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
        return result
    }

    func validate(_ snapshot: RepositorySyncSnapshot) {
        var planNames: [String: UUID] = [:]
        for plan in snapshot.plans {
            let entity = RepositorySyncEntity.plan(plan.id)
            if plan.name.isEmpty || plan.name.hasPrefix(".")
                || plan.name.contains("/") || plan.name.contains("\\") || plan.name.contains("\0")
                || plan.name.lowercased() == "settings.yaml" {
                conflict(entity, "invalidName")
            }
            let name = plan.name.precomposedStringWithCanonicalMapping.lowercased()
            if let other = planNames[name] {
                conflict(.plan(other), "nameCollision")
                conflict(entity, "nameCollision")
            }
            planNames[name] = plan.id
            if plan.statuses.isEmpty { conflict(entity, "missingStatuses") }
            var names: Set<String> = []
            for status in plan.statuses {
                if status.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !names.insert(status.name).inserted {
                    conflict(entity, "invalidStatuses")
                }
            }
        }

        var files = snapshot.tasks.map { ($0.path, RepositorySyncEntity.task($0.task.id)) }
        files += snapshot.plans.map { ("\($0.name)/plan.yaml", RepositorySyncEntity.plan($0.id)) }
        if snapshot.settings != nil { files.append(("settings.yaml", .settings)) }
        var fileOwners: [String: RepositorySyncEntity] = [:]
        for (path, entity) in files {
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            if let other = fileOwners[normalized] {
                conflict(other, "pathCollision")
                conflict(entity, "pathCollision")
            }
            fileOwners[normalized] = entity
        }
        for (path, entity) in files {
            let components = path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            for end in 1..<components.count {
                if let other = fileOwners[components.prefix(end).joined(separator: "/")] {
                    conflict(other, "pathCollision")
                    conflict(entity, "pathCollision")
                }
            }
        }

        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.task.id, $0.task) })
        for snapshotTask in snapshot.tasks {
            let task = snapshotTask.task
            let entity = RepositorySyncEntity.task(task.id)
            if snapshotTask.path.split(separator: "/").first.map(String.init) != task.plan {
                conflict(entity, "planPathMismatch")
            }
            if let plan = snapshot.plans.first(where: { $0.name == task.plan }) {
                if !plan.statuses.contains(where: { $0.name == task.status }) {
                    conflict(entity, "missingStatus")
                }
            } else {
                conflict(entity, "missingPlan")
            }
            if Set(task.bundledTaskIDs).count != task.bundledTaskIDs.count {
                conflict(entity, "invalidBundle")
            }
            for childID in task.bundledTaskIDs {
                guard let child = tasks[childID], child.id != task.id,
                      child.parentBundleID == task.id,
                      child.plan == task.plan, child.status == task.status else {
                    conflict(entity, "invalidBundle")
                    continue
                }
            }
            if let parentID = task.parentBundleID {
                guard let parent = tasks[parentID], parent.bundledTaskIDs.contains(task.id),
                      parent.plan == task.plan, parent.status == task.status else {
                    conflict(entity, "invalidBundle")
                    continue
                }
            }
            var visited: Set<UUID> = [task.id]
            var parentID = task.parentBundleID
            while let id = parentID {
                guard visited.insert(id).inserted else {
                    conflict(entity, "bundleCycle")
                    break
                }
                parentID = tasks[id]?.parentBundleID
            }
        }
        if let settings = snapshot.settings {
            let names = Set(snapshot.plans.map(\.name))
            if Set(settings.planOrder).count != settings.planOrder.count
                || !Set(settings.planOrder).isSubset(of: names) {
                conflict(.settings, "invalidPlanOrder")
            }
        }
    }
}
