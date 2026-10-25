import AppKit

// A character pack is a folder containing:
//   agent.json  – frame size + named animations (see docs/character-packs.md)
//   map.png     – sprite sheet; every frame is a rectangle of `framesize` pixels
//
// Animation names follow the classic Office Assistant convention
// (RestPose, Greeting, Thinking, Explain, GetAttention, Idle1_1, ...),
// so the app's behaviors work with any pack that uses them.

struct Branch: Codable {
    var frameIndex: Int
    var weight: Int // percent; leftover probability falls through to the next frame
}

struct Branching: Codable {
    var branches: [Branch]
}

struct Frame: Codable {
    var duration: Int // milliseconds
    var images: [[Int]]? // [[x, y], ...] pixel offsets into the sheet, drawn in order (last on top)
    var exitBranch: Int? // frame to jump to when the animation is asked to stop
    var branching: Branching?
    var sound: String? // file in the pack's sounds/ folder, played when the frame appears
}

struct Animation: Codable {
    var frames: [Frame]
    var returnAnimation: String? // played automatically when this one finishes
}

struct PackManifest: Codable {
    var name: String?
    var framesize: [Int]
    var scale: Double? // points per sheet pixel; defaults to 1
    var animations: [String: Animation]
}

enum PackError: LocalizedError {
    case missingFile(String)
    case badSheet
    case badManifest(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "The pack is missing \(name)."
        case .badSheet: return "map.png couldn't be read as an image."
        case .badManifest(let why): return "agent.json is invalid: \(why)"
        }
    }
}

final class CharacterPack {
    let name: String
    let frameSize: CGSize // pixels
    let displayScale: CGFloat
    let animations: [String: Animation]
    let soundsFolder: URL?
    private let sheet: CGImage
    private var cache: [String: CGImage] = [:]

    var pointSize: CGSize {
        CGSize(width: frameSize.width * displayScale, height: frameSize.height * displayScale)
    }

    var animationNames: [String] { animations.keys.sorted() }

    /// Case-insensitive, since original characters use names like "RESTPOSE".
    func animation(named name: String) -> Animation? {
        animations[name] ?? animations.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    init(name: String, frameSize: CGSize, displayScale: CGFloat, animations: [String: Animation],
         sheet: CGImage, soundsFolder: URL? = nil) {
        self.name = name
        self.frameSize = frameSize
        self.displayScale = displayScale
        self.animations = animations
        self.sheet = sheet
        self.soundsFolder = soundsFolder
    }

    func soundURL(for frame: Frame) -> URL? {
        guard let sound = frame.sound, let soundsFolder else { return nil }
        return soundsFolder.appendingPathComponent(sound)
    }

    static func load(from folder: URL) throws -> CharacterPack {
        let manifestURL = folder.appendingPathComponent("agent.json")
        let sheetURL = folder.appendingPathComponent("map.png")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw PackError.missingFile("agent.json") }
        guard FileManager.default.fileExists(atPath: sheetURL.path) else { throw PackError.missingFile("map.png") }

        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw PackError.badManifest(error.localizedDescription)
        }
        guard manifest.framesize.count == 2 else { throw PackError.badManifest("framesize must be [width, height]") }

        guard let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PackError.badSheet }

        return CharacterPack(
            name: manifest.name ?? folder.deletingPathExtension().lastPathComponent,
            frameSize: CGSize(width: manifest.framesize[0], height: manifest.framesize[1]),
            displayScale: CGFloat(manifest.scale ?? 1),
            animations: manifest.animations,
            sheet: sheet,
            soundsFolder: folder.appendingPathComponent("sounds", isDirectory: true)
        )
    }

    /// Writes this pack as agent.json + map.png — handy as a template for artists.
    func export(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = PackManifest(name: name, framesize: [Int(frameSize.width), Int(frameSize.height)],
                                    scale: Double(displayScale), animations: animations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("agent.json"))
        guard let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]) else {
            throw PackError.badSheet
        }
        try png.write(to: folder.appendingPathComponent("map.png"))
    }

    /// Composites a frame's image layers. Returns nil for frames with no images
    /// (the player keeps showing the previous frame).
    func image(for frame: Frame) -> CGImage? {
        guard let layers = frame.images, !layers.isEmpty else { return nil }
        let key = layers.map { $0.map(String.init).joined(separator: ",") }.joined(separator: ";")
        if let cached = cache[key] { return cached }

        let w = Int(frameSize.width), h = Int(frameSize.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for layer in layers where layer.count == 2 {
            let rect = CGRect(x: layer[0], y: layer[1], width: w, height: h)
            if let tile = sheet.cropping(to: rect) {
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        let image = ctx.makeImage()
        cache[key] = image
        return image
    }
}
