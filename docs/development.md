# Development

```bash
swift run                 # run from source
scripts/build-app.sh      # build build/Clippy.app (needed for Siri / Shortcuts)
```

`swift run` builds work for everything except Siri, Shortcuts and Spotlight: those
need the App Intents metadata that `scripts/build-app.sh` adds. When you use
`swift run`, macOS's local-network permission belongs to your terminal app.

## Command line

| Command | What it does |
|---|---|
| `--ask apple "Say hi"` | Ask Apple Intelligence and print the answer |
| `--ask <host:port> <model> "Say hi"` | Ask an OpenAI-compatible server (`CLIPPY_API_KEY` for a key) |
| `--shortcut "<name>" "Say hi"` | Run a Shortcut with the text as input |
| `--import-acs <file.acs> <folder>` | Convert a Microsoft Agent character into a pack |
| `--export-placeholder <folder>` | Write the built-in paperclip as a template pack |
| `--open-settings` | Open Assistant Settings at launch |
| `--demo-ask "<question>"` | Ask a question through the same path Siri uses |
| `--demo-chat [--thinking] [--long]` | Fill the balloon with a sample thread |

Prefix with `swift run Clippy`, e.g. `swift run Clippy --ask apple "Say hi"`.

## Layout

| File | What it does |
|---|---|
| `App.swift` | Menu bar item, pack loading, command-line flags |
| `CharacterController.swift` | Window, idle behavior, speech balloon, asking the assistant |
| `CharacterWindow.swift` | Transparent floating panel, drag and click handling |
| `AnimationPlayer.swift` | Frame timing, branching, exit branches |
| `CharacterPack.swift` | Pack format: loading, compositing, export |
| `AcsImporter.swift` | Reads Microsoft Agent `.acs` files and writes a pack |
| `PlaceholderPack.swift` | The original stand-in paperclip, drawn in code |
| `SpeechBubble.swift` | The yellow balloon: chat thread, New chat, Ask |
| `AppleIntelligence.swift` | Apple's on-device model as a brain |
| `AskClippyIntent.swift` | "Ask Clippy", timer and Pomodoro actions for Siri, Shortcuts and Spotlight |
| `HideRequest.swift` | Reads "go away for an hour" and friends from the chat |
| `Timers.swift` | Reads timer requests from the chat; the countdown and Pomodoro cycle |
| `Assistant.swift` | `AssistantProvider` protocol, OpenAI-compatible streaming client, offline joke mode |
| `AssistantSettings.swift` | Settings window, saved settings, Keychain |
| `Shortcuts.swift` | Runs Shortcuts with the `shortcuts` command-line tool |
| `Support/Info.plist` | Bundle id, local-network permission text, http allowance |
| `scripts/build-app.sh` | Builds `build/Clippy.app` with the App Intents metadata |
| `scripts/make-icon.swift` | Draws the app icon from your imported character (or the placeholder) as an `.icns` |
