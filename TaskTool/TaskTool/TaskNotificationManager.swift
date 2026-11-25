//
//  TaskNotificationManager.swift
//  TaskTool
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class TaskNotificationManager: ObservableObject {
    @Published var preferences: NotificationPreferences {
        didSet {
            savePreferences()
            rescheduleLatest()
        }
    }
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var scheduledCount: Int = 0

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private weak var observedStore: TaskStore?

    private enum Keys {
        static let enabled = "notifications.enabled"
        static let dueTasks = "notifications.dueTasks"
        static let reminderHour = "notifications.reminderHour"
        static let reminderMinute = "notifications.reminderMinute"
        static let stalePings = "notifications.stalePings"
        static let stalePingDays = "notifications.stalePingDays"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hasSavedDue = defaults.object(forKey: Keys.dueTasks) != nil
        let hasSavedPings = defaults.object(forKey: Keys.stalePings) != nil
        let savedHour = defaults.object(forKey: Keys.reminderHour) as? Int ?? 9
        let savedMinute = defaults.object(forKey: Keys.reminderMinute) as? Int ?? 0
        let savedDays = defaults.object(forKey: Keys.stalePingDays) as? Int ?? 3

        self.preferences = NotificationPreferences(
            isEnabled: defaults.bool(forKey: Keys.enabled),
            notifyDueTasks: hasSavedDue ? defaults.bool(forKey: Keys.dueTasks) : true,
            reminderHour: savedHour,
            reminderMinute: savedMinute,
            notifyStalePings: hasSavedPings ? defaults.bool(forKey: Keys.stalePings) : true,
            stalePingDays: max(1, savedDays)
        )
    }

    private var notificationCenter: UNUserNotificationCenter? {
        // Guard against headless test processes without a valid app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func observe(_ taskStore: TaskStore) {
        observedStore = taskStore
        cancellables.removeAll()

        Publishers.CombineLatest(taskStore.$tasks, taskStore.$plans)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] tasks, plans in
                self?.reschedule(tasks: tasks, plans: plans)
            }
            .store(in: &cancellables)

        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        guard let center = notificationCenter else { return }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            requestAuthorizationAndEnable()
        } else {
            preferences.isEnabled = false
        }
    }

    private func requestAuthorizationAndEnable() {
        guard let center = notificationCenter else {
            preferences.isEnabled = true
            return
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshAuthorizationStatus()
                self.preferences.isEnabled = granted
            }
        }
    }

    func rescheduleLatest() {
        guard let store = observedStore else { return }
        reschedule(tasks: store.tasks, plans: store.plans)
    }

    func reschedule(tasks: [Task], plans: [Plan]) {
        let specs = NotificationPlanner.buildNotifications(
            tasks: tasks,
            plans: plans,
            preferences: preferences
        )
        scheduledCount = specs.count

        guard let center = notificationCenter else { return }
        center.getPendingNotificationRequests { requests in
            let existingIDs = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(NotificationPlanner.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: existingIDs)

            for spec in specs {
                let content = UNMutableNotificationContent()
                content.title = spec.title
                content.body = spec.body
                content.sound = .default

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: spec.fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: spec.identifier, content: content, trigger: trigger)
                center.add(request)
            }
        }
    }

    func sendTestNotification() {
        guard let center = notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = "TaskTool Reminders Active"
        content.body = "You'll be notified for upcoming due dates and follow-up pings."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(NotificationPlanner.identifierPrefix)test.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    private func savePreferences() {
        defaults.set(preferences.isEnabled, forKey: Keys.enabled)
        defaults.set(preferences.notifyDueTasks, forKey: Keys.dueTasks)
        defaults.set(preferences.reminderHour, forKey: Keys.reminderHour)
        defaults.set(preferences.reminderMinute, forKey: Keys.reminderMinute)
        defaults.set(preferences.notifyStalePings, forKey: Keys.stalePings)
        defaults.set(preferences.stalePingDays, forKey: Keys.stalePingDays)
    }
}
