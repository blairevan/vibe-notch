# DingTalk Notification Design

## Goal

Add optional DingTalk group custom robot notifications to Vibe Notch. Users configure the robot token and optional signing secret in the Vibe Notch menu. Notifications cover the unified session events already received from Claude Code and Codex Desktop.

## Scope

The feature sends notifications when:

- a session first enters `waitingForInput`; or
- a tool first enters `waitingForApproval`.

The feature does not distinguish Claude from Codex, alter either hook payload, send conversation content, or support DingTalk enterprise applications.

## Architecture

### `DingTalkNotificationCoordinator`

The coordinator subscribes to `SessionStore.sessionsPublisher`. Its first snapshot seeds internal state without sending notifications. Later snapshots are compared with the previous state:

- a transition into `waitingForInput` creates one task-completed notification;
- each new permission `toolUseId` creates one permission-required notification; and
- repeated snapshots and repeated tool identifiers are ignored.

The coordinator starts with the application and stops on termination. It consumes session state without changing it and does not depend on `NotchView` lifecycle.

### `DingTalkClient`

The client owns DingTalk request construction and response parsing. It uses `URLSession` and system frameworks only.

For an unsigned robot, the request targets:

```text
https://oapi.dingtalk.com/robot/send?access_token=<token>
```

When a signing secret is present, the client adds a millisecond timestamp and a URL-encoded Base64 HMAC-SHA256 signature generated from `timestamp + "\n" + secret`.

The request body uses DingTalk Markdown messages. A send succeeds only when both the HTTP response and DingTalk business response indicate success.

### `DingTalkCredentialStore`

The robot token and optional signing secret are sensitive values and are stored in macOS Keychain. The enabled flag remains in `UserDefaults`. Credentials, complete request URLs, and message bodies must not appear in logs.

The credential store is exposed through a small protocol so menu state and coordinator behavior can be tested without accessing the real Keychain.

## Menu Configuration

Add an expandable `DingTalk Notification` row to the existing Vibe Notch menu with:

- `Enable DingTalk`;
- `Robot Token`;
- optional `Signing Secret`;
- `Send Test Message`; and
- `Clear Configuration`.

The application accepts the `access_token` value, not a complete Webhook URL. Sensitive inputs are masked. Enabling is rejected while the token is empty. Test-send progress and the final success or sanitized error are shown inline.

## Message Content

Task-completed example:

```text
Vibe Notch - Task Completed

Project: vibe-notch
Status: Task completed, waiting for input
Time: 2026-07-27 14:30
```

Permission-required example:

```text
Vibe Notch - Permission Required

Project: vibe-notch
Tool: Bash
Status: Waiting for approval
Time: 2026-07-27 14:30
```

Only the final component of the working directory is included. Full paths, commands, file content, conversation text, and complete tool input are excluded.

## Error Handling

- Validate and trim token and secret values before storage or use.
- Construct URLs with `URLComponents` to preserve query encoding.
- Apply a finite request timeout and do not perform application-level automatic retries, preventing duplicate messages.
- Distinguish invalid configuration, transport failures, HTTP failures, invalid response data, and DingTalk business failures.
- Show sanitized errors for manual test sends.
- Log sanitized runtime failures without interrupting Vibe Notch UI or permission handling.
- Preserve existing Keychain values if a save operation fails.

## Files

Add:

- `ClaudeIsland/Services/DingTalk/DingTalkClient.swift`
- `ClaudeIsland/Services/DingTalk/DingTalkCredentialStore.swift`
- `ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift`
- `ClaudeIsland/UI/Components/DingTalkSettingsRow.swift`
- `ClaudeIslandTests/DingTalkClientTests.swift`
- `ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift`

Modify:

- `ClaudeIsland/Core/Settings.swift`
- `ClaudeIsland/UI/Views/NotchMenuView.swift`
- `ClaudeIsland/Core/NotchViewModel.swift`
- `ClaudeIsland/App/AppDelegate.swift`
- `ClaudeIsland.xcodeproj/project.pbxproj`

## Testing

Add an XCTest target without adding third-party dependencies. Tests cover:

- unsigned and signed URL generation with a fixed timestamp;
- success, HTTP failure, malformed response, and DingTalk business failure;
- initial snapshot suppression;
- first target-state transition delivery;
- duplicate phase and `toolUseId` suppression; and
- identical behavior for the shared Claude and Codex session format.

Run the relevant tests and a Debug build after the final edit. Existing notification behavior must remain unchanged when DingTalk is disabled or unconfigured.
