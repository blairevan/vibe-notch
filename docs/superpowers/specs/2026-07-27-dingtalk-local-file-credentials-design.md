# DingTalk Local File Credentials Design

## Goal

Remove every runtime dependency on macOS Keychain for DingTalk robot credentials. Persist the robot token and optional signing secret in an owner-only local file while preserving the existing menu, notification coordinator, and DingTalk client behavior.

## Storage Location and Format

The credential store uses this file:

```text
~/Library/Application Support/Vibe Notch/dingtalk.json
```

The JSON payload remains the existing `DingTalkCredentials` Codable value with `token` and `signingSecret` fields. The enabled flag remains in `UserDefaults`; no credential value is copied there.

The `Vibe Notch` directory is restricted to POSIX mode `0700`. The credential file is restricted to POSIX mode `0600`. Every successful load and save repairs these permissions so an existing file cannot remain more broadly accessible.

## Atomic Persistence

`LocalDingTalkCredentialFileAccess` implements the existing binary persistence boundary without importing Security or invoking Keychain APIs. Saving follows this sequence:

1. Create the application-support directory with mode `0700`.
2. Create a uniquely named temporary file in that directory with mode `0600`.
3. Write and synchronize the complete encoded credential payload.
4. Atomically replace the destination, using the temporary file's metadata, or move it into place when no destination exists.
5. Reapply destination mode `0600` and remove any leftover temporary file after failures.

A failed replacement leaves the previous complete credential file in place. Empty or missing files do not silently become valid credentials: a missing file loads `.empty`, while malformed JSON produces a credential-store error that contains no credential material.

## Menu and Runtime Behavior

The menu continues to show masked token and signing-secret fields and the existing save, enable, test, and clear actions. Their persistence calls now target the local file. Clearing deletes the local file and disables notifications.

The notification coordinator continues to depend on `DingTalkCredentialStoring`, so its event detection and privacy behavior do not change. Logs and user-facing errors must not contain a token, secret, complete webhook URL, or request body.

## Legacy Keychain Item

The application contains no migration or cleanup code that accesses Keychain. During this installation only, the previously created generic-password item for Vibe Notch DingTalk credentials is deleted directly without reading it. The deletion command treats a missing item as success.

The old credentials are not migrated. The user must save the DingTalk token and optional signing secret again through the Vibe Notch menu.

## Tests

Credential-store tests cover:

- Codable round-trip behavior;
- missing-file behavior;
- trimming and round-trip persistence;
- directory mode `0700` and file mode `0600`;
- malformed JSON rejection;
- failed saves preserving the previous credential value; and
- clearing the credential file.

The full DingTalk test suite and a Debug application build verify that the existing client, coordinator, and menu integration still compile and behave correctly.
