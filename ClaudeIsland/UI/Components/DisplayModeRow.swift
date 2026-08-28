import AppKit
import SwiftUI

/// Selector row for switching between Dynamic Island (floating capsule) and Menu Bar Only modes.
struct DisplayModeRow: View {
    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false
    @State private var selectedMode: DisplayMode = AppSettings.displayMode

    var body: some View {
        VStack(spacing: 0) {
            mainRow

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        optionRow(for: mode)
                    }
                }
                .padding(.top, 4)
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
                Image(systemName: selectedMode == .dynamicIsland ? "capsule.portrait" : "menubar.rectangle")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Display Mode")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Text(selectedMode.rawValue)
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

    private func optionRow(for mode: DisplayMode) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            selectedMode = mode
            AppSettings.displayMode = mode
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode == .dynamicIsland ? "island.fill" : "menubar.arrow.up.rectangle")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? TerminalColors.green : .white.opacity(0.4))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.7))

                    Text(mode == .dynamicIsland ? "Floating Dynamic Island capsule overlay" : "Zero top obstruction, menu bar icon only")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
