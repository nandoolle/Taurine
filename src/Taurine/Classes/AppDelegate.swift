// Derived from Caffeine by Dominic Rodemer. See LICENSE.
import Cocoa
import Darwin
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var lockDescriptor: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.apply(showInDock: UserDefaults.standard.bool(forKey: PreferenceKeys.showInDock))
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
            self.menuBarController = MenuBarController(launchSource: LaunchSource.from(launchUserInfo: notification.userInfo))
            self.offerToEjectInstallDisk()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func offerToEjectInstallDisk() {
        guard let volume = InstallDiskOffer.volumeToEject(
            bundlePath: Bundle.main.bundlePath,
            mountedVolumes: InstallDiskOffer.liveMountedVolumes()
        ) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Eject the Taurine install disk?")
        alert.informativeText = String(localized: "Taurine is installed. The disk image it came from is still mounted.")
        alert.addButton(withTitle: String(localized: "Eject"))
        alert.addButton(withTitle: String(localized: "Keep Mounted"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume))
        } catch {
            // Sem isto o clique em Ejetar não produz efeito visível quando o
            // volume está em uso — tipicamente aberto no Finder.
            let failure = NSAlert()
            failure.messageText = String(localized: "The install disk could not be ejected.")
            failure.informativeText = String(localized: "It may still be in use. Close any window showing it and eject it from the Finder.")
            failure.runModal()
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
