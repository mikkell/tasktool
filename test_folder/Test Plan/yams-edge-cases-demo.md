---
id: TEST-YAMS-EDGE-CASES-001
type: task
plan: Test Plan
status: To Do
tags: [yaml, testing, "tag with spaces", emoji-🎉]
priority: high
completed: false
due_date: 2026-02-15T00:00:00Z
created: 2026-02-02T08:17:41Z
updated: 2026-02-02T08:17:41Z
metadata:
  author: "TaskTool Team"
  version: 1.0
---
# YAML Frontmatter: Edge Cases & Features

This task demonstrates all the YAML frontmatter capabilities now supported by TaskTool using the Yams library.

## Supported Features

### ✅ Inline Arrays
The `tags` field above uses inline format: `[yaml, testing, "tag with spaces"]`

### ✅ Special Characters
- Colons in titles: "Meeting: Q1 Planning"
- Ampersands: "Research & Development"  
- Quotes: "Said 'hello' to team"
- Emojis: 🎉 🚀 ✅

### ✅ Multiple Data Types
- Strings: `plan: Test Plan`
- Booleans: `completed: false`
- Numbers: `priority: high` (treated as string)
- Dates: `due_date: 2026-02-15T00:00:00Z`
- Nested objects: `metadata: {...}`
- Arrays: `tags: [...]`

### ✅ Comments Allowed
You can now include YAML comments in frontmatter (though they won't be preserved on save).

### ✅ Multiline Strings
Use the `|` or `>` operators for multiline values.

## Testing Checklist

- [x] Inline array format works
- [x] Multiline array format works
- [x] Special characters in strings
- [x] Nested YAML objects
- [x] Boolean values
- [x] Numeric values
- [x] ISO8601 date parsing
- [x] Emoji support
- [x] Quotes and escaping

## Obsidian Compatibility

This file is 100% compatible with Obsidian's YAML frontmatter parsing. Any file that works in Obsidian will work in TaskTool, and vice versa.
