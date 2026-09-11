import AppKit

// Define o ícone customizado de um arquivo (aqui, o .dmg no Finder).
// NSWorkspace é a única API da Apple para isto; grava num fork do arquivo.
let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[2]) else {
    FileHandle.standardError.write(Data("uso: set-file-icon <arquivo> <icone.icns>\n".utf8))
    exit(1)
}
guard NSWorkspace.shared.setIcon(icon, forFile: args[1], options: []) else {
    FileHandle.standardError.write(Data("error: não foi possível aplicar o ícone\n".utf8))
    exit(1)
}
