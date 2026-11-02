// Renders the app icon into the asset catalog.
//   swift scripts/make-icon.swift
// The icon is drawn in code so it can be tweaked and regenerated: a
// space-black MacBook, tilted, with the notch and its two lit ears, on the
// Midnight palette (docs/design-language.md, colour round 2). It stands in
// until the hand-drawn Icon Composer version lands.
import AppKit

let outputDir = "Upthere/Resources/Assets.xcassets/AppIcon.appiconset"

// MARK: Colour

/// OKLCH → sRGB, with chroma pulled in until the colour fits.
func oklch(_ l: Double, _ c: Double, _ h: Double, _ alpha: CGFloat = 1) -> CGColor {
    func rgb(_ c: Double) -> (Double, Double, Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let L = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let M = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let S = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }
    var chroma = c
    while chroma > 0, !{ let (r, g, b) = rgb(chroma); return [r, g, b].allSatisfy { $0 >= 0 && $0 <= 1 } }() { chroma -= 0.002 }
    let (r, g, b) = rgb(max(chroma, 0))
    func encode(_ x: Double) -> CGFloat { let x = min(1, max(0, x)); return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) }
    return CGColor(srgbRed: encode(r), green: encode(g), blue: encode(b), alpha: alpha)
}

/// The Midnight palette, as OKLCH (l, c, h).
enum Palette {
    static let skyTop = (0.38, 0.04, 254.0), skyBottom = (0.17, 0.025, 264.0)
    static let screen = [(0.16, 0.025, 262.0), (0.27, 0.04, 256.0), (0.42, 0.05, 250.0)]
    /// The one warm light: the screen's horizon and the lit left ear.
    static let glow = (0.80, 0.12, 62.0), ear = (0.82, 0.12, 62.0)
    static let starlight = (0.93, 0.027, 80.0)
    /// Space black body.
    static let rim = (0.30, 0.006, 300.0), deckFar = (0.22, 0.006, 300.0), deckNear = (0.36, 0.008, 290.0), edge = (0.17, 0.005, 300.0)
}
func tone(_ t: (Double, Double, Double), _ alpha: CGFloat = 1) -> CGColor { oklch(t.0, t.1, t.2, alpha) }
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

// MARK: Shapes

func superellipse(in rect: CGRect, exponent n: CGFloat = 4.4) -> CGPath {
    let path = CGMutablePath(), a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi, ct = cos(t), st = sin(t)
        let p = CGPoint(x: rect.midX + a * copysign(pow(abs(ct), 2 / n), ct), y: rect.midY + b * copysign(pow(abs(st), 2 / n), st))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// Rounded rect with separate top and bottom radii (top-left origin).
func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + top, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: top)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: bottom)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bottom)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: top)
    p.closeSubpath()
    return p
}

/// The notch (with its ears) hanging from `top`: round bottom corners and
/// the small outward fillets a real MacBook notch has.
func notch(centerX: CGFloat, top: CGFloat, width w: CGFloat, height h: CGFloat) -> CGPath {
    let r = h * 0.42, f = h * 0.22, l = centerX - w / 2, rt = centerX + w / 2
    let p = CGMutablePath()
    p.move(to: CGPoint(x: l - f, y: top))
    p.addLine(to: CGPoint(x: rt + f, y: top))
    p.addQuadCurve(to: CGPoint(x: rt, y: top + f), control: CGPoint(x: rt, y: top))
    p.addLine(to: CGPoint(x: rt, y: top + h - r))
    p.addQuadCurve(to: CGPoint(x: rt - r, y: top + h), control: CGPoint(x: rt, y: top + h))
    p.addLine(to: CGPoint(x: l + r, y: top + h))
    p.addQuadCurve(to: CGPoint(x: l, y: top + h - r), control: CGPoint(x: l, y: top + h))
    p.addLine(to: CGPoint(x: l, y: top + f))
    p.addQuadCurve(to: CGPoint(x: l - f, y: top), control: CGPoint(x: l, y: top))
    p.closeSubpath()
    return p
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) { ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath() }
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, _ color: (Double, Double, Double), _ alpha: CGFloat) {
    ctx.drawRadialGradient(gradient([tone(color, alpha), tone(color, 0)], [0, 1]), startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

// MARK: Laptop

/// A small 3D model (lid + deck, one lid width = 1) seen by a perspective
/// camera, then fitted into the icon.
struct Camera {
    var yaw: CGFloat = 0, pitch: CGFloat = 14, lean: CGFloat = 12, depth: CGFloat = 0.34, lens: CGFloat = 3.2
    let lidHeight: CGFloat = 0.64
    var origin = CGPoint.zero, scale: CGFloat = 1

    /// Lid coordinates: x right, y down from its top edge.
    func lid(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = lidHeight - y, a = lean * .pi / 180
        return (x - 0.5, h * cos(a), -h * sin(a))
    }
    /// Deck coordinates: x right, z towards the viewer, y up.
    func deck(_ x: CGFloat, _ z: CGFloat, _ y: CGFloat = 0) -> (CGFloat, CGFloat, CGFloat) { (x - 0.5, y, z) }

    func projected(_ p: (CGFloat, CGFloat, CGFloat)) -> CGPoint {
        let yaw = self.yaw * .pi / 180, pitch = self.pitch * .pi / 180
        let x = p.0, y = p.1 - lidHeight * 0.35, z = p.2 - depth * 0.3
        let x1 = x * cos(yaw) + z * sin(yaw), z1 = -x * sin(yaw) + z * cos(yaw)
        let y2 = y * cos(pitch) - z1 * sin(pitch), z2 = y * sin(pitch) + z1 * cos(pitch)
        let d = lens - z2
        return CGPoint(x: x1 / d * lens, y: -y2 / d * lens)
    }
    func point(_ p: (CGFloat, CGFloat, CGFloat)) -> CGPoint {
        let q = projected(p)
        return CGPoint(x: origin.x + q.x * scale, y: origin.y + q.y * scale)
    }

    /// Centres the laptop in a `width`×`height` box around `center`.
    mutating func fit(center: CGPoint, width: CGFloat, height: CGFloat) {
        let corners = [lid(0, 0), lid(1, 0), lid(0, lidHeight), lid(1, lidHeight), deck(0, depth), deck(1, depth), deck(0, depth, -0.02), deck(1, depth, -0.02)].map(projected)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        scale = min(width / (xs.max()! - xs.min()!), height / (ys.max()! - ys.min()!))
        origin = CGPoint(x: center.x - (xs.min()! + xs.max()!) / 2 * scale, y: center.y - (ys.min()! + ys.max()!) / 2 * scale)
    }

    /// Flattens a path drawn in a plane's 2D coordinates and projects it.
    func project(_ path: CGPath, onto plane: (CGFloat, CGFloat) -> (CGFloat, CGFloat, CGFloat)) -> CGPath {
        let out = CGMutablePath()
        var current = CGPoint.zero
        func line(_ p: CGPoint) { out.addLine(to: point(plane(p.x, p.y))) }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; out.move(to: point(plane(current.x, current.y)))
            case .addLineToPoint:
                let end = e.points[0]
                for i in 1...8 { let t = CGFloat(i) / 8; line(CGPoint(x: current.x + (end.x - current.x) * t, y: current.y + (end.y - current.y) * t)) }
                current = end
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                for i in 1...12 {
                    let t = CGFloat(i) / 12, m = 1 - t
                    line(CGPoint(x: m * m * current.x + 2 * m * t * c.x + t * t * end.x, y: m * m * current.y + 2 * m * t * c.y + t * t * end.y))
                }
                current = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for i in 1...12 {
                    let t = CGFloat(i) / 12, m = 1 - t, a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
                    line(CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * end.x, y: a * current.y + b * c1.y + c * c2.y + d * end.y))
                }
                current = end
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
        }
        return out
    }
}

func drawLaptop(_ ctx: CGContext, _ cam: Camera) {
    let lid = { (x: CGFloat, y: CGFloat) in cam.lid(x, y) }
    let deck = { (x: CGFloat, z: CGFloat) in cam.deck(x, z) }
    let h = cam.lidHeight, d = cam.depth

    // Deck: front edge, top surface, keyboard well, trackpad.
    let front = CGMutablePath()
    front.addLines(between: [cam.deck(0, d), cam.deck(1, d), cam.deck(1, d, -0.02), cam.deck(0, d, -0.02)].map(cam.point))
    front.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: CGColor(gray: 0, alpha: 0.45))
    fill(ctx, front, tone(Palette.edge))
    ctx.restoreGState()
    fill(ctx, cam.project(roundedRect(CGRect(x: 0, y: 0, width: 1, height: d), top: 0.005, bottom: 0.03), onto: deck),
         gradient([tone(Palette.deckFar), tone(Palette.deckNear)], [0, 1]), from: cam.point(cam.deck(0.5, 0)), to: cam.point(cam.deck(0.5, d)))
    fill(ctx, cam.project(roundedRect(CGRect(x: 0.08, y: d * 0.08, width: 0.84, height: d * 0.4), top: 0.015, bottom: 0.015), onto: deck), CGColor(gray: 0, alpha: 0.5))
    fill(ctx, cam.project(roundedRect(CGRect(x: 0.33, y: d * 0.56, width: 0.34, height: d * 0.36), top: 0.02, bottom: 0.02), onto: deck), CGColor(gray: 0, alpha: 0.08))

    // Lid: rim, bezel, screen with its one warm horizon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.3))
    fill(ctx, cam.project(roundedRect(CGRect(x: 0, y: 0, width: 1, height: h), top: 0.04, bottom: 0.008), onto: lid), tone(Palette.rim))
    ctx.restoreGState()
    fill(ctx, cam.project(roundedRect(CGRect(x: 0.012, y: 0.012, width: 0.976, height: h - 0.02), top: 0.032, bottom: 0.004), onto: lid), CGColor(gray: 0.03, alpha: 1))
    let screenRect = CGRect(x: 0.032, y: 0.032, width: 0.936, height: h - 0.06)
    let screen = cam.project(roundedRect(screenRect, top: 0.02, bottom: 0), onto: lid)
    fill(ctx, screen, gradient(Palette.screen.map { tone($0) }, [0, 0.55, 1]),
         from: cam.point(cam.lid(0.5, screenRect.minY)), to: cam.point(cam.lid(0.5, screenRect.maxY)))
    ctx.saveGState(); ctx.addPath(screen); ctx.clip()
    glow(ctx, at: cam.point(cam.lid(0.5, screenRect.maxY)), radius: 0.55 * cam.scale, Palette.glow, 0.45)
    ctx.restoreGState()

    // The notch with its ears, drawn larger than life so it reads small.
    let k: CGFloat = 1.5, notchW = 0.13 * k, notchH = 0.05 * k, ear = 0.11 * k
    fill(ctx, cam.project(notch(centerX: 0.5, top: screenRect.minY - 0.002, width: notchW + ear * 2, height: notchH), onto: lid), CGColor(gray: 0, alpha: 1))
    let pillH = notchH * 0.3, pillW = ear * 0.58, pillY = screenRect.minY + (notchH - pillH) / 2 + notchH * 0.04
    let leftX = 0.5 - notchW / 2 - ear / 2 - pillW / 2, rightX = 0.5 + notchW / 2 + ear / 2 - pillW / 2
    glow(ctx, at: cam.point(cam.lid(leftX + pillW / 2, pillY + pillH / 2)), radius: pillW * 0.9 * cam.scale, Palette.ear, 0.35)
    for (x, color) in [(leftX, tone(Palette.ear)), (rightX, tone(Palette.starlight))] {
        let pill = CGPath(roundedRect: CGRect(x: x, y: pillY, width: pillW, height: pillH), cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
        fill(ctx, cam.project(pill, onto: lid), color)
    }
}

// MARK: Icon

/// Draws the 1024×1024 master. Coordinates use a top-left origin.
func drawIcon(_ ctx: CGContext) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: 824pt body centred, room for the drop shadow.
    let body = CGRect(x: 100, y: 92, width: 824, height: 824)
    let shape = superellipse(in: body)

    ctx.saveGState()
    // Shadow offsets ignore the flipped CTM: negative height points down.
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
    fill(ctx, shape, tone(Palette.skyBottom))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([tone(Palette.skyTop), tone(Palette.skyBottom)], [0, 1]),
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    glow(ctx, at: CGPoint(x: 512, y: 700), radius: 500, Palette.glow, 0.28)
    var camera = Camera()
    camera.fit(center: CGPoint(x: 512, y: 512), width: 720, height: 640)
    drawLaptop(ctx, camera)
    // Subtle top highlight for depth.
    ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)], [0, 1]),
                           start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
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
