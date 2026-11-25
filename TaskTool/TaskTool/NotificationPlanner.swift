//
//  NotificationPlanner.swift
//  TaskTool
//

import Foundation

struct NotificationPreferences: Equatable {
    var isEnabled: Bool = false
    var notifyDueTasks: Bool = true
    var reminderHour: Int = 9
    var reminderMinute: Int = 0
    var notifyStalePings: Bool = true
    var stalePingDays: Int = 3
}

struct ScheduledNotificationSpec: Equatable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
}

enum NotificationPlanner {
    static let identifierPrefix = "tasktool."
    static let maxScheduledCount = 60

    static func buildNotifications(
        tasks: [Task],
        plans: [Plan],
        preferences: NotificationPreferences,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ScheduledNotificationSpec] {
        guard preferences.isEnabled else { return [] }

        let doneStatusesByPlan: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: plans.map { plan in
                (plan.name, Set(plan.statuses.filter(\.isDoneStatus).map(\.name)))
            }
        )

        let horizon = calendar.date(byAdding: .day, value: 60, to: now) ?? now
        var specs: [ScheduledNotificationSpec] = []

        for task in tasks {
            let isDone = doneStatusesByPlan[task.plan]?.contains(task.status) ?? false
            guard !isDone else { continue }

            if preferences.notifyDueTasks, let dueDate = task.dueDate {
                if let fireDate = reminderDate(
                    onDayOf: dueDate,
                    hour: preferences.reminderHour,
                    minute: preferences.reminderMinute,
                    calendar: calendar
                ), fireDate > now, fireDate <= horizon {
                    var parts: [String] = []
                    if let priority = task.priority {
                        parts.append("\(priority.displayName) priority")
                    }
                    parts.append(task.plan)
                    parts.append(task.status)

                    specs.append(ScheduledNotificationSpec(
                        identifier: "\(identifierPrefix)due.\(task.id.uuidString)",
                        title: "Due Today: \(task.title)",
                        body: parts.joined(separator: " · "),
                        fireDate: fireDate
                    ))
                }
            }

            if preferences.notifyStalePings, let lastPing = task.lastPingAt {
                let days = max(1, preferences.stalePingDays)
                if let targetDay = calendar.date(byAdding: .day, value: days, to: lastPing),
                   let fireDate = reminderDate(
                    onDayOf: targetDay,
                    hour: preferences.reminderHour,
                    minute: preferences.reminderMinute,
                    calendar: calendar
                   ),
                   fireDate > now, fireDate <= horizon {
                    specs.append(ScheduledNotificationSpec(
                        identifier: "\(identifierPrefix)ping.\(task.id.uuidString)",
                        title: "Follow-up Reminder: \(task.title)",
                        body: "Last pinged \(days) day\(days == 1 ? "" : "s") ago in \(task.plan)",
                        fireDate: fireDate
                    ))
                }
            }
        }

        return Array(
            specs
                .sorted { lhs, rhs in
                    if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
                    return lhs.identifier < rhs.identifier
                }
                .prefix(maxScheduledCount)
        )
    }

    private static func reminderDate(
        onDayOf date: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)
        components.second = 0
        return calendar.date(from: components)
    }
}
