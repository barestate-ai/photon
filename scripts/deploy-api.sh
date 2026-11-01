#!/bin/bash
# Deploys the barestate-api Worker (server/barestate-api/). Idempotent: it creates the KV
# namespace, the META_API_KEY secret and the invites key only when they are missing, syncs
# the namespace id into wrangler.toml only when it differs, and deploys. It never prints
# the Meta key, invite codes or tokens, and it touches nothing else in the account.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
API=server/barestate-api

export CLOUDFLARE_ACCOUNT_ID=476f3d30838d09d1253b76f0c92c265d
export WRANGLER_SEND_METRICS=false

# 1. KV namespace barestate-api-kv.
ns_id=$(wrangler kv namespace list | python3 -c '
import json, sys
print(next((ns["id"] for ns in json.load(sys.stdin) if ns["title"] == "barestate-api-kv"), ""))
')
if [ -z "$ns_id" ]; then
  ns_id=$(wrangler kv namespace create barestate-api-kv | sed -n 's/.*id = "\([0-9a-f]\{32\}\)".*/\1/p' | head -1)
  [ -n "$ns_id" ] || { echo "deploy-api: could not read the new namespace id" >&2; exit 1; }
  echo "deploy-api: created KV namespace barestate-api-kv"
else
  echo "deploy-api: KV namespace barestate-api-kv exists"
fi

# 2. Sync the namespace id into wrangler.toml when it differs.
if grep -q "id = \"$ns_id\"" "$API/wrangler.toml"; then
  echo "deploy-api: wrangler.toml already pins the namespace"
else
  python3 - "$API/wrangler.toml" "$ns_id" <<'PY'
import re, sys
path, ns_id = sys.argv[1], sys.argv[2]
src = open(path).read()
out, n = re.subn(r'(binding\s*=\s*"STATE",\s*id\s*=\s*")[0-9a-f]{32}(")', r'\g<1>' + ns_id + r'\g<2>', src)
if n != 1:
    sys.exit("deploy-api: STATE kv binding not found in " + path)
open(path, "w").write(out)
PY
  echo "deploy-api: synced the namespace id into $API/wrangler.toml"
fi

# 3. The Meta key as Worker secret META_API_KEY, from .env, never echoed.
if (cd "$API" && wrangler secret list) | grep -qw META_API_KEY; then
  echo "deploy-api: secret META_API_KEY exists"
else
  # Same parsing as the app's own .env loader (ModelKey.swift): whitespace, export, quotes.
  # A miss fails here, before wrangler can store an empty secret (pipefail propagates it).
  python3 - "$ROOT/.env" <<'PY' | (cd "$API" && wrangler secret put META_API_KEY)
import sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("export "):
        line = line[7:]
    if line.startswith("MODEL_API_KEY="):
        v = line.split("=", 1)[1].strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        sys.stdout.write(v)
        break
else:
    sys.exit("deploy-api: .env has no MODEL_API_KEY")
PY
  echo "deploy-api: stored META_API_KEY from .env"
fi

# 4. The invites key once, with 3 fresh random codes, never printed. The owner reads them
#    with: wrangler kv key get --remote --namespace-id <id> invites
#    (kv key commands need --remote: without it wrangler 4.156 silently uses local
#    miniflare state under .wrangler/.)
if wrangler kv key get --remote --namespace-id "$ns_id" invites 2>/dev/null | grep -q '^\['; then
  echo "deploy-api: invites key exists"
else
  wrangler kv key put --remote --namespace-id "$ns_id" invites \
    "$(python3 -c 'import json, secrets; print(json.dumps([secrets.token_urlsafe(18) for _ in range(3)]))')" >/dev/null
  echo "deploy-api: created 3 fresh invite codes (owner: wrangler kv key get --remote --namespace-id $ns_id invites)"
fi

# 5. Deploy. The custom-domain route creates the api.barestate.xyz DNS + cert in the zone.
(cd "$API" && wrangler deploy)
