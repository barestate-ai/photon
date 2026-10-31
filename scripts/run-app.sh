#!/bin/bash
# Run the bundled app in the foreground; every argument goes to it (--data-dir, --test-hooks, --url).
# exec keeps the app's PID equal to this script's PID, so callers can signal it directly.
cd "$(dirname "$0")/.." || exit 1
APP_BUNDLE=".build/Photon.app"
exec "$APP_BUNDLE/Contents/MacOS/Barestate" "$@"
