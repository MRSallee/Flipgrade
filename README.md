# Flipgrade

Native macOS photo culling + grading.

**Photo editing shouldn’t be a chore.** Flip through a folder fast, star your favorites, grade later.

**Version:** v0.3.2 — momentum Cover Flow scroll, responsive previews, stage-capped layer culls.

## Cull model

- **0–3 stars** on each photo (`0` `1` `2` `3`)
- **Layers** (↑ / ↓): `ALL` → ≥1★ → ≥2★ → 3★
- Flip within a layer with ← / →
- Ratings saved to `_flipgrade/index.json`
- Finder tags follow stars: **1★ Orange · 2★ Yellow · 3★ Green** (cleared at 0★)
- **Enter** opens Grade on the current photo; **Esc** returns to Flip

## Grade

- Single large image + slim right inspector
- White balance (temp/tint), exposure, contrast
- Tone mode: **LAB** (default) or **RGB** (Settings / inspector)
- Recipes in `_flipgrade/recipes/<file>.json`
- **Space** 1:1 zoom with inspector floating over the image

## Run

```bash
chmod +x Scripts/run.sh
./Scripts/run.sh
```

## Requirements

- macOS 14+
- Swift 6 / Xcode Command Line Tools

## Notes

- `_comms/` is gitignored shared scratch (Zion ORF corpus).
- Grade recipes are non-destructive; demosaic stays on `RAWRender` / Display P3.
