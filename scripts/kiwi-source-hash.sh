#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Stable across machines; include build flags as well as the vendored source.
{ find Vendor/Kiwi/source -type f ! -name .DS_Store -print0; printf '%s\0' scripts/build-kiwi.sh Vendor/Kiwi/upstream.json; } |
    xargs -0 shasum -a 256 | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
