//
//  BoardFilterBar.swift
//  TaskTool
//

import SwiftUI

struct BoardFilterBar: View {
    @Binding var filter: TaskBoardFilter
    let availableTags: [String]
    let totalCount: Int
    let filteredCount: Int

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Due date filter chips
                    ForEach(DueDateFilter.allCases, id: \.self) { option in
                        let isSelected = filter.dueDateFilter == option
                        FilterChip(
                            title: option.displayName,
                            systemImage: option.symbolName,
                            isSelected: isSelected,
                            tint: option == .overdue ? .red : .accentColor
                        ) {
                            filter.dueDateFilter = isSelected ? nil : option
                        }
                    }

                    chipDivider

                    // Priority chips
                    ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                        let isSelected = filter.selectedPriorities.contains(priority)
                        FilterChip(
                            title: priority.displayName,
                            systemImage: priority.symbolName,
                            isSelected: isSelected,
                            tint: Color.from(string: priority.colorName)
                        ) {
                            if isSelected {
                                filter.selectedPriorities.remove(priority)
                            } else {
                                filter.selectedPriorities.insert(priority)
                            }
                        }
                    }

                    chipDivider

                    // Recurring & Stale Pings
                    FilterChip(
                        title: "Recurring",
                        systemImage: "repeat",
                        isSelected: filter.recurringOnly,
                        tint: .purple
                    ) {
                        filter.recurringOnly.toggle()
                    }

                    FilterChip(
                        title: "Stale Pings",
                        systemImage: "bell.badge",
                        isSelected: filter.stalePingOnly,
                        tint: .orange
                    ) {
                        filter.stalePingOnly.toggle()
                    }

                    if !availableTags.isEmpty {
                        chipDivider

                        ForEach(availableTags, id: \.self) { tag in
                            let isSelected = filter.selectedTags.contains(tag)
                            FilterChip(
                                title: "#\(tag)",
                                systemImage: nil,
                                isSelected: isSelected,
                                tint: .accentColor
                            ) {
                                if isSelected {
                                    filter.selectedTags.remove(tag)
                                } else {
                                    filter.selectedTags.insert(tag)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if filter.isActive {
                HStack(spacing: 8) {
                    Text("\(filteredCount)/\(totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Button("Clear") {
                        filter.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var chipDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 2)
    }
}

private struct FilterChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? tint.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(isSelected ? tint : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? tint.opacity(0.65) : Color.primary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
