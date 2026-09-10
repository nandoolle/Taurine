import AppKit

/// O Taurine é um app de barra de menus (LSUIElement), então nasce sem ícone no
/// Dock. Mostrá-lo é opt-in e alterna a política de ativação em tempo real.
enum DockPresence {
    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// A janela ativa é reapresentada depois da troca: sair de `.regular` desativa
    /// o app, e sem isto as Preferências perdem o foco para a janela de baixo.
    ///
    /// Só a janela é reordenada, sem `activate(ignoringOtherApps:)`: forçar a
    /// ativação global no meio da troca de política faz o Dock e as janelas dos
    /// outros apps piscarem.
    static func apply(showInDock: Bool, to application: NSApplication = .shared) {
        let window = application.keyWindow
        application.setActivationPolicy(self.policy(showInDock: showInDock))
        guard let window else { return }
        // A troca de política é assíncrona: reordenar no mesmo ciclo de evento
        // volta a ser desfeito pelo AppKit.
        DispatchQueue.main.async {
            application.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
