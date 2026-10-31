#!/bin/bash
# Build our vendored source; no downloads or modifications to upstream files.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
cmake_bin="${CMAKE:-$(command -v cmake || true)}"
if [ -z "$cmake_bin" ] && [ -x "$root/.build/kiwi-tools/bin/cmake" ]; then
    cmake_bin="$root/.build/kiwi-tools/bin/cmake"
fi
if [ -z "$cmake_bin" ]; then
    echo "CMake is required. See Vendor/Kiwi/README.md (tool setup)." >&2
    exit 1
fi
source_hash=$(bash scripts/kiwi-source-hash.sh)
build_root="$root/.build/kiwi-native"
mkdir -p "$build_root"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
    "$cmake_bin" -S "$root/Vendor/Kiwi/source" -B "$build_root/$arch" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DKIWI_BUILD_DYNAMIC=OFF -DKIWI_BUILD_CLI=OFF -DKIWI_BUILD_EVALUATOR=OFF \
        -DKIWI_BUILD_MODEL_BUILDER=OFF -DKIWI_BUILD_TEST=OFF -DKIWI_JAVA_BINDING=OFF \
        -DKIWI_USE_MIMALLOC=ON -DKIWI_USE_CPUINFO=OFF
    "$cmake_bin" --build "$build_root/$arch" --target kiwi_static --parallel "${KIWI_BUILD_JOBS:-4}"
done
staging=$(mktemp -d "$root/.build/kiwi-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/headers"
cp Vendor/Kiwi/source/include/kiwi/{capi.h,Macro.h} "$staging/headers/"
cat > "$staging/headers/module.modulemap" <<'MODULE'
module Kiwi {
    header "capi.h"
    export *
}
MODULE
xcrun lipo -create "$build_root/arm64/libkiwi_static.a" "$build_root/x86_64/libkiwi_static.a" -output "$staging/libkiwi.a"
xcodebuild -create-xcframework -library "$staging/libkiwi.a" -headers "$staging/headers" -output "$staging/Kiwi.xcframework"
# Do not label a build as current if files changed while compiling.
if [ "$source_hash" != "$(bash scripts/kiwi-source-hash.sh)" ]; then
    echo "Kiwi sources changed during compilation; run make rebuild-kiwi again." >&2
    exit 1
fi
printf '%s\n' "$source_hash" > "$staging/Kiwi.xcframework/SOURCE_SHA256"
{
    "$cmake_bin" --version
    xcrun clang --version
    xcodebuild -version
    xcrun lipo -info "$staging/libkiwi.a"
} > "$staging/Kiwi.xcframework/BUILD_INFO.txt"
# Keep the previous library until the new one has successfully built.
if [ -d Vendor/Kiwi/Kiwi.xcframework ]; then
    backup=$(mktemp -d "$root/.build/kiwi-previous.XXXXXX")
    mv Vendor/Kiwi/Kiwi.xcframework "$backup/"
fi
mv "$staging/Kiwi.xcframework" Vendor/Kiwi/
echo "Local Kiwi XCFramework ready (arm64 + x86_64)."
