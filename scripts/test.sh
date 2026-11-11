#!/bin/bash
# Runs this plugin's tests against the Light Table checkout in LIGHTTABLE_ROOT (default ../lighttable).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
host="${LIGHTTABLE_ROOT:-$repo/../lighttable}"
[[ -f "$host/scripts/package-plugin.py" ]] || { echo "No Light Table checkout at $host; set LIGHTTABLE_ROOT." >&2; exit 1; }
export LIGHTTABLE_ROOT="$(cd "$host" && pwd)"
source "$LIGHTTABLE_ROOT/scripts/swift-env.sh"
export LIGHTTABLE_ROOT
swift test --package-path "$repo" --disable-sandbox "$@"
