import AppKit

// Convert the generated monochrome sheet to black template masks, removing
// its pale checkerboard preview, then fit both states into Retina status items.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = NSBitmapImageRep(data: try Data(contentsOf: root.appendingPathComponent("assets/menu-bar/generated-beverage-cans.png")))!
for (index, name) in ["inactive", "active"].enumerated() {
    let start = index * source.pixelsWide / 2
    let end = (index + 1) * source.pixelsWide / 2
    var minX = end, minY = source.pixelsHigh, maxX = start, maxY = 0
    for y in 0..<source.pixelsHigh { for x in start..<end {
        let color = source.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        if color.redComponent < 0.35 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    } }
    let width = maxX - minX + 3, height = maxY - minY + 3
    let mask = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<height { for x in 0..<width {
        let color = source.colorAt(x: minX - 1 + x, y: minY - 1 + y)!.usingColorSpace(.deviceRGB)!
        let alpha = max(0, min(1, (0.7 - color.redComponent) / 0.6))
        mask.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
    } }
    let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(mask)
    let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 7, y: 3, width: 30, height: index == 0 ? 32 : 38), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    output.size = NSSize(width: 22, height: 22)
    let path = root.appendingPathComponent("src/Taurine/Resources/Assets.xcassets/\(name).imageset/\(name)@2x.png")
    try output.representation(using: .png, properties: [:])!.write(to: path)
    var peak = 0.0, visible = 0
    for y in 0..<44 { for x in 0..<44 { let a = output.colorAt(x:x,y:y)!.alphaComponent; peak = max(peak,a); if a > 0 { visible += 1 } } }
    print("\(name): 44×44, peak alpha \(peak), visible pixels \(visible), corner alpha \(output.colorAt(x:0,y:0)!.alphaComponent)")
}
