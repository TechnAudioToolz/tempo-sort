// Draws the app icon: tempo bars rising into folders. swift Tools/make_icon.swift <out.png>
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset = 100.0, rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
bg.addClip()
NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.22, alpha: 1), NSColor(red: 0.22, green: 0.12, blue: 0.36, alpha: 1)])!
    .draw(in: rect, angle: -60)
// Five bars, one per range color, rising left to right.
let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal]
let barW = 92.0, gap = 34.0
let total = 5 * barW + 4 * gap
var x = (size - total) / 2
for (i, c) in colors.enumerated() {
    let h = 190.0 + Double(i) * 95
    let r = CGRect(x: x, y: 250, width: barW, height: h)
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22).fill()
    x += barW + gap
}
// Folder base the bars sort into.
NSColor.white.withAlphaComponent(0.92).setFill()
let base = NSBezierPath(roundedRect: CGRect(x: 230, y: 190, width: 564, height: 40), xRadius: 20, yRadius: 20)
base.fill()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
