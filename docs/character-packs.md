# Character packs

A pack is a folder containing:

- `map.png`: a sprite sheet. Every frame is a `framesize` rectangle placed anywhere in it.
- `agent.json`: the frame size and the named animations.
- `sounds/` (optional): audio files that frames refer to by name.

```json
{
  "name": "My Character",
  "framesize": [124, 93],
  "scale": 1,
  "animations": {
    "Thinking": {
      "frames": [
        { "duration": 500, "images": [[0, 0]], "exitBranch": 2 },
        { "duration": 500, "images": [[124, 0]], "exitBranch": 2,
          "branching": { "branches": [{ "frameIndex": 0, "weight": 100 }] } },
        { "duration": 100, "images": [[248, 0]] }
      ]
    }
  }
}
```

| Field | Meaning |
|---|---|
| `images` | `[x, y]` pixel offsets into the sheet, composited in order with the last on top. A frame with no images keeps showing the previous one. |
| `branching` | Weighted random jumps (out of 100). This is how idle animations loop. Leftover probability falls through to the next frame. |
| `exitBranch` | Where to jump when the app wants the animation to stop. |
| `scale` | Points per sheet pixel. Use `0.5` for @2x art. |
| `sound` | Per frame, optional: a file in `sounds/`, played when that frame appears. |
| `returnAnimation` | Per animation, optional: played automatically when it finishes. |

Animation names are matched without regard to case. The app looks for the classic
names: `RestPose`, `Greeting`, `GetAttention`, `Thinking`, `Explain`, `Wave`,
`GoodBye`, and anything starting with `Idle` for random idle behavior.

To get a working template, export the built-in placeholder:

```bash
swift run Clippy --export-placeholder "Packs/My Character"
```

`Packs/` is git-ignored, so packs you keep there never get committed.

## Importing Microsoft Agent characters

`--import-acs` (or 📎 → **Import .acs Character…**) converts any Microsoft Agent
`.acs` file into a pack. It decodes every image, flattens each frame into one
sprite-sheet tile, and keeps frame timing, branching, exit branches and the
character's sound effects. Lip-sync mouth overlays aren't imported yet.

Office 97's `.act` format isn't supported.
