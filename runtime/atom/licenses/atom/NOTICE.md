# Atom — upstream notice

Atom is a model from Barestate Labs. The shipped checkpoint is a
derivative artifact: Barestate selected, converted, packaged, and
evaluated it. Atom carries no Barestate gradient updates.

This notice covers the upstream components and must travel with any
distributed copy of the model package. It is a compliance artifact,
not marketing copy.

## Upstream components

| component | identifier | declared license | verified |
|---|---|---|---|
| Base architecture and remote code | `microsoft/Florence-2-base` | MIT | 2026-09-26, HF API `license:mit`, `gated:false` |
| Upstream model weights (Samsung TinyClick) | distributed via `Krystianz/TinyClick` rev `0e1356f0b7cfb416099207121f6a766818ab8a66`; same weights mirrored at `kzawistowsk/TinyClick` (`base_model: microsoft/Florence-2-base`) | MIT — "Model was originally shared on MIT license" | 2026-09-26, HF API `license:mit` |
| MLX conversion Atom was converted from | `lokendra77/TinyClick-mlx` rev `c450f599` | **none declared** | 2026-09-26, HF API tags contain no `license:*` |

## Points that need a human decision before public distribution

1. **The copyright holder lines in `LICENSE` are reconstructed, not
   copied.** The upstream model card does not publish a copyright line,
   and `github.com/SamsungLabs/TinyClick` and the original
   `Samsung/TinyClick` HF repo do not resolve publicly as of
   2026-09-26. Confirm the exact holder text from a first-party source
   if one becomes available, and replace the lines in `LICENSE`.
2. **The repository Atom was converted from declares no license.**
   `lokendra77/TinyClick-mlx` (`c450f599`) carries no license tag. The
   MIT basis comes from the upstream TinyClick distribution and the
   `microsoft/Florence-2-base` base, not from that repo. Keep this
   recorded.
3. **Closed source does not change any of the above.** MIT permits
   closed, commercial redistribution. It requires only that the
   copyright notice and permission notice travel with copies and
   substantial portions — which is exactly this file and `LICENSE`.
   Nothing here forces Barestate to publish source, weights, or
   training data.

## Packaging requirement

Any distributed bundle of the model must contain `LICENSE` and this
`NOTICE.md` alongside the weights, tokenizer, processor, and configs.
The local evaluation package at `~/.tinycua/models/tinyclick-4bit` stays
byte-frozen for benchmark reproducibility (169,049,084 bytes);
`scripts/check_atom_claims.py` verifies that these files exist in the
repo and are treated as part of the release bundle.
