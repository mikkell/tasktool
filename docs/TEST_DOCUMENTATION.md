# TaskTool Test Suite Documentation

## Overview
Comprehensive test suite for the TaskTool macOS app covering all major functionality including models, file operations, parsing, and UI workflows.

## Test Statistics
- **Total Test Files**: 7
- **Unit Test Files**: 6
- **UI Test Files**: 1
- **Estimated Test Cases**: 40+
- **Test Coverage Areas**: Models, Parsing, Storage, UI, Integration

## Unit Tests

### 1. PlanTests.swift
Tests for the Plan model and related functionality.

**Test Cases:**
- `testPlanInitialization()` - Verifies plan creation with default values
- `testPlanDefaultStatuses()` - Validates the three default statuses (To Do, In Progress, Done)
- `testPlanFolderName()` - Checks folder name generation
- `testPlanCustomStatuses()` - Tests custom status configurations
- `testTaskStatusEquality()` - Validates status comparison
- `testPlanEquality()` - Tests plan equality based on ID

### 2. TaskTests.swift
Tests for the Task model and properties.

**Test Cases:**
- `testTaskInitialization()` - Basic task creation
- `testTaskWithFullDetails()` - Task with all optional fields
- `testTaskFileName()` - File name generation from title
- `testTaskFileNameWithSpecialCharacters()` - File name sanitization
- `testTaskFileNameNormalization()` - Handles multiple spaces and special chars
- `testTaskEquality()` - Task comparison based on ID
- `testTaskIdentifiability()` - Unique ID generation

### 3. MarkdownParserTests.swift
Tests for markdown parsing and serialization.

**Test Cases:**
- `testParseSimpleTask()` - Parse basic task from markdown
- `testParseTaskWithTags()` - Parse tasks with tag arrays
- `testParseTaskWithDueDate()` - Parse tasks with due dates
- `testSerializeTask()` - Convert Task model to markdown
- `testParsePlan()` - Parse plan from markdown with statuses
- `testSerializePlan()` - Convert Plan model to markdown

### 4. TaskStoreTests.swift
Comprehensive tests for file system operations and data management.

**Test Cases:**
- `testCreatePlan()` - Create plan folder and file
- `testUpdatePlan()` - Update existing plan metadata
- `testDeletePlan()` - Remove plan and all tasks
- `testRenamePlan()` - Rename plan folder and update tasks
- `testCreateTask()` - Create task file in plan folder
- `testUpdateTask()` - Modify existing task
- `testDeleteTask()` - Remove task file
- `testMoveTaskBetweenPlans()` - Move task file between folders
- `testArchiveDoneTasks()` - Archive completed tasks to subfolder
- `testLoadAllData()` - Load plans and tasks from disk
- `testPlanOrderAssignment()` - Verify sequential order assignment

**Features Tested:**
- Temporary directory setup/teardown for isolated testing
- File creation and validation
- Folder operations (create, rename, delete)
- Data persistence verification
- Archive folder creation
- In-memory state management

### 5. ColorExtensionTests.swift
Tests for the Color extension utility.

**Test Cases:**
- `testColorFromStringBlue()` - Blue color mapping
- `testColorFromStringGreen()` - Green color mapping
- `testColorFromStringRed()` - Red color mapping
- `testColorFromStringOrange()` - Orange color mapping
- `testColorFromStringPurple()` - Purple color mapping
- `testColorFromStringYellow()` - Yellow color mapping
- `testColorFromStringGray()` - Gray color mapping
- `testColorFromStringCaseInsensitive()` - Case insensitivity
- `testColorFromStringInvalid()` - Default fallback behavior
- `testColorFromStringEmpty()` - Empty string handling

### 6. TaskToolTests.swift
Placeholder test file (from Xcode template).

## UI Tests

### TaskToolUITests.swift
End-to-end UI workflow tests.

**Test Cases:**
- `testAppLaunches()` - Verify app launches successfully
- `testCreatePlanFlow()` - Complete plan creation workflow
- `testCreateTaskFlow()` - Complete task creation workflow
- `testEditStatusesButton()` - Status editor accessibility
- `testArchiveButton()` - Archive functionality presence
- `testLaunchPerformance()` - App launch performance metrics

**Note**: UI tests require storage location to be pre-configured.

## Running Tests

### Run All Tests
```bash
cd TaskTool
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool -destination 'platform=macOS'
```

### Run Only Unit Tests
```bash
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool \
  -destination 'platform=macOS' -only-testing:TaskToolTests
```

### Run Only UI Tests
```bash
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool \
  -destination 'platform=macOS' -only-testing:TaskToolUITests
```

### Run Specific Test Class
```bash
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool \
  -destination 'platform=macOS' -only-testing:TaskToolTests/PlanTests
```

### Run Specific Test Method
```bash
xcodebuild test -project TaskTool.xcodeproj -scheme TaskTool \
  -destination 'platform=macOS' \
  -only-testing:TaskToolTests/TaskStoreTests/testArchiveDoneTasks
```

## Test Coverage

### Covered Functionality
✅ Plan creation, modification, deletion, renaming  
✅ Task creation, modification, deletion  
✅ Markdown parsing and serialization  
✅ YAML frontmatter handling  
✅ File system operations (CRUD)  
✅ Task movement between plans  
✅ Archive functionality  
✅ Status management  
✅ Color mapping  
✅ File naming and sanitization  
✅ Data persistence  
✅ Folder operations  
✅ UI workflows  
✅ Launch performance  

### Not Covered (Future Enhancements)
- Drag-and-drop between columns (complex UI testing)
- File watching and auto-reload
- Concurrent file modifications
- Network/OneDrive sync edge cases
- Large dataset performance
- Memory leak detection
- Security/entitlements edge cases

## Test Best Practices

### Unit Tests
- Use temporary directories for file operations
- Clean up after each test (tearDown)
- Test one thing per test method
- Use descriptive test names
- Mock external dependencies when possible

### UI Tests
- Start with clean state
- Use accessibility identifiers
- Handle asynchronous operations with timeouts
- Test happy paths and error states
- Avoid brittle coordinate-based interactions

## Continuous Integration

The test suite can be integrated into CI/CD pipelines:

```bash
#!/bin/bash
# CI test script
set -e

cd TaskTool

# Run tests with code coverage
xcodebuild test \
  -project TaskTool.xcodeproj \
  -scheme TaskTool \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  | xcpretty --test --color

# Check for test failures
if [ ${PIPESTATUS[0]} -ne 0 ]; then
  echo "Tests failed!"
  exit 1
fi
```

## Maintenance

### Adding New Tests
1. Create test file in appropriate folder (TaskToolTests/ or TaskToolUITests/)
2. Import XCTest and @testable import TaskTool
3. Create test class extending XCTestCase
4. Implement setUp/tearDown if needed
5. Write test methods with `test` prefix
6. Run tests to verify

### Updating Existing Tests
- When models change, update parsing tests
- When file format changes, update serialization tests
- When UI changes, update UI test selectors
- Keep tests in sync with implementation

## Known Issues
- UI tests require manual storage location setup
- Some tests may fail on fresh installations
- File watching tests are not yet implemented
- Performance tests have platform-specific thresholds

## Test Metrics
- Expected test execution time: ~10-15 seconds (unit tests)
- Expected test execution time: ~20-30 seconds (UI tests)
- Code coverage target: 70%+
- Critical path coverage target: 90%+
