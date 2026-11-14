#!/bin/sh
# Build the Constellation x86_64 sample apk repository.
#
# 用途：给"apk 可用"这条验收提供一个可复现的端到端输入——不用联网、
# 不依赖外部发行版的仓库。产出：
#   build/apk-repo-amd64/x86_64/<pkg>.apk + APKINDEX.tar.gz
#
# 注意（踩过的坑，供后续写 M2 仓库脚本时参考）：
#   - apk-tools 3.x 产出的是 **v3（ADB）格式**包，`apk index` 只认 v2，
#     必须用 `apk mkndx` 建索引；两者都要 `--allow-untrusted`（未签名）。
#   - `mkpkg` 的 `--compat` 是**带参数**选项，写成裸 `--compat` 会吞掉紧随
#     其后的参数（症状：ERROR: required info field 'name' not provided）。
#     默认 compat 已可用，不必传。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APK=${APK_BIN:-$ROOT/build/apk-amd64/usr/bin/apk}
OUT=${APK_REPO_DIR:-$ROOT/build/apk-repo-amd64}
WORK=$(mktemp -d /tmp/constellation-mkrepo.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

[ -x "$APK" ] || { echo "build apk first: scripts/build-apk-amd64.sh" >&2; exit 1; }

mkdir -p "$OUT/x86_64" "$WORK/pkgroot/etc"
echo "Constellation OS 1.0 (x86_64 / ThinkPad X61)" > "$WORK/pkgroot/etc/constellation-release"
echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$WORK/pkgroot/etc/constellation-release"

PKG=constellation-release-1.0.0-r0.apk
rm -f "$OUT/x86_64/$PKG" "$OUT/x86_64/APKINDEX.tar.gz"

( cd "$OUT/x86_64" && "$APK" mkpkg \
    -I name:constellation-release \
    -I version:1.0.0-r0 \
    -I arch:x86_64 \
    -I description:"Constellation OS release identification" \
    -I url:https://example.invalid/constellation \
    -I license:MIT \
    -F "$WORK/pkgroot" -o "$PKG" )

( cd "$OUT/x86_64" && "$APK" mkndx --allow-untrusted -o APKINDEX.tar.gz "$PKG" )

echo "repo written: $OUT"
ls -l "$OUT/x86_64"
