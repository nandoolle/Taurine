import Foundation

/// Após instalar pelo DMG, o volume fica montado sem ninguém para ejetá-lo: o
/// Finder só copia arquivos, não avisa o app. Quando o Taurine abre de
/// /Applications e um volume do próprio DMG ainda está montado, oferecemos ejetar.
enum InstallDiskOffer {
    /// Um volume só é candidato se for do Taurine e o app rodar de fora dele:
    /// rodando de dentro, ejetar arrancaria o binário em execução.
    static func volumeToEject(bundlePath: String, mountedVolumes: [String]) -> String? {
        guard !bundlePath.hasPrefix("/Volumes/") else { return nil }
        return mountedVolumes.first { volume in
            let name = (volume as NSString).lastPathComponent
            return volume.hasPrefix("/Volumes/") && name.hasPrefix("Taurine")
        }
    }

    static func liveMountedVolumes(fileManager: FileManager = .default) -> [String] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey]
        guard let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else { return [] }
        return volumes.map(\.path)
    }
}
