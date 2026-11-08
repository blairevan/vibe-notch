import Foundation

/// Metadata supplied by the official Antigravity lifecycle hook bridge.
nonisolated struct AntigravityHookMetadata: Codable, Equatable, Sendable {
    let conversationId: String
    let executionNum: Int?
    let invocationNum: Int?
    let fullyIdle: Bool?
    let terminationReason: String?
    let hasError: Bool
    let isSubagent: Bool
    var transcriptPath: String? = nil
    var lastUserInput: String? = nil
    var error: String? = nil
    var initialNumSteps: Int? = nil

    /// Classify known host enums conservatively; unknown stops are never successes.
    var outcome: AntigravityOutcome {
        if hasError { return .failed }
        let reason = (terminationReason ?? "").uppercased()
            .replacingOccurrences(of: "EXECUTOR_TERMINATION_REASON_", with: "")
        switch reason {
        case "NO_TOOL_CALL", "MODEL_STOP": return .completed
        case "ERROR", "MAX_STEPS_EXCEEDED", "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS",
            "MAX_TOKEN_BUDGET_EXCEEDED":
            return .failed
        case "USER_CANCELED", "USER_CANCELLED": return .cancelled
        default: return .stopped
        }
    }
}

/// A terminal result derived from an explicit Stop, independent of conversation text.
nonisolated enum AntigravityOutcome: String, Codable, Sendable {
    case completed, failed, cancelled, stopped

    /// Short status used in notification-only surfaces.
    var label: String {
        switch self {
        case .completed: return "任务已完成"
        case .failed: return "任务异常中断"
        case .cancelled: return "任务已取消"
        case .stopped: return "任务已停止（原因未确认）"
        }
    }
}

/// Per-session event reducer; does not read transcripts or infer completion from silence.
nonisolated struct AntigravitySession: Equatable, Sendable {
    let conversationId: String
    var generation = 0
    var isActive = false
    var outcome: AntigravityOutcome?
    var completionID: String?
    var isSubagent = false
    var initialStep: Int?
    var isLoadingNotification = false

    /// Starts an event-only session for one upstream conversation.
    init(conversationId: String) {
        self.conversationId = conversationId
    }

    /// Consume one hook; only a fully idle Stop may terminate an active turn.
    mutating func apply(event: String, metadata: AntigravityHookMetadata) {
        isSubagent = isSubagent || metadata.isSubagent
        switch event {
        case "PreInvocation":
            if !isActive {
                generation += 1
                outcome = nil
                completionID = nil
                isActive = true
                initialStep = metadata.initialNumSteps
                isLoadingNotification = false
            }
        case "Stop":
            guard isActive, metadata.fullyIdle == true else { return }
            isActive = false
            outcome = metadata.outcome
            completionID =
                "\(conversationId):\(generation):\(metadata.executionNum.map(String.init) ?? "stop")"
        default:
            break
        }
    }
}

/// Source labels and stable bundle identities for the three official clients.
nonisolated enum AntigravitySource: String, CaseIterable, Sendable {
    case app = "antigravity"
    case cli = "antigravity-cli"
    case ide = "antigravity-ide"
    case unknown = "antigravity-unknown"

    /// Human-readable source shown in the notch and DingTalk.
    var label: String {
        switch self {
        case .app: return "Antigravity"
        case .cli: return "agy"
        case .ide: return "Antigravity IDE"
        case .unknown: return "Antigravity（来源未知）"
        }
    }

    /// Application identity, absent for a CLI or an unrecognized source.
    var bundleIdentifier: String? {
        switch self {
        case .app: return "com.google.antigravity"
        case .ide: return "com.google.antigravity-ide"
        case .cli, .unknown: return nil
        }
    }
}

extension SessionState {
    /// Recognized source for metadata-only notification and focus routing.
    nonisolated var antigravitySource: AntigravitySource? {
        AntigravitySource(rawValue: conversationInfo.clientName ?? "")
    }
}
