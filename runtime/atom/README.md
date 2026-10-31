# Atom runtime

The offline click-grounding runtime Photon calls before it asks Muse. One screenshot and one instruction in, one point out, over stdio JSON lines.

Vendored unchanged from the author's own MIT repository, `barestate-ai/atom-inference` at commit `f19f5d9`
(the files of `runtime/` that Photon needs, not `run.sh` or `test_runtime.py`, plus its top-level `LICENSE`). Two edits: `model-manifest.json` has an empty `baseURL` and a matching comment (the model now ships as a release archive) and `install_model.py` defaults its destination to the layout `scripts/setup-atom.sh` uses.

Licences: `LICENSE` (MIT, Microsoft Florence-2 and Samsung TinyClick) and `licenses/atom/{LICENSE,NOTICE.md}` (the model's own, packed into the archive).

Install: `make atom`, or `Photon.app/Contents/Resources/atom/setup-atom.sh` from a DMG install. `make atom-archive` packs the verified model for the release. The weights are never committed.

## Slim runtime lock (2026-11-01, D71)

The lock vendored from upstream pinned 61 dists (torchvision, scipy, opencv, fastapi/uvicorn, mlx-audio, sounddevice, …) and a fresh runtime measured 2.4 GB, 1.1 GB of it the uv cache kept inside the runtime directory. `requirements.in` now lists only what `atom_runtime.py` and the model's `processing_florence2.py` import at runtime: mlx, mlx-metal, mlx-vlm, transformers, tokenizers, pillow, numpy and torch (torch stays: the Florence-2 processor imports it at module level; torchvision went, proven unused by a real ground in a scratch venv). `requirements.lock` was regenerated with `uv pip compile --generate-hashes --python-version 3.11 --python-platform aarch64-apple-darwin` (mlx 0.32.2, mlx-vlm 0.7.1 and transformers 5.17.0 kept exactly); it still carries mlx-vlm 0.7.1's declared dependencies (fastapi, uvicorn, opencv, mlx-audio, …) because `uv pip sync --require-hashes` needs the full declared closure. `bootstrap.sh` deletes the uv cache after the sync. A fresh `scripts/setup-atom.sh runtime` into an empty directory now measures 1.2 GB.
