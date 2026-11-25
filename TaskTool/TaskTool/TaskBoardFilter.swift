//
//  TaskBoardFilter.swift
//  TaskTool
//

import Foundation

enum DueDateFilter: String, CaseIterable, Hashable {
    case overdue
    case dueToday
    case dueThisWeek
    case noDueDate

    var displayName: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueToday: return "Due Today"
        case .dueThisWeek: return "Due This Week"
        case .noDueDate: return "No Due Date"
        }
    }

    var symbolName: String {
        switch self {
        case .overdue: return "calendar.badge.exclamationmark"
        case .dueToday: return "calendar.badge.clock"
        case .dueThisWeek: return "calendar"
        case .noDueDate: return "calendar.badge.minus"
        }
    }
}

struct TaskBoardFilter: Equatable {
    var selectedTags: Set<String> = []
    var selectedPriorities: Set<TaskPriority> = []
    var dueDateFilter: DueDateFilter? = nil
    var recurringOnly: Bool = false
    var stalePingOnly: Bool = false

    var isActive: Bool {
        !selectedTags.isEmpty
            || !selectedPriorities.isEmpty
            || dueDateFilter != nil
            || recurringOnly
            || stalePingOnly
    }

    var activeFilterCount: Int {
        selectedTags.count
            + selectedPriorities.count
            + (dueDateFilter != nil ? 1 : 0)
            + (recurringOnly ? 1 : 0)
            + (stalePingOnly ? 1 : 0)
    }

    mutating func clear() {
        selectedTags.removeAll()
        selectedPriorities.removeAll()
        dueDateFilter = nil
        recurringOnly = false
        stalePingOnly = false
    }

    func matches(
        _ task: Task,
        searchText: String = "",
        effectiveDueDate: Date?,
        isDone: Bool,
        now: Date = Date(),
        stalePingDays: Int = 3,
        calendar: Calendar = .current
    ) -> Bool {
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            let matchesSearch = task.title.lowercased().contains(query)
                || task.body.lowercased().contains(query)
                || task.tags.contains(where: { $0.lowercased().contains(query) })
            if !matchesSearch { return false }
        }

        if !selectedTags.isEmpty {
            let taskTagsLower = Set(task.tags.map { $0.lowercased() })
            for requiredTag in selectedTags {
                if !taskTagsLower.contains(requiredTag.lowercased()) {
                    return false
                }
            }
        }

        if !selectedPriorities.isEmpty {
            guard let priority = task.priority, selectedPriorities.contains(priority) else {
                return false
            }
        }

        if recurringOnly && task.recurrence == nil {
            return false
        }

        if stalePingOnly {
            guard !isDone, let lastPing = task.lastPingAt else { return false }
            let cutoff = calendar.date(byAdding: .day, value: -max(1, stalePingDays), to: now) ?? now
            if lastPing > cutoff { return false }
        }

        if let dueDateFilter {
            let startOfToday = calendar.startOfDay(for: now)
            switch dueDateFilter {
            case .overdue:
                guard !isDone, let due = effectiveDueDate else { return false }
                if calendar.startOfDay(for: due) >= startOfToday { return false }
            case .dueToday:
                guard let due = effectiveDueDate else { return false }
                if !calendar.isDate(due, inSameDayAs: now) { return false }
            case .dueThisWeek:
                guard let due = effectiveDueDate else { return false }
                let dueDay = calendar.startOfDay(for: due)
                let weekEnd = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
                if dueDay < startOfToday || dueDay >= weekEnd { return false }
            case .noDueDate:
                if effectiveDueDate != nil { return false }
            }
        }

        return true
    }
}
