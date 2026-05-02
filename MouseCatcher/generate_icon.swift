#!/usr/bin/env swift
import AppKit
import CoreGraphics

let brandBlue = NSColor(red: 0x00/255.0, green: 0x40/255.0, blue: 0x80/255.0, alpha: 1.0)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = size
    let cx = s / 2
    let cy = s / 2

    // Brand-blue gradient rounded rect background.
    let bgRect = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    brandBlue.setFill()
    bgPath.fill()

    let cs = CGColorSpaceCreateDeviceRGB()
    if let depth = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(white: 1.0, alpha: 0.08).cgColor,
            NSColor(white: 0.0, alpha: 0.10).cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.saveGState()
        ctx.addPath(bgPath.cgPath)
        ctx.clip()
        ctx.drawRadialGradient(
            depth,
            startCenter: CGPoint(x: cx, y: cy + s * 0.12),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: s * 0.55,
            options: []
        )
        ctx.restoreGState()
    }

    // Crosshair / target rings — concentric circles + cardinal ticks.
    ctx.saveGState()
    ctx.addPath(bgPath.cgPath)
    ctx.clip()

    let strong = NSColor(white: 1.0, alpha: 0.85)
    let soft   = NSColor(white: 1.0, alpha: 0.40)
    let stroke = s * 0.014
    let thin   = s * 0.008

    let outerR = s * 0.30
    let midR   = s * 0.22
    let innerR = s * 0.13

    ctx.setStrokeColor(strong.cgColor)
    ctx.setLineWidth(stroke)
    ctx.strokeEllipse(in: CGRect(x: cx - outerR, y: cy - outerR, width: outerR * 2, height: outerR * 2))

    ctx.setStrokeColor(soft.cgColor)
    ctx.setLineWidth(thin)
    ctx.strokeEllipse(in: CGRect(x: cx - midR, y: cy - midR, width: midR * 2, height: midR * 2))
    ctx.strokeEllipse(in: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))

    // Cardinal tick marks just outside the outer ring.
    ctx.setStrokeColor(soft.cgColor)
    ctx.setLineWidth(thin)
    ctx.setLineCap(.round)
    let tickInner = outerR + s * 0.04
    let tickOuter = tickInner + s * 0.06
    ctx.move(to: CGPoint(x: cx - tickOuter, y: cy)); ctx.addLine(to: CGPoint(x: cx - tickInner, y: cy))
    ctx.move(to: CGPoint(x: cx + tickInner, y: cy)); ctx.addLine(to: CGPoint(x: cx + tickOuter, y: cy))
    ctx.move(to: CGPoint(x: cx, y: cy - tickOuter)); ctx.addLine(to: CGPoint(x: cx, y: cy - tickInner))
    ctx.move(to: CGPoint(x: cx, y: cy + tickInner)); ctx.addLine(to: CGPoint(x: cx, y: cy + tickOuter))
    ctx.strokePath()

    // Cursor arrow shape, white-filled with a subtle dark stroke, drawn so its
    // tip sits roughly at the bullseye. Coordinates are in a 0–1 unit space
    // measured from the cursor's tip; the path is then translated/scaled so
    // the tip lands at (cx, cy).
    let cursorScale = s * 0.18
    let tx = cx
    let ty = cy
    func p(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
        // Cursor is drawn in a unit space where tip is (0, 0); positive uy
        // goes downward (screen-style). We map to context coordinates where y
        // increases upward, so flip uy.
        return CGPoint(x: tx + ux * cursorScale, y: ty - uy * cursorScale)
    }
    let cursor = NSBezierPath()
    cursor.move(to:    p(0.00, 0.00))   // tip
    cursor.line(to:    p(0.00, 1.40))   // long left edge down
    cursor.line(to:    p(0.42, 1.04))   // notch into the body
    cursor.line(to:    p(0.66, 1.62))   // tail bottom-left
    cursor.line(to:    p(0.86, 1.52))   // tail bottom-right
    cursor.line(to:    p(0.62, 0.94))   // back up to body edge
    cursor.line(to:    p(1.04, 0.78))   // top-right of body
    cursor.close()

    NSColor(white: 1.0, alpha: 1.0).setFill()
    cursor.fill()
    NSColor(red: 0.05, green: 0.20, blue: 0.40, alpha: 1.0).setStroke()
    cursor.lineWidth = s * 0.008
    cursor.stroke()

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        let points = UnsafeMutablePointer<NSPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for i in 0..<elementCount {
            let element = self.element(at: i, associatedPoints: points)
            switch element {
            case .moveTo:           path.move(to: points[0])
            case .lineTo:           path.addLine(to: points[0])
            case .curveTo:          path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:     path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:        path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let destDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let sizes: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png",256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png",512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png",1024),
]

for (filename, pixels) in sizes {
    let image = drawIcon(size: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { continue }
    let url = URL(fileURLWithPath: destDir).appendingPathComponent(filename)
    try! png.write(to: url)
}
