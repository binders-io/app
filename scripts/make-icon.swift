import AppKit

// Renders the Binders app icon into the asset catalog: one page held by two rings on the indigo cover, a few lines written on it.
//   swift scripts/make-icon.swift Binders/Resources/Assets.xcassets/AppIcon.appiconset
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor { NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) }

/// A binder ring: silver torus with a hole showing the cover behind it.
func ring(cx: CGFloat, cy: CGFloat, radius: CGFloat, hole: NSColor) {
    let outer = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    NSGradient(colors: [rgb(236, 238, 242), rgb(160, 166, 178)])!.draw(in: outer, angle: -60)
    let inner = radius * 0.5
    hole.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2)).fill()
}

func draw(_ s: CGFloat) {
    let inset = s * 0.08
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cover = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [rgb(96, 76, 244), rgb(34, 24, 110)])!.draw(in: cover, angle: -90)
    let ink = rgb(70, 52, 210)
    let page = NSRect(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.15, width: r.width * 0.56, height: r.height * 0.70)
    NSColor.black.withAlphaComponent(0.25).setFill()
    rounded(page.offsetBy(dx: 0, dy: -s * 0.014), s * 0.035).fill()
    rgb(250, 250, 247).setFill()
    rounded(page, s * 0.035).fill()
    // Three lines of notes, the last one shorter.
    for (index, fy) in [0.70, 0.52, 0.34].enumerated() {
        let y = page.minY + page.height * CGFloat(fy)
        ink.withAlphaComponent(0.3).setFill()
        rounded(NSRect(x: page.minX + page.width * 0.24, y: y - s * 0.014, width: page.width * (index == 2 ? 0.36 : 0.56), height: s * 0.028), s * 0.014).fill()
    }
    for fy in [0.30, 0.70] as [CGFloat] { ring(cx: page.minX, cy: page.minY + page.height * fy, radius: s * 0.062, hole: rgb(34, 24, 110)) }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    try! render(pixels: points * scale).write(to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons")
