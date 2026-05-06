# TaskTool — Copilot Instructions

## Build & Test

All commands run from `TaskTool/` (the directory containing `TaskTool.xcodeproj`):

```bash
# Build
xcodebuild -project TaskTool.xcodeproj -scheme TaskTool -configuration Debug build

# All tests
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool -destination 'platform=macOS'

# Unit tests only
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool -destination 'platform=macOS' \
  -only-testing:TaskToolTests

# Single test class
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests

# Single test method
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests/testArchiveTasksMovesFileToArchivedSubfolder
```

## Architecture

MVVM with file-based persistence (no database). The data flow is:

```
ContentView  →  TaskStore (@MainActor ObservableObject)  →  MarkdownParser  →  File System
```

- **`TaskStore`** is the single source of truth. It owns all `@Published` state (`plans`, `tasks`, `settings`, `storageURL`) and performs every file I/O operation. Business logic lives here — not in views.
- **`MarkdownParser`** is a stateless static utility (Yams-powered) for serialising/deserialising tasks (Markdown + YAML frontmatter), plans (`plan.yaml`), and settings (`settings.yaml`).
- **`ContentView`** handles all Kanban UI, drag-drop, sheets, and alerts. No business logic.
- **Models** (`Task`, `Plan`, `Settings`) are plain `struct`s. `Plan.order` is derived from `settings.yaml` at load time and is never written to `plan.yaml`.

### File watching

`DispatchSourceFileSystemObject` monitors the storage root. It is debounced to 1.5 s to coalesce rapid events (e.g. cloud sync bursts). After any write, `markSaving()` suppresses reload for 2.5 s to prevent the watcher from re-reading a file mid-write.

### Security-scoped bookmarks

`setStorageLocation()` calls `startAccessingSecurityScopedResource()` and saves a security-scoped bookmark to `UserDefaults`. This only works in the sandboxed production app — it returns `false` in unit tests.

## Key Conventions

### File writes
- Always use `atomically: false` in `String.write(to:)`. Atomic (temp-file) writes cause conflicts with OneDrive and other cloud-sync folders.
- Always call `markSaving()` before any file write so the file watcher doesn't trigger a reload mid-operation.

### Task status
`Task.status` is a `String` that must match a `Plan.TaskStatus.name` value from the owning plan — it is **not** a fixed enum. Default plan statuses are `"To Do"`, `"In Progress"`, `"Done"`.

### File naming
- Task filenames are slugified from the title (lowercase, hyphenated). Titles that produce an empty slug (emoji-only, symbols-only) fall back to the first 8 characters of the task's UUID — this prevents creating a hidden `.md` file.
- If two tasks produce the same slug, the second gets a UUID suffix: `duplicate-task-a1b2c3d4.md`.

### Phantom plan guard
`loadAllData` only treats a subdirectory as a plan if it contains a `plan.yaml`. Stray directories (`.git`, `Archived/`, cloud-sync folders, backups) are silently skipped.

### YAML serialisation
`MarkdownParser` automatically double-quotes YAML values containing `:`, `#`, `"`, `{`, `[`, `-`, or leading/trailing spaces. Do not add manual quoting — the serialiser handles it.

### Yams date handling
Yams 5.x may deserialise ISO8601 timestamps as native Swift `Date` objects rather than `String`. All date parsing in `MarkdownParser` uses a dual-type check — `as? String` first, then `as? Date` as fallback. Follow this pattern for any new date field.

### Plan ordering
Plan display order is stored centrally in `settings.yaml` (`plan_order: [...]`). It is **not** written to individual `plan.yaml` files. `Plan.order` is populated at load time from settings.

### Cross-plan task moves
When moving a task between plans, write the destination file first, then delete the source. This ensures no data loss if the delete step fails.

## Unit Tests

The test suite has 106 tests across 7 files (`TaskToolTests/`):

| Suite | Coverage |
|---|---|
| `TaskStoreTests` | Full CRUD for plans/tasks, rename, move, archive, reload, collision guard, phantom-dir guard |
| `MarkdownParserTests` | Parse/serialize tasks/plans/settings, roundtrips, YAML quoting, Yams `Date` handling |
| `TaskCreationTests` | Task routing to correct plan folder, custom status default |
| `TaskTests` | Task model, `fileName` slug, UUID fallback for empty/emoji/special-char titles |
| `PlanTests` | Plan model, default statuses, custom statuses |
| `ColorExtensionTests` | All named colours, case-insensitivity, unknown-colour fallback to `.gray` |

### Writing new tests
- **I/O tests** → add to `TaskStoreTests` using the `setUp` pattern: create a temp directory, assign `taskStore.storageURL = tempDir` directly, then call `taskStore.loadAllData()`.
- **Never** call `setStorageLocation()` in tests — it requires a security-scoped resource that is not available outside the sandboxed app.
- **Parser tests** → add to `MarkdownParserTests`; no filesystem needed.
- **Model tests** → add to `TaskTests` or `PlanTests`.
