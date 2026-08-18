# Rich DingTalk Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade DingTalk group robot notifications in Vibe Notch to a rich card format with task summary, head/tail-truncated assistant message, duration stats, and terminal metadata.

**Architecture:** Extend `DingTalkNotificationCoordinator` with text formatting helpers for duration formatting, message quotation, and head/tail string truncation (front 200 + tail 200 chars). Update unit tests to verify the rich format.

**Tech Stack:** Swift 5, SwiftUI, Combine, XCTest, macOS 15.6+

## Global Constraints

- Do not expose full raw paths, tokens, or raw tool inputs.
- All unit tests must pass with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

---

### Task 1: Rich Notification Formatting & Unit Tests

**Files:**
- Modify: `ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift`
- Modify: `ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests for rich formatting and truncation**
- [ ] **Step 2: Run tests to verify failure**
- [ ] **Step 3: Implement rich notification message generation in coordinator**
- [ ] **Step 4: Run full test suite to verify all 21+ tests pass**
- [ ] **Step 5: Rebuild and install debug application**
