# DingTalk Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional DingTalk group robot notifications for Vibe Notch task completion and permission requests.

**Architecture:** A main-actor coordinator observes the existing unified `SessionStore` publisher, converts first-time target state transitions into privacy-minimized messages, and sends them through an injectable DingTalk client. Robot credentials are kept as one Codable Keychain value, while the enabled flag remains in `UserDefaults`.

**Tech Stack:** Swift 5, SwiftUI, Combine, Foundation `URLSession`, CryptoKit, Security, XCTest, macOS 15.6+

## Global Constraints

- Do not add third-party dependencies.
- Do not distinguish Claude from Codex or alter their hook payloads.
- Accept a DingTalk robot `access_token`, not a complete Webhook URL.
- Store token and optional signing secret in macOS Keychain and never log them.
- Do not send conversation text, full paths, commands, file content, or tool input.
- Keep all new functions and types documented and avoid type bypasses.

---

### Task 1: XCTest Target and DingTalk Client

**Files:**
- Create: `ClaudeIsland/Services/DingTalk/DingTalkClient.swift`
- Create: `ClaudeIslandTests/DingTalkClientTests.swift`
- Modify: `ClaudeIsland.xcodeproj/project.pbxproj`
- Modify: `ClaudeIsland.xcodeproj/xcshareddata/xcschemes/ClaudeIsland.xcscheme`

**Interfaces:**
- Produces: `DingTalkMessage`, `DingTalkClientError`, and `DingTalkClient.send(_:credentials:timestamp:) async throws`.
- Consumes: `DingTalkCredentials` from Task 2; define that small value type in the client file initially and move it unchanged in Task 2.

- [ ] **Step 1: Add the XCTest target and failing client tests**

Add a filesystem-synchronized `ClaudeIslandTests` unit-test target hosted by `Vibe Notch.app`, include it in the shared scheme, then add tests with fixed inputs:

```swift
@MainActor
final class DingTalkClientTests: XCTestCase {
    func testUnsignedRequestUsesTokenAndMarkdownBody() async throws {
        let recorder = RequestRecorder(response: #"{"errcode":0,"errmsg":"ok"}"#)
        let client = DingTalkClient(transport: recorder.send)
        try await client.send(
            DingTalkMessage(title: "Vibe Notch - Test", text: "hello"),
            credentials: DingTalkCredentials(token: "token value", signingSecret: ""),
            timestamp: 1_700_000_000_000
        )
        XCTAssertEqual(recorder.request?.url?.host, "oapi.dingtalk.com")
        XCTAssertTrue(recorder.request?.url?.absoluteString.contains("access_token=token%20value") == true)
    }

    func testBusinessFailureThrowsSanitizedError() async {
        let recorder = RequestRecorder(response: #"{"errcode":310000,"errmsg":"invalid token"}"#)
        let client = DingTalkClient(transport: recorder.send)
        await XCTAssertThrowsErrorAsync {
            try await client.send(.test, credentials: .init(token: "bad", signingSecret: ""))
        }
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
xcodebuild test -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -destination 'platform=macOS' -only-testing:ClaudeIslandTests/DingTalkClientTests
```

Expected: compilation fails because the DingTalk client types do not exist.

- [ ] **Step 3: Implement request building, optional signing, and response parsing**

Implement:

```swift
struct DingTalkMessage: Equatable, Sendable {
    let title: String
    let text: String
    static let test = DingTalkMessage(title: "Vibe Notch - Test", text: "DingTalk notifications are configured correctly.")
}

struct DingTalkCredentials: Codable, Equatable, Sendable {
    let token: String
    let signingSecret: String
}

@MainActor
final class DingTalkClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(transport: @escaping Transport = DingTalkClient.liveTransport) {
        self.transport = transport
    }

    func send(
        _ message: DingTalkMessage,
        credentials: DingTalkCredentials,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws {
        let request = try makeRequest(message: message, credentials: credentials, timestamp: timestamp)
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw DingTalkClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DingTalkClientError.httpStatus(http.statusCode)
        }
        let result = try JSONDecoder().decode(DingTalkAPIResponse.self, from: data)
        guard result.errcode == 0 else {
            throw DingTalkClientError.business(code: result.errcode, message: result.errmsg)
        }
    }

    private func makeRequest(
        message: DingTalkMessage,
        credentials: DingTalkCredentials,
        timestamp: Int64
    ) throws -> URLRequest {
        let token = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DingTalkClientError.missingToken }
        var components = URLComponents(string: "https://oapi.dingtalk.com/robot/send")
        var items = [URLQueryItem(name: "access_token", value: token)]
        let secret = credentials.signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let input = Data("\(timestamp)\n\(secret)".utf8)
            let key = SymmetricKey(data: Data(secret.utf8))
            let signature = Data(HMAC<SHA256>.authenticationCode(for: input, using: key)).base64EncodedString()
            items.append(URLQueryItem(name: "timestamp", value: String(timestamp)))
            items.append(URLQueryItem(name: "sign", value: signature))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw DingTalkClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DingTalkPayload(msgtype: "markdown", markdown: .init(title: message.title, text: message.text))
        )
        return request
    }
}

private struct DingTalkPayload: Encodable {
    struct Markdown: Encodable { let title: String; let text: String }
    let msgtype: String
    let markdown: Markdown
}
```

Use `URLComponents`, `JSONEncoder`, `HMAC<SHA256>`, a 10-second request timeout, HTTP validation, and response fields `errcode`/`errmsg`. Error descriptions may include the numeric business code and server message but must not include credentials, full URL, or request body.

- [ ] **Step 4: Run client tests**

Run the Task 1 test command. Expected: all `DingTalkClientTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add ClaudeIsland/Services/DingTalk/DingTalkClient.swift ClaudeIslandTests/DingTalkClientTests.swift ClaudeIsland.xcodeproj
git commit -m "feat: add DingTalk robot client"
```

### Task 2: Keychain Credential Store

**Files:**
- Create: `ClaudeIsland/Services/DingTalk/DingTalkCredentialStore.swift`
- Create: `ClaudeIslandTests/DingTalkCredentialStoreTests.swift`
- Modify: `ClaudeIsland/Services/DingTalk/DingTalkClient.swift`

**Interfaces:**
- Produces: `DingTalkCredentialStoring`, `DingTalkCredentialStore.shared`, `load()`, `save(_:)`, and `clear()`.
- Consumes: `DingTalkCredentials`, moved unchanged from the client file into the credential store file.

- [ ] **Step 1: Write failing codec and store contract tests**

```swift
func testCredentialsRoundTripThroughCodec() throws {
    let credentials = DingTalkCredentials(token: "token", signingSecret: "secret")
    let data = try JSONEncoder().encode(credentials)
    XCTAssertEqual(try JSONDecoder().decode(DingTalkCredentials.self, from: data), credentials)
}

func testEmptyStoreReturnsEmptyCredentials() throws {
    let store = InMemoryDingTalkCredentialStore()
    XCTAssertEqual(try store.load(), .empty)
}
```

- [ ] **Step 2: Run the credential tests and verify they fail**

Run the same `xcodebuild test` command with `-only-testing:ClaudeIslandTests/DingTalkCredentialStoreTests`. Expected: missing store protocol/type errors.

- [ ] **Step 3: Implement one-item Keychain persistence**

Define:

```swift
protocol DingTalkCredentialStoring {
    func load() throws -> DingTalkCredentials
    func save(_ credentials: DingTalkCredentials) throws
    func clear() throws
}

final class DingTalkCredentialStore: DingTalkCredentialStoring {
    static let shared = DingTalkCredentialStore()
    private let service = "com.celestial.ClaudeIsland.dingtalk"
    private let account = "robot-credentials"
}
```

Encode both fields into one JSON blob. Use `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete`. Treat `errSecItemNotFound` as empty on load/clear. Because updates replace one item, a failed write leaves the previous item intact.

- [ ] **Step 4: Run credential and client tests**

Expected: both test classes pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add ClaudeIsland/Services/DingTalk ClaudeIslandTests/DingTalkCredentialStoreTests.swift
git commit -m "feat: store DingTalk credentials in Keychain"
```

### Task 3: Session Notification Coordinator

**Files:**
- Create: `ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift`
- Create: `ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift`
- Modify: `ClaudeIsland/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `SessionStore.sessionsPublisher`, `DingTalkCredentialStoring`, `DingTalkClient`, and `AppSettings.dingTalkEnabled`.
- Produces: `start()`, `stop()`, and internal `processSnapshot(_:)` used by deterministic tests.

- [ ] **Step 1: Write failing transition and privacy tests**

Cover these exact cases:

```swift
func testInitialWaitingSnapshotDoesNotNotify()
func testTransitionToWaitingForInputNotifiesOnce()
func testPermissionToolUseIdNotifiesOnce()
func testRemovedSessionClearsDeduplicationState()
func testMessageContainsProjectNameButNotFullPathOrToolInput()
```

Inject an enabled closure, in-memory credential store, and async send closure that appends `DingTalkMessage` values.

- [ ] **Step 2: Run coordinator tests and verify they fail**

Expected: missing `DingTalkNotificationCoordinator`.

- [ ] **Step 3: Implement snapshot seeding, transition detection, and messages**

Implement a `@MainActor final class DingTalkNotificationCoordinator` with:

```swift
func start()
func stop()
func processSnapshot(_ sessions: [SessionState])
```

Track previous phase markers by `sessionId` and notified permission IDs by session. Seed the first snapshot and suppress all sends. On later snapshots, enqueue sends only when enabled and credentials contain a non-empty token. Format time in the local timezone and use `session.projectName`; never use `session.cwd` or `PermissionContext.formattedInput` in message text.

- [ ] **Step 4: Wire application lifecycle**

Add a retained coordinator property to `AppDelegate`, call `start()` after hooks are installed, and call `stop()` during termination.

- [ ] **Step 5: Run coordinator tests and commit**

Expected: all coordinator tests pass.

```bash
git add ClaudeIsland/Services/DingTalk/DingTalkNotificationCoordinator.swift ClaudeIslandTests/DingTalkNotificationCoordinatorTests.swift ClaudeIsland/App/AppDelegate.swift
git commit -m "feat: notify DingTalk from session transitions"
```

### Task 4: Menu Configuration and Final Verification

**Files:**
- Create: `ClaudeIsland/Core/DingTalkSettingsController.swift`
- Create: `ClaudeIsland/UI/Components/DingTalkSettingsRow.swift`
- Modify: `ClaudeIsland/Core/Settings.swift`
- Modify: `ClaudeIsland/Core/NotchViewModel.swift`
- Modify: `ClaudeIsland/UI/Views/NotchMenuView.swift`

**Interfaces:**
- Consumes: `DingTalkCredentialStore`, `DingTalkClient.send`, and `AppSettings.dingTalkEnabled`.
- Produces: `DingTalkSettingsController.shared`, `isExpanded`, `expandedPickerHeight`, and the menu editing/test experience.

- [ ] **Step 1: Add settings state and expandable menu UI**

Add `AppSettings.dingTalkEnabled`, then create a main row labeled `DingTalk Notification`. Expanded content contains `SecureField` controls for `Robot Token` and `Signing Secret`, an enabled toggle, `Save`, `Send Test Message`, and `Clear Configuration`. Disable enable/test actions when the trimmed token is empty and show inline progress/result text.

- [ ] **Step 2: Integrate dynamic menu sizing**

Observe `DingTalkSettingsController.shared.$isExpanded` in `NotchViewModel`, add its `expandedPickerHeight`, and insert `DingTalkSettingsRow()` under the notification settings section of `NotchMenuView`.

- [ ] **Step 3: Format and run all tests**

```bash
xcodebuild test -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -destination 'platform=macOS'
```

Expected: all DingTalk unit tests pass.

- [ ] **Step 4: Build the app**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`. The known CoreSimulator version warning may appear but must not cause the macOS build to fail.

- [ ] **Step 5: Inspect the final diff and commit**

```bash
git diff --check
git status --short
git diff --stat HEAD
git add ClaudeIsland ClaudeIslandTests ClaudeIsland.xcodeproj
git commit -m "feat: configure DingTalk notifications in menu"
```
