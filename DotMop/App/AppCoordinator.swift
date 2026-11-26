import AppKit
import CoreServices
import SwiftUI

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let preferences = PreferencesStore()
    lazy var model = MainViewModel(preferences: preferences, showAutomaticConfirmation: { [weak self] in
        self?.showMainWindow()
    })
    lazy var loginItems = LoginItemService()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var receivedContext: LaunchContext?
    private var launchFinished = false
    private var started = false
    private var waitingToQuit = false

    private var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isTestHost else { return }
        let manager = NSAppleEventManager.shared()
        receivedContext = LaunchContext(event: manager.currentAppleEvent)
        manager.setEventHandler(self, andSelector: #selector(handleOpenApplication(_:withReplyEvent:)),
                                forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isTestHost else { return }
        launchFinished = true
        applyAppearance()
        loginItems.refresh()
        if let context = receivedContext ?? LaunchContext(event: NSAppleEventManager.shared().currentAppleEvent) {
            start(context)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if !isTestHost, let context = LaunchContext(event: NSAppleEventManager.shared().currentAppleEvent) {
            receive(context)
        }
        return false
    }

    @objc private func handleOpenApplication(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        if let context = LaunchContext(event: event) { receive(context) }
    }

    private func receive(_ context: LaunchContext) {
        receivedContext = context
        if launchFinished { start(context) }
    }

    private func start(_ context: LaunchContext) {
        guard !started else { return }
        started = true
        model.start(autoScan: context.shouldScan(scanOnOpen: preferences.value.autoScanOnOpen))
        if context.opensMainWindow { showMainWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !isTestHost { loginItems.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTestHost else { return false }
        if started { showMainWindow() }
        else { receive(.manual) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow, !preferences.value.keepRunning {
            Task { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard started, model.cleaningDiskID != nil else { return .terminateNow }
        if !waitingToQuit {
            waitingToQuit = true
            Task {
                await model.stopCleanupForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if started { model.stop() }
    }

    func showMainWindow() {
        if !started, launchFinished {
            start(.manual)
            return
        }
        if mainWindow == nil {
            let controller = NSHostingController(rootView: MainView(coordinator: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "DotMop"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 560))
            window.contentMinSize = NSSize(width: 680, height: 460)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.center()
            mainWindow = window
        }
        present(mainWindow)
    }

    func showSettings() {
        loginItems.refresh()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(coordinator: self))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = text("设置")
        present(settingsWindow)
    }

    func applyAppearance() {
        NSApp.appearance = preferences.value.appearance.nativeAppearance
    }

    func applyLanguage() {
        settingsWindow?.title = text("设置")
    }

    func text(_ key: String) -> String {
        L10n.text(key, language: preferences.value.language)
    }

    private func present(_ window: NSWindow?) {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
