#!/bin/bash
# Explicit one-time model fetch. Normal app builds never access the network.
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.24.1
checksum=50d163e1af817444ef21f7ec5ea07ef69fb347282d57a6b49260f2039d4dc346
destination=Sources/JenaNoteKit/Resources/KiwiModel
if [ -d "$destination" ]; then
    if [ "$(cat "$destination/VERSION" 2>/dev/null || true)" = "$version" ] && [ -s "$destination/cong.mdl" ] && [ -s "$destination/sj.morph" ]; then
        exit 0
    fi
    echo "Existing Kiwi model is incomplete or has another version: $destination. Preserve it and inspect before replacing." >&2
    exit 1
fi
mkdir -p .build/kiwi-downloads
archive=".build/kiwi-downloads/kiwi_model_v${version}_base.tgz"
if [ ! -f "$archive" ]; then
    download=$(mktemp .build/kiwi-downloads/download.XXXXXX)
    curl --fail --location --retry 3 --output "$download" "https://github.com/bab2min/Kiwi/releases/download/v${version}/kiwi_model_v${version}_base.tgz"
    printf '%s  %s\n' "$checksum" "$download" | shasum -a 256 --check
    mv "$download" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 --check
staging=$(mktemp -d .build/kiwi-downloads/extract.XXXXXX)
tar -xzf "$archive" -C "$staging"
printf '%s\n' "$version" > "$staging/models/cong/base/VERSION"
mkdir -p "$(dirname "$destination")"
mv "$staging/models/cong/base" "$destination"
echo "Kiwi $version model prepared ($destination)"
