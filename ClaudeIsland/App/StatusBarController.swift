import AppKit
import Combine
import Foundation

/// Manages the system status bar item in the macOS top right menu bar.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
    }

    /// Sets up the status bar item once on launch.
    func setup() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: "Vibe Notch")
                ?? NSImage(systemSymbolName: "dot.radiowaves.up.forward", accessibilityDescription: "Vibe Notch")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusBarButtonClicked)
            button.toolTip = "Vibe Notch"
        }
        self.statusItem = item

        // Observe display mode changes to refresh
        NotificationCenter.default.publisher(for: .displayModeDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    @objc private func statusBarButtonClicked() {
        guard let appDelegate = AppDelegate.shared,
              let windowController = appDelegate.windowController else {
            return
        }

        let vm = windowController.viewModel
        if vm.status == .opened {
            vm.notchClose()
        } else {
            vm.notchOpen(reason: .click)
        }
    }

    private func refreshStatusItem() {
        // Keeps status bar icon active and visible across modes
        statusItem?.button?.needsDisplay = true
    }
}
