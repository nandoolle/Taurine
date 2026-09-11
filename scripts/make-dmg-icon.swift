import AppKit

// Compõe o ícone do app com o badge de imagem de disco no canto inferior direito.
let args = CommandLine.arguments
let base = NSImage(contentsOfFile: args[1])!
let badge = NSImage(contentsOfFile: args[2])!
let outPath = args[3]
let scale = CGFloat(Double(args[4])!)     // fração da largura total
let inset = CGFloat(Double(args[5])!)     // margem, fração da largura total

let S: CGFloat = 1024
let out = NSImage(size: NSSize(width: S, height: S))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
base.draw(in: NSRect(x: 0, y: 0, width: S, height: S))

// Mantém a proporção original do badge; `scale` controla a largura.
let bw = S * scale
let bh = bw * (badge.size.height / badge.size.width)
let rect = NSRect(x: S - bw - S * inset, y: S * inset, width: bw, height: bh)

// Sombra projetada sobre o ícone do Taurine, para o badge descolar do fundo.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
shadow.shadowBlurRadius = bw * 0.09
shadow.shadowOffset = NSSize(width: -bw * 0.02, height: bw * 0.02)
shadow.set()
badge.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()

out.unlockFocus()
let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
