import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon shape: rounded square with ~22% corner radius, inset like system icons.
let inset = size * 0.08
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.80, alpha: 1)])!
gradient.draw(in: path, angle: -60)

// Subtle inner highlight.
ctx.saveGState()
path.addClip()
let hl = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
hl.draw(in: rect, angle: 90)
ctx.restoreGState()

// Symbol.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let tinted = NSImage(size: symbol.size, flipped: false) { r in
    symbol.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    return true
}
let s = tinted.size
let origin = CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.01)
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
image.unlockFocus()

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
