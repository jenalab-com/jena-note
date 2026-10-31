#!/bin/bash
# Offline preflight only. Downloads and C++ rebuilds are explicit developer actions.
set -euo pipefail
cd "$(dirname "$0")/.."
framework=Vendor/Kiwi/Kiwi.xcframework
if [ ! -f "$framework/Info.plist" ] || [ ! -f "$framework/SOURCE_SHA256" ]; then
    echo "Local Kiwi library is missing. Run make bootstrap-kiwi once; see Vendor/Kiwi/README.md." >&2
    exit 1
fi
if [ "$(cat "$framework/SOURCE_SHA256")" != "$(bash scripts/kiwi-source-hash.sh)" ]; then
    echo "Kiwi source/build configuration changed. Run make rebuild-kiwi to apply it." >&2
    exit 1
fi
model=Sources/JenaNoteKit/Resources/KiwiModel
if [ "$(cat "$model/VERSION" 2>/dev/null || true)" != "0.24.1" ]; then
    echo "Kiwi model is missing or incompatible. Run bash scripts/fetch-kiwi-model.sh explicitly." >&2
    exit 1
fi
for file in combiningRule.txt cong.mdl default.dict dialect.dict extract.mdl multi.dict nounchr.mdl sj.morph typo.dict; do
    if [ ! -s "$model/$file" ]; then
        echo "Kiwi model is incomplete: $model/$file. Restore the pinned model before building." >&2
        exit 1
    fi
done
