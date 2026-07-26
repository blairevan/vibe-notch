import SwiftUI

/// Expandable menu form for DingTalk robot configuration.
struct DingTalkSettingsRow: View {
    @ObservedObject private var controller = DingTalkSettingsController.shared
    @State private var isEnabled = AppSettings.dingTalkEnabled
    @State private var token = ""
    @State private var signingSecret = ""
    @State private var feedback: Feedback?
    @State private var isTesting = false
    @State private var isHovered = false

    private let credentialStore = DingTalkCredentialStore.shared
    private let client = DingTalkClient()

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if controller.isExpanded {
                configurationForm
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .padding(.top, 4)
            }
        }
        .onAppear(perform: loadCredentials)
    }

    /// Main menu row showing enabled and expansion states.
    private var mainRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                controller.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "paperplane")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("DingTalk Notification")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isEnabled ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isEnabled ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))

                Image(systemName: controller.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// Expanded credential fields and actions.
    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            credentialField(title: "Robot Token", placeholder: "access_token", text: $token)
            credentialField(title: "Signing Secret", placeholder: "Optional SEC...", text: $signingSecret)

            HStack(spacing: 8) {
                compactButton(isEnabled ? "Disable" : "Enable", action: toggleEnabled)
                compactButton("Save", action: saveCredentials)
                compactButton(isTesting ? "Sending..." : "Test", action: sendTestMessage)
                    .disabled(isTesting)
                compactButton("Clear", isDestructive: true, action: clearCredentials)
            }

            if let feedback {
                Text(feedback.message)
                    .font(.system(size: 10))
                    .foregroundColor(feedback.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Builds one labeled masked credential field.
    private func credentialField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }

    /// Builds one compact form action button.
    private func compactButton(
        _ title: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(isDestructive ? .red.opacity(0.8) : TerminalColors.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
            )
    }

    /// Loads masked credential field values from Keychain.
    private func loadCredentials() {
        do {
            let credentials = try credentialStore.load()
            token = credentials.token
            signingSecret = credentials.signingSecret
            isEnabled = AppSettings.dingTalkEnabled
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    /// Saves the current fields after validating the required token.
    private func saveCredentials() {
        guard let credentials = validatedCredentials() else { return }
        do {
            try credentialStore.save(credentials)
            token = credentials.token
            signingSecret = credentials.signingSecret
            feedback = .success("Configuration saved.")
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    /// Enables or disables runtime DingTalk notifications.
    private func toggleEnabled() {
        if isEnabled {
            isEnabled = false
            AppSettings.dingTalkEnabled = false
            feedback = .success("Notifications disabled.")
            return
        }

        guard let credentials = validatedCredentials() else { return }
        do {
            try credentialStore.save(credentials)
            isEnabled = true
            AppSettings.dingTalkEnabled = true
            feedback = .success("Notifications enabled.")
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    /// Sends a test message using the current form values without persisting them.
    private func sendTestMessage() {
        guard let credentials = validatedCredentials() else { return }
        isTesting = true
        feedback = nil

        Task { @MainActor in
            defer { isTesting = false }
            do {
                try await client.send(.test, credentials: credentials)
                feedback = .success("Test message sent.")
            } catch {
                feedback = .failure(error.localizedDescription)
            }
        }
    }

    /// Clears Keychain credentials and disables notifications.
    private func clearCredentials() {
        do {
            try credentialStore.clear()
            token = ""
            signingSecret = ""
            isEnabled = false
            AppSettings.dingTalkEnabled = false
            feedback = .success("Configuration cleared.")
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    /// Returns trimmed valid fields or updates inline validation feedback.
    private func validatedCredentials() -> DingTalkCredentials? {
        let credentials = DingTalkCredentials(token: token, signingSecret: signingSecret).trimmed
        guard !credentials.token.isEmpty else {
            feedback = .failure("Robot token is required.")
            return nil
        }
        return credentials
    }

    /// Current hover-dependent row text color.
    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

/// Inline status shown by the DingTalk settings form.
private enum Feedback {
    case success(String)
    case failure(String)

    /// User-facing feedback text.
    var message: String {
        switch self {
        case .success(let message), .failure(let message):
            return message
        }
    }

    /// Semantic color for success and failure states.
    var color: Color {
        switch self {
        case .success:
            return TerminalColors.green
        case .failure:
            return .red.opacity(0.8)
        }
    }
}
