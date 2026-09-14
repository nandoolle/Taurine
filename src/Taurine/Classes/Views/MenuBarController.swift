//
//  MenuBarController.swift
//  Taurine
//
//  Created by Dominic Rodemer on 11.11.25.
//

import Cocoa
import Combine
import SwiftUI

@MainActor
class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var viewModel: TaurineViewModel
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private lazy var activeIcon = self.statusIcon(named: "active")
    private lazy var inactiveIcon = self.statusIcon(named: "inactive")

    init(launchSource: LaunchSource = .user) {
        self.viewModel = TaurineViewModel()
        super.init()
        self.setupMenuBar()
        self.setupObservers()

        self.updateIcon()
        self.viewModel.start(launchSource: launchSource)
    }

    func cleanup() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    var isBusy: Bool { self.viewModel.isBusy }

    func prepareToQuit() async -> Bool {
        await self.viewModel.prepareToQuit()
    }

    private func setupMenuBar() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: 22)

        guard let button = statusItem?.button else { return }

        // Set up button actions (icon will be set after observers are configured)
        button.action = #selector(self.statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupObservers() {
        self.viewModel.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.updateIcon()
                }
            }
            .store(in: &self.cancellables)

        self.viewModel.session.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                DispatchQueue.main.async { self?.showError(message) }
            }
            .store(in: &self.cancellables)

        self.viewModel.$showPreferences
            .sink { [weak self] show in
                if show {
                    self?.showPreferencesWindow()
                }
            }
            .store(in: &self.cancellables)
    }

    private func statusIcon(named name: String) -> NSImage? {
        guard let image = NSImage(named: NSImage.Name(name)) else { return nil }
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        button.image = self.viewModel.isActive ? self.activeIcon : self.inactiveIcon
        button.appearsDisabled = false
        button.alphaValue = self.viewModel.isActive ? 1 : 0.65
        button.toolTip = self.viewModel.formattedTimeRemaining()
        button.setAccessibilityLabel("Taurine")
        button.setAccessibilityValue(self.viewModel.formattedTimeRemaining())
    }

    @objc
    private func statusItemClicked(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || (event.type == .leftMouseUp && !event.modifierFlags.intersection([.control, .command]).isEmpty) {
            self.showContextMenu()
        } else {
            self.toggleOrShowPreferences()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status info (only show if active)
        if let timeString = viewModel.formattedTimeRemaining() {
            let infoItem = NSMenuItem(title: timeString, action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
            menu.addItem(NSMenuItem.separator())
        }

        let toggleItem = NSMenuItem(
            title: self.viewModel.helperRequiresApproval ? String(localized: "Finish setup…") :
                (self.viewModel.isActive ? String(localized: "Deactivate Taurine…") : String(localized: "Activate Taurine…")),
            action: #selector(toggleActive(_:)), keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = !self.viewModel.isBusy
        menu.addItem(toggleItem)

        // Duration options in submenu
        let activateForItem = NSMenuItem(
            title: String(localized: "Activate for"),
            action: nil,
            keyEquivalent: ""
        )
        activateForItem.isEnabled = !self.viewModel.isBusy && !self.viewModel.helperRequiresApproval
        let submenu = NSMenu()

        var durations: [(String, Int)] = [
            (String(localized: "Indefinitely"), 0),
            (String(localized: "5 minutes"), 5),
            (String(localized: "10 minutes"), 10),
            (String(localized: "15 minutes"), 15),
            (String(localized: "30 minutes"), 30),
            (String(localized: "1 hour"), 60),
            (String(localized: "2 hours"), 120),
            (String(localized: "5 hours"), 300),
        ]

        #if DEBUG
        durations.insert((String(localized: "1 minute"), 1), at: 1)
        #endif

        for (title, minutes) in durations {
            let item = NSMenuItem(
                title: title,
                action: #selector(activateWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes
            submenu.addItem(item)
        }

        activateForItem.submenu = submenu
        menu.addItem(activateForItem)

        menu.addItem(NSMenuItem.separator())

        // Show in Dock
        let dockItem = NSMenuItem(
            title: String(localized: "Show Taurine in Dock"),
            action: #selector(toggleShowInDock(_:)),
            keyEquivalent: ""
        )
        dockItem.target = self
        dockItem.state = UserDefaults.standard.bool(forKey: PreferenceKeys.showInDock) ? .on : .off
        menu.addItem(dockItem)

        // Preferences
        let prefsItem = NSMenuItem(
            title: String(localized: "Preferences..."),
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = self
        // O sistema injeta um glifo em itens que reconhece, e ele disputa a
        // coluna do checkmark. Sem imagem, todos os itens alinham pelo ✓.
        prefsItem.image = nil
        menu.addItem(prefsItem)

        // About
        let aboutItem = NSMenuItem(
            title: String(localized: "About Taurine"),
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.image = nil
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.isEnabled = !self.viewModel.isBusy
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
        self.statusItem?.button?.performClick(nil)
        self.statusItem?.menu = nil
    }

    @objc
    private func activateWithDuration(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let seconds = minutes > 0 ? TimeInterval(minutes * 60) : 0
        self.viewModel.activate(withTimeout: seconds)
    }

    @objc
    private func showPreferences(_: Any?) {
        self.showPreferencesWindow()
    }

    @objc
    private func toggleShowInDock(_: Any?) {
        let showInDock = !UserDefaults.standard.bool(forKey: PreferenceKeys.showInDock)
        UserDefaults.standard.set(showInDock, forKey: PreferenceKeys.showInDock)
        DockPresence.apply(showInDock: showInDock)
    }

    @objc
    private func toggleActive(_: Any?) {
        self.toggleOrShowPreferences()
    }

    // Aguardando aprovação, a única ação útil é abrir os Ajustes do Sistema —
    // é lá que o usuário resolve. Nos demais casos ativar registra o daemon.
    private func toggleOrShowPreferences() {
        if self.viewModel.helperRequiresApproval {
            self.viewModel.openHelperSystemSettings()
        } else {
            self.viewModel.toggleActive()
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not complete the sleep change")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        self.viewModel.session.errorMessage = nil
    }

    func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if self.preferencesWindow == nil {
            let contentView = PreferencesView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Taurine - Preferences")
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            // Barra transparente e sem título visível: ela assume a cor da
            // janela e o cabeçalho do app ocupa o topo sem faixa cinza. O
            // `title` acima continua valendo para Exposé e acessibilidade.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // A janela não redimensiona nem minimiza: os botões existem apenas
            // como espaço morto ao lado do fechar.
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.setContentSize(hostingController.view.fittingSize)
            window.center()

            self.preferencesWindow = window
        }

        self.preferencesWindow?.makeKeyAndOrderFront(nil)
        // Sem primeiro responder definido o AppKit elege o primeiro controle
        // focável — o slider da bateria — que passa a exibir um anel permanente.
        // A janela não tem campo que deva receber foco ao abrir.
        self.preferencesWindow?.makeFirstResponder(nil)
    }

    @objc
    private func showAbout(_: Any?) {
        NSApp.activate(ignoringOtherApps: true)

        let credits =
            String(
                localized: "Based on Caffeine (MIT).\n\n© 2006 Tomas Franzén\n© 2018 Michael Jones\n© 2022 Dominic Rodemer\n\nSource code:\nhttps://github.com/domzilla/Caffeine"
            )

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: credits),
        ])
    }

    @objc
    private func quit(_: Any?) {
        NSApp.terminate(nil)
    }
}
