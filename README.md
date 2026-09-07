# Flipgrade

Native macOS photo culling + grading.

**Photo editing shouldn’t be a chore.** Flip through a folder fast, star your favorites, grade later.

**Version:** v0.1.1 — star-layer cull, progressive RAW previews, Space 1:1 zoom.

## Cull model

- **0–3 stars** on each photo (`0` `1` `2` `3`)
- **Layers** (↑ / ↓): `ALL` → ≥1★ → ≥2★ → 3★
- Flip within a layer with ← / →
- Ratings saved to `_flipgrade/index.json`

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
- Grade tools (WB, LAB, crop) are not in this spike.
