// Renders the Jetway app icon: a jet bridge-ish "airplane.departure" symbol on a sky gradient.
import AppKit

func render(size: Int, to path: String) {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let inset = rect.insetBy(dx: s * 0.05, dy: s * 0.05)
    let shape = NSBezierPath(roundedRect: inset, xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.95, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)
    // subtle horizon band
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    NSBezierPath(rect: NSRect(x: inset.minX, y: inset.minY + inset.height * 0.28, width: inset.width, height: inset.height * 0.02)).fill()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.55, weight: .medium)
    if let sym = NSImage(systemSymbolName: "airplane.departure", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2 + s * 0.03, width: w, height: h))
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
    try! png.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    render(size: size, to: "\(out)/icon_\(name).png")
}
print("icons rendered")
