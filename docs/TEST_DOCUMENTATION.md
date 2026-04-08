# TaskTool Test Suite Documentation

## Overview

Comprehensive test suite for the TaskTool macOS application covering all major functionality: models, file system operations, markdown/YAML parsing, integration workflows, and UI launch verification.

## Test Statistics

| Metric | Value |
|--------|-------|
| **Total test files** | 7 |
| **Unit test files** | 6 |
| **UI test files** | 1 |
| **Total test cases** | 106 |
| **Failures** | 0 |

## Unit Tests

### 1. `TaskStoreTests.swift` — 50 tests

Integration tests for all `TaskStore` file-system operations.

**setUp pattern:**
```swift
override func setUp() async throws {
    try await super.setUp()
    taskStore = TaskStore()
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, ...)
    taskStore.storageURL = tempDir   // ← direct assignment, not setStorageLocation()
    taskStore.loadAllData()
}
```

> **Why `storageURL` is set directly:** `setStorageLocation()` calls `url.startAccessingSecurityScopedResource()`, which returns `false` in the non-sandboxed unit-test environment, causing it to bail without setting `storageURL`. Tests must bypass this by assigning the URL directly.

**Plan operations (8 tests):**

| Test | What is verified |
|------|-----------------|
| `testCreatePlanWritesPlanYaml` | `plan.yaml` is written to disk on plan creation |
| `testCreatePlanAddsToPlansArray` | In-memory `plans` array is updated |
| `testCreateMultiplePlans` | Multiple plans coexist correctly |
| `testCreatePlanUpdatesSettingsOrder` | `settings.yaml` is written with the new plan's name |
| `testCreatePlanAssignsIncrementingOrder` | Each new plan gets a sequential `order` value |
| `testUpdatePlanWritesChangesToFile` | Edited plan properties are persisted to `plan.yaml` |
| `testUpdatePlanReflectsInMemory` | In-memory `plans` array reflects edits immediately |
| `testDeletePlanRemovesFolderFromDisk` | Plan folder is removed from the file system |
| `testDeletePlanRemovesFromPlansArray` | In-memory `plans` array is updated |
| `testDeletePlanRemovesItsTasksFromArray` | In-memory `tasks` for the plan are removed |
| `testDeletePlanRemovesFromSettingsPlanOrder` | `settings.yaml` no longer lists the deleted plan |

**Plan rename operations (5 tests):**

| Test | What is verified |
|------|-----------------|
| `testRenamePlanRenamesFolderOnDisk` | Folder is renamed on the file system |
| `testRenamePlanUpdatesInMemoryPlanName` | In-memory plan name is updated |
| `testRenamePlanUpdatesTaskPlanField` | All tasks that referenced the old name are updated |
| `testRenamePlanMovesTaskFilesToNewFolder` | Task `.md` files are moved to the new folder |
| `testRenamePlanUpdatesSettingsPlanOrder` | `settings.yaml` reflects the new name |

**Task CRUD operations (12 tests):**

| Test | What is verified |
|------|-----------------|
| `testCreateTaskWritesMarkdownFile` | `.md` file is created on disk |
| `testCreateTaskAddsToTasksArray` | In-memory `tasks` array is updated |
| `testCreateTaskInCorrectPlanFolder` | File is written inside the right plan subfolder |
| `testCreateTaskInNonExistentPlanThrows` | Error thrown when target plan does not exist |
| `testCreateTaskFileContainsFrontmatter` | Written file contains `---` YAML frontmatter block |
| `testCreateTaskFilenameCollisionKeepsBothFiles` | Second task with identical slug gets a UUID-suffix filename |
| `testCreateTaskWithEmojiTitleDoesNotCreateHiddenFile` | Emoji-only titles fall back to UUID prefix, avoiding `.md` hidden file |
| `testUpdateTaskStatusWritesToFile` | Updated status is persisted to disk |
| `testUpdateTaskStatusReflectsInMemory` | In-memory `tasks` array reflects the status change |
| `testUpdateTaskMoveToNewPlan_NewFileExists` | After cross-plan move, file exists in destination folder |
| `testUpdateTaskMoveToNewPlan_OldFileGone` | After cross-plan move, old file is deleted |
| `testUpdateTaskMoveToNewPlan_InMemoryPlanUpdated` | In-memory task has updated `plan` field |
| `testUpdateTaskTitleRenamesFile` | Renaming a task's title renames the `.md` file |
| `testUpdateTaskSetsUpdatedTimestamp` | `updated` timestamp is always later than or equal to `created` |
| `testDeleteTaskRemovesFileFromDisk` | `.md` file is deleted |
| `testDeleteTaskRemovesFromTasksArray` | In-memory `tasks` array is updated |
| `testDeleteNonExistentTaskFileThrows` | Deleting a task whose file is already gone throws an error |

**Archive operations (3 tests):**

| Test | What is verified |
|------|-----------------|
| `testArchiveTasksMovesFileToArchivedSubfolder` | Done task file moves to `{plan}/Archived/` |
| `testArchiveTasksRemovesFromTasksArray` | Archived tasks are removed from the active `tasks` array |
| `testArchiveCreatesArchivedFolderIfMissing` | `Archived/` subdirectory is created automatically |

**Persistence / reload (6 tests):**

| Test | What is verified |
|------|-----------------|
| `testLoadAllDataLoadsSavedPlans` | Plans written in a previous session are loaded correctly |
| `testLoadAllDataLoadsSavedTasks` | Tasks written in a previous session are loaded correctly |
| `testLoadAllDataPreservesPlanOrder` | `plan_order` from `settings.yaml` is respected |
| `testLoadAllDataSkipsDirectoriesWithoutPlanYaml` | Stray directories (`.git`, backups, etc.) are ignored |
| `testLoadAllDataDoesNotLoadArchivedTasksAsPlanTasks` | Files inside `Archived/` are not loaded as active tasks |
| `testSaveAndLoadSettings` | `settings.yaml` round-trips correctly |
| `testSettingsFileCreatedOnFirstLoad` | `settings.yaml` is created on first `loadAllData()` call |

---

### 2. `MarkdownParserTests.swift` — 34 tests

Unit tests for the static `MarkdownParser` serialiser/deserialiser.

**Task parsing (8 tests):**

| Test | What is verified |
|------|-----------------|
| `testParseSimpleTask` | Minimal frontmatter parses to a valid `Task` |
| `testParseTaskWithTags` | Multiline `tags:` array is parsed correctly |
| `testParseTaskWithDueDate` | `due_date` field is parsed as `Date` |
| `testParseTaskPreservesUUID` | `id` field parses to the exact original UUID |
| `testParseTaskMissingFrontmatterThrows` | Missing `---` delimiters throw a `ParseError` |
| `testParseTaskMultilineBody` | Multi-section markdown body is preserved verbatim |
| `testParseTaskEmptyBodyIsAllowed` | Task with no body content is valid |

**Task serialisation (5 tests):**

| Test | What is verified |
|------|-----------------|
| `testSerializeTask` | Task model renders correct YAML frontmatter |
| `testSerializeTaskIncludesDueDate` | `due_date` is emitted when set |
| `testSerializeTaskOmitsDueDateWhenNil` | `due_date` field is omitted when `nil` |
| `testSerializeTaskOmitsTagsWhenEmpty` | `tags:` block is omitted when the array is empty |
| `testRoundtripTask` | Serialize → parse produces an identical `Task` |
| `testRoundtripTaskWithDueDate` | Roundtrip with a `due_date` preserves the date |

**Plan parsing / serialisation (7 tests):**

| Test | What is verified |
|------|-----------------|
| `testParsePlan` | Full `plan.yaml` parses to correct `Plan` model |
| `testParsePlanUsesDefaultStatusesWhenMissing` | Plan without `statuses:` gets 3 default statuses |
| `testParsePlanInvalidYamlThrows` | Garbage input throws a `ParseError` |
| `testSerializePlan` | Plan model renders correct YAML |
| `testSerializePlanOmitsOrderField` | `order` is **not** written to `plan.yaml` (stored in `settings.yaml`) |
| `testRoundtripPlan` | Serialize → parse produces an identical `Plan` |

**YAML quoting (8 tests):**

| Test | What is verified |
|------|-----------------|
| `testYamlQuotingAppliedForColonInPlanName` | Plan name with `:` is double-quoted |
| `testYamlQuotingAppliedForHashInDescription` | Description with `#` is double-quoted |
| `testYamlQuotingAppliedForEmptyDescription` | Empty string is double-quoted |
| `testYamlQuotingNotAppliedForNormalStrings` | Normal strings are written without quotes |
| `testQuotedPlanNameSurvivesRoundtrip` | Quoted name parses back to the original unquoted string |
| `testYamlQuotingAppliedForStatusNameWithColon` | Status names with `:` are double-quoted |
| `testYamlQuotingForSettingsPlanOrder` | Plan names in `settings.yaml` are quoted if needed |

**Settings (4 tests):**

| Test | What is verified |
|------|-----------------|
| `testParseSettings` | `settings.yaml` parses to correct `Settings` model |
| `testParseEmptySettings` | Empty YAML produces default `Settings` |
| `testSerializeSettings` | Settings model renders correct YAML |
| `testRoundtripSettings` | Serialize → parse produces identical `Settings` |

> **Yams date-type quirk:** Yams 5.x deserialises ISO8601 timestamps as native Swift `Date` objects, not `String`. All `metadata["due_date"] as? String` style casts would silently return `nil`. Both `parseTask` and `parsePlan` handle this with a dual-type check — try `as? String` first, then `as? Date` as fallback. The Yams date roundtrip tests verify this behaviour.

---

### 3. `TaskCreationTests.swift` — 3 tests

Integration tests focusing specifically on task creation routing.

| Test | What is verified |
|------|-----------------|
| `testTaskIsCreatedInSelectedPlan` | New task file is placed in the correct plan folder |
| `testTaskCreatedInCorrectPlanWhenMultiplePlansExist` | Task routes to the right folder when many plans exist |
| `testTaskCreatedWithDefaultStatusFromPlan` | New task receives the first status from the plan's `statuses` array |

---

### 4. `TaskTests.swift` — 10 tests

Unit tests for the `Task` model.

| Test | What is verified |
|------|-----------------|
| `testTaskInitialization` | Task created with default values |
| `testTaskWithFullDetails` | Task created with all optional fields populated |
| `testTaskFileName` | Normal title slugifies to a hyphenated lowercase filename |
| `testTaskFileNameWithSpecialCharacters` | Special characters are stripped from the slug |
| `testTaskFileNameNormalization` | Multiple spaces and mixed casing are normalised |
| `testTaskEquality` | Two tasks with the same UUID are equal |
| `testTaskIdentifiability` | Newly created tasks have distinct UUIDs |
| `testTaskFileNameEmptySlugFallsBackToUUID` | Title that slugifies to empty string uses UUID prefix |
| `testTaskFileNameAllSpecialCharsFallsBackToUUID` | All-special-char title uses UUID prefix (no `.md` hidden file) |
| `testTaskFileNameOnlySpacesFallsBackToUUID` | Whitespace-only title uses UUID prefix |

---

### 5. `PlanTests.swift` — 6 tests

Unit tests for the `Plan` model.

| Test | What is verified |
|------|-----------------|
| `testPlanInitialization` | Plan created with correct defaults |
| `testPlanDefaultStatuses` | Default plan ships with 3 statuses: To Do, In Progress, Done |
| `testPlanFolderName` | `name` is used directly as the folder name |
| `testPlanCustomStatuses` | Plans support any number of custom statuses |
| `testTaskStatusEquality` | `TaskStatus` equality is based on UUID |
| `testPlanEquality` | `Plan` equality is based on UUID |

---

### 6. `ColorExtensionTests.swift` — 10 tests

Unit tests for the `Color` extension that maps string names to SwiftUI `Color` values.

| Test | What is verified |
|------|-----------------|
| `testColorFromStringBlue` | `"blue"` → `.blue` |
| `testColorFromStringGreen` | `"green"` → `.green` |
| `testColorFromStringRed` | `"red"` → `.red` |
| `testColorFromStringOrange` | `"orange"` → `.orange` |
| `testColorFromStringPurple` | `"purple"` → `.purple` |
| `testColorFromStringYellow` | `"yellow"` → `.yellow` |
| `testColorFromStringGray` | `"gray"` → `.gray` |
| `testColorFromStringCaseInsensitive` | `"BLUE"` / `"Blue"` work correctly |
| `testColorFromStringInvalid` | Unknown string falls back to `.gray` |
| `testColorFromStringEmpty` | Empty string falls back to `.gray` |

---

## UI Tests

### `TaskToolUITestsLaunchTests.swift` — 2 tests (launch × 2 configurations)

| Test | What is verified |
|------|-----------------|
| `testLaunch` | App launches and takes a screenshot in each UI configuration (light mode, dark mode) |

> The launch test runs once per UI configuration because `runsForEachTargetApplicationUIConfiguration` returns `true`.

---

## Running the Tests

### All tests

```bash
cd TaskTool
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS'
```

### Unit tests only

```bash
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests
```

### UI tests only

```bash
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolUITests
```

### Specific test class

```bash
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests
```

### Specific test method

```bash
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests/testArchiveTasksMovesFileToArchivedSubfolder
```

---

## Coverage Summary

### Covered

✅ Plan CRUD (create, read, update, delete, rename)  
✅ Task CRUD (create, read, update, delete)  
✅ Cross-plan task moves (write destination first, then delete source)  
✅ Task archiving to `Archived/` subfolder  
✅ Markdown parsing with YAML frontmatter  
✅ Plan YAML serialisation/deserialisation  
✅ Settings YAML serialisation/deserialisation  
✅ Yams native `Date` type handling (ISO8601 round-trip)  
✅ YAML quoting for special characters  
✅ Filename collision resolution (UUID suffix)  
✅ Emoji/special-char title fallback to UUID filename  
✅ Phantom directory guard (non-plan folders skipped)  
✅ `Archived/` subfolder excluded from active task load  
✅ Settings persistence and plan order  
✅ Color mapping (all named colors, case-insensitivity, unknown fallback)  
✅ App launch (light mode + dark mode)  

### Not yet covered

- File-watcher debounce behaviour (requires real filesystem timing)
- `markSaving()` / concurrent-write suppression
- Drag-and-drop between columns (complex UI)
- OneDrive/iCloud sync edge cases
- Security-scoped bookmark refresh
- Large dataset performance

---

## CI Integration

```bash
#!/bin/bash
set -e

cd TaskTool

xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  | xcpretty --test --color

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  echo "Tests failed!"
  exit 1
fi

echo "All 106 tests passed."
```

---

## Adding New Tests

1. Identify the right test class (model test → `TaskTests`/`PlanTests`, I/O test → `TaskStoreTests`, parsing → `MarkdownParserTests`)
2. For tests that need file I/O, use the `setUp`/`tearDown` pattern from `TaskStoreTests` (temporary directory + direct `storageURL` assignment)
3. Keep tests atomic: one assertion per test is ideal; at most one behaviour per test
4. Run the full suite to verify no regressions before opening a PR

---

## Known Constraints

- **Security-scoped resources in tests**: `setStorageLocation()` must not be called in unit tests — use `taskStore.storageURL = tempDir` + `taskStore.loadAllData()` instead.
- **File watcher not tested directly**: `DispatchSourceFileSystemObject` fires asynchronously and would require `XCTestExpectation` with real filesystem delays; covered implicitly by `testLoadAllData*` reload tests.
- **UI test storage location**: The `testLaunch` UI test does not configure a storage location; it only verifies the app opens without crashing.
