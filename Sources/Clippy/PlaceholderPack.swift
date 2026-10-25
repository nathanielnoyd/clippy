import AppKit

/// An original stand-in paperclip, drawn in code so the repo ships no third-party art.
/// It uses the same animation names as classic packs, so behaviors behave identically.
enum PlaceholderPack {
    private struct Pose {
        var look = CGPoint.zero // pupil offset
        var blink = false
        var brow: CGFloat = 0 // eyebrow raise
        var tilt: CGFloat = 0 // degrees, positive leans left
        var squash: CGFloat = 1 // vertical scale, for bounces
    }

    private static let poses: [Pose] = [
        Pose(),                                   // 0 neutral
        Pose(blink: true),                        // 1 blink
        Pose(look: CGPoint(x: -2.5, y: 0)),       // 2 look left
        Pose(look: CGPoint(x: 2.5, y: 0)),        // 3 look right
        Pose(look: CGPoint(x: 1, y: 3)),          // 4 look up
        Pose(look: CGPoint(x: 1, y: 3), brow: 3), // 5 look up, brows raised
        Pose(brow: 2, tilt: 10),                  // 6 lean left
        Pose(brow: 2, tilt: -10),                 // 7 lean right
        Pose(brow: 4),                            // 8 brows raised
        Pose(brow: 1, squash: 0.9),               // 9 squashed
        Pose(look: CGPoint(x: -2, y: -2)),        // 10 look down-left (reading)
    ]

    private static let pointSize = CGSize(width: 124, height: 93)
    private static let pixelScale: CGFloat = 2

    static func make() -> CharacterPack {
        let fw = Int(pointSize.width * pixelScale), fh = Int(pointSize.height * pixelScale)
        let ctx = CGContext(data: nil, width: fw * poses.count, height: fh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, pose) in poses.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i * fw), y: 0)
            ctx.scaleBy(x: pixelScale, y: pixelScale)
            draw(pose)
            ctx.restoreGState()
        }
        NSGraphicsContext.current = previous

        return CharacterPack(name: "Placeholder Paperclip",
                             frameSize: CGSize(width: fw, height: fh),
                             displayScale: 1 / pixelScale,
                             animations: animations(frameWidth: fw),
                             sheet: ctx.makeImage()!)
    }

    // MARK: - Animations

    private static func animations(frameWidth fw: Int) -> [String: Animation] {
        func f(_ pose: Int, _ ms: Int, exit: Int? = nil, loopTo: Int? = nil, weight: Int = 100) -> Frame {
            Frame(duration: ms, images: [[pose * fw, 0]], exitBranch: exit,
                  branching: loopTo.map { Branching(branches: [Branch(frameIndex: $0, weight: weight)]) })
        }
        return [
            "RestPose": Animation(frames: [f(0, 100)]),
            "Idle1_1": Animation(frames: [f(0, 900), f(1, 120), f(0, 400), f(1, 120), f(0, 200)]),
            "IdleEyeBrowRaise": Animation(frames: [f(8, 500), f(0, 200), f(8, 300), f(0, 200)]),
            "IdleLookAround": Animation(frames: [f(2, 700), f(0, 200), f(3, 700), f(0, 200)]),
            "Greeting": Animation(frames: [f(9, 120), f(8, 200), f(6, 160), f(7, 160), f(6, 160), f(7, 160), f(0, 200)]),
            "Wave": Animation(frames: [f(6, 160), f(7, 160), f(6, 160), f(7, 160), f(0, 150)]),
            "GetAttention": Animation(frames: [f(9, 100), f(8, 150), f(9, 100), f(8, 250), f(0, 150)]),
            "Explain": Animation(frames: [f(8, 400), f(3, 500), f(8, 300), f(0, 200)]),
            "Writing": Animation(frames: [f(10, 400, exit: 2), f(1, 120, exit: 2, loopTo: 0), f(0, 100)]),
            // Loops until the player is asked to exit (when the answer arrives).
            "Thinking": Animation(frames: [f(4, 500, exit: 3), f(5, 500, exit: 3), f(4, 300, exit: 3, loopTo: 0), f(0, 100)]),
            "GoodBye": Animation(frames: [f(6, 160), f(7, 160), f(9, 200), f(1, 300)]),
        ]
    }

    // MARK: - Drawing (in 124×93 point space, y up)

    private static func draw(_ pose: Pose) {
        let cx: CGFloat = 62
        let transform = NSAffineTransform()
        transform.translateX(by: cx, yBy: 8)
        transform.rotate(byDegrees: pose.tilt)
        transform.scaleX(by: 1, yBy: pose.squash)
        transform.translateX(by: -cx, yBy: -8)
        transform.concat()

        // The wire: three nested U-loops, like a gem clip standing on end.
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

        // Eyes sit across the wire, slightly above the middle.
        for dx: CGFloat in [-8, 8] {
            let center = NSPoint(x: cx + dx, y: 58)
            let eye = NSBezierPath(ovalIn: NSRect(x: center.x - 6.5, y: center.y - 7.5, width: 13, height: 15))
            if pose.blink {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: center.x - 6, y: center.y))
                lid.curve(to: NSPoint(x: center.x + 6, y: center.y),
                          controlPoint1: NSPoint(x: center.x - 3, y: center.y - 3),
                          controlPoint2: NSPoint(x: center.x + 3, y: center.y - 3))
                lid.lineWidth = 1.6
                NSColor.black.setStroke()
                lid.stroke()
            } else {
                NSColor.white.setFill()
                eye.fill()
                eye.lineWidth = 1.2
                NSColor.black.setStroke()
                eye.stroke()
                let p = NSPoint(x: center.x + pose.look.x, y: center.y - 1 + pose.look.y)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 1.4, y: p.y + 0.4, width: 1.6, height: 1.6)).fill()
            }

            // Eyebrows: a thick wire arc, outer end lifted.
            let brow = NSBezierPath()
            let by = center.y + 10 + pose.brow
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
}
