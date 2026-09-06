# TaskTool - Task Management for macOS

## Project Overview
This is a Task Management project for a macOS SwiftUI-based app, where users can manage all of their tasks and plans in a Kanban-style board view. All data is stored as markdown files (tasks) and YAML files (settings and plans) in a user-selected folder, making it perfect for CLI access and LLM interaction.

## Technical Stack
- **Platform**: macOS 26.2+
- **Language**: Swift 5.0
- **Framework**: SwiftUI
- **Data Persistence**: Markdown files for tasks, YAML files for settings and plans
- **Architecture**: MVVM pattern with file-based storage
- **CLI**: Command-line interface enabled via direct file access

## Project Structure
```
TaskTool/
├── TaskTool.xcodeproj       # Xcode project file
├── TaskTool/                # Main app source
│   ├── TaskToolApp.swift    # App entry point
│   ├── ContentView.swift    # Main UI with Kanban board
│   ├── Task.swift           # Task model
│   ├── Plan.swift           # Plan model
│   ├── Settings.swift       # Settings model
│   ├── TaskStore.swift      # File system manager & state
│   ├── MarkdownParser.swift # Markdown/YAML serialization/deserialization
│   └── Assets.xcassets/     # App icons and assets
├── TaskToolTests/           # Unit tests
└── TaskToolUITests/         # UI tests
```

## Data Model & Storage

### Storage Format
- **Tasks**: Markdown files with YAML frontmatter
- **Plans**: Pure YAML files (plan.yaml)
- **Settings**: Pure YAML file (settings.yaml) in root directory

This approach provides:
- LLM-friendly format (markdown + YAML)
- Human-readable and editable in any text editor
- Git-compatible for version control
- Direct CLI access without special tools
- No database sync issues

### Folder Structure
```
~/Documents/TaskTool/  (or user-chosen location)
├── settings.yaml              # Global settings
├── Work/
│   ├── plan.yaml              # Plan metadata (YAML)
│   ├── update-sales-page.md   # Task file
│   ├── design-new-feature.md  # Task file
│   └── fix-bug-123.md
├── Personal/
│   ├── plan.yaml
│   ├── grocery-shopping.md
│   └── call-dentist.md
```

### Task File Format
```markdown
---
id: 550e8400-e29b-41d4-a716-446655440000
type: task
plan: Work
status: in-progress
due_date: 2026-01-25T00:00:00Z
tags:
  - sales
  - course-launch
created: 2026-01-22T09:47:00Z
updated: 2026-01-22T10:30:00Z
---
# Update sales page for the new course

- [ ] Draft new copy for the features section
- [x] Find new testimonials
- [ ] Update pricing table

## Notes
Need to coordinate with design team on the new layout.
```

### Settings File Format (settings.yaml)
```yaml
# TaskTool Settings
plan_order:
  - Work
  - Personal
  - Ideas
available_tags:
  - bug
  - auth
  - sales
```

### Plan File Format (plan.yaml)
```yaml
# Plan: Work
id: plan-work-2026
name: Work
color: blue
created: 2026-01-15T08:00:00Z
description: Tasks related to work projects and deliverables
statuses:
  - id: status-todo-uuid
    name: To Do
    color: gray
    order: 0
  - id: status-inprogress-uuid
    name: In Progress
    color: blue
    order: 1
  - id: status-done-uuid
    name: Done
    color: green
    order: 2
```

**Note**: Plan ordering is managed centrally in `settings.yaml`, not in individual `plan.yaml` files.

## Key Features
- **Kanban board view** - Three columns: To Do, In Progress, Done
- **Plan-based organization** - Tasks grouped by plans
- **Markdown-based storage** - Direct file system access
- **User-selected storage location** - Choose where your data lives
- **File watching** - Auto-reload when files change externally
- **CLI-friendly** - LLMs can read/write task files directly
- **SwiftUI-native macOS interface**

## Models

### Task Model
- `id: UUID` - Unique identifier
- `title: String` - Task title
- `plan: String` - Plan name
- `status: TaskStatus` - todo, in-progress, done
- `dueDate: Date?` - Optional due date
- `tags: [String]` - Array of tags
- `created: Date` - Creation timestamp
- `updated: Date` - Last update timestamp
- `body: String` - Markdown body content (subtasks, notes)

### Plan Model
- `id: UUID` - Unique identifier
- `name: String` - Plan name (also folder name)
- `color: String` - UI color identifier
- `created: Date` - Creation timestamp
- `description: String` - Plan description
- `statuses: [TaskStatus]` - Custom status columns
- `order: Int` - Display order in sidebar (tracked in settings.yaml)

### Settings Model
- `planOrder: [String]` - Array of plan names in display order
- `availableTags: [String]` - Global registry of tags, auto-populated when new tags are used on tasks, reusable across all tasks

## Architecture Components

### TaskStore
`@MainActor` ObservableObject that:
- Manages in-memory cache of tasks, plans, and settings
- Handles file I/O operations
- Watches storage folder for external changes
- Provides CRUD operations for tasks and plans
- Reads/writes settings.yaml for global configuration

### MarkdownParser
Static utility for:
- Parsing markdown files with YAML frontmatter (tasks)
- Parsing pure YAML files (plans, settings)
- Serializing Task/Plan/Settings models to markdown/YAML
- Extracting titles and body content
- Handling frontmatter metadata

### File Watching
Uses `DispatchSourceFileSystemObject` to monitor the storage folder and automatically reload data when files change externally (e.g., via CLI or text editor).

## Development Guidelines
- Use SwiftUI best practices for macOS
- Maintain markdown compatibility for CLI/LLM access
- Keep models clean and focused (separate Task, Plan entities)
- All dates use ISO8601 format for consistency
- File names are slugified from titles
- UUIDs in frontmatter handle file renames
- Always update `updated` timestamp on task modifications
- Validate markdown format on parse
- Handle file system errors gracefully

## CLI Usage
Tasks can be manipulated directly via:
- Text editors (VS Code, vim, etc.)
- Standard CLI tools (`cat`, `grep`, `find`, etc.)
- LLMs reading/writing markdown files
- Git for version control and history

Example CLI operations:
```bash
# View all tasks in a plan
ls ~/Documents/TaskTool/Work/

# Read a task
cat ~/Documents/TaskTool/Work/update-sales-page.md

# Create a new task (LLM or manual)
echo "---
id: $(uuidgen)
type: task
plan: Work
status: todo
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---
# New task title

Task body content
" > ~/Documents/TaskTool/Work/new-task.md

# Search across all tasks
grep -r "sales" ~/Documents/TaskTool/
``` 