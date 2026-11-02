// Regenerates Beacon's app icon, menu bar icon and in-app brand images from
// the brand kit's PNGs. The kit ships raster artwork only — no ICNS, SVG or
// asset catalogue — so this is the one place those are derived.
//
//   swift Scripts/generate-brand-assets.swift            # uses Brand/ in this repo
//   swift Scripts/generate-brand-assets.swift <kit-dir>  # or another copy of the kit
import AppKit
import Foundation

let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let kit = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repo.appendingPathComponent("Brand")
let assets = repo.appendingPathComponent("Beacon/Assets.xcassets")

// Authoritative values from palette/beacon-colours.json.
let ink = CGColor(srgbRed: 24 / 255, green: 28 / 255, blue: 32 / 255, alpha: 1)
let signal = (r: 245.0 / 255, g: 181.0 / 255, b: 68.0 / 255)

func load(_ name: String) -> CGImage {
    let url = kit.appendingPathComponent("logos/\(name)")
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { fatalError("Missing \(url.path)") }
    return image
}

/// Crops to the opaque artwork so sizing is based on the mark, not the PNG's padding.
func trimmed(_ image: CGImage) -> CGImage {
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

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    draw(context)
    return context.makeImage()!
}

/// Draws `image` aspect-fit and centred inside `box`.
func drawFitted(_ image: CGImage, in box: CGRect, context: CGContext, alpha: CGFloat = 1) {
    let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let origin = CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
    context.setAlpha(alpha)
    context.draw(image, in: CGRect(origin: origin, size: size))
    context.setAlpha(1)
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeJSON(_ object: Any, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

/// Refills artwork with an exact palette colour, keeping its shape and edges.
/// The kit notes generated imagery drifts from the palette, and the palette
/// is authoritative — the amber PNG renders noticeably duller than Signal.
func recoloured(_ image: CGImage, red: Double, green: Double, blue: Double) -> CGImage {
    render(width: image.width, height: image.height) { context in
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(rect)
    }
}

let amber = recoloured(trimmed(load("beacon-symbol-amber.png")), red: signal.r, green: signal.g, blue: signal.b)
let black = trimmed(load("beacon-symbol-black.png"))
let wordmark = trimmed(load("beacon-wordmark.png"))

// MARK: App icon — amber symbol on an Ink squircle, as in the concept board.

let iconMaster = render(width: 1024, height: 1024) { context in
    // macOS icon grid: 824pt body inset 100pt, with the system's drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(path)
    context.setFillColor(ink)
    context.fillPath()
    context.restoreGState()
    // One stem-width of clear space is the guide's minimum; the icon gets more.
    drawFitted(amber, in: body.insetBy(dx: 190, dy: 170), context: context)
}

let iconDir = assets.appendingPathComponent("AppIcon.appiconset")
var iconImages: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let sized = render(width: pixels, height: pixels) { context in
            context.draw(iconMaster, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        write(sized, to: iconDir.appendingPathComponent(name))
        iconImages.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
writeJSON(["images": iconImages, "info": ["author": "xcode", "version": 1]],
          to: iconDir.appendingPathComponent("Contents.json"))

// MARK: Menu bar — the monochrome symbol as a template image, so macOS
// colours it. An 18pt canvas with the mark 16pt tall matches system extras.

func menuBarSet(named name: String, alpha: CGFloat) {
    let dir = assets.appendingPathComponent("\(name).imageset")
    var images: [[String: String]] = []
    for scale in [1, 2, 3] {
        let side = 18 * scale
        let mark = 16 * CGFloat(scale)
        let image = render(width: side, height: side) { context in
            let box = CGRect(x: (CGFloat(side) - mark) / 2, y: (CGFloat(side) - mark) / 2,
                             width: mark, height: mark)
            drawFitted(black, in: box, context: context, alpha: alpha)
        }
        let file = "\(name)@\(scale)x.png"
        write(image, to: dir.appendingPathComponent(file))
        images.append(["idiom": "universal", "scale": "\(scale)x", "filename": file])
    }
    writeJSON([
        "images": images,
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ], to: dir.appendingPathComponent("Contents.json"))
}
menuBarSet(named: "MenuBarIcon", alpha: 1)
// Quiet state for when the service isn't running: same mark, dimmed.
menuBarSet(named: "MenuBarIconInactive", alpha: 0.4)

// MARK: In-app artwork. Kept large; SwiftUI scales it down.

func artworkSet(named name: String, image: CGImage) {
    let dir = assets.appendingPathComponent("\(name).imageset")
    write(image, to: dir.appendingPathComponent("\(name).png"))
    writeJSON([
        "images": [["idiom": "universal", "filename": "\(name).png"]],
        "info": ["author": "xcode", "version": 1],
    ], to: dir.appendingPathComponent("Contents.json"))
}
artworkSet(named: "BeaconSymbol", image: amber)
artworkSet(named: "BeaconWordmark", image: wordmark)

// MARK: Daemon pages — small copies embedded as data URIs, since beacond
// serves its error pages with no files beside them. Rendered at 3x the CSS
// size they're shown at, which keeps them sharp and each well under 20 KB.

func scaled(_ image: CGImage, height: Int) -> CGImage {
    let width = Int((Double(image.width) * Double(height) / Double(image.height)).rounded())
    return render(width: width, height: height) { context in
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

func base64PNG(_ image: CGImage) -> String {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.base64EncodedString()
}

let pageScale = 3
let pageWordmark = scaled(wordmark, height: 36 * pageScale)
let pageSymbol = scaled(amber, height: 36 * pageScale)
let artworkSource = """
// Generated by Scripts/generate-brand-assets.swift from Brand/. Don't edit;
// rerun the script after updating the brand kit.

/// Beacon's artwork for the pages the proxy serves, as PNG data URIs.
enum BrandArtwork {
    /// The full lowercase wordmark. The guide keeps it on light surfaces.
    static let wordmark = "data:image/png;base64,\(base64PNG(pageWordmark))"
    static let wordmarkWidth = \(pageWordmark.width / pageScale)
    static let wordmarkHeight = \(pageWordmark.height / pageScale)

    /// The amber symbol on its own, for dark surfaces.
    static let symbol = "data:image/png;base64,\(base64PNG(pageSymbol))"
    static let symbolWidth = \(pageSymbol.width / pageScale)
    static let symbolHeight = \(pageSymbol.height / pageScale)
}

"""
try! artworkSource.write(
    to: repo.appendingPathComponent("Sources/beacond/BrandArtwork.swift"), atomically: true, encoding: .utf8
)

// MARK: Accent colour — Signal.

writeJSON([
    "colors": [[
        "idiom": "universal",
        "color": ["color-space": "srgb", "components": [
            "red": String(format: "%.3f", signal.r), "green": String(format: "%.3f", signal.g),
            "blue": String(format: "%.3f", signal.b), "alpha": "1.000",
        ]],
    ]],
    "info": ["author": "xcode", "version": 1],
], to: assets.appendingPathComponent("AccentColor.colorset/Contents.json"))

print("Wrote brand assets to \(assets.path)")
