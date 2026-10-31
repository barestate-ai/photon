# Atom runtime

The offline click-grounding runtime Photon calls before it asks Muse. One screenshot and one instruction in, one point out, over stdio JSON lines.

Vendored unchanged from the author's own MIT repository, `barestate-ai/atom-inference` at commit `f19f5d9`
(the files of `runtime/` that Photon needs, not `run.sh` or `test_runtime.py`, plus its top-level `LICENSE`). Two edits: `model-manifest.json` has an empty `baseURL` and a matching comment (the model now ships as a release archive) and `install_model.py` defaults its destination to the layout `scripts/setup-atom.sh` uses.

Licences: `LICENSE` (MIT, Microsoft Florence-2 and Samsung TinyClick) and `licenses/atom/{LICENSE,NOTICE.md}` (the model's own, packed into the archive).

Install: `make atom`, or `Photon.app/Contents/Resources/atom/setup-atom.sh` from a DMG install. `make atom-archive` packs the verified model for the release. The weights are never committed.
