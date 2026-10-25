import AppKit

// Converts a Microsoft Agent character file (.acs) you own into a character pack,
// entirely on this machine. Layout follows Remy Lebeau's published
// "Microsoft Agent Character Data Specification".
//
// Each distinct frame composition is flattened into one tile of the sprite sheet,
// so the resulting pack uses a single image layer per frame.

enum AcsError: LocalizedError {
    case notAcs
    case truncated(at: Int)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notAcs: return "That isn't a Microsoft Agent .acs file. (Office 97's .act files aren't supported.)"
        case .truncated(let at): return "The file ends unexpectedly (offset \(at))."
        case .corrupt(let why): return "The file looks damaged: \(why)"
        }
    }
}

// MARK: - Binary reader

private struct Reader {
    let data: [UInt8]
    var pos: Int

    init(_ data: [UInt8], at pos: Int = 0) {
        self.data = data
        self.pos = pos
    }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, pos + n <= data.count else { throw AcsError.truncated(at: pos) }
        defer { pos += n }
        return data[pos..<pos + n]
    }

    mutating func skip(_ n: Int) throws { _ = try bytes(n) }

    mutating func u8() throws -> UInt8 { try bytes(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        let s = b.startIndex
        return UInt32(b[s]) | UInt32(b[s + 1]) << 8 | UInt32(b[s + 2]) << 16 | UInt32(b[s + 3]) << 24
    }

    /// ULONG character count, UTF-16LE characters, then a null terminator when non-empty.
    mutating func string() throws -> String {
        let count = Int(try u32())
        guard count < 1 << 16 else { throw AcsError.corrupt("implausible string length \(count)") }
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        try skip(2)
        return String(decoding: units, as: UTF16.self)
    }

    mutating func locator() throws -> (offset: Int, size: Int) {
        (Int(try u32()), Int(try u32()))
    }
}

// MARK: - ACS model

private struct AcsFrameImage {
    var index: Int
    var x: Int
    var y: Int
}

private struct AcsFrame {
    var images: [AcsFrameImage]
    var sound: Int?
    var durationCs: Int // hundredths of a second
    var exitFrame: Int?
    var branches: [Branch]
}

private struct AcsAnimation {
    var name: String
    var returnAnimation: String?
    var frames: [AcsFrame]
}

private struct AcsImage {
    var width: Int
    var height: Int
    var pixels: [UInt8] // palette indices, bottom-up rows, 4-byte-aligned stride
    var stride: Int { (width + 3) & ~3 }
}

enum AcsImporter {
    /// Parses `acsURL` and writes a pack (agent.json + map.png) into `folder`.
    @discardableResult
    static func convert(_ acsURL: URL, to folder: URL) throws -> CharacterPack {
        let bytes = [UInt8](try Data(contentsOf: acsURL))
        var header = Reader(bytes)
        guard bytes.count >= 36, try header.u32() == 0xABCD_ABC3 else { throw AcsError.notAcs }
        let characterInfo = try header.locator()
        let animationList = try header.locator()
        let imageList = try header.locator()
        let audioList = try header.locator()

        let info = try readCharacterInfo(bytes, at: characterInfo.offset)
        let animations = try readAnimations(bytes, at: animationList.offset)
        let images = try readImages(bytes, at: imageList.offset)
        let sounds = audioList.size > 0 ? try readSounds(bytes, at: audioList.offset) : []

        let name = acsURL.deletingPathExtension().lastPathComponent.capitalized
        let pack = try buildPack(name: name, info: info, animations: animations, images: images,
                                 soundCount: sounds.count)
        try pack.export(to: folder)

        // Sounds are complete WAV files (PCM or MS ADPCM, both of which Core Audio plays).
        let soundsFolder = folder.appendingPathComponent("sounds", isDirectory: true)
        try? FileManager.default.removeItem(at: soundsFolder)
        if !sounds.isEmpty {
            try FileManager.default.createDirectory(at: soundsFolder, withIntermediateDirectories: true)
            for (i, wav) in sounds.enumerated() {
                try wav.write(to: soundsFolder.appendingPathComponent(soundFileName(i)))
            }
        }
        return try CharacterPack.load(from: folder)
    }

    private static func soundFileName(_ index: Int) -> String { "\(index).wav" }

    // MARK: Character info

    private struct CharacterInfo {
        var width: Int
        var height: Int
        var transparentIndex: Int
        var palette: [(r: UInt8, g: UInt8, b: UInt8)]
    }

    private static func readCharacterInfo(_ bytes: [UInt8], at offset: Int) throws -> CharacterInfo {
        var r = Reader(bytes, at: offset)
        try r.skip(4) // minor + major version
        _ = try r.locator() // localized info
        try r.skip(16) // GUID
        let width = Int(try r.u16())
        let height = Int(try r.u16())
        let transparent = Int(try r.u8())
        let flags = try r.u32()
        try r.skip(4) // animation set version

        if flags & 0x20 != 0 { // voice output info
            try r.skip(16 + 16 + 4 + 2) // engine GUID, mode GUID, speed, pitch
            if try r.u8() != 0 {
                try r.skip(2) // language id
                _ = try r.string() // dialect
                try r.skip(4) // gender, age
                _ = try r.string() // style
            }
        }
        if flags & 0x200 != 0 { // word balloon info
            try r.skip(2 + 12) // lines, chars per line, three colors
            _ = try r.string() // font name
            try r.skip(4 + 4 + 1 + 1) // height, weight, italic, unknown
        }

        let count = Int(try r.u32())
        guard (1...256).contains(count) else { throw AcsError.corrupt("palette has \(count) colors") }
        var palette: [(UInt8, UInt8, UInt8)] = []
        for _ in 0..<count {
            let quad = try r.bytes(4) // RGBQUAD: blue, green, red, reserved
            let s = quad.startIndex
            palette.append((quad[s + 2], quad[s + 1], quad[s]))
        }
        guard width > 0, height > 0 else { throw AcsError.corrupt("character size \(width)×\(height)") }
        return CharacterInfo(width: width, height: height, transparentIndex: transparent,
                             palette: palette.map { (r: $0.0, g: $0.1, b: $0.2) })
    }

    // MARK: Animations

    private static func readAnimations(_ bytes: [UInt8], at offset: Int) throws -> [AcsAnimation] {
        var list = Reader(bytes, at: offset)
        let count = Int(try list.u32())
        var result: [AcsAnimation] = []
        for _ in 0..<count {
            _ = try list.string() // upper-cased name
            let location = try list.locator()

            var r = Reader(bytes, at: location.offset)
            let name = try r.string()
            let transition = try r.u8() // 0 = return animation, 1 = exit branches, 2 = none
            let returnName = try r.string()
            let frameCount = Int(try r.u16())
            var frames: [AcsFrame] = []
            for _ in 0..<frameCount {
                let imageCount = Int(try r.u16())
                var images: [AcsFrameImage] = []
                for _ in 0..<imageCount {
                    images.append(AcsFrameImage(index: Int(try r.u32()), x: Int(try r.i16()), y: Int(try r.i16())))
                }
                let sound = Int(try r.u16()) // 0xFFFF = no sound
                let duration = Int(try r.u16())
                let exit = Int(try r.i16())
                let branchCount = Int(try r.u8())
                var branches: [Branch] = []
                for _ in 0..<branchCount {
                    branches.append(Branch(frameIndex: Int(try r.u16()), weight: Int(try r.u16())))
                }
                let overlayCount = Int(try r.u8()) // mouth shapes for lip sync; not used yet
                for _ in 0..<overlayCount {
                    try r.skip(1 + 1 + 2 + 1) // type, replaces top image, image index, unknown
                    let hasRegion = try r.u8() != 0
                    try r.skip(2 + 2 + 2 + 2) // x, y, width, height
                    if hasRegion { try r.skip(Int(try r.u32())) }
                }
                frames.append(AcsFrame(images: images, sound: sound == 0xFFFF ? nil : sound, durationCs: duration,
                                       exitFrame: exit >= 0 ? exit : nil, branches: branches))
            }
            result.append(AcsAnimation(name: name,
                                       returnAnimation: transition == 0 && !returnName.isEmpty ? returnName : nil,
                                       frames: frames))
        }
        return result
    }

    // MARK: Images

    private static func readImages(_ bytes: [UInt8], at offset: Int) throws -> [AcsImage] {
        var list = Reader(bytes, at: offset)
        let count = Int(try list.u32())
        var result: [AcsImage] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let location = try list.locator()
            try list.skip(4) // checksum

            var r = Reader(bytes, at: location.offset)
            try r.skip(1) // unknown
            let width = Int(try r.u16())
            let height = Int(try r.u16())
            let compressed = try r.u8() != 0
            let size = Int(try r.u32())
            let raw = Array(try r.bytes(size))

            let stride = (width + 3) & ~3
            let expected = stride * height
            let pixels = compressed ? try decompress(raw, outputSize: expected) : raw
            guard pixels.count >= expected else { throw AcsError.corrupt("image \(i) is too short") }
            result.append(AcsImage(width: width, height: height, pixels: pixels))
        }
        return result
    }

    // MARK: Sounds

    private static func readSounds(_ bytes: [UInt8], at offset: Int) throws -> [Data] {
        var list = Reader(bytes, at: offset)
        let count = Int(try list.u32())
        var result: [Data] = []
        for _ in 0..<count {
            let location = try list.locator()
            try list.skip(4) // checksum
            var r = Reader(bytes, at: location.offset)
            result.append(Data(try r.bytes(location.size)))
        }
        return result
    }

    /// Microsoft Agent's LZ77-style bit stream: bits read least-significant first,
    /// a leading 0x00 byte, and a 20-bit offset of 0xFFFFF marking the end.
    static func decompress(_ src: [UInt8], outputSize: Int) throws -> [UInt8] {
        guard src.count > 7, src[0] == 0 else { throw AcsError.corrupt("bad compressed image header") }
        var out = [UInt8](repeating: 0, count: outputSize)
        var o = 0
        var bit = 8 // skip the leading zero byte
        let totalBits = src.count * 8

        func read(_ n: Int) throws -> Int {
            guard bit + n <= totalBits else { throw AcsError.corrupt("compressed image ran past its end") }
            var value = 0
            for i in 0..<n {
                let b = bit + i
                if src[b >> 3] & (1 << (b & 7)) != 0 { value |= 1 << i }
            }
            bit += n
            return value
        }

        while true {
            if try read(1) == 0 {
                guard o < outputSize else { throw AcsError.corrupt("image data overflows") }
                out[o] = UInt8(try read(8))
                o += 1
                continue
            }

            var length = 2
            var ones = 0
            while ones < 3, try read(1) == 1 { ones += 1 }
            let offset: Int
            switch ones {
            case 0: offset = try read(6) + 1
            case 1: offset = try read(9) + 65
            case 2: offset = try read(12) + 577
            default:
                let v = try read(20)
                if v == 0xFFFFF { return out } // end of stream
                offset = v + 4673
                length += 1
            }

            // Up to 11 one-bits give the size of the extra length field; the
            // terminating zero bit is present even after the 11th one.
            var lengthBits = 0
            while lengthBits < 11, try read(1) == 1 { lengthBits += 1 }
            if lengthBits == 11 { _ = try read(1) }
            if lengthBits > 0 {
                length += (1 << lengthBits) - 1 + (try read(lengthBits))
            }

            guard offset <= o, o + length <= outputSize else {
                throw AcsError.corrupt("back-reference out of range")
            }
            for _ in 0..<length {
                out[o] = out[o - offset]
                o += 1
            }
        }
    }

    // MARK: Pack assembly

    private static func buildPack(name: String, info: CharacterInfo,
                                  animations: [AcsAnimation], images: [AcsImage],
                                  soundCount: Int) throws -> CharacterPack {
        let w = info.width, h = info.height

        // Each distinct composition of (image, x, y) layers becomes one tile.
        var tileIndex: [String: Int] = [:]
        var tiles: [[AcsFrameImage]] = []
        func tile(for layers: [AcsFrameImage]) -> Int {
            let key = layers.map { "\($0.index)@\($0.x),\($0.y)" }.joined(separator: ";")
            if let existing = tileIndex[key] { return existing }
            tiles.append(layers)
            tileIndex[key] = tiles.count - 1
            return tiles.count - 1
        }

        var packAnimations: [String: Animation] = [:]
        var tileOfFrame: [String: [Int?]] = [:]
        for animation in animations {
            tileOfFrame[animation.name] = animation.frames.map { $0.images.isEmpty ? nil : tile(for: $0.images) }
        }

        let columns = 32
        let rows = (tiles.count + columns - 1) / columns
        func origin(of tile: Int) -> [Int] { [(tile % columns) * w, (tile / columns) * h] }

        for animation in animations {
            let tilesForFrames = tileOfFrame[animation.name]!
            let frames = animation.frames.enumerated().map { i, frame in
                Frame(duration: frame.durationCs * 10,
                      images: tilesForFrames[i].map { [origin(of: $0)] },
                      exitBranch: frame.exitFrame,
                      branching: frame.branches.isEmpty ? nil : Branching(branches: frame.branches),
                      sound: frame.sound.flatMap { $0 < soundCount ? soundFileName($0) : nil })
            }
            packAnimations[animation.name] = Animation(frames: frames, returnAnimation: animation.returnAnimation)
        }

        // Render the sprite sheet (RGBA, top-down rows).
        let sheetW = columns * w, sheetH = max(rows, 1) * h
        var rgba = [UInt8](repeating: 0, count: sheetW * sheetH * 4)
        for (t, layers) in tiles.enumerated() {
            let tx = (t % columns) * w, ty = (t / columns) * h
            // The first image listed is the topmost, so paint from the end of the list.
            for layer in layers.reversed() {
                guard layer.index < images.count else { throw AcsError.corrupt("frame uses missing image \(layer.index)") }
                let image = images[layer.index]
                for y in 0..<image.height {
                    let fy = layer.y + y
                    guard fy >= 0, fy < h else { continue }
                    let row = (image.height - 1 - y) * image.stride // stored bottom-up
                    for x in 0..<image.width {
                        let fx = layer.x + x
                        guard fx >= 0, fx < w else { continue }
                        let index = Int(image.pixels[row + x])
                        guard index != info.transparentIndex, index < info.palette.count else { continue }
                        let c = info.palette[index]
                        let p = ((ty + fy) * sheetW + tx + fx) * 4
                        rgba[p] = c.r
                        rgba[p + 1] = c.g
                        rgba[p + 2] = c.b
                        rgba[p + 3] = 255
                    }
                }
            }
        }

        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let sheet = CGImage(width: sheetW, height: sheetH, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: sheetW * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw AcsError.corrupt("couldn't build the sprite sheet") }

        return CharacterPack(name: name, frameSize: CGSize(width: w, height: h), displayScale: 1,
                             animations: packAnimations, sheet: sheet)
    }
}
