#!/bin/bash
# Builds this plugin and packages it into Light Table: build/plugins/<Name>-<version>.ltplugin,
# dist/plugins/<Name>-<version>.zip and dist/checksums/plugins/<Name>-<version>.zip.sha256 under the
# Light Table checkout (LIGHTTABLE_ROOT, default ../lighttable). Usage: scripts/build.sh [release|debug] [plugin-id-suffix]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
host="${LIGHTTABLE_ROOT:-$repo/../lighttable}"
[[ -f "$host/scripts/package-plugin.py" ]] || { echo "No Light Table checkout at $host; set LIGHTTABLE_ROOT." >&2; exit 1; }
export LIGHTTABLE_ROOT="$(cd "$host" && pwd)"
source "$LIGHTTABLE_ROOT/scripts/swift-env.sh"
export LIGHTTABLE_ROOT
configuration="${1:-release}"
only="${2:-}"
swift build --package-path "$repo" -c "$configuration" --disable-sandbox
bin="$(swift build --package-path "$repo" -c "$configuration" --show-bin-path)"
python3 "$LIGHTTABLE_ROOT/scripts/package-plugin.py" --plugin-repo "$repo" --bin-path "$bin" ${only:+--only "$only"}
