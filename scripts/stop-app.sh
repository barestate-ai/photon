#!/bin/bash
# Stop the app that owns <data-dir>/app.pid: SIGTERM runs its normal quit path, then escalate to
# SIGKILL for the app and any helper it left behind.
# Usage: scripts/stop-app.sh <data-dir> [timeout-seconds]
data_dir=${1:?usage: stop-app.sh <data-dir> [timeout-seconds]}
timeout=${2:-10}
pid_file="$data_dir/app.pid"
[ -f "$pid_file" ] || { echo "stop-app: no $pid_file; nothing to stop"; exit 0; }
pid=$(cat "$pid_file")

descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

# A zombie (exited, not yet reaped by the launching harness) counts as stopped.
alive() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null)
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}

alive "$pid" || { rm -f "$pid_file" "$data_dir/app.sock"; exit 0; }
helpers=$(descendants "$pid")
kill -TERM "$pid"
for _ in $(seq 1 $((timeout * 10))); do
  alive "$pid" || break
  sleep 0.1
done
if alive "$pid"; then
  echo "stop-app: $pid ignored SIGTERM for ${timeout}s; sending SIGKILL" >&2
  kill -KILL "$pid"
fi
for helper in $helpers; do
  kill -KILL "$helper" 2>/dev/null
done
rm -f "$pid_file" "$data_dir/app.sock"
echo "stop-app: stopped $pid"
