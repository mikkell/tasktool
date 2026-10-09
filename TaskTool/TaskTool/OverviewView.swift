import SwiftUI
import Combine
import UniformTypeIdentifiers

private enum OverviewCalendar {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    static func dayKey(for date: Date) -> String {
        let components = calendar().dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private enum OverviewUrgency: Int {
    case overdue
    case dueToday
    case blocked
    case dueSoon
    case inProgress

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .dueToday: "Due today"
        case .blocked: "Blocked / waiting"
        case .dueSoon: "Due soon"
        case .inProgress: "In progress"
        }
    }

    var color: Color {
        switch self {
        case .overdue: .red
        case .dueToday: .orange
        case .blocked: .purple
        case .dueSoon: .blue
        case .inProgress: .green
        }
    }
}

private struct RankedOverviewTask: Identifiable {
    let task: Task
    let urgency: OverviewUrgency

    var id: UUID { task.id }
}

private struct PlanProgress: Identifiable {
    let plan: Plan
    let completed: Int
    let total: Int

    var id: UUID { plan.id }
    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
}

struct OverviewView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @State private var currentDate = Date()
    @State private var focusNote = ""
    @State private var selectedFocusTaskIDs = Set<String>()
    @State private var taskToOpen: Task?
    @State private var taskForDueDate: Task?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isOutlookEmailDropTargeted = false

    private var todayStart: Date {
        OverviewCalendar.calendar().startOfDay(for: currentDate)
    }

    private var todayKey: String {
        OverviewCalendar.dayKey(for: currentDate)
    }

    private var allPlanNames: Set<String> {
        Set(taskStore.plans.map(\.name))
    }

    private var selectedPlanNames: Set<String> {
        guard let savedNames = taskStore.settings.overviewSelectedPlanNames else {
            return allPlanNames
        }
        return Set(savedNames).intersection(allPlanNames)
    }

    private var filteredBoardTasks: [Task] {
        taskStore.tasks.filter {
            $0.parentBundleID == nil && selectedPlanNames.contains($0.plan)
        }
    }

    private var selectedArchivedTasks: [Task] {
        taskStore.archivedTasks.filter {
            $0.parentBundleID == nil && selectedPlanNames.contains($0.plan)
        }
    }

    private var openTaskCount: Int {
        filteredBoardTasks.filter { !taskStore.isDoneTask($0) }.count
    }

    private var overdueTaskCount: Int {
        filteredBoardTasks.filter { task in
            guard !taskStore.isDoneTask(task), let dueDate = task.dueDate else { return false }
            return OverviewCalendar.calendar().startOfDay(for: dueDate) < todayStart
        }.count
    }

    private var completedTodayCount: Int {
        let calendar = OverviewCalendar.calendar()
        let nextDay = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        return completedTasks().filter {
            guard let completedAt = $0.completedAt else { return false }
            return completedAt >= todayStart && completedAt < nextDay
        }.count
    }

    private var completedThisWeekCount: Int {
        guard let week = OverviewCalendar.calendar().dateInterval(of: .weekOfYear, for: currentDate) else {
            return 0
        }
        return completedTasks().filter {
            guard let completedAt = $0.completedAt else { return false }
            return completedAt >= week.start && completedAt < week.end
        }.count
    }

    private var progressByPlan: [PlanProgress] {
        taskStore.plans
            .filter { selectedPlanNames.contains($0.name) }
            .sorted { $0.order < $1.order }
            .map { plan in
                let active = filteredBoardTasks.filter { $0.plan == plan.name }
                let archived = selectedArchivedTasks.filter { $0.plan == plan.name }
                let completedActive = active.filter { taskStore.isDoneTask($0) }.count
                return PlanProgress(
                    plan: plan,
                    completed: completedActive + archived.count,
                    total: active.count + archived.count
                )
            }
    }

    private var rankedTasks: [RankedOverviewTask] {
        let calendar = OverviewCalendar.calendar()
        let lastDueSoonDay = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? todayStart

        return filteredBoardTasks.compactMap { task in
            guard !taskStore.isDoneTask(task) else { return nil }
            let dueDay = task.dueDate.map { calendar.startOfDay(for: $0) }
            let urgency: OverviewUrgency?

            if let dueDay, dueDay < todayStart {
                urgency = .overdue
            } else if dueDay == todayStart {
                urgency = .dueToday
            } else if isBlockedOrWaiting(task.status) {
                urgency = .blocked
            } else if let dueDay, dueDay <= lastDueSoonDay {
                urgency = .dueSoon
            } else if isInProgress(task.status) {
                urgency = .inProgress
            } else {
                urgency = nil
            }

            guard let urgency else { return nil }
            return RankedOverviewTask(task: task, urgency: urgency)
        }
        .sorted { lhs, rhs in
            if lhs.urgency.rawValue != rhs.urgency.rawValue {
                return lhs.urgency.rawValue < rhs.urgency.rawValue
            }
            switch (lhs.task.dueDate, rhs.task.dueDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.task.title.localizedCaseInsensitiveCompare(rhs.task.title) == .orderedAscending
            }
        }
        .prefix(5)
        .map { $0 }
    }

    private var focusTaskChoices: [Task] {
        filteredBoardTasks
            .filter { !$0.isBundle && !taskStore.isDoneTask($0) }
            .sorted {
                if $0.plan != $1.plan { return $0.plan < $1.plan }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private var selectedFocusTasks: [Task] {
        selectedFocusTaskIDs.compactMap { identifier in
            taskStore.tasks.first(where: { $0.id.uuidString == identifier })
                ?? taskStore.archivedTasks.first(where: { $0.id.uuidString == identifier })
        }
    }

    private var outlookEmailDropTarget: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop an Outlook email here")
                    .font(.headline)
                Text("TaskTool adds its subject to Inbox; sender and date are saved as notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "envelope.badge")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            isOutlookEmailDropTargeted ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isOutlookEmailDropTargeted ? Color.accentColor : Color.primary.opacity(0.1),
                    style: StrokeStyle(lineWidth: isOutlookEmailDropTargeted ? 2 : 1, dash: [6])
                )
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                outlookEmailDropTarget
                header
                metrics
                dailyFocus
                priorityTasks
                planProgressSection
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.taskToolBoardBackground)
        .onAppear(perform: refreshDailyFocus)
        .onDrop(of: outlookEmailDropTypes, isTargeted: $isOutlookEmailDropTargeted) { providers in
            if let fileProvider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) {
                _ = fileProvider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                    guard let url else {
                        DispatchQueue.main.async {
                            taskStore.showOutlookEmailDropError(
                                error?.localizedDescription ?? "Outlook didn't provide a readable email file."
                            )
                        }
                        return
                    }

                    do {
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        guard let data = try file.read(upToCount: OutlookEmailMessage.maximumMessageBytes + 1) else {
                            throw OutlookEmailDropError.invalidEmailFile
                        }
                        DispatchQueue.main.async {
                            taskStore.captureOutlookEmail(data: data)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            taskStore.showOutlookEmailDropError(
                                "TaskTool couldn't read Outlook's temporary email file: \(error.localizedDescription)"
                            )
                        }
                    }
                }
                return true
            }

            let emailTypes = outlookEmailDropTypes.dropFirst()
            guard let emailProvider = providers.first(where: { provider in
                emailTypes.contains(where: provider.hasItemConformingToTypeIdentifier)
            }),
            let emailType = emailTypes.first(where: emailProvider.hasItemConformingToTypeIdentifier) else {
                return false
            }
            _ = emailProvider.loadDataRepresentation(forTypeIdentifier: emailType) { data, error in
                DispatchQueue.main.async {
                    if let data {
                        taskStore.captureOutlookEmail(data: data)
                    } else {
                        taskStore.showOutlookEmailDropError(
                            error?.localizedDescription ?? "The dropped email couldn't be read."
                        )
                    }
                }

            }
            return true
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            let previousDay = todayKey
            currentDate = date
            if previousDay != OverviewCalendar.dayKey(for: date) {
                refreshDailyFocus()
            }
        }

        .task(id: focusNote) {
            do {
                try await _Concurrency.Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            saveDailyFocus()
        }
        .sheet(item: $taskToOpen) { task in
            if task.isBundle {
                BundleDetailView(bundle: task)
            } else {
                TaskDetailView(task: task)
            }
        }
        .sheet(item: $taskForDueDate) { task in
            OverviewDueDateSheet(task: task)
        }
        .alert("Overview Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var outlookEmailDropTypes: [String] {
        [
            UTType.fileURL.identifier,
            UTType.emailMessage.identifier,
            "com.apple.mail.email",
            "public.rfc822-message"
        ]
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Overview")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text(currentDate.formatted(date: .complete, time: .omitted))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                ForEach(taskStore.plans.sorted { $0.order < $1.order }) { plan in
                    Toggle(
                        plan.name,
                        isOn: Binding(
                            get: { selectedPlanNames.contains(plan.name) },
                            set: { setPlan(plan.name, selected: $0) }
                        )
                    )
                }
            } label: {
                Label("\(selectedPlanNames.count) of \(taskStore.plans.count) plans", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Filter Overview by plan")
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(title: "Completed", systemImage: "checkmark.circle.fill") {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(completedTodayCount)")
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    Text("today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(completedThisWeekCount)")
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    Text("this week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            metricCard(title: "Open tasks", systemImage: "circle.dashed") {
                Text("\(openTaskCount)")
                    .font(.title2.bold())
                    .contentTransition(.numericText())
            }

            metricCard(title: "Overdue", systemImage: "calendar.badge.exclamationmark") {
                Text("\(overdueTaskCount)")
                    .font(.title2.bold())
                    .foregroundStyle(overdueTaskCount > 0 ? Color.red : Color.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var dailyFocus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today's focus", systemImage: "scope")
                    .font(.title2.bold())
                Spacer()
                Menu {
                    if focusTaskChoices.isEmpty {
                        Text("No open tasks in the selected plans")
                    } else {
                        ForEach(focusTaskChoices) { task in
                            Button {
                                toggleFocusTask(task)
                            } label: {
                                Label(
                                    "\(task.title) — \(task.plan)",
                                    systemImage: selectedFocusTaskIDs.contains(task.id.uuidString)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                        }
                    }
                } label: {
                    Label("Choose tasks", systemImage: "plus")
                }
                .disabled(focusTaskChoices.isEmpty)
            }

            TextEditor(text: $focusNote)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68, maxHeight: 110)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                .accessibilityLabel("Today's focus note")

            if !selectedFocusTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(selectedFocusTasks) { task in
                        HStack(spacing: 8) {
                            Image(systemName: taskStore.archivedTasks.contains(where: { $0.id == task.id })
                                  ? "archivebox"
                                  : "circle")
                                .foregroundStyle(.secondary)
                            Text(task.title)
                                .lineLimit(1)
                            Text(task.plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                selectedFocusTaskIDs.remove(task.id.uuidString)
                                saveDailyFocus()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from today's focus")
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var priorityTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Needs attention")
                    .font(.title2.bold())
                Spacer()
                Text("Top \(rankedTasks.count) across selected plans")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if rankedTasks.isEmpty {
                ContentUnavailableView(
                    "Nothing needs attention",
                    systemImage: "checkmark.circle",
                    description: Text("No overdue, due-soon, blocked, or in-progress tasks match this plan filter.")
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rankedTasks.enumerated()), id: \.element.id) { index, item in
                        overviewTaskRow(item)
                        if index < rankedTasks.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var planProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Progress by plan")
                .font(.title2.bold())

            if progressByPlan.isEmpty {
                Text("Select one or more plans to see their progress.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(progressByPlan.enumerated()), id: \.element.id) { index, progress in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.from(string: progress.plan.color))
                                .frame(width: 9, height: 9)
                            Text(progress.plan.name)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            ProgressView(value: progress.fraction)
                                .tint(Color.from(string: progress.plan.color))
                            Text("\(progress.completed)/\(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if index < progressByPlan.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func metricCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func overviewTaskRow(_ item: RankedOverviewTask) -> some View {
        let task = item.task
        let plan = taskStore.plans.first(where: { $0.name == task.plan })
        let effectiveDueDate = task.dueDate ?? (task.isBundle
            ? taskStore.childTasks(of: task).compactMap(\.dueDate).min()
            : nil)

        return HStack(spacing: 12) {
            Button {
                taskToOpen = task
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(task.plan)
                        if let effectiveDueDate {
                            Text("·")
                            Text(effectiveDueDate, style: .date)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.urgency.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(item.urgency.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(item.urgency.color.opacity(0.1), in: Capsule())

            Menu {
                Button("Open task...") {
                    taskToOpen = task
                }
                if !task.isBundle, let doneStatus = plan?.statuses.first(where: { $0.isDoneStatus }) {
                    Button("Mark complete") {
                        updateStatus(task, to: doneStatus.name)
                    }
                    Menu("Change status") {
                        ForEach(plan?.statuses.sorted { $0.order < $1.order } ?? []) { status in
                            Button(status.name) {
                                updateStatus(task, to: status.name)
                            }
                            .disabled(status.name == task.status)
                        }
                    }
                }
                Button("Edit due date...") {
                    taskForDueDate = task
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("Quick actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func completedTasks() -> [Task] {
        filteredBoardTasks.filter { taskStore.isDoneTask($0) } + selectedArchivedTasks
    }

    private func isBlockedOrWaiting(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized.contains("blocked") || normalized.contains("waiting")
    }

    private func isInProgress(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized.contains("progress") || normalized.contains("doing")
    }

    private func setPlan(_ planName: String, selected: Bool) {
        var names = selectedPlanNames
        if selected {
            names.insert(planName)
        } else {
            names.remove(planName)
        }
        let savedNames = names == allPlanNames ? nil : names.sorted()
        updateSettings { $0.overviewSelectedPlanNames = savedNames }
    }

    private func refreshDailyFocus() {
        let dateKey = OverviewCalendar.dayKey(for: currentDate)
        guard taskStore.settings.overviewFocusDate == dateKey else {
            focusNote = ""
            selectedFocusTaskIDs = []
            updateSettings {
                $0.overviewFocusDate = dateKey
                $0.overviewFocusNote = ""
                $0.overviewFocusTaskIDs = []
            }
            return
        }
        focusNote = taskStore.settings.overviewFocusNote
        selectedFocusTaskIDs = Set(taskStore.settings.overviewFocusTaskIDs)
    }

    private func toggleFocusTask(_ task: Task) {
        let taskID = task.id.uuidString
        if selectedFocusTaskIDs.contains(taskID) {
            selectedFocusTaskIDs.remove(taskID)
        } else {
            selectedFocusTaskIDs.insert(taskID)
        }
        saveDailyFocus()
    }

    private func saveDailyFocus() {
        let dateKey = OverviewCalendar.dayKey(for: currentDate)
        updateSettings {
            $0.overviewFocusDate = dateKey
            $0.overviewFocusNote = focusNote
            $0.overviewFocusTaskIDs = selectedFocusTaskIDs.sorted()
        }
    }

    private func updateSettings(_ update: (inout Settings) -> Void) {
        let previousSettings = taskStore.settings
        var updatedSettings = previousSettings
        update(&updatedSettings)
        taskStore.settings = updatedSettings
        do {
            try taskStore.saveSettings()
        } catch {
            taskStore.settings = previousSettings
            showError("Couldn't save Overview settings: \(error.localizedDescription)")
        }
    }

    private func updateStatus(_ task: Task, to status: String) {
        var updatedTask = task
        updatedTask.status = status
        do {
            try taskStore.updateTask(updatedTask)
        } catch {
            showError("Couldn't update '\(task.title)': \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

private struct OverviewDueDateSheet: View {
    let task: Task
    @EnvironmentObject private var taskStore: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var showingError = false
    @State private var errorMessage = ""

    init(task: Task) {
        self.task = task
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Due date")
                .font(.title2.bold())

            Toggle("Set a due date", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Date", selection: $dueDate, displayedComponents: .date)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .alert("Couldn't update due date", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func save() {
        guard let liveTask = taskStore.tasks.first(where: { $0.id == task.id }) else {
            errorMessage = "This task is no longer available in an active plan."
            showingError = true
            return
        }
        var updatedTask = liveTask
        updatedTask.dueDate = hasDueDate ? dueDate : nil
        do {
            try taskStore.updateTask(updatedTask)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
