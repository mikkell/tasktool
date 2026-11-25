//
//  CommandPaletteView.swift
//  TaskTool
//

import SwiftUI

enum CommandPaletteItem: Identifiable {
    case action(id: String, title: String, subtitle: String, systemImage: String, tint: Color, perform: () -> Void)
    case plan(Plan)
    case task(Task, planColor: Color)

    var id: String {
        switch self {
        case .action(let id, _, _, _, _, _): return "action-\(id)"
        case .plan(let plan): return "plan-\(plan.id.uuidString)"
        case .task(let task, _): return "task-\(task.id.uuidString)"
        }
    }

    var sectionTitle: String {
        switch self {
        case .action: return "Actions"
        case .plan: return "Plans"
        case .task: return "Tasks"
        }
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var taskStore: TaskStore
    let activePlan: Plan?
    let onDismiss: () -> Void
    let onSelectOverview: () -> Void
    let onSelectPlan: (Plan) -> Void
    let onOpenTask: (Task) -> Void
    let onCreatePlan: () -> Void
    let onCreateTask: (Plan) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var items: [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [CommandPaletteItem] = []

        // 1. Quick actions
        var actions: [CommandPaletteItem] = [
            .action(
                id: "overview",
                title: "Go to Overview",
                subtitle: "Daily focus, habits & summary",
                systemImage: "square.grid.2x2",
                tint: .accentColor,
                perform: onSelectOverview
            ),
            .action(
                id: "new-plan",
                title: "Create New Plan",
                subtitle: "Add a new Kanban board",
                systemImage: "folder.badge.plus",
                tint: .accentColor,
                perform: onCreatePlan
            ),
            .action(
                id: "reload",
                title: "Reload Tasks from Disk",
                subtitle: "Refresh all plans and task files",
                systemImage: "arrow.clockwise",
                tint: .secondary,
                perform: { taskStore.loadAllData() }
            )
        ]

        if let targetPlan = activePlan ?? taskStore.plans.sorted(by: { $0.order < $1.order }).first {
            actions.insert(
                .action(
                    id: "new-task",
                    title: "New Task in \(targetPlan.name)",
                    subtitle: "Create a task in \(targetPlan.name)",
                    systemImage: "plus.circle.fill",
                    tint: Color.from(string: targetPlan.color),
                    perform: { onCreateTask(targetPlan) }
                ),
                at: 0
            )
        }

        if taskStore.gitRemoteURL != nil {
            actions.append(
                .action(
                    id: "git-sync",
                    title: "Sync with Git",
                    subtitle: "Pull and push task repository changes",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .blue,
                    perform: {
                        _Concurrency.Task { await taskStore.syncGit() }
                    }
                )
            )
        }

        if trimmed.isEmpty {
            results.append(contentsOf: actions)
        } else {
            results.append(contentsOf: actions.filter { item in
                guard case let .action(_, title, subtitle, _, _, _) = item else { return false }
                return title.lowercased().contains(trimmed) || subtitle.lowercased().contains(trimmed)
            })
        }

        // 2. Plans
        let sortedPlans = taskStore.plans.sorted(by: { $0.order < $1.order })
        let matchingPlans = trimmed.isEmpty
            ? sortedPlans
            : sortedPlans.filter {
                $0.name.lowercased().contains(trimmed)
                    || $0.description.lowercased().contains(trimmed)
            }
        results.append(contentsOf: matchingPlans.map { .plan($0) })

        // 3. Tasks across all plans
        let planColors = Dictionary(uniqueKeysWithValues: taskStore.plans.map { ($0.name, Color.from(string: $0.color)) })
        let matchingTasks: [Task]
        if trimmed.isEmpty {
            // When query is empty, show recently updated non-done tasks first (capped to keep palette snappy)
            matchingTasks = Array(
                taskStore.tasks
                    .filter { !taskStore.isDoneTask($0) }
                    .sorted { $0.updated > $1.updated }
                    .prefix(12)
            )
        } else {
            matchingTasks = Array(
                taskStore.tasks
                    .filter { task in
                        task.title.lowercased().contains(trimmed)
                            || task.plan.lowercased().contains(trimmed)
                            || task.status.lowercased().contains(trimmed)
                            || task.body.lowercased().contains(trimmed)
                            || task.tags.contains(where: { $0.lowercased().contains(trimmed) })
                            || (task.priority?.displayName.lowercased().contains(trimmed) ?? false)
                            || task.id.uuidString.lowercased().hasPrefix(trimmed)
                    }
                    .sorted { lhs, rhs in
                        let lhsTitle = lhs.title.lowercased().contains(trimmed)
                        let rhsTitle = rhs.title.lowercased().contains(trimmed)
                        if lhsTitle != rhsTitle { return lhsTitle }
                        return lhs.updated > rhs.updated
                    }
                    .prefix(30)
            )
        }

        results.append(contentsOf: matchingTasks.map { task in
            .task(task, planColor: planColors[task.plan] ?? .blue)
        })

        return results
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    TextField("Search tasks across all plans, jump to a plan, or run an action…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .onSubmit { executeSelected() }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("⎋")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                // Results list
                if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No matching tasks, plans, or actions")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    if index == 0 || items[index - 1].sectionTitle != item.sectionTitle {
                                        Text(item.sectionTitle)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 14)
                                            .padding(.top, index == 0 ? 8 : 12)
                                            .padding(.bottom, 4)
                                    }

                                    paletteRow(item: item, isSelected: index == selectedIndex)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedIndex = index
                                            execute(item)
                                        }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: selectedIndex) { _, newIndex in
                            if items.indices.contains(newIndex) {
                                proxy.scrollTo(items[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }

                Divider()

                // Footer hints
                HStack(spacing: 16) {
                    hintLabel(keys: "↑↓", label: "Navigate")
                    hintLabel(keys: "↩", label: "Open / Run")
                    hintLabel(keys: "⎋", label: "Close")
                    Spacer()
                    Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            }
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .padding(.top, 72)
        }
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex + 1) % items.count
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    @ViewBuilder
    private func paletteRow(item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .action(_, let title, let subtitle, let systemImage, let tint, _):
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

            case .plan(let plan):
                Circle()
                    .fill(Color.from(string: plan.color))
                    .frame(width: 10, height: 10)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.name)
                        .fontWeight(.medium)
                    if !plan.description.isEmpty {
                        Text(plan.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                let count = taskStore.tasks.filter { $0.plan == plan.name && $0.parentBundleID == nil }.count
                Text("\(count) task\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .task(let task, let planColor):
                Circle()
                    .fill(planColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let priority = task.priority {
                            Text(priority.displayName)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.from(string: priority.colorName))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.from(string: priority.colorName).opacity(0.15))
                                .cornerRadius(4)
                        }
                        if task.recurrence != nil {
                            Image(systemName: "repeat")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(task.plan)
                            .font(.caption)
                            .foregroundStyle(planColor)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(task.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let dueDate = task.dueDate {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(dueDate, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if !task.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(task.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private func hintLabel(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func executeSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        execute(items[selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        onDismiss()
        switch item {
        case .action(_, _, _, _, _, let perform):
            perform()
        case .plan(let plan):
            onSelectPlan(plan)
        case .task(let task, _):
            onOpenTask(task)
        }
    }
}
