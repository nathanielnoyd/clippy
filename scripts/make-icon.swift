// Draws Clippy's app icon and writes it as an .icns.
// Usage: swift scripts/make-icon.swift <out.icns> [pack folder]
//
// With a pack (e.g. Clippit imported from your own .acs), the icon shows its rest pose.
// Without one it falls back to PlaceholderPack's paperclip, so the repo still ships no
// third-party art. scripts/build-app.sh runs this for every build.
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "AppIcon.icns")
let character = args.count > 2 ? restPose(ofPackAt: URL(fileURLWithPath: args[2])) : nil

/// The first frame of the pack's rest pose, cropped to the character.
func restPose(ofPackAt folder: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("agent.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let size = json["framesize"] as? [Int], size.count == 2,
          let animations = json["animations"] as? [String: [String: Any]],
          let rest = animations.first(where: { $0.key.caseInsensitiveCompare("RestPose") == .orderedSame })?.value,
          let frame = (rest["frames"] as? [[String: Any]])?.first,
          let layers = frame["images"] as? [[Int]], !layers.isEmpty,
          let sheet = NSImage(contentsOf: folder.appendingPathComponent("map.png"))?
              .cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        FileHandle.standardError.write("make-icon: no usable pack at \(folder.path); using the placeholder\n".data(using: .utf8)!)
        return nil
    }
    let (w, h) = (size[0], size[1])
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for layer in layers where layer.count == 2 {
        if let tile = sheet.cropping(to: CGRect(x: layer[0], y: layer[1], width: w, height: h)) {
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    // Trim the transparent margin so the character fills the tile.
    let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var box = (minX: w, minY: h, maxX: -1, maxY: -1)
    for y in 0..<h { for x in 0..<w where pixels[y * w * 4 + x * 4 + 3] > 0 {
        box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
    } }
    guard box.maxX >= 0 else { return nil }
    return ctx.makeImage()!.cropping(to: CGRect(x: box.minX, y: box.minY,
                                                width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1))
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024)
    scale.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Drawing (in 1024×1024 space, y up)

func draw() {
    // Rounded tile on the macOS icon grid (824 pt with a soft drop shadow), in the balloon's yellow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(red: 1, green: 0.95, blue: 0.62, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 1, green: 0.99, blue: 0.82, alpha: 1),
               ending: NSColor(red: 0.99, green: 0.87, blue: 0.45, alpha: 1))!.draw(in: tilePath, angle: -90)

    if let character {
        // Fit inside a 620 pt square, keeping the pixel art crisp.
        let scale = 620 / CGFloat(max(character.width, character.height))
        let size = NSSize(width: CGFloat(character.width) * scale, height: CGFloat(character.height) * scale)
        NSGraphicsContext.current!.imageInterpolation = .none
        NSImage(cgImage: character, size: .zero)
            .draw(in: NSRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height))
        return
    }

    // PlaceholderPack's clip spans roughly x 46…78, y 11…92 in its 124×93 space; center and enlarge it.
    let t = NSAffineTransform()
    t.translateX(by: 512, yBy: 512)
    t.scale(by: 8.2)
    t.translateX(by: -62, yBy: -51)
    t.concat()
    drawClip()
}

/// PlaceholderPack.draw with the neutral pose.
func drawClip() {
    let cx: CGFloat = 62

    let wire = NSBezierPath()
    wire.move(to: NSPoint(x: cx - 5, y: 36))
    wire.line(to: NSPoint(x: cx - 5, y: 70))
    wire.appendArc(withCenter: NSPoint(x: cx, y: 70), radius: 5, startAngle: 180, endAngle: 0, clockwise: true)
    wire.line(to: NSPoint(x: cx + 5, y: 20))
    wire.appendArc(withCenter: NSPoint(x: cx - 4, y: 20), radius: 9, startAngle: 0, endAngle: 180, clockwise: true)
    wire.line(to: NSPoint(x: cx - 13, y: 76))
    wire.appendArc(withCenter: NSPoint(x: cx, y: 76), radius: 13, startAngle: 180, endAngle: 0, clockwise: true)
    wire.line(to: NSPoint(x: cx + 13, y: 30))
    wire.lineCapStyle = .round
    wire.lineJoinStyle = .round

    wire.lineWidth = 5
    NSColor(white: 0.30, alpha: 1).setStroke()
    wire.stroke()
    wire.lineWidth = 3
    NSColor(white: 0.72, alpha: 1).setStroke()
    wire.stroke()
    wire.lineWidth = 1
    NSColor(white: 0.95, alpha: 1).setStroke()
    wire.stroke()

    for dx: CGFloat in [-8, 8] {
        let center = NSPoint(x: cx + dx, y: 58)
        let eye = NSBezierPath(ovalIn: NSRect(x: center.x - 6.5, y: center.y - 7.5, width: 13, height: 15))
        NSColor.white.setFill()
        eye.fill()
        eye.lineWidth = 1.2
        NSColor.black.setStroke()
        eye.stroke()
        let p = NSPoint(x: center.x, y: center.y - 1)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 1.4, y: p.y + 0.4, width: 1.6, height: 1.6)).fill()

        let brow = NSBezierPath()
        let by = center.y + 10
        brow.move(to: NSPoint(x: center.x - 5, y: by + (dx < 0 ? 1 : 0)))
        brow.curve(to: NSPoint(x: center.x + 5, y: by + (dx > 0 ? 1 : 0)),
                   controlPoint1: NSPoint(x: center.x - 2, y: by + 3),
                   controlPoint2: NSPoint(x: center.x + 2, y: by + 3))
        brow.lineWidth = 2.2
        brow.lineCapStyle = .round
        NSColor(white: 0.25, alpha: 1).setStroke()
        brow.stroke()
    }
}

// MARK: - Iconset → icns

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
