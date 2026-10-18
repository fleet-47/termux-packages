#!/usr/bin/env bash
# Reuse the exact successful upstream llvm-22 build without rebuilding LLVM.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p /data/data/.built-packages "$HOME/.termux-build/_cache-aarch64"
for deb in upstream-llvm22/debs/*.deb; do
    package=$(dpkg-deb -f "$deb" Package)
    version=$(dpkg-deb -f "$deb" Version)
    architecture=$(dpkg-deb -f "$deb" Architecture)
    test "$version" = 22.1.8
    test "$architecture" = aarch64
    # Match termux_step_get_dependencies: avoid modifying root directory metadata.
    ar p "$deb" data.tar.xz | tar xJ --no-overwrite-dir --transform='s#^.$#data#' -C /
    cp "$deb" "$HOME/.termux-build/_cache-aarch64/"
    printf '%s\n' "$version" > "/data/data/.built-packages/$package"
done
