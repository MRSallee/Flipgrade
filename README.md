# Flipgrade

Native macOS photo culling + grading.

**Photo editing shouldn’t be a chore.** Flip through a folder fast, mark Keepers / Archive / Rejects, grade later.

**Version:** v0.1.0 — Phase 0 spike (Cover Flow cull). Phase 1 cull product next.

## What’s in v0.1.0

- Open a folder of RAWs/JPEGs (auto-opens `_comms/Zion` if present)
- Cover Flow–style Flip browser (interrupt-safe stacked flips)
- Embedded-preview pipeline (avoid full demosaic while culling)
- Keys: `←` `→` flip · `P` keeper · `A` archive · `X` reject · `U` undecided · `⌘O` open folder
- Decisions saved to `_flipgrade/index.json` inside the folder

## Requirements

- macOS 14+
- Swift 6 / Xcode Command Line Tools (full Xcode optional for now)

## Run

```bash
chmod +x Scripts/run.sh
./Scripts/run.sh
```

That builds a `Flipgrade.app` bundle and opens it with LaunchServices (needed for a real window/Dock icon). Raw `.build/debug/Flipgrade` often stays invisible when launched from a tooling shell.

## Notes

- `_comms/` is gitignored shared scratch (Zion ORF corpus).
- Grade tools (WB, LAB, crop) are intentionally not in this spike.
