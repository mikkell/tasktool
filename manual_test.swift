#!/usr/bin/env swift

import Foundation

// Create test directory
let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("task-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

print("Test directory: \(testDir.path)")

// Create two plans
let plan1Dir = testDir.appendingPathComponent("First")
let plan2Dir = testDir.appendingPathComponent("Second")
try FileManager.default.createDirectory(at: plan1Dir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: plan2Dir, withIntermediateDirectories: true)

// Create plan.yaml files
let plan1YAML = """
id: plan-first-001
name: First
color: blue
created: 2026-01-28T19:00:00Z
description: First plan
statuses:
  - id: status-todo-001
    name: To Do
    color: gray
    order: 0
  - id: status-done-001
    name: Done
    color: green
    order: 1
"""

let plan2YAML = """
id: plan-second-001
name: Second
color: green
created: 2026-01-28T19:00:00Z
description: Second plan
statuses:
  - id: status-todo-002
    name: To Do
    color: gray
    order: 0
  - id: status-done-002
    name: Done
    color: green
    order: 1
"""

try plan1YAML.write(to: plan1Dir.appendingPathComponent("plan.yaml"), atomically: true, encoding: .utf8)
try plan2YAML.write(to: plan2Dir.appendingPathComponent("plan.yaml"), atomically: true, encoding: .utf8)

print("✅ Created plan folders and plan.yaml files")

// Create settings.yaml
let settingsYAML = """
# TaskTool Settings
plan_order:
  - First
  - Second
"""

try settingsYAML.write(to: testDir.appendingPathComponent("settings.yaml"), atomically: true, encoding: .utf8)

print("✅ Created settings.yaml")

// Create a task in the Second plan (not the first one)
let taskMarkdown = """
---
id: \(UUID().uuidString)
type: task
plan: Second
status: To Do
created: 2026-01-28T19:00:00Z
updated: 2026-01-28T19:00:00Z
---
# Test Task in Second Plan

This should be in the Second plan, not First!
"""

let taskFile = plan2Dir.appendingPathComponent("test-task.md")
try taskMarkdown.write(to: taskFile, atomically: true, encoding: .utf8)

print("✅ Created task in Second plan")
print("\nChecking file locations:")
print("First plan: \(try FileManager.default.contentsOfDirectory(atPath: plan1Dir.path))")
print("Second plan: \(try FileManager.default.contentsOfDirectory(atPath: plan2Dir.path))")

// Read the task back
let content = try String(contentsOf: taskFile, encoding: .utf8)
print("\nTask content:")
print(content)

// Cleanup
try? FileManager.default.removeItem(at: testDir)
print("\n✅ Test completed and cleaned up")
