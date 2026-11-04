#!/bin/bash
# Compatibility entry point; the maintained recipe lives with the Kiwi sources.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$root/Vendor/Kiwi/scripts/prepare-kiwi.sh" "$@"
