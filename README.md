# Clippy for macOS

Your favorite Office Assistant, as a native Mac app. Loads the original character
from a Microsoft Agent `.acs` file, and answers questions using Apple's
on-device model or any OpenAI-compatible API.

<p align="center">
  <img src="docs/images/demo.gif" width="480" alt="Clippy greets you, thinks, and answers a question in its yellow speech balloon">
</p>

<p align="center">
  <img src="docs/images/getartsy.gif" width="186" alt="Clippy turning into a paintbrush (GetArtsy)">
  <img src="docs/images/emptytrash.gif" width="186" alt="Clippy emptying the trash (EmptyTrash)">
  <img src="docs/images/idleatom.gif" width="186" alt="Clippy becoming an atom while idle (IdleAtom)">
</p>

## Features

- Imports Microsoft Agent `.acs` characters with their animations, idle loops and
  sounds.
- Answers with Apple Intelligence on your Mac, a model server like Ollama or
  LM Studio, a hosted OpenAI-compatible API, or a Shortcut.
- Sits above your other windows and loops through original animations.
- Hides when you tell it to ("go away for an hour", "come back at 3pm").
- Sets timers and runs Pomodoros ("set a timer for 10 minutes to check the oven").
  The countdown shows in the menu bar and Clippy pops up when it's done.
- Supports custom characters through a sprite sheet and JSON
  [pack format](docs/character-packs.md).

## Requirements

- macOS 14 or later
- Xcode 26 or later to build
- For Apple Intelligence: macOS 26 on a supported Mac, with Apple Intelligence
  turned on
- For the original artwork: `CLIPPIT.ACS` from Office

## Installation

```bash
git clone https://github.com/nathanielnoyd/clippy.git
cd clippy
scripts/build-app.sh
open build/Clippy.app
```

This builds `build/Clippy.app`. Move it to `/Applications` and add it to
**System Settings → General → Login Items** if you want it to start at login.

Until you import a character, the app shows a placeholder paperclip.

## Importing the original Clippy

`CLIPPIT.ACS` shipped with Office 2000, XP and 2003. It's on the install media, or
in `C:\Windows\msagent\chars` on a machine with Office installed. Copies can also be
found online by searching for `CLIPPIT.ACS`. 

1. Copy `CLIPPIT.ACS` to your Mac.
2. Choose **📎 → Import .acs Character…** and select the file.

The character is converted to a pack in
`~/Library/Application Support/Clippy/Packs/` and loaded. Frames, timing, idle loops
and sounds are kept. Lip-sync mouth shapes aren't imported, and Office 97's `.act`
format isn't supported.

Other Agent characters (Merlin, Rover, Links, The Genius) import the same way.

## Choosing a model

Open **📎 → Assistant Settings…** (⌘,).

### Apple Intelligence

Choose **Apple Intelligence (on this Mac)**. Settings shows whether the model is
available. It runs entirely on your Mac and works best for short questions.

### OpenAI-compatible API

Choose **Model server (OpenAI-compatible)**, enter the address, click **Check
Connection**, pick a model and click **Save**. Anything that serves
`/v1/chat/completions` works:

| Server | Address | To reach it from another machine |
|---|---|---|
| [Ollama](https://ollama.com) | `http://<host>:11434` | Start it with `OLLAMA_HOST=0.0.0.0` |
| [LM Studio](https://lmstudio.ai) | `http://<host>:1234` | Turn on **Serve on Local Network** |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | `http://<host>:8080` | `llama-server --host 0.0.0.0` |
| [vLLM](https://github.com/vllm-project/vllm) | `http://<host>:8000` | `--host 0.0.0.0` |
| Hosted APIs | The provider's base URL, e.g. `https://api.openai.com/v1` | |

- A bare `host:port` gets `/v1` appended. Enter a full URL if your server uses a
  different path.
- The API key is optional and stored in the Keychain.
- The last 20 messages are sent with each question.
- macOS asks for Local Network access the first time Clippy connects to another
  machine.

### Shortcut

Under **When you ask Clippy**, choose **Run a Shortcut** and select. Your question
is passed in as text and the Shortcut's output is shown in the balloon.

### Offline jokes

Defaults to replies with canned lines.

## Using Clippy

- Click Clippy to open the balloon, type a question and press Return.
- Drag Clippy to move it.
- **New chat** clears the conversation.
- The **📎** menu lets you play animations, change the size (1×, 1.5×, 2×), toggle
  sounds, load or import a character, or go back to the placeholder.

## Making your own characters

A pack is a folder with a sprite sheet (`map.png`), a manifest (`agent.json`) with
frames, timing and branching, and optional sounds. Export the placeholder to start
from:

```bash
swift run Clippy --export-placeholder "Packs/My Character"
```

Load it with **📎 → Load Character Pack…**. The format is described in
[docs/character-packs.md](docs/character-packs.md).

## Development

Run from source with `swift run`. See [docs/development.md](docs/development.md)
for command-line flags and the code layout.

## License

[MIT](LICENSE).

This is an unofficial fan project, not affiliated with Microsoft.
