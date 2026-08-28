import SwiftUI

/// Expandable UI row that presents system health diagnostics and auto-fix capabilities.
struct DoctorRow: View {
    @ObservedObject private var doctor = DiagnosticDoctor.shared
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @State private var actionFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if isExpanded {
                diagnosticDetails
                    .padding(.leading, 28)
                    .padding(.trailing, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
        .onAppear {
            if doctor.latestReport == nil {
                Task {
                    _ = await doctor.runDiagnostics()
                }
            }
        }
    }

    private var mainRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cross.case")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("System Diagnostics (Doctor)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if doctor.isRunning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else if let report = doctor.latestReport {
                    if report.isAllHealthy {
                        Text("Healthy")
                            .font(.system(size: 11))
                            .foregroundColor(TerminalColors.green)
                    } else if report.errorCount > 0 {
                        Text("\(report.errorCount) Error\(report.errorCount > 1 ? "s" : "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red.opacity(0.85))
                    } else {
                        Text("\(report.warningCount) Warning\(report.warningCount > 1 ? "s" : "")")
                            .font(.system(size: 11))
                            .foregroundColor(.yellow.opacity(0.85))
                    }
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
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

    private var diagnosticDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = doctor.latestReport {
                ForEach(report.items) { item in
                    itemRow(for: item)
                }
            }

            HStack(spacing: 8) {
                compactButton("Re-check") {
                    Task {
                        _ = await doctor.runDiagnostics()
                    }
                }

                compactButton("Auto-Fix All") {
                    Task {
                        _ = await doctor.autoFixAll()
                        actionFeedback = "Auto-fix applied!"
                    }
                }

                compactButton("Ping DingTalk") {
                    Task {
                        let success = await doctor.pingDingTalk()
                        actionFeedback = success ? "DingTalk ping success!" : (doctor.lastPingStatus ?? "Ping failed")
                    }
                }
            }
            .padding(.top, 4)

            if let feedback = actionFeedback {
                Text(feedback)
                    .font(.system(size: 10))
                    .foregroundColor(feedback.contains("failed") || feedback.contains("Error") ? .red.opacity(0.85) : TerminalColors.green)
                    .lineLimit(2)
            }
        }
    }

    private func itemRow(for item: DiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon(for: item.status)
                .frame(width: 14, height: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))

                    Text("[\(item.category)]")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }

                Text(item.details)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(for status: DiagnosticStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(TerminalColors.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow.opacity(0.85))
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.85))
        case .notApplicable:
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func compactButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(TerminalColors.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
            )
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
