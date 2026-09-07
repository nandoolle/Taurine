// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import Cocoa
import Darwin
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        self.setupMainMenu()
        do {
            // A process-owned lock also covers copies of Taurine at other paths.
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Taurine", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.lockDescriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard self.lockDescriptor >= 0, flock(self.lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Taurine is already running or could not acquire its session lock.")
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            self.menuBarController = MenuBarController()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let preferences = appMenu.addItem(withTitle: String(localized: "Preferences…"), action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Taurine"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: String(localized: "Edit"))
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        for (title, action, key) in [
            (String(localized: "Undo"), "undo:", "z"),
            (String(localized: "Redo"), "redo:", "Z"),
            (String(localized: "Cut"), "cut:", "x"),
            (String(localized: "Copy"), "copy:", "c"),
            (String(localized: "Paste"), "paste:", "v"),
            (String(localized: "Select All"), "selectAll:", "a")
        ] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        NSApp.mainMenu = mainMenu
    }

    @objc private func openPreferences(_: Any?) {
        self.menuBarController?.showPreferencesWindow()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        self.menuBarController?.showPreferencesWindow()
        return false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let menuBarController else { return .terminateNow }
        guard !menuBarController.isBusy else { return .terminateCancel }
        Task {
            let restored = await menuBarController.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        self.menuBarController?.cleanup()
        if self.lockDescriptor >= 0 { close(self.lockDescriptor) }
    }
}
