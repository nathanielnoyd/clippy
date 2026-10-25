import AppKit
import SwiftUI

@main
enum Main {
    static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-placeholder"), i + 1 < args.count {
            do {
                try PlaceholderPack.make().export(to: URL(fileURLWithPath: args[i + 1]))
                print("Exported placeholder pack to \(args[i + 1])")
                exit(0)
            } catch {
                print("Export failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        if let i = args.firstIndex(of: "--import-acs"), i + 2 < args.count {
            do {
                let pack = try AcsImporter.convert(URL(fileURLWithPath: args[i + 1]),
                                                   to: URL(fileURLWithPath: args[i + 2]))
                print("Imported \(pack.name): \(pack.animations.count) animations → \(args[i + 2])")
                exit(0)
            } catch {
                print("Import failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        // Shortcut check from the terminal: --shortcut <name> <input>
        if let i = args.firstIndex(of: "--shortcut"), i + 2 < args.count {
            Task.detached {
                do {
                    let output = try await ShortcutRunner.run(args[i + 1], input: args[i + 2])
                    print(output.isEmpty ? "(ran, no text output)" : output)
                    exit(0)
                } catch {
                    print("Failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            DispatchSemaphore(value: 0).wait()
        }

        // Check a brain from the terminal:
        //   --ask <server> <model> <question>   (a model server)
        //   --ask apple <question>              (Apple Intelligence on this Mac)
        if let i = args.firstIndex(of: "--ask"), i + 2 < args.count {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let provider: AssistantProvider
                    let question: String
                    if args[i + 1] == "apple" {
                        guard #available(macOS 26, *) else { throw AppleIntelligenceError("Needs macOS 26 or later.") }
                        provider = AppleIntelligenceProvider()
                        question = args[i + 2]
                    } else {
                        guard i + 3 < args.count else { throw AssistantError.badURL("missing model or question") }
                        let server = OpenAICompatibleProvider(
                            baseURL: try OpenAICompatibleProvider.normalize(args[i + 1]), model: args[i + 2],
                            apiKey: ProcessInfo.processInfo.environment["CLIPPY_API_KEY"])
                        print("Models: \(try await server.listModels().joined(separator: ", "))")
                        provider = server
                        question = args[i + 3]
                    }
                    for try await piece in provider.stream([ChatMessage(role: "user", content: question)]) {
                        print(piece, terminator: "")
                        fflush(stdout)
                    }
                    print()
                    exit(0)
                } catch {
                    print("\nFailed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            done.wait()
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon; lives in the menu bar
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let packPathKey = "lastPackPath"
    private static let sizeKey = "characterSize"
    private static let soundsKey = "soundsEnabled"
    private static let hiddenKey = "hidden"
    private static let returnDateKey = "hiddenUntil"
    private static let hideDurations: [(title: String, minutes: Double)] = [
        ("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("4 Hours", 240),
    ]
    private static let timerMinutes: [Double] = [1, 5, 10, 15, 25, 30, 45, 60]
    private static let sizes: [(title: String, value: Double)] = [("1×", 1), ("1.5×", 1.5), ("2×", 2)]

    private var statusItem: NSStatusItem!
    private var controller: CharacterController!
    private var assistant = AssistantSettings()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.sizeKey: 1.0, Self.soundsKey: true])

        controller = CharacterController(pack: savedPack() ?? PlaceholderPack.make())
        controller.sizeMultiplier = CGFloat(defaults.double(forKey: Self.sizeKey))
        controller.soundsEnabled = defaults.bool(forKey: Self.soundsKey)
        assistant = AssistantSettings.load()
        controller.assistant = assistant
        ClippyBridge.current = controller
        controller.contextMenu = { [weak self] in self?.makeContextMenu() }
        if defaults.bool(forKey: Self.hiddenKey) { // stay hidden across relaunches, unless it's time
            let until = defaults.object(forKey: Self.returnDateKey) as? Date
            if until.map({ $0 > .now }) ?? true { controller.hide(until: until, animated: false) }
        }
        controller.onVisibilityChange = { [weak self] in self?.visibilityChanged() }
        controller.show()
        if CommandLine.arguments.contains("--open-settings") { openSettings() }
        // Sends a question through the same path as Siri's "Ask Clippy" (for testing).
        if let i = CommandLine.arguments.firstIndex(of: "--demo-ask"), i + 1 < CommandLine.arguments.count {
            let question = CommandLine.arguments[i + 1]
            Task { @MainActor in _ = await controller.answerFromSiri(question) }
        }
        if CommandLine.arguments.contains("--demo-chat") {
            controller.showDemoChat(thinking: CommandLine.arguments.contains("--thinking"),
                                   long: CommandLine.arguments.contains("--long"))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📎"
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular) // steady countdown
        controller.timer.onTick = { [weak self] in self?.updateCountdown() }
        controller.timer.onChange = { [weak self] in
            self?.updateCountdown()
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    /// "📎 24:59" in the menu bar while a timer runs.
    private func updateCountdown() {
        let timer = controller.timer
        statusItem.button?.title = timer.isRunning ? "📎 \(timer.clock)" : "📎"
    }

    private func visibilityChanged() {
        let defaults = UserDefaults.standard
        defaults.set(controller.isHidden, forKey: Self.hiddenKey)
        defaults.set(controller.returnDate, forKey: Self.returnDateKey)
        rebuildMenu()
    }

    /// "Hide Clippy" / "Show Clippy", plus "Hide For" with a return time.
    private func addVisibilityItems(to menu: NSMenu) {
        if controller.isHidden {
            let show = NSMenuItem(title: "Show Clippy", action: #selector(showCharacter), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            if let date = controller.returnDate {
                menu.addItem(withTitle: "Back \(describeReturn(date))", action: nil, keyEquivalent: "")
            }
        } else {
            let hide = NSMenuItem(title: "Hide Clippy", action: #selector(hideCharacter), keyEquivalent: "")
            hide.target = self
            menu.addItem(hide)
        }

        let hideFor = NSMenuItem(title: controller.isHidden ? "Bring Back In" : "Hide For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for option in Self.hideDurations {
            let item = NSMenuItem(title: option.title, action: #selector(hideForDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.minutes
            sub.addItem(item)
        }
        let tomorrow = NSMenuItem(title: "Tomorrow Morning", action: #selector(hideUntilTomorrow), keyEquivalent: "")
        tomorrow.target = self
        sub.addItem(tomorrow)
        hideFor.submenu = sub
        menu.addItem(hideFor)
    }

    /// The running timer with Skip and Cancel, or ways to start one.
    private func addTimerItems(to menu: NSMenu) {
        let timer = controller.timer
        if timer.isRunning, let title = timer.title, let end = timer.endDate {
            let icon = timer.isPomodoro ? "🍅" : "⏱"
            menu.addItem(withTitle: "\(icon) \(title), until \(end.formatted(date: .omitted, time: .shortened))",
                         action: nil, keyEquivalent: "")
            if timer.isPomodoro {
                let skip = NSMenuItem(title: "Skip to Next", action: #selector(skipTimer), keyEquivalent: "")
                skip.target = self
                menu.addItem(skip)
            }
            let cancel = NSMenuItem(title: timer.isPomodoro ? "Stop Pomodoro" : "Cancel Timer",
                                    action: #selector(cancelTimer), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            return
        }

        let pomodoro = NSMenuItem(title: "Start Pomodoro", action: #selector(startPomodoro), keyEquivalent: "")
        pomodoro.target = self
        menu.addItem(pomodoro)
        let timerItem = NSMenuItem(title: "Start Timer", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for minutes in Self.timerMinutes {
            let item = NSMenuItem(title: ClippyTimer.describe(minutes * 60), action: #selector(startTimer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            sub.addItem(item)
        }
        timerItem.submenu = sub
        menu.addItem(timerItem)
    }

    @objc private func startPomodoro() {
        controller.timer.startPomodoro()
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        controller.timer.start(seconds: minutes * 60, label: nil)
    }

    @objc private func skipTimer() {
        controller.timer.skip()
    }

    @objc private func cancelTimer() {
        controller.timer.cancel()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        addVisibilityItems(to: menu)
        menu.addItem(.separator())
        addTimerItems(to: menu)
        return menu
    }

    @objc private func hideCharacter() {
        controller.hide()
    }

    @objc private func showCharacter() {
        controller.reappear()
    }

    @objc private func hideForDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Double else { return }
        controller.hide(until: .now.addingTimeInterval(minutes * 60))
    }

    @objc private func hideUntilTomorrow() {
        controller.hide(until: HideRequest.date(in: "tomorrow morning"))
    }

    private func savedPack() -> CharacterPack? {
        guard let path = UserDefaults.standard.string(forKey: Self.packPathKey) else { return nil }
        return try? CharacterPack.load(from: URL(fileURLWithPath: path))
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        addVisibilityItems(to: menu)
        menu.addItem(.separator())
        addTimerItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Character: \(controller.pack.name)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Brain: \(assistant.summary)", action: nil, keyEquivalent: "")
        let settings = NSMenuItem(title: "Assistant Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let animate = NSMenuItem(title: "Play Animation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in controller.pack.animationNames {
            let item = NSMenuItem(title: name, action: #selector(playAnimation(_:)), keyEquivalent: "")
            item.target = self
            sub.addItem(item)
        }
        animate.submenu = sub
        menu.addItem(animate)

        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for option in Self.sizes {
            let item = NSMenuItem(title: option.title, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.value
            item.state = Double(controller.sizeMultiplier) == option.value ? .on : .off
            sizeMenu.addItem(item)
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = controller.soundsEnabled ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())

        let load = NSMenuItem(title: "Load Character Pack…", action: #selector(loadPack), keyEquivalent: "o")
        load.target = self
        menu.addItem(load)
        let importAcs = NSMenuItem(title: "Import .acs Character…", action: #selector(importAcsFile), keyEquivalent: "i")
        importAcs.target = self
        menu.addItem(importAcs)
        let reset = NSMenuItem(title: "Use Placeholder Paperclip", action: #selector(usePlaceholder), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.alphaValue = controller.isHidden ? 0.5 : 1 // dimmed while Clippy is away
    }

    @objc private func playAnimation(_ sender: NSMenuItem) {
        controller.play(sender.title)
    }

    @objc private func openSettings() {
        let model = AssistantSettingsModel(assistant)
        model.onCancel = { [weak self] in self?.settingsWindow?.close() }
        model.onSave = { [weak self] settings in
            guard let self else { return }
            do {
                if settings.destination == .balloon { _ = try settings.makeProvider() } // validates the address
                controller.assistant = settings
                settings.save()
                assistant = settings
                rebuildMenu()
                settingsWindow?.close()
            } catch {
                model.status = error.localizedDescription
            }
        }

        settingsWindow?.close()
        let hosting = NSHostingController(rootView: AssistantSettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize] // window follows the section's height
        let window = NSWindow(contentViewController: hosting)
        window.title = "Assistant Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        controller.sizeMultiplier = CGFloat(value)
        UserDefaults.standard.set(value, forKey: Self.sizeKey)
        rebuildMenu()
    }

    @objc private func toggleSounds() {
        controller.soundsEnabled.toggle()
        UserDefaults.standard.set(controller.soundsEnabled, forKey: Self.soundsKey)
        rebuildMenu()
    }

    @objc private func loadPack() {
        let open = NSOpenPanel()
        open.message = "Choose a character pack folder (contains agent.json and map.png)"
        open.canChooseDirectories = true
        open.canChooseFiles = false
        NSApp.activate()
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            use(try CharacterPack.load(from: url), savedAt: url)
        } catch {
            showError("Couldn't load that character", error)
        }
    }

    /// Converts an .acs file the user owns into a pack under Application Support, then loads it.
    @objc private func importAcsFile() {
        let open = NSOpenPanel()
        open.message = "Choose a Microsoft Agent character file (.acs) that you own"
        open.allowedContentTypes = [.data]
        open.canChooseDirectories = false
        NSApp.activate()
        guard open.runModal() == .OK, let acs = open.url else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent("Clippy/Packs", isDirectory: true)
                .appendingPathComponent(acs.deletingPathExtension().lastPathComponent.capitalized, isDirectory: true)
            use(try AcsImporter.convert(acs, to: folder), savedAt: folder)
        } catch {
            showError("Couldn't import that file", error)
        }
    }

    private func use(_ pack: CharacterPack, savedAt folder: URL) {
        controller.swap(to: pack)
        UserDefaults.standard.set(folder.path, forKey: Self.packPathKey)
        rebuildMenu()
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func usePlaceholder() {
        UserDefaults.standard.removeObject(forKey: Self.packPathKey)
        controller.swap(to: PlaceholderPack.make())
        rebuildMenu()
    }
}
