// Renders the DMG window background: Canvas surface, the Beacon wordmark and
// descriptor, and a Signal arrow from the app icon to the Applications link.
//
//   swift Scripts/render-dmg-background.swift
//
// Writes Scripts/dmg-bg.png and dmg-bg@2x.png; make-dmg.sh combines them into
// a HiDPI TIFF. Rerun after changing the brand kit or the DMG window layout.
import AppKit

let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let outputDir = repo.appendingPathComponent("Scripts")

// The DMG window is 600×400; make-dmg.sh puts the app icon at x=150 and the
// Applications link at x=450, both at y=200 from the top.
let baseSize = CGSize(width: 600, height: 400)

// Authoritative values from Brand/palette/beacon-colours.json.
let canvas = NSColor(srgbRed: 245 / 255, green: 243 / 255, blue: 238 / 255, alpha: 1)
let signal = NSColor(srgbRed: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 1)
let ink = NSColor(srgbRed: 24 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1)
let slate = NSColor(srgbRed: 115 / 255, green: 124 / 255, blue: 134 / 255, alpha: 1)

/// The wordmark cropped to its opaque artwork, so it centres on the mark itself.
func trimmedWordmark() -> CGImage {
    let url = repo.appendingPathComponent("Brand/logos/beacon-wordmark.png")
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("Missing \(url.path)") }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = 0, maxY = 0
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
}
let wordmark = trimmedWordmark()

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(baseSize.width * scale), pixelsHigh: Int(baseSize.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)

    canvas.setFill()
    NSRect(origin: .zero, size: baseSize).fill()

    // Wordmark, 160pt wide: above the guide's 140 px minimum.
    let markWidth: CGFloat = 160
    let markHeight = markWidth * CGFloat(wordmark.height) / CGFloat(wordmark.width)
    ctx.draw(wordmark, in: CGRect(x: (baseSize.width - markWidth) / 2, y: 318, width: markWidth, height: markHeight))

    func draw(_ text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (baseSize.width - size.width) / 2, y: centerY - size.height / 2), withAttributes: attrs)
    }
    draw("DNS & reverse proxy for macOS", font: .systemFont(ofSize: 13, weight: .medium),
         color: slate, centerY: 300)
    draw("Drag Beacon into Applications to install", font: .systemFont(ofSize: 13, weight: .medium),
         color: ink, centerY: 56)

    // Arrow between the two icon positions (y=200 from the top is y=200 here too).
    signal.setStroke()
    signal.setFill()
    let arrowY: CGFloat = 200
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 240, y: arrowY))
    line.line(to: NSPoint(x: 348, y: arrowY))
    line.lineWidth = 7
    line.lineCapStyle = .round
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 344, y: arrowY + 14))
    head.line(to: NSPoint(x: 370, y: arrowY))
    head.line(to: NSPoint(x: 344, y: arrowY - 14))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 4
    head.fill()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    rep.size = baseSize  // tag DPI so Finder scales the @2x correctly
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: outputDir.appendingPathComponent("dmg-bg.png"))
try render(scale: 2).write(to: outputDir.appendingPathComponent("dmg-bg@2x.png"))
print("Rendered dmg-bg.png and dmg-bg@2x.png in \(outputDir.path)")
