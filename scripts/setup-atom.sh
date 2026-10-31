#!/bin/bash
# Installs Atom, the local click-grounding model Photon uses before it asks Muse.
#   setup-atom.sh [runtime|model|all]   default all
#   setup-atom.sh pack                  repo only: write dist/atom-tinyclick-4bit-v1.tar.gz
# Overrides: BARESTATE_RUNTIME_DIR, BARESTATE_ATOM_MODEL, ATOM_ARCHIVE (a local archive),
#   ATOM_URL (model archive URL; default the public R2 host, GitHub release as fallback).
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1 # the bundled copy is sealed by codesign

HERE="$(cd "$(dirname "$0")" && pwd)"
ATOM="$HERE"
[[ -f "$ATOM/bootstrap.sh" ]] || ATOM="$HERE/../runtime/atom" # repo checkout; the app bundle has them beside this script
SUPPORT="$HOME/Library/Application Support/Barestate"
RUNTIME_DIR="${BARESTATE_RUNTIME_DIR:-$SUPPORT/Runtime}"
MODEL_DIR="${BARESTATE_ATOM_MODEL:-$SUPPORT/models/atom/tinyclick-4bit-v1/tinyclick-4bit}"
ASSET="atom-tinyclick-4bit-v1.tar.gz"
# Public Cloudflare R2 host; the private GitHub release below is the documented fallback.
ATOM_URL="${ATOM_URL:-https://download.barestate.xyz/$ASSET}"
RELEASE="v0.1.0"
REPO="barestate-ai/photon"

die() { echo "setup-atom: $*" >&2; exit 1; }

# The private venv once it exists: a clean Mac has no usable system python3 without developer tools.
py() {
  if [[ -x "$RUNTIME_DIR/venv/bin/python" ]]; then echo "$RUNTIME_DIR/venv/bin/python"; else echo python3; fi
}

free_mb() { # <path that may not exist yet>
  local dir="$1"
  while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
  df -Pk "$dir" | awk 'NR==2 { print int($4 / 1024) }'
}

need_mb() { # <path> <megabytes>
  local free
  free="$(free_mb "$1")"
  (( free >= $2 )) || die "needs $2 MB free near $1, only $free MB available"
}

verified() { # every manifest file present with its pinned size and SHA-256
  "$(py)" -c '
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from install_model import verify_directory
verify_directory(Path(sys.argv[2]), json.load(open(sys.argv[1] + "/model-manifest.json")))
' "$ATOM" "$MODEL_DIR" 2>/dev/null
}

runtime() {
  if [[ ! -x "$RUNTIME_DIR/venv/bin/python" ]]; then need_mb "$RUNTIME_DIR" 2500; fi
  BARESTATE_RUNTIME_DIR="$RUNTIME_DIR" "$ATOM/bootstrap.sh"
}

fetch() { # <dir>: the public archive URL, falling back to the private GitHub release
  if curl --fail --remove-on-error --location --silent --show-error --proto '=https' --tlsv1.2 \
    "$ATOM_URL" -o "$1/$ASSET"; then
    return
  fi
  rm -f "$1/$ASSET" # a partial download must not defeat the fallback
  echo "setup-atom: $ATOM_URL failed; trying the GitHub release" >&2
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release download "$RELEASE" --repo "$REPO" --pattern "$ASSET" --dir "$1" >&2
  else
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      "https://github.com/$REPO/releases/download/$RELEASE/$ASSET" -o "$1/$ASSET"
  fi
}

model() {
  if verified; then echo "atom model already installed and verified: $MODEL_DIR" >&2; return; fi
  [[ ! -e "$MODEL_DIR" ]] || die "$MODEL_DIR exists but does not match the manifest; move it away and re-run"
  need_mb "$MODEL_DIR" 600
  local archive
  # not local: the EXIT trap runs after this function returns
  work="$(mktemp -d "${TMPDIR:-/tmp}/atom-setup.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  archive="${ATOM_ARCHIVE:-}"
  if [[ -z "$archive" ]]; then fetch "$work"; archive="$work/$ASSET"; fi
  [[ -f "$archive" ]] || die "no archive at $archive"
  mkdir "$work/package"
  tar -xzf "$archive" -C "$work/package"
  "$(py)" "$ATOM/install_model.py" --source "file://$work/package" --destination "$MODEL_DIR"
}

pack() {
  [[ "$ATOM" == "$HERE/../runtime/atom" ]] || die "pack runs from a repository checkout"
  verified || die "$MODEL_DIR does not match the manifest"
  local out
  out="$(cd "$ATOM/../.." && pwd)/dist"
  mkdir -p "$out"
  local files
  files="$("$(py)" -c 'import json,sys; print("\n".join(f["path"] for f in json.load(open(sys.argv[1]))["files"]))' "$ATOM/model-manifest.json")"
  # MIT requires the licence and notice to travel with the weights.
  # shellcheck disable=SC2086
  COPYFILE_DISABLE=1 tar -czf "$out/$ASSET" -C "$MODEL_DIR" $files -C "$ATOM" licenses/atom/LICENSE licenses/atom/NOTICE.md
  echo "$out/$ASSET"
}

mode="${1:-all}"
case "$mode" in
  runtime | model | all)
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "Atom requires an Apple Silicon Mac"
    [[ "$mode" == model ]] || runtime
    [[ "$mode" == runtime ]] || model
    ;;
  pack) pack ;;
  *) die "usage: setup-atom.sh [runtime|model|all|pack]" ;;
esac
