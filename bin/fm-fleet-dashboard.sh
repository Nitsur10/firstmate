#!/usr/bin/env bash
# fm-fleet-dashboard.sh - private, read-only fleet dashboard.
# Usage and limits: fm-fleet-dashboard.sh --help
# Python 3's standard library serves a token-protected 127.0.0.1 page.
# Uses fm-fleet-snapshot.sh --local-read-only; no fleet files are written.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$SCRIPT_DIR/fm-fleet-dashboard.py" "$@"
