#!/bin/sh
# 从源码构建 grub4dos（BIOS 版，0.4.6a）并取出 grldr / grldr.mbr / bootlace.com。
#
# 为什么自建：chenall/grub4dos 的 GitHub Release 只发 UEFI 版（grub4dos-for_UEFI），
# BIOS 版的二进制包没有稳定的、可钉哈希的下载点。源码本身是 0.4.6a，仓库里
# 有 `build` 脚本，用现代 gcc（-m32）可以直接编出来 —— 于是钉 commit、
# 自己编，和本工程其它依赖一样的待遇。
#
# 产物：build/grub4dos/{grldr,grldr.mbr,bootlace.com}
# 用法：scripts/build-grub4dos.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMIT=cd65de1e1a1fda15de8cc45d09ffa0cfaca9aa7c
SRC=${GRUB4DOS_SRC:-$ROOT/toolchain/src/grub4dos}
OUT=${GRUB4DOS_OUT:-$ROOT/build/grub4dos}

command -v git >/dev/null 2>&1 || { echo "grub4dos: 需要 git" >&2; exit 1; }
command -v 7z  >/dev/null 2>&1 || { echo "grub4dos: 需要 p7zip（7z）" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet https://github.com/chenall/grub4dos.git "$SRC"
fi
cd "$SRC"
git fetch --quiet origin || true
git checkout --quiet "$COMMIT"
echo "grub4dos: 源码 $(cat grub4dos_version) @ $(git rev-parse --short HEAD)"

# build 脚本会产出 grub4dos-<ver>-<date>.7z
rm -f ./*.7z ./*.zip
sh ./build >/tmp/grub4dos-build.log 2>&1 || {
  echo "grub4dos: 构建失败，见 /tmp/grub4dos-build.log" >&2; exit 1; }
pkg=$(ls -1 ./*.7z | head -1)
[ -n "$pkg" ] || { echo "grub4dos: 没产出 7z" >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
tmp=$(mktemp -d /tmp/grub4dos-pkg.XXXXXX)
7z x -o"$tmp" "$pkg" >/dev/null
d=$(find "$tmp" -maxdepth 2 -name grldr -printf '%h\n' | head -1)
[ -n "$d" ] || { echo "grub4dos: 包里没有 grldr" >&2; exit 1; }
cp "$d/grldr" "$d/grldr.mbr" "$d/bootlace.com" "$OUT/"
[ -f "$d/sample/menu.lst" ] && cp "$d/sample/menu.lst" "$OUT/menu.lst.sample"
rm -rf "$tmp"

echo "grub4dos: 产物在 $OUT"
for f in grldr grldr.mbr bootlace.com; do
  printf '  %-12s %8s B  sha256=%s\n' "$f" "$(stat -c%s "$OUT/$f")" \
    "$(sha256sum "$OUT/$f" | cut -c1-16)"
done
