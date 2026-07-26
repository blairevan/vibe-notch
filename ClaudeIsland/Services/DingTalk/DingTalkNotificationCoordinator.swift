import Combine
import Foundation
import os.log

/// Observes unified session state and sends privacy-safe DingTalk notifications.
@MainActor
final class DingTalkNotificationCoordinator {
    /// Injectable sender used by production code and unit tests.
    typealias SendHandler = (DingTalkMessage, DingTalkCredentials) async throws -> Void

    private static let logger = Logger(subsystem: "com.claudeisland", category: "DingTalk")

    private let credentialStore: DingTalkCredentialStoring
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let send: SendHandler
    private var subscription: AnyCancellable?
    private var hasSeededSnapshot = false
    private var previousPhases: [String: PhaseMarker] = [:]
    private var notifiedPermissionIds: [String: Set<String>] = [:]

    /// Creates a coordinator with injectable state and transport dependencies.
    init(
        credentialStore: DingTalkCredentialStoring? = nil,
        isEnabled: (() -> Bool)? = nil,
        now: (() -> Date)? = nil,
        send: SendHandler? = nil
    ) {
        self.credentialStore = credentialStore ?? DingTalkCredentialStore.shared
        self.isEnabled = isEnabled ?? { AppSettings.dingTalkEnabled }
        self.now = now ?? Date.init

        if let send {
            self.send = send
        } else {
            let client = DingTalkClient()
            self.send = { message, credentials in
                try await client.send(message, credentials: credentials)
            }
        }
    }

    /// Starts observing the central session publisher once.
    func start() {
        guard subscription == nil else { return }
        subscription = SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                Task { @MainActor in
                    await self?.processSnapshot(sessions)
                }
            }
    }

    /// Stops observing and clears transient deduplication state.
    func stop() {
        subscription?.cancel()
        subscription = nil
        hasSeededSnapshot = false
        previousPhases.removeAll()
        notifiedPermissionIds.removeAll()
    }

    /// Processes one complete session snapshot and sends newly triggered messages.
    func processSnapshot(_ sessions: [SessionState]) async {
        guard hasSeededSnapshot else {
            seedSnapshot(sessions)
            return
        }

        removeStateForMissingSessions(sessions)
        var messages: [DingTalkMessage] = []

        for session in sessions {
            let currentPhase = PhaseMarker(session.phase)
            let previousPhase = previousPhases[session.sessionId]

            if currentPhase == .waitingForInput && previousPhase != .waitingForInput {
                messages.append(taskCompletedMessage(for: session))
            }

            if case .waitingForApproval(let toolUseId) = currentPhase {
                var sessionIds = notifiedPermissionIds[session.sessionId] ?? []
                if sessionIds.insert(toolUseId).inserted {
                    messages.append(permissionMessage(for: session))
                }
                notifiedPermissionIds[session.sessionId] = sessionIds
            }

            previousPhases[session.sessionId] = currentPhase
        }

        await sendMessagesIfConfigured(messages)
    }

    /// Seeds current phases and permissions without generating historical messages.
    private func seedSnapshot(_ sessions: [SessionState]) {
        hasSeededSnapshot = true
        for session in sessions {
            let phase = PhaseMarker(session.phase)
            previousPhases[session.sessionId] = phase
            if case .waitingForApproval(let toolUseId) = phase {
                notifiedPermissionIds[session.sessionId] = [toolUseId]
            }
        }
    }

    /// Removes state belonging to sessions no longer present in the snapshot.
    private func removeStateForMissingSessions(_ sessions: [SessionState]) {
        let activeIds = Set(sessions.map(\.sessionId))
        previousPhases = previousPhases.filter { activeIds.contains($0.key) }
        notifiedPermissionIds = notifiedPermissionIds.filter { activeIds.contains($0.key) }
    }

    /// Sends generated messages when enabled credentials are available.
    private func sendMessagesIfConfigured(_ messages: [DingTalkMessage]) async {
        guard !messages.isEmpty, isEnabled() else { return }

        let credentials: DingTalkCredentials
        do {
            credentials = try credentialStore.load().trimmed
        } catch {
            Self.logger.error("Could not load DingTalk credentials")
            return
        }
        guard !credentials.token.isEmpty else { return }

        for message in messages {
            do {
                try await send(message, credentials)
            } catch {
                Self.logger.error("DingTalk notification failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Creates a task-completed message containing only safe session metadata.
    private func taskCompletedMessage(for session: SessionState) -> DingTalkMessage {
        DingTalkMessage(
            title: "Vibe Notch - Task Completed",
            text: """
            ### Vibe Notch - Task Completed

            - Project: \(safeValue(session.projectName, fallback: "Unknown"))
            - Status: Task completed, waiting for input
            - Time: \(formattedTime())
            """
        )
    }

    /// Creates a permission message without including tool input or full paths.
    private func permissionMessage(for session: SessionState) -> DingTalkMessage {
        DingTalkMessage(
            title: "Vibe Notch - Permission Required",
            text: """
            ### Vibe Notch - Permission Required

            - Project: \(safeValue(session.projectName, fallback: "Unknown"))
            - Tool: \(safeValue(session.pendingToolName ?? "Unknown", fallback: "Unknown"))
            - Status: Waiting for approval
            - Time: \(formattedTime())
            """
        )
    }

    /// Formats the injected current time in the user's local timezone.
    private func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: now())
    }

    /// Normalizes an external display value and limits its size.
    private func safeValue(_ value: String, fallback: String) -> String {
        let normalized = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return fallback }
        return String(normalized.prefix(100))
    }
}

/// Comparable subset of session phase data used for transition detection.
private enum PhaseMarker: Equatable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval(String)
    case compacting
    case ended

    /// Converts the complete session phase into a comparable marker.
    init(_ phase: SessionPhase) {
        switch phase {
        case .idle:
            self = .idle
        case .processing:
            self = .processing
        case .waitingForInput:
            self = .waitingForInput
        case .waitingForApproval(let context):
            self = .waitingForApproval(context.toolUseId)
        case .compacting:
            self = .compacting
        case .ended:
            self = .ended
        }
    }
}
