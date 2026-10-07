// Renders the app icon into the asset catalog.
//   swift scripts/make-icon.swift
// The icon is drawn in code so it can be tweaked and regenerated.
import AppKit

let outputDir = "Upthere/Resources/Assets.xcassets/AppIcon.appiconset"

func superellipse(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = c.y + b * copysign(pow(abs(st), 2 / n), st)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the 1024×1024 master. Coordinates use a top-left origin.
func drawIcon(_ ctx: CGContext) {
    let canvas: CGFloat = 1024
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: 824pt body centred, room for the drop shadow.
    let body = CGRect(x: 100, y: 92, width: 824, height: 824)
    let shape = superellipse(in: body, exponent: 4.4)

    ctx.saveGState()
    // Shadow offsets ignore the flipped CTM: negative height points down.
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B1530))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Dusk sky: deep violet at the top, warm glow at the horizon.
    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x15122B), color(0x3B2366), color(0xB2456E), color(0xF39A5B)] as CFArray,
        locations: [0, 0.38, 0.74, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])

    // Soft sun rising behind the notch's glow.
    let sun = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFD7A0, 0.55), color(0xFFD7A0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        sun, startCenter: CGPoint(x: 512, y: 860), startRadius: 0, endCenter: CGPoint(x: 512, y: 860),
        endRadius: 420, options: [])

    // The notch with its ears, hanging from the top edge.
    let bar = CGRect(x: body.minX + 96, y: body.minY - 40, width: body.width - 192, height: 340)
    let notchPath = CGMutablePath()
    let r: CGFloat = 92
    notchPath.move(to: CGPoint(x: bar.minX, y: bar.minY))
    notchPath.addLine(to: CGPoint(x: bar.maxX, y: bar.minY))
    notchPath.addLine(to: CGPoint(x: bar.maxX, y: bar.maxY - r))
    notchPath.addQuadCurve(to: CGPoint(x: bar.maxX - r, y: bar.maxY), control: CGPoint(x: bar.maxX, y: bar.maxY))
    notchPath.addLine(to: CGPoint(x: bar.minX + r, y: bar.maxY))
    notchPath.addQuadCurve(to: CGPoint(x: bar.minX, y: bar.maxY - r), control: CGPoint(x: bar.minX, y: bar.maxY))
    notchPath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: color(0x000000, 0.45))
    ctx.addPath(notchPath)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()

    let midY = bar.minY + 40 + (bar.height - 40) / 2

    // Left ear: Claude-style spark.
    let spark = CGPoint(x: bar.minX + 140, y: midY)
    ctx.setStrokeColor(color(0xE07A55))
    ctx.setLineCap(.round)
    ctx.setLineWidth(26)
    for i in 0..<8 {
        let angle = CGFloat(i) / 8 * 2 * .pi
        let length: CGFloat = i % 2 == 0 ? 74 : 48
        ctx.move(to: CGPoint(x: spark.x + cos(angle) * 14, y: spark.y + sin(angle) * 14))
        ctx.addLine(to: CGPoint(x: spark.x + cos(angle) * length, y: spark.y + sin(angle) * length))
    }
    ctx.strokePath()

    // Right ear: audio bars.
    let heights: [CGFloat] = [92, 150, 64, 120]
    let barWidth: CGFloat = 30, gap: CGFloat = 22
    var x = bar.maxX - 140 - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap) / 2
    for h in heights {
        let rect = CGRect(x: x, y: midY + 75 - h, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    // Subtle top highlight for depth.
    let gloss = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(pixels: points * scale).write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))
print("wrote \(sizes.count) icons to \(outputDir)")
