# TaskTool

A powerful, file-based task management application for macOS that stores all data as markdown and YAML files. Perfect for developers, CLI enthusiasts, and anyone who wants their task data in plain text format that's LLM-friendly and git-compatible.

![macOS](https://img.shields.io/badge/macOS-26.2+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-green.svg)
![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)

## ✨ Features

- 📊 **Kanban Board Interface** — Visual task management with drag-and-drop between customisable status columns
- 📁 **File-Based Storage** — All data stored as markdown and YAML files; no database, no lock-in
- 🔄 **Live File Watching** — Debounced auto-reload when files change externally (editor, CLI, OneDrive sync)
- 🎨 **Custom Plans & Statuses** — Color-coded plans, each with fully configurable status columns
- 🏷️ **Tagging System** — Add tags to tasks for easy search and filtering
- 📅 **Due Dates** — Optional per-task due dates with a calendar picker
- 🔍 **Drag & Drop** — Move tasks between status columns and between plans
- 📦 **Archive** — Move completed tasks to an `Archived/` subfolder with one click
- 💻 **CLI-Friendly** — All files are plain text; manipulate with `grep`, `sed`, LLMs, or any editor
- 🔗 **Obsidian Compatible** — Full YAML 1.2 frontmatter compatibility via [Yams](https://github.com/jpsim/Yams)
- ☁️ **OneDrive / cloud-folder safe** — Hardened file writes and file-watcher debouncing prevent sync conflicts

## 📋 Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Technical Architecture](#technical-architecture)
- [Data Storage Format](#data-storage-format)
- [Usage](#usage)
- [CLI Integration](#cli-integration)
- [Development](#development)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## 🚀 Installation

### Requirements

- macOS 26.2 or later
- Xcode 16.0 or later (for building from source)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/tasktool.git
cd tasktool/TaskTool

# Open in Xcode
open TaskTool.xcodeproj

# Build and run (⌘R in Xcode)
```

## 🎯 Quick Start

1. **Launch TaskTool**
2. **Choose a storage folder** — Select any folder (local drive, OneDrive, iCloud Drive, etc.)
3. **Create a plan** — Click "Create Plan" in the sidebar (e.g., "Work", "Personal")
4. **Add tasks** — Press **⌘N** or click "New Task" and start organising

Your storage folder will look like this after setup:

```
~/Documents/TaskTool/
├── settings.yaml          # Plan order and global settings
├── Work/
│   ├── plan.yaml          # Plan metadata and status columns
│   ├── update-website.md  # Task file
│   └── fix-bug.md
└── Personal/
    ├── plan.yaml
    └── grocery-shopping.md
```

## 🏗 Technical Architecture

### Technology Stack

| Layer | Technology |
|-------|-----------|
| Framework | SwiftUI (native macOS) |
| Language | Swift 5.0 |
| Architecture | MVVM |
| Data layer | File system (Markdown + YAML) |
| YAML parser | [Yams](https://github.com/jpsim/Yams) 5.4.0 |
| Concurrency | Swift `@MainActor` |
| File watching | `DispatchSourceFileSystemObject` with 1.5 s debounce |

### Project Structure

```
TaskTool/
├── TaskTool/
│   ├── TaskToolApp.swift       # App entry point and scene setup
│   ├── ContentView.swift       # Kanban UI, drag-drop, sheets, alerts
│   ├── Task.swift              # Task model + fileName slug generation
│   ├── Plan.swift              # Plan model + TaskStatus subtype
│   ├── Settings.swift          # Global settings model
│   ├── TaskStore.swift         # @MainActor state manager & file I/O
│   ├── MarkdownParser.swift    # Markdown/YAML serialization (Yams)
│   └── Assets.xcassets/
├── TaskToolTests/              # 104 unit tests
└── TaskToolUITests/            # 2 launch tests
```

### Core Components

#### Task (`Task.swift`)

```swift
struct Task: Identifiable, Codable, Hashable {
    let id: UUID          // Stable identity across file renames
    var title: String
    var plan: String      // Plan folder name
    var status: String    // Matches a Plan.TaskStatus.name
    var dueDate: Date?
    var tags: [String]
    var created: Date
    var updated: Date     // Set automatically on every save
    var body: String      // Full markdown body content
}
```

`Task.fileName` slugifies the title into a safe filesystem name. Titles that produce an empty slug (emoji-only, special-characters-only) fall back to the first 8 characters of the UUID so a hidden `.md` file is never created.

#### Plan (`Plan.swift`)

```swift
struct Plan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String        // Also the folder name on disk
    var color: String       // "blue" | "green" | "red" | "orange" | "purple" | "yellow" | "gray"
    var created: Date
    var description: String
    var statuses: [TaskStatus]   // Ordered status columns
    var order: Int               // Derived from settings.yaml, not stored in plan.yaml

    struct TaskStatus: Identifiable, Codable, Hashable {
        var id: UUID
        var name: String
        var color: String
        var order: Int
    }
}
```

#### TaskStore (`TaskStore.swift`)

The central coordinator — an `@MainActor ObservableObject` that owns all in-memory state and marshals every file operation.

| Responsibility | Detail |
|---|---|
| CRUD | `createPlan`, `updatePlan`, `deletePlan`, `renamePlan`, `createTask`, `updateTask`, `deleteTask`, `archiveDoneTasks` |
| Persistence | Reads/writes markdown and YAML on every operation; reloads on startup |
| File watching | `DispatchSourceFileSystemObject` on the storage root, debounced 1.5 s |
| Conflict prevention | `markSaving()` suppresses file-watcher reloads for 2.5 s after any write |
| Security bookmarks | Persists access to the user-selected folder across launches; auto-refreshes stale bookmarks |
| Safe task moves | Writes destination file first, then deletes source — no data loss if the second step fails |
| Collision guard | If two tasks produce the same filename a UUID suffix is appended to the second |

#### MarkdownParser (`MarkdownParser.swift`)

Static serialization/deserialisation utility powered by [Yams](https://github.com/jpsim/Yams).

Notable behaviours:
- **Yams date handling**: ISO8601 timestamps may be deserialised as native `Date` objects by Yams; the parser handles both `String` and `Date` types transparently.
- **YAML quoting**: Values containing `:`, `#`, `"`, leading/trailing spaces, `-`, `{`, or `[` are automatically double-quoted on serialisation.
- **Phantom plan guard**: `loadAllData` only treats a directory as a plan if it contains a `plan.yaml` — stray folders (`.git`, backups, `Archived/`, etc.) are silently skipped.

### Data Flow

```
┌────────────────────────┐
│      ContentView       │  SwiftUI views + drag-drop handlers
└───────────┬────────────┘
            │ @EnvironmentObject
            ▼
┌────────────────────────┐
│       TaskStore        │  @MainActor — single source of truth
│   @Published state     │  file watching · CRUD · bookmarks
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│    MarkdownParser      │  Stateless serialisation via Yams
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│      File System       │  tasks → *.md
│   (plain text files)   │  plans → plan.yaml
│                        │  settings → settings.yaml
└────────────────────────┘
```

## 💾 Data Storage Format

### Task File (Markdown + YAML frontmatter)

```markdown
---
id: 550e8400-e29b-41d4-a716-446655440000
type: task
plan: Work
status: In Progress
due_date: 2026-02-15T00:00:00Z
tags:
  - web
  - priority
created: 2026-01-22T09:47:00Z
updated: 2026-02-02T10:30:00Z
---
# Update website homepage

- [x] Design new hero section
- [ ] Implement responsive layout
- [ ] Add testimonials

## Notes
Coordinate with design team on final assets.
```

Both inline and multiline tag formats are supported:

```yaml
tags: [work, urgent, priority]   # inline (Obsidian-style)
tags:                             # multiline
  - work
  - urgent
```

### Plan File (`plan.yaml`)

```yaml
# Plan: Work
id: 728b8416-f28b-4322-a899-4a3f80dd1580
name: Work
color: blue
created: 2026-01-15T08:00:00Z
description: Work projects and deliverables
statuses:
  - id: 24bdb7d7-aca7-4c3c-b03d-509828d343e7
    name: To Do
    color: gray
    order: 0
  - id: 26b9e1c0-63f1-467d-83b0-8a90fd74d6b5
    name: In Progress
    color: blue
    order: 1
  - id: b75d72f7-994a-480e-b63a-f1fdb7da6c9f
    name: Done
    color: green
    order: 2
```

> Plan display order is managed centrally in `settings.yaml`, not in individual `plan.yaml` files.

### Settings File (`settings.yaml`)

```yaml
# TaskTool Settings
plan_order:
  - Work
  - Personal
  - Ideas
```

### File Naming

| File | Convention |
|------|-----------|
| Task | Title slugified to lowercase-hyphenated (e.g., `update-website.md`). Falls back to first 8 chars of UUID if slug is empty. |
| Plan | Always `plan.yaml` inside the plan's folder |
| Settings | Always `settings.yaml` in the storage root |

If two tasks produce the same filename, the second receives a UUID suffix: `duplicate-task-a1b2c3d4.md`.

## 📖 Usage

### Plans

| Action | How |
|--------|-----|
| Create | Sidebar → "Create Plan" |
| Edit name / colour / description | Right-click plan → "Edit…" |
| Reorder | Drag plans in the sidebar |
| Delete | Right-click → "Delete" (confirms before deleting all tasks) |
| Customise statuses | Toolbar → "Edit Statuses" |

### Tasks

| Action | How |
|--------|-----|
| Create | **⌘N**, toolbar "New Task" button, or **+** in any column header |
| Edit | Click a task card to open the detail sheet |
| Move status | Drag task card to the target column |
| Move to different plan | Drag task card to the plan name in the sidebar |
| Delete | Open task detail → "Delete Task" |
| Archive done tasks | Toolbar → "Archive Done" → moves all Done-status tasks to `{plan}/Archived/` |

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **⌘N** | New task in the selected plan |
| **⌘S** | Save task (inside the task editor) |
| **Esc** | Cancel / close current sheet |

## 💻 CLI Integration

```bash
# Navigate to your storage folder
cd ~/Documents/TaskTool

# List all plans
ls -d */

# Read a task
cat Work/update-website.md

# Create a new task from the shell
cat > Work/new-task.md << EOF
---
id: $(uuidgen | tr '[:upper:]' '[:lower:]')
type: task
plan: Work
status: To Do
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---
# New task title

Task body content
EOF

# Search all tasks
grep -r "priority" .

# Find all in-progress tasks
grep -rl "status: In Progress" .

# Update a task status in-place
sed -i '' 's/status: To Do/status: Done/' Work/update-website.md
```

### Git version control

```bash
cd ~/Documents/TaskTool
git init
git add .
git commit -m "Initial task snapshot"

# View history of a single task
git log --oneline Work/update-website.md
git diff HEAD~1 Work/update-website.md
```

## 🧪 Development

### Prerequisites

- macOS 26.2+
- Xcode 16.0+
- Swift 5.0+

### Building

```bash
xcodebuild -project TaskTool.xcodeproj \
           -scheme TaskTool \
           -configuration Debug \
           build
```

### Dependencies (Swift Package Manager)

| Package | Version | Purpose |
|---------|---------|---------|
| [Yams](https://github.com/jpsim/Yams) | 5.4.0 | YAML 1.2 parsing |

## ✅ Testing

### Running Tests

```bash
# All tests
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS'

# Unit tests only
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests

# Specific suite
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests
```

### Test Suite (106 tests, 0 failures)

| Suite | Tests | What is covered |
|-------|-------|-----------------|
| `TaskStoreTests` | 40 | Full CRUD for plans and tasks, rename, move between plans, archive, reload from disk, phantom-dir guard, filename collision guard, emoji filenames, updated-timestamp |
| `MarkdownParserTests` | 34 | Parse/serialize task/plan/settings, roundtrips, YAML quoting, Yams native `Date` handling, missing frontmatter error, empty body, multiline body |
| `TaskCreationTests` | 3 | Task routed to correct plan folder, multi-plan routing, custom status default |
| `TaskTests` | 10 | Task model properties, fileName slug, UUID fallback for empty/emoji/special-char titles |
| `PlanTests` | 6 | Plan model, default statuses, custom statuses |
| `ColorExtensionTests` | 10 | All named colours, case-insensitivity, unknown-colour default |
| `TaskToolUITests` | 2 | App launch in light mode and dark mode |
| `TaskToolTests` | 1 | Placeholder |

> **Note for contributors**: Unit tests set `taskStore.storageURL` directly rather than calling `setStorageLocation()`. This is intentional — `setStorageLocation` requires a security-scoped resource (only valid in the sandboxed production app).

## 🔧 Troubleshooting

### Files not loading
- Ensure the storage folder has read/write permissions.
- Each plan folder must contain a `plan.yaml` — folders without one are skipped.
- Confirm `settings.yaml` exists in the root of the storage folder (it is created automatically on first launch).

### Changes not appearing after external edits
- The file watcher monitors only the root storage directory. Wait ~2 s after saving externally for the debounced reload to fire.
- Files must have a `.md` extension — other extensions are ignored.
- Validate YAML frontmatter syntax at [yamllint.com](http://www.yamllint.com/).

### Using TaskTool with OneDrive or other cloud folders

TaskTool is designed to work safely with cloud-synced folders:

- **No atomic/temp-file writes** — files are written directly to avoid conflicts when OneDrive has the target file locked during upload.
- **`isSaving` guard (2.5 s)** — suppresses file-watcher reloads after any write, giving OneDrive time to finish syncing before the app re-reads the folder.
- **Debounced watcher (1.5 s)** — rapid sync events are coalesced into a single reload, preventing UI flicker.
- **Safe task moves** — when moving a task between plans the destination file is written first; the source is only deleted after a successful write.

If tasks revert after a status change on a very slow connection, the OneDrive upload may be taking longer than the 2.5 s guard window. This is rare and will self-correct on the next file-system event.

### Plan name collisions
Plan names must be unique (case-insensitive). The app prevents duplicates when creating or renaming a plan.

### YAML special characters
Values containing `:`, `#`, `"`, or leading/trailing spaces are automatically quoted by the serialiser. You do not need to quote them manually when editing files in a text editor.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Add unit tests for new functionality
4. Ensure all 106 tests pass
5. Commit with a descriptive message
6. Open a Pull Request

### Code style guidelines
- Follow Swift API Design Guidelines
- Keep business logic in `TaskStore`, UI logic in views (MVVM)
- Call `markSaving()` before every file write so the watcher doesn't reload mid-operation
- Use `atomically: false` for all `String.write(to:)` calls (required for cloud-folder compatibility)
- Add `@testable import TaskTool` and write unit tests for new model or store methods

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Yams](https://github.com/jpsim/Yams) — YAML parser for Swift
- [Obsidian](https://obsidian.md) — Inspiration for the YAML frontmatter format

---

*Made with ❤️ and SwiftUI*
