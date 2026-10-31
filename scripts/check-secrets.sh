#!/bin/bash
# Fails when a secret-shaped token, a tailnet host name or a forbidden artifact is tracked, or
# when .env is not ignored. Reports paths only, never the matched text. Never reads .env.
cd "$(dirname "$0")/.." || exit 1
status=0

if ! git check-ignore -q .env; then
  echo "check-secrets: .env is not ignored"
  status=1
fi

while IFS= read -r path; do
  echo "check-secrets: key-shaped token in $path"
  status=1
done < <(git grep -lIE 'LLM_[0-9]+_' -- .)

while IFS= read -r path; do
  echo "check-secrets: tailnet host name in $path"
  status=1
done < <(git grep -lIE '[A-Za-z0-9-]+\.tail[0-9a-f]+\.ts\.net' -- .)

forbidden='^(Vendor/|Resources/Art/|\.build/|\.logs/|dist/)|(^|/)\.env($|\.)|\.sqlite|\.framework/|(^|/)libcef[^/]*\.(dylib|so|a)$|\.(safetensors|gguf|npz|bin)$'
while IFS= read -r path; do
  echo "check-secrets: forbidden file is tracked: $path"
  status=1
done < <(git ls-files | grep -E "$forbidden")

while IFS= read -r path; do
  [ -e "$path" ] || continue
  if [ "$(stat -f %z "$path")" -gt $((5 * 1024 * 1024)) ]; then
    echo "check-secrets: tracked file over 5 MB: $path"
    status=1
  fi
done < <(git ls-files)

[ "$status" -eq 0 ] && echo "check-secrets: ok"
exit "$status"
