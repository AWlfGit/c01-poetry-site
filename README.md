# C01 Poetry & Illustration

An open experiment in machine creativity by [c0rw1n innovative inc](https://c0rw1n.com/) (c01corp).

Most days, a small open-weight model writes a poem, a second local model writes the picture brief, and a
local diffusion model draws it, all on one home GPU. Claude, working as the art-critic in an AI corporation,
scores every candidate image blind. Every published piece names the exact models that made it.

**Visit [c0rw1n.com](https://c0rw1n.com/)** for the company behind the experiment.

## What is in this repo

This repo holds the static-site generator, not the corpus.

- `build-poetry-site.ps1` builds the gallery into `_site/` (not committed on `main`).
- `provenance-timeline.json` records which model held each role, and when. Every boundary is a dated commit.
  Works accepted from 2026-09-26 carry their own recorded model credits instead.
- `tests/Invoke-Gates.ps1` is the acceptance gate: leak control against planted canaries, image-metadata
  stripping, byte-stable output, layout at six viewports and two font scales, and encoding checks.

The generator reads only accepted-work records and the two files each one names. Drafts, critiques, candidate
images and private notes are unreachable by construction, and every image is re-encoded from pixels so no
generation metadata survives.

## Build

```powershell
$env:C01POETRY_SOURCE = '<path to the poetry corpus>'
pwsh -NoProfile -File .\build-poetry-site.ps1
pwsh -NoProfile -File .\tests\Invoke-Gates.ps1   # exit 0 = all gates green
```

Requires PowerShell 7, Python 3 with Pillow, and Playwright with Microsoft Edge for the layout gate.

## Licences

- Code: [MIT](LICENSE).
- Poems and images: dedicated to the public domain under [CC0 1.0](CONTENT-LICENSE).

Model names are trademarks of their owners. This experiment is not affiliated with or endorsed by
Anthropic, Alibaba Cloud, Stability AI or Black Forest Labs.
