// Native vector artwork for the Taurine application icon.
import AppKit

let output = CommandLine.arguments[1]
let canvas = NSImage(size: NSSize(width: 1024, height: 1024))
canvas.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.16, alpha: 1).setFill()
background.fill()
let mint = NSColor(calibratedRed: 0.52, green: 0.96, blue: 0.72, alpha: 1)
mint.setStroke()
let body = NSBezierPath(roundedRect: NSRect(x: 320, y: 206, width: 384, height: 574), xRadius: 72, yRadius: 72)
body.lineWidth = 26
body.stroke()
let lid = NSBezierPath(ovalIn: NSRect(x: 320, y: 696, width: 384, height: 112))
NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.16, alpha: 1).setFill()
lid.fill()
mint.setStroke()
lid.lineWidth = 26
lid.stroke()
let tab = NSBezierPath(ovalIn: NSRect(x: 470, y: 726, width: 100, height: 46))
tab.lineWidth = 16
tab.stroke()
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 536, y: 645))
bolt.line(to: NSPoint(x: 410, y: 450))
bolt.line(to: NSPoint(x: 503, y: 450))
bolt.line(to: NSPoint(x: 472, y: 320))
bolt.line(to: NSPoint(x: 622, y: 526))
bolt.line(to: NSPoint(x: 531, y: 526))
bolt.close()
mint.setFill()
bolt.fill()
canvas.unlockFocus()
let representation = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
