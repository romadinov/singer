// Renders the app icon PNGs: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let body = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.26, green: 0.26, blue: 0.36, alpha: 1),
                        NSColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)])!.draw(in: body, angle: -90)
    let lcd = rect.insetBy(dx: s * 0.09, dy: s * 0.13)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: lcd, xRadius: s * 0.03, yRadius: s * 0.03).fill()
    let heights: [CGFloat] = [0.35, 0.6, 0.85, 0.7, 0.95, 0.55, 0.75, 0.4, 0.6, 0.3]
    let gap = lcd.width * 0.025
    let barW = (lcd.width - gap * CGFloat(heights.count + 1)) / CGFloat(heights.count)
    for (i, h) in heights.enumerated() {
        let bar = NSRect(x: lcd.minX + gap + CGFloat(i) * (barW + gap), y: lcd.minY + gap,
                         width: barW, height: (lcd.height - 2 * gap) * h)
        NSGradient(colors: [NSColor(red: 0, green: 0.95, blue: 0.2, alpha: 1), .yellow, .orange, .red])!
            .draw(in: NSBezierPath(rect: bar), angle: 90)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
