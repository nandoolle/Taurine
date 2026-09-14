import Darwin
import Foundation

/// Observa o bundle por evento do kernel em vez de sondagem.
///
/// O descritor acompanha o inode, então `.rename` cobre o arrasto para o Lixo e
/// `.delete` a remoção definitiva — sem depender de comparar caminhos. Se o
/// `open` falhar, `nextEvent` cai para a espera por tempo: ficar sem vigilância
/// deixaria o Mac acordado para sempre.
actor BundleWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending = false
    private var cancelled = false

    private let path: String

    init(path: String) {
        self.path = path
    }

    /// Armar fora do `init` mantém o actor consistente: o handler do source pode
    /// disparar assim que ele resume.
    func start() {
        self.armSource(path: self.path)
    }

    var isWatching: Bool { self.source != nil }

    /// Refaz o observador num caminho que voltou a existir. O descritor anterior
    /// aponta para o inode substituído pelo update e nunca mais dispara.
    func rearm(path: String) {
        guard !self.cancelled else { return }
        self.armSource(path: path)
    }

    /// Suspende até o próximo evento. Sem observador vivo o kernel não avisa
    /// nada, então a espera vira sondagem.
    func nextEvent() async throws {
        if self.pending {
            self.pending = false
            return
        }
        guard !self.cancelled else { throw CancellationError() }
        guard self.source != nil else {
            try await Task.sleep(for: BundleWatchdog.interval)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.waiter = continuation
        }
        // Acordar por cancelamento não é evento: sem isto o watchdog trataria o
        // desligamento como remoção do bundle.
        if self.cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    func cancel() {
        self.cancelled = true
        self.source?.cancel()
        self.source = nil
        self.waiter?.resume()
        self.waiter = nil
    }

    private func armSource(path: String) {
        let descriptor = open(path, O_EVTONLY)
        let previous = self.source
        self.source = nil
        previous?.cancel()
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { Task { [weak self] in await self?.signal() } }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func signal() {
        guard let waiter = self.waiter else {
            self.pending = true
            return
        }
        self.waiter = nil
        waiter.resume()
    }
}
