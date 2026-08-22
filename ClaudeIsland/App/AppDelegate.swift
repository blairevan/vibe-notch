//
//  AppDelegate.swift
//  ClaudeIsland
//
//  Application delegate handling lifecycle and background monitoring.
//

import AppKit
import Foundation
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowManager: WindowManager?
    var screenObserver: ScreenObserver?
    var updateCheckTimer: Timer?
    let dingTalkCoordinator = DingTalkNotificationCoordinator()

    /// Detect if running within an XCTest runner environment
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip UI setup and monitoring when running unit tests
        if Self.isRunningUnitTests {
            return
        }

        HookInstaller.installIfNeeded()
        dingTalkCoordinator.start()
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.windowManager?.recreateWindow()
        }

        NotchViewModel.shared.startMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.checkForUpdatesInBackground()
        }

        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 86400,
            repeats: true
        ) { [weak self] _ in
            self?.checkForUpdatesInBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }

        dingTalkCoordinator.stop()
        updateCheckTimer?.invalidate()
        screenObserver = nil
    }

    private func checkForUpdatesInBackground() {
        guard AppSettings.automaticallyCheckForUpdates else { return }
        UpdaterViewModel.shared.checkForUpdatesInBackground()
    }
}
