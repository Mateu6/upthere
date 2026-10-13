// Overlay art for demo renders (ffmpeg here has no drawtext):
//   swift art.swift notch <width-px> <height-px> <radius-px> out.png
//   swift art.swift caption <width-px> <title> <subtitle|-> out.png
import AppKit

func write(_ image: NSBitmapImageRep, to path: String) {
    try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func canvas(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Deep indigo with a glow `glowY` px from the top.
func drawBackdrop(_ ctx: CGContext, _ w: Int, _ h: Int, glowY: CGFloat) {
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.035, green: 0.035, blue: 0.075, alpha: 1),
        CGColor(red: 0.075, green: 0.06, blue: 0.16, alpha: 1),
        CGColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1),
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.42, green: 0.40, blue: 0.95, alpha: 0.38),
        CGColor(red: 0.42, green: 0.40, blue: 0.95, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) - glowY)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                           endRadius: CGFloat(max(w, h)) * 0.5, options: [])
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "notch":
    // The physical notch: screen captures don't include it, so the ears
    // would float around a strip of menu bar without it.
    let (w, h, r) = (Int(args[2])!, Int(args[3])!, CGFloat(Double(args[4])!))
    let image = canvas(w, h) { ctx in
        ctx.setFillColor(.black)
        // Origin is bottom-left: round the bottom corners only.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: CGFloat(h)))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: r, y: 0), radius: r)
        path.addLine(to: CGPoint(x: CGFloat(w) - r, y: 0))
        path.addArc(tangent1End: CGPoint(x: CGFloat(w), y: 0), tangent2End: CGPoint(x: CGFloat(w), y: r), radius: r)
        path.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h)))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
    write(image, to: args[5])

case "caption":
    let width = Int(args[2])!
    let title = args[3]
    let subtitle = args[4] == "-" ? nil : args[4]
    let scale = CGFloat(width) / 1080
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let titleText = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 76 * scale, weight: .bold),
        .foregroundColor: NSColor.white, .paragraphStyle: center, .kern: -1.2 * scale,
    ])
    let subtitleText = subtitle.map {
        NSAttributedString(string: $0, attributes: [
            .font: NSFont.systemFont(ofSize: 40 * scale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62), .paragraphStyle: center,
        ])
    }
    let inset = 72 * scale
    let box = CGSize(width: CGFloat(width) - inset * 2, height: .greatestFiniteMagnitude)
    let titleHeight = ceil(titleText.boundingRect(with: box, options: .usesLineFragmentOrigin).height)
    let gap = 22 * scale
    let subtitleHeight = subtitleText.map { ceil($0.boundingRect(with: box, options: .usesLineFragmentOrigin).height) } ?? 0
    let height = Int(titleHeight + (subtitleText == nil ? 0 : gap + subtitleHeight) + 8 * scale)
    let image = canvas(width, height) { _ in
        let top = CGFloat(height)
        titleText.draw(with: CGRect(x: inset, y: top - titleHeight, width: box.width, height: titleHeight),
                       options: .usesLineFragmentOrigin)
        subtitleText?.draw(with: CGRect(x: inset, y: top - titleHeight - gap - subtitleHeight, width: box.width,
                                        height: subtitleHeight), options: .usesLineFragmentOrigin)
    }
    write(image, to: args[5])

case "backdrop":
    // Deep indigo, a glow where the notch strip sits, the repo at the foot.
    let (w, h, glowY, footerY) = (Int(args[2])!, Int(args[3])!, CGFloat(Double(args[4])!), CGFloat(Double(args[5])!))
    let footer = args[6] == "-" ? nil : args[6]
    let image = canvas(w, h) { ctx in
        drawBackdrop(ctx, w, h, glowY: glowY)
        guard let footer else { return }
        let center2 = NSMutableParagraphStyle()
        center2.alignment = .center
        let scale = CGFloat(min(w, h)) / 1080
        let mark = NSMutableAttributedString(string: "upthere", attributes: [
            .font: NSFont.systemFont(ofSize: 44 * scale, weight: .bold), .foregroundColor: NSColor.white,
            .paragraphStyle: center2, .kern: -0.6 * scale,
        ])
        mark.append(NSAttributedString(string: "\n" + footer, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 26 * scale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5), .paragraphStyle: center2,
        ]))
        mark.draw(with: CGRect(x: 0, y: footerY, width: CGFloat(w), height: 120 * scale),
                  options: .usesLineFragmentOrigin)
    }
    write(image, to: args[7])

case "card":
    // Intro/outro: the icon, a big title, a line under it, a small mono line.
    let (w, h) = (Int(args[2])!, Int(args[3])!)
    let (icon, title, subtitle, small) = (args[4], args[5], args[6], args[7])
    let scale = CGFloat(min(w, h)) / 1080
    let image = canvas(w, h) { ctx in
        drawBackdrop(ctx, w, h, glowY: CGFloat(h) * 0.42)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 120 * scale, weight: .heavy), .foregroundColor: NSColor.white,
            .paragraphStyle: center, .kern: -3 * scale,
        ])
        let lines = NSMutableParagraphStyle()
        lines.alignment = .center
        lines.paragraphSpacingBefore = 18 * scale
        text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 46 * scale, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: lines,
        ]))
        if small != "-" {
            let gap = NSMutableParagraphStyle()
            gap.alignment = .center
            gap.paragraphSpacingBefore = 44 * scale
            text.append(NSAttributedString(string: "\n" + small, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 32 * scale, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5), .paragraphStyle: gap,
            ]))
        }
        let inset = 80 * scale
        let box = CGSize(width: CGFloat(w) - inset * 2, height: .greatestFiniteMagnitude)
        let textHeight = ceil(text.boundingRect(with: box, options: .usesLineFragmentOrigin).height)
        let iconSide: CGFloat = icon == "-" ? 0 : 260 * scale
        let iconGap: CGFloat = icon == "-" ? 0 : 40 * scale
        // Centre the whole block a little above the middle.
        let blockTop = CGFloat(h) / 2 + (iconSide + iconGap + textHeight) / 2 + 40 * scale
        if icon != "-", let iconImage = NSImage(contentsOfFile: icon) {
            iconImage.draw(in: CGRect(x: (CGFloat(w) - iconSide) / 2, y: blockTop - iconSide,
                                      width: iconSide, height: iconSide))
        }
        text.draw(with: CGRect(x: inset, y: blockTop - iconSide - iconGap - textHeight, width: box.width,
                               height: textHeight), options: .usesLineFragmentOrigin)
    }
    write(image, to: args[8])

default:
    print("usage: art.swift notch W H R out.png | caption W title subtitle|- out.png"
        + " | backdrop W H glowY footerY footer|- out.png | card W H icon|- title subtitle small|- out.png")
    exit(1)
}
