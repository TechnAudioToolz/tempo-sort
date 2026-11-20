// Store cover (1280x720) and square thumbnail (600x600). swift Tools/make_cover.swift
import AppKit
func png(_ w: Double, _ h: Double, _ path: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let icon = NSImage(contentsOfFile: "Resources/icon-1024.png")!
let shot = NSImage(contentsOfFile: "docs/screenshot-scanned.png")!
let bg = NSGradient(colors: [NSColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1), NSColor(red: 0.19, green: 0.10, blue: 0.31, alpha: 1)])!
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: NSPoint) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
png(1280, 720, "docs/gumroad-cover.png") {
    bg.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 720), angle: -35)
    icon.draw(in: NSRect(x: 40, y: 560, width: 140, height: 140))
    text("Tempo Sort", 64, .bold, .white, at: NSPoint(x: 190, y: 622))
    text("Sort your music into folders by BPM", 28, .medium, NSColor.white.withAlphaComponent(0.85), at: NSPoint(x: 194, y: 585))
    let lines = ["Finds every track's BPM", "in a folder and subfolders", "", "2 to 5 BPM ranges", "→ 80bpm-100bpm folders", "", "Copy or move, with undo", "", "Free · Mac · Offline"]
    for (i, l) in lines.enumerated() { text(l, 24, .regular, NSColor.white.withAlphaComponent(i == 8 ? 1 : 0.8), at: NSPoint(x: 60, y: 470 - Double(i) * 38)) }
    let w = 760.0, h = w * shot.size.height / shot.size.width
    let r = NSRect(x: 480, y: 30, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.set()
    NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).addClip()
    shot.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
}
png(600, 600, "docs/gumroad-thumbnail.png") {
    bg.draw(in: NSRect(x: 0, y: 0, width: 600, height: 600), angle: -35)
    icon.draw(in: NSRect(x: 130, y: 150, width: 340, height: 340))
    let t = "Tempo Sort" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: NSColor.white]
    t.draw(at: NSPoint(x: (600 - t.size(withAttributes: attrs).width) / 2, y: 70), withAttributes: attrs)
}
