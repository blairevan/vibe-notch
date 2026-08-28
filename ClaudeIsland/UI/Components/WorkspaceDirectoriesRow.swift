import AppKit
import SwiftUI

/// Unified settings row for viewing and configuring Claude, Codex, and DSH workspace directories.
struct WorkspaceDirectoriesRow: View {
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @State private var claudePath: String = AppSettings.claudeDirectoryName
    @State private var codexPath: String = AppSettings.codexDirectoryPath
    @State private var dshPath: String = AppSettings.dshDirectoryPath

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if isExpanded {
                VStack(spacing: 6) {
                    directoryItem(
                        name: "Claude Code",
                        defaultPath: "~/.claude",
                        currentPath: claudePath,
                        icon: "apple.terminal"
                    ) {
                        openPicker(title: "Choose Claude Config Directory", defaultDir: ClaudePaths.claudeDir) { chosen in
                            claudePath = chosen
                            AppSettings.claudeDirectoryName = chosen
                            ClaudePaths.invalidateCache()
                            HookInstaller.installIfNeeded()
                        }
                    } onReset: {
                        claudePath = ""
                        AppSettings.claudeDirectoryName = ""
                        ClaudePaths.invalidateCache()
                        HookInstaller.installIfNeeded()
                    }

                    directoryItem(
                        name: "Codex Desktop",
                        defaultPath: "~/.codex",
                        currentPath: codexPath,
                        icon: "laptopcomputer"
                    ) {
                        let defaultUrl = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.codex")
                        openPicker(title: "Choose Codex Directory", defaultDir: defaultUrl) { chosen in
                            codexPath = chosen
                            AppSettings.codexDirectoryPath = chosen
                            HookInstaller.installIfNeeded()
                        }
                    } onReset: {
                        let std = FileManager.default.homeDirectoryForCurrentUser.path + "/.codex"
                        codexPath = std
                        AppSettings.codexDirectoryPath = std
                        HookInstaller.installIfNeeded()
                    }

                    directoryItem(
                        name: "DeepSeek Harness",
                        defaultPath: "~/.dsh",
                        currentPath: dshPath,
                        icon: "bolt.fill"
                    ) {
                        let defaultUrl = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.dsh")
                        openPicker(title: "Choose DSH Directory", defaultDir: defaultUrl) { chosen in
                            dshPath = chosen
                            AppSettings.dshDirectoryPath = chosen
                            HookInstaller.installIfNeeded()
                        }
                    } onReset: {
                        let std = FileManager.default.homeDirectoryForCurrentUser.path + "/.dsh"
                        dshPath = std
                        AppSettings.dshDirectoryPath = std
                        HookInstaller.installIfNeeded()
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 8)
                .padding(.top, 4)
            }
        }
        .onAppear {
            claudePath = AppSettings.claudeDirectoryName
            codexPath = AppSettings.codexDirectoryPath
            dshPath = AppSettings.dshDirectoryPath
        }
    }

    private var mainRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Workspace & Directories")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Text("3 Managed")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))

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

    private func directoryItem(
        name: String,
        defaultPath: String,
        currentPath: String,
        icon: String,
        onChoose: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        let isCustom = !currentPath.isEmpty && !currentPath.hasSuffix(defaultPath.replacingOccurrences(of: "~", with: ""))
        let resolvedDisplay = shortenedPath(currentPath.isEmpty ? defaultPath : currentPath)
        let exists = FileManager.default.fileExists(atPath: expandPath(currentPath.isEmpty ? defaultPath : currentPath))

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))

                    Circle()
                        .fill(exists ? TerminalColors.green : Color.white.opacity(0.2))
                        .frame(width: 5, height: 5)

                    Text(exists ? "Active" : "Not Found")
                        .font(.system(size: 9))
                        .foregroundColor(exists ? TerminalColors.green.opacity(0.8) : .white.opacity(0.35))
                }

                Text(resolvedDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 4) {
                Button("Choose…", action: onChoose)
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.06))
                    )

                if isCustom {
                    Button("Reset", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.red.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.06))
                        )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func openPicker(title: String, defaultDir: URL, onSelected: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = defaultDir

        let notchWindow = NSApp.windows.first { $0 is NotchPanel }
        let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
        let wasIgnoring = notchWindow?.ignoresMouseEvents ?? true
        notchWindow?.level = .normal
        notchWindow?.ignoresMouseEvents = true

        let response = panel.runModal()

        notchWindow?.level = originalLevel
        notchWindow?.ignoresMouseEvents = wasIgnoring

        if response == .OK, let url = panel.url {
            onSelected(url.path)
        }
    }

    private func shortenedPath(_ raw: String) -> String {
        let home = NSHomeDirectory()
        let path = raw.hasPrefix("~") ? raw.replacingOccurrences(of: "~", with: home) : raw
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func expandPath(_ raw: String) -> String {
        if raw.hasPrefix("~") {
            return NSHomeDirectory() + raw.dropFirst()
        }
        return raw
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
