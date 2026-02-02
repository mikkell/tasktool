# TaskTool

A powerful, file-based task management application for macOS that stores all data as markdown and YAML files. Perfect for developers, CLI enthusiasts, and anyone who wants their task data in plain text format that's LLM-friendly and git-compatible.

![macOS](https://img.shields.io/badge/macOS-15.2+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-green.svg)
![License](https://img.shields.io/badge/license-MIT-lightgrey.svg)

## ✨ Features

- 📊 **Kanban Board Interface** - Visual task management with customizable status columns
- 📁 **File-Based Storage** - All data stored as markdown and YAML files
- 🔄 **Live File Watching** - Auto-reload when files change externally
- 🎨 **Custom Plans & Statuses** - Organize tasks with color-coded plans and flexible status columns
- 🏷️ **Tagging System** - Tag tasks for better organization and filtering
- 📅 **Due Dates** - Track deadlines with optional due date support
- 🔍 **Drag & Drop** - Intuitive task movement between statuses and plans
- 💻 **CLI-Friendly** - Direct file access for terminal tools and LLMs
- 🔗 **Obsidian Compatible** - Full YAML frontmatter compatibility
- 🚀 **No Database** - No sync issues, no lock-in, just plain text files

## 📋 Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Technical Architecture](#technical-architecture)
- [Data Storage Format](#data-storage-format)
- [Usage](#usage)
- [CLI Integration](#cli-integration)
- [Development](#development)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

## 🚀 Installation

### Requirements

- macOS 15.2 or later
- Xcode 16.0 or later (for building from source)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/tasktool.git
cd tasktool/TaskTool

# Open in Xcode
open TaskTool.xcodeproj

# Build and run
# Press ⌘R in Xcode
```

## 🎯 Quick Start

1. **Launch TaskTool**
2. **Choose a storage folder** - Select where you want your task files stored
3. **Create a plan** - Click "New Plan" in the sidebar (e.g., "Work", "Personal")
4. **Add tasks** - Click "New Task" and start organizing!

Your data structure will look like this:
```
~/Documents/TaskTool/
├── settings.yaml
├── Work/
│   ├── plan.yaml
│   └── update-website.md
└── Personal/
    ├── plan.yaml
    └── grocery-shopping.md
```

## 🏗 Technical Architecture

### Technology Stack

- **Framework**: SwiftUI (native macOS)
- **Language**: Swift 5.0
- **Architecture**: MVVM (Model-View-ViewModel)
- **Data Layer**: File system (Markdown + YAML)
- **YAML Parser**: [Yams](https://github.com/jpsim/Yams) 5.1.3+
- **Concurrency**: Swift Concurrency (@MainActor)
- **File Watching**: DispatchSourceFileSystemObject

### Project Structure

```
TaskTool/
├── TaskTool/
│   ├── TaskToolApp.swift          # App entry point
│   ├── ContentView.swift          # Main Kanban UI
│   ├── Models/
│   │   ├── Task.swift             # Task model
│   │   ├── Plan.swift             # Plan model
│   │   └── Settings.swift         # Settings model
│   ├── Services/
│   │   ├── TaskStore.swift        # State management & file I/O
│   │   └── MarkdownParser.swift   # Markdown/YAML serialization
│   └── Assets.xcassets/
├── TaskToolTests/                 # Unit tests
└── TaskToolUITests/               # UI tests
```

### Core Components

#### 1. Models

**Task** (`Task.swift`)
```swift
struct Task: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var plan: String
    var status: String          // Flexible string-based status
    var dueDate: Date?
    var tags: [String]
    var created: Date
    var updated: Date
    var body: String            // Markdown body content
}
```

**Plan** (`Plan.swift`)
```swift
struct Plan: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var created: Date
    var description: String
    var statuses: [TaskStatus]  // Custom status columns
    var order: Int              // Display order (from settings.yaml)
    
    struct TaskStatus {
        var id: UUID
        var name: String
        var color: String
        var order: Int
    }
}
```

**Settings** (`Settings.swift`)
```swift
struct Settings: Codable {
    var planOrder: [String]     // Plan display order
}
```

#### 2. TaskStore (State Management)

The `TaskStore` is the central coordinator, implemented as an `@MainActor ObservableObject`:

```swift
@MainActor
class TaskStore: ObservableObject {
    @Published var plans: [Plan]
    @Published var tasks: [Task]
    @Published var storageURL: URL?
    @Published var settings: Settings
    
    // Core responsibilities:
    // 1. Load/save tasks, plans, and settings from/to files
    // 2. Watch file system for external changes
    // 3. Provide CRUD operations
    // 4. Maintain in-memory cache
    // 5. Handle security-scoped bookmarks
}
```

**Key Features:**
- **File Watching**: Monitors storage folder using `DispatchSourceFileSystemObject`
- **Auto-reload**: Detects external file changes and refreshes UI
- **Security-Scoped Resources**: Maintains sandboxed access to user-selected folder
- **Conflict Prevention**: Prevents reload during save operations

#### 3. MarkdownParser (Serialization)

Handles all file I/O and format conversion using the Yams library:

```swift
struct MarkdownParser {
    // Task parsing with YAML frontmatter
    static func parseTask(from: String, plan: String) throws -> Task
    static func serializeTask(_ task: Task) -> String
    
    // Plan parsing (pure YAML)
    static func parsePlan(from: String, name: String) throws -> Plan
    static func serializePlan(_ plan: Plan) -> String
    
    // Settings parsing (pure YAML)
    static func parseSettings(from: String) throws -> Settings
    static func serializeSettings(_ settings: Settings) -> String
}
```

**YAML Frontmatter Parsing:**
- Uses [Yams](https://github.com/jpsim/Yams) for robust YAML 1.2 parsing
- Supports inline arrays: `tags: [work, urgent]`
- Supports multiline arrays
- Handles special characters, quotes, and edge cases
- Full Obsidian compatibility

### Data Flow

```
┌─────────────────┐
│   ContentView   │  SwiftUI Views
└────────┬────────┘
         │ @EnvironmentObject
         ▼
┌─────────────────┐
│   TaskStore     │  State Management
│  (@MainActor)   │  - Published properties
└────────┬────────┘  - File watching
         │
         ▼
┌─────────────────┐
│ MarkdownParser  │  Serialization
│     (Yams)      │  - Parse/serialize
└────────┬────────┘  - YAML frontmatter
         │
         ▼
┌─────────────────┐
│  File System    │  Storage
│  (Markdown +    │  - Tasks: *.md
│   YAML files)   │  - Plans: plan.yaml
└─────────────────┘  - Settings: settings.yaml
```

### Concurrency Model

- **Main Actor**: All UI updates and file operations run on `@MainActor`
- **Thread Safety**: Published properties ensure UI consistency
- **File Watching**: Background file system events dispatch to main queue
- **No Race Conditions**: Single-threaded state management

## 💾 Data Storage Format

### Folder Structure

```
storage_folder/
├── settings.yaml              # Global settings
├── Work/                      # Plan folder
│   ├── plan.yaml              # Plan metadata
│   ├── task-1.md              # Task file
│   ├── task-2.md
│   └── ...
├── Personal/
│   ├── plan.yaml
│   └── ...
└── Ideas/
    ├── plan.yaml
    └── ...
```

### Task File Format (Markdown with YAML Frontmatter)

**File**: `update-website.md`

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

**Supported Frontmatter Formats:**

```yaml
# Inline arrays (Obsidian-style)
tags: [work, urgent, priority]

# Multiline arrays
tags:
  - work
  - urgent
  - priority

# Special characters (quoted)
title: "Meeting: Q1 Planning"
description: "R&D: Research & Development"

# Multiple data types
completed: false
priority: 1
active: true
```

### Plan File Format (Pure YAML)

**File**: `plan.yaml`

```yaml
# Plan: Work
id: 728b8416-f28b-4322-a899-4a3f80dd1580
name: Work
color: blue
created: 2026-01-15T08:00:00Z
description: Tasks related to work projects
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

### Settings File Format (Pure YAML)

**File**: `settings.yaml`

```yaml
# TaskTool Settings
plan_order:
  - Work
  - Personal
  - Ideas
```

### File Naming Convention

- **Tasks**: Slugified from title (e.g., "Update Website" → `update-website.md`)
- **Plans**: Always `plan.yaml` in plan folder
- **Settings**: Always `settings.yaml` in root
- **UUID Tracking**: Files can be renamed; UUIDs in frontmatter maintain identity

## 📖 Usage

### Creating Plans

1. Click "New Plan" button
2. Enter plan name and choose color
3. (Optional) Customize status columns
4. Plan folder is created automatically

### Managing Tasks

**Create Task:**
1. Select a plan
2. Click "New Task"
3. Enter title and details
4. Task file is created: `{plan-folder}/{slugified-title}.md`

**Move Task:**
- Drag and drop between status columns
- Drag to different plan in sidebar
- Status and plan fields update automatically

**Edit Task:**
- Click task card to edit in UI
- Or edit markdown file directly in your favorite editor

**Tag Tasks:**
- Add tags in UI or frontmatter
- Support for inline arrays: `tags: [tag1, tag2]`

### Customizing Status Columns

Each plan can have custom status columns:

1. Edit plan
2. Add/remove/reorder statuses
3. Choose colors for each status
4. Tasks automatically move to new statuses

## 💻 CLI Integration

### Direct File Access

All task operations can be performed via CLI:

```bash
# Navigate to storage folder
cd ~/Documents/TaskTool

# List all plans
ls -d */

# View all tasks in a plan
ls Work/

# Read a task
cat Work/update-website.md

# Create a new task
cat > Work/new-task.md << 'EOF'
---
id: $(uuidgen)
type: task
plan: Work
status: To Do
created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---
# New task title

Task body content
EOF

# Search across all tasks
grep -r "priority" .

# Find tasks by tag
grep -r "tags:" . | grep "urgent"

# List tasks by status
grep -r "status: In Progress" .
```

### LLM Integration

The markdown + YAML format is perfect for LLM interaction:

```bash
# Let an LLM read all tasks
cat Work/*.md | llm "Summarize my work tasks"

# Create tasks via LLM
llm "Create 3 tasks for building a website" | \
  process_and_save_to_tasktool.sh

# Update task status
sed -i '' 's/status: To Do/status: Done/' Work/task.md
```

### Git Integration

Version control your tasks:

```bash
cd ~/Documents/TaskTool
git init
git add .
git commit -m "Initial task snapshot"

# Track changes over time
git log --oneline
git diff HEAD~1 Work/important-task.md
```

## 🧪 Development

### Prerequisites

- macOS 15.2+
- Xcode 16.0+
- Swift 5.0+

### Building

```bash
cd TaskTool
open TaskTool.xcodeproj

# Or via command line
xcodebuild -project TaskTool.xcodeproj \
           -scheme TaskTool \
           -configuration Debug \
           build
```

### Dependencies

TaskTool uses Swift Package Manager for dependencies:

- **Yams** (5.1.3+): YAML parsing library
  - Repository: https://github.com/jpsim/Yams
  - Purpose: Robust YAML frontmatter parsing

To update dependencies:
```bash
# In Xcode: File > Packages > Update to Latest Package Versions
```

### Project Configuration

**Minimum Deployment**: macOS 15.2
**Swift Language Version**: 5.0
**Capabilities Required**:
- File access (user-selected folder)
- Security-scoped bookmarks

## ✅ Testing

### Running Tests

```bash
# Run all tests
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS'

# Run specific test suite
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests/MarkdownParserTests
```

### Test Coverage

**Unit Tests** (`TaskToolTests/`):
- ✅ MarkdownParserTests - YAML parsing/serialization
- ✅ TaskTests - Task model validation
- ✅ PlanTests - Plan model validation
- ✅ ColorExtensionTests - Color parsing
- ✅ TaskStoreTests - State management

**UI Tests** (`TaskToolUITests/`):
- ✅ Launch tests
- ✅ Basic navigation tests

### Manual Testing

Test files are provided in `test_folder/`:
- `meeting-q1-planning.md` - Title with colon
- `inline-tags-test.md` - Inline array format
- `yams-edge-cases-demo.md` - Comprehensive edge cases

## 🔧 Troubleshooting

### Files not loading
- Ensure storage folder has read/write permissions
- Check that `settings.yaml` exists in root
- Verify `plan.yaml` exists in each plan folder

### Changes not appearing
- File watcher may need restart (close/reopen folder)
- Check for YAML syntax errors in frontmatter
- Ensure file names end with `.md` for tasks

### YAML parsing errors
- Validate YAML syntax at [yamllint.com](http://www.yamllint.com/)
- Check for proper indentation (2 spaces)
- Quote strings with special characters

## 🗺 Roadmap

- [ ] Search and filter functionality
- [ ] Task dependencies
- [ ] Recurring tasks
- [ ] Export/import (JSON, CSV)
- [ ] Custom task templates
- [ ] Task archiving
- [ ] Statistics and insights
- [ ] iCloud sync option
- [ ] iOS companion app

## 🤝 Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftUI best practices
- Maintain MVVM architecture
- Add unit tests for new features
- Update documentation

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Yams](https://github.com/jpsim/Yams) - YAML parser for Swift
- [Obsidian](https://obsidian.md) - Inspiration for YAML frontmatter format
- SwiftUI community for excellent resources

## 📧 Contact

For questions, issues, or suggestions:
- Open an issue on GitHub
- Email: [your-email@example.com]

---

**Made with ❤️ and SwiftUI**

