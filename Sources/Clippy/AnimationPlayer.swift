import AppKit

/// Plays a pack's frame-based animations, honoring the classic branching rules:
/// each frame may randomly jump elsewhere (loops), and `exitBranch` gives a
/// graceful path out when the animation is asked to stop.
final class AnimationPlayer {
    private let pack: CharacterPack
    private let onFrame: (CGImage) -> Void
    private var timer: Timer?
    private var animation: Animation?
    private var index = 0
    private var exiting = false
    private var completion: (() -> Void)?

    var onSound: ((URL) -> Void)?
    private(set) var currentName: String?
    var isPlaying: Bool { animation != nil }

    init(pack: CharacterPack, onFrame: @escaping (CGImage) -> Void) {
        self.pack = pack
        self.onFrame = onFrame
    }

    func has(_ name: String) -> Bool { pack.animation(named: name) != nil }

    func play(_ name: String, completion: (() -> Void)? = nil) {
        guard let next = pack.animation(named: name), !next.frames.isEmpty else {
            completion?()
            return
        }
        timer?.invalidate()
        animation = next
        currentName = name
        index = 0
        exiting = false
        self.completion = completion
        showCurrentFrame()
    }

    /// Ask a looping animation to wind down via its exit branches.
    func exitCurrent() {
        exiting = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        animation = nil
        currentName = nil
        completion = nil
    }

    private func showCurrentFrame() {
        guard let animation, index >= 0, index < animation.frames.count else {
            finish()
            return
        }
        let frame = animation.frames[index]
        if let image = pack.image(for: frame) {
            onFrame(image)
        }
        if let sound = pack.soundURL(for: frame) {
            onSound?(sound)
        }
        let seconds = max(Double(frame.duration), 10) / 1000
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.advance()
        }
    }

    private func advance() {
        guard let animation, index < animation.frames.count else { return finish() }
        let frame = animation.frames[index]

        if exiting, let exit = frame.exitBranch {
            index = exit
        } else if !exiting, let branching = frame.branching {
            let roll = Int.random(in: 0..<100)
            var total = 0
            var target: Int?
            for branch in branching.branches {
                total += branch.weight
                if roll < total {
                    target = branch.frameIndex
                    break
                }
            }
            index = target ?? index + 1
        } else {
            index += 1
        }
        showCurrentFrame()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        let returnName = animation?.returnAnimation
        let finishedName = currentName
        animation = nil
        currentName = nil
        let done = completion
        completion = nil
        if let returnName, returnName != finishedName, has(returnName) {
            play(returnName, completion: done)
        } else {
            done?()
        }
    }
}
