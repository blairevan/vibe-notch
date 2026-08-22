# DingTalk Local File Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace DingTalk Keychain persistence with an owner-only local JSON file and remove the legacy Keychain item during installation without reading it.

**Architecture:** Keep `DingTalkCredentialStoring` as the application-facing boundary and replace its Keychain data adapter with `LocalDingTalkCredentialFileAccess`. The adapter writes a mode-`0600` temporary file inside a mode-`0700` application-support directory, atomically installs it, and repairs permissions on load and save.

**Tech Stack:** Swift 5, Foundation, XCTest, macOS 15.6+

## Global Constraints

- Do not import Security or invoke Keychain APIs from Vibe Notch DingTalk code.
- Store credentials only at `~/Library/Application Support/Vibe Notch/dingtalk.json`.
- Enforce directory mode `0700` and file mode `0600`.
- Never log or expose the token, signing secret, complete webhook URL, or request body.
- Add no new dependencies.
- Delete the legacy Keychain item without reading or migrating it.

---

### Task 1: File-backed credential persistence

**Files:**
- Modify: `ClaudeIsland/Services/DingTalk/DingTalkCredentialStore.swift`
- Modify: `ClaudeIslandTests/DingTalkCredentialStoreTests.swift`

**Interfaces:**
- Consumes: `DingTalkCredentials`, `DingTalkCredentialStoring`.
- Produces: `DingTalkCredentialFileAccessing`, `LocalDingTalkCredentialFileAccess`, and the unchanged `DingTalkCredentialStore.shared`, `load()`, `save(_:)`, and `clear()` interface.

- [x] **Step 1: Replace Keychain test doubles with file tests**

Add tests that create a unique temporary directory and construct:

```swift
let fileURL = temporaryDirectory.appendingPathComponent("dingtalk.json")
let fileAccess = LocalDingTalkCredentialFileAccess(fileURL: fileURL)
let store = DingTalkCredentialStore(fileAccess: fileAccess)
```

Assert that a missing file returns `.empty`, saved values are trimmed and round-trip, malformed JSON throws `DingTalkCredentialStoreError.invalidData`, clear removes the file, and POSIX permissions read through `FileManager.attributesOfItem(atPath:)` equal `0o700` for the parent and `0o600` for the file. Retain an in-memory `DingTalkCredentialFileAccessing` failure double to prove a failed write preserves its previous value.

- [x] **Step 2: Run credential tests and verify the old implementation fails the new contract**

```bash
xcodebuild test -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -destination 'platform=macOS' -only-testing:ClaudeIslandTests/DingTalkCredentialStoreTests
```

Expected: compilation fails because `LocalDingTalkCredentialFileAccess` and the `fileAccess:` initializer do not exist.

- [x] **Step 3: Implement the local file adapter**

Replace `DingTalkKeychainAccessing` with:

```swift
@MainActor
protocol DingTalkCredentialFileAccessing {
    func readData() throws -> Data?
    func writeData(_ data: Data) throws
    func deleteData() throws
}
```

Make `DingTalkCredentialStore` accept `fileAccess: DingTalkCredentialFileAccessing?` and default to `LocalDingTalkCredentialFileAccess()`. Implement the production adapter with a default application-support URL and an injectable explicit URL for tests. Use `FileManager.createDirectory`, `createFile`, `FileHandle.write(contentsOf:)`, `FileHandle.synchronize()`, `FileManager.replaceItemAt(...options: .usingNewMetadataOnly)`, and `FileManager.moveItem` to install complete mode-`0600` data atomically. Remove the `Security` import, all `SecItem*` calls, all Keychain status errors, and all Keychain comments.

- [x] **Step 4: Run credential tests and verify they pass**

Run the command from Step 2. Expected: all `DingTalkCredentialStoreTests` pass.

### Task 2: Menu wording, documentation, and regression verification

**Files:**
- Modify: `ClaudeIsland/UI/Components/DingTalkSettingsRow.swift`
- Modify: `docs/superpowers/specs/2026-07-27-dingtalk-notification-design.md`
- Modify: `docs/superpowers/plans/2026-07-27-dingtalk-notification.md`

**Interfaces:**
- Consumes: unchanged `DingTalkCredentialStore.shared` menu calls.
- Produces: documentation and source comments that accurately describe local-file persistence.

- [x] **Step 1: Remove stale Keychain wording**

Change menu comments to say “local credential file.” Update the original design and implementation plan so storage requirements, architecture, tests, and technology references point to the owner-only local JSON file rather than Keychain or Security.

- [x] **Step 2: Verify no runtime Keychain implementation remains**

```bash
rg -n 'import Security|SecItem|DingTalkKeychain|Keychain operation' ClaudeIsland ClaudeIslandTests
```

Expected: no matches.

- [x] **Step 3: Run formatting checks and the complete test suite**

```bash
git diff --check
xcodebuild test -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -destination 'platform=macOS'
```

Expected: no whitespace errors and all tests pass.

- [x] **Step 4: Build the Debug application**

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`. Known CoreSimulator warnings may appear but must not fail the macOS build.

### Task 3: Install and remove the legacy credential item

**Files:**
- Replace installed bundle: `/Applications/Vibe Notch.app`
- Create on first menu save: `~/Library/Application Support/Vibe Notch/dingtalk.json`

**Interfaces:**
- Consumes: the verified Debug application product.
- Produces: an installed app with no runtime Keychain access and no legacy Vibe Notch DingTalk generic-password item.

- [x] **Step 1: Stop the running application and install the verified build**

Use `osascript` to quit Vibe Notch, copy the built `.app` bundle over the installed bundle with a recoverable backup, apply ad-hoc signing if needed, and relaunch it. Do not delete unrelated application data.

- [x] **Step 2: Delete the known legacy item without reading it**

```bash
security delete-generic-password -s com.celestial.ClaudeIsland.dingtalk -a robot-credentials
```

Expected: the item is deleted, or the command reports that it was already absent. Never run `find-generic-password` or print item data.

- [ ] **Step 3: Verify installation and local-file permissions after the user saves credentials**

```bash
stat -f '%Lp %N' "$HOME/Library/Application Support/Vibe Notch" "$HOME/Library/Application Support/Vibe Notch/dingtalk.json"
```

Expected: directory mode `700` and file mode `600`. Do not display file contents.
