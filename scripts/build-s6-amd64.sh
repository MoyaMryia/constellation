#!/bin/sh
# Build the static x86_64 musl s6 stack (skalibs + execline + s6) for M2.
#
# 与 scripts/build-s6.sh 的差别：
#   1) 目标三元组 x86_64-linux-musl，装到 build/m2root-amd64；
#   2) 源码双来源回退：skarnet.org 为上游正源，NJU 的 Debian pool 为镜像
#      （实测 skarnet.org 从本机不可达，SSL 直接 EOF）。两个来源的
#      tarball 内容等价、但字节不同，故两个 SHA256 都在此钉定，任一匹配即
#      通过——校验和仍是契约，只是契约有两个合法原文。
#   3) 不构建 s6-rc：M2 的 rootfs 只用 s6-svscan + 服务目录（见
#      rootfs/sbin/init 与 rootfs/etc/s6/），且 Debian pool 无 s6-rc 源码包。
#      s6-rc 只有一个来源（skarnet.org），待该站可达时再纳入。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TRIPLE=${TRIPLE:-x86_64-linux-musl}
BUILD_DIR=${M2_BUILD_DIR:-/tmp/m2src}
INSTALL_DIR=${M2_INSTALL_DIR:-$ROOT/build/m2root-amd64}
PREFIX=$INSTALL_DIR/usr
CC_WRAP=${CC_WRAP:-$ROOT/toolchain/musl-amd64/bin/x86_64-linux-musl-gcc}
STRIP=${STRIP:-$ROOT/toolchain/musl-amd64/bin/x86_64-linux-musl-strip}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}
DEBMIRROR=${DEBMIRROR:-https://mirrors.nju.edu.cn/debian}

SKALIBS_VER=2.15.1.0
EXECLINE_VER=2.9.9.2
S6_VER=2.15.1.0

# 每个包：目录名、上游 SHA256、Debian orig SHA256、上游 URL、Debian URL
SKALIBS_SHA_UP=f9c905e74935c6fe911c7e344e3e89d5fbd2014c1a04650b524b15ce9b5635d1
SKALIBS_SHA_DEB=efa8b213fe341d57c8b7ad087d928b8d3296643a3a1583bf7e7675766bb68b06
EXECLINE_SHA_UP=908ed4db3a6b3a23a205d8fd4cf2a71089156f2aeae0f54656045aafad2dee32
EXECLINE_SHA_DEB=b856e1a0bc8113d7110627720b7ddab3b539bcd63d4bb901a6d88470ecbb2281
S6_SHA_UP=eab9c46e22b66b16135f9a05ec68a0ea287d9060b84d10defaaa2caad158ab52
S6_SHA_DEB=3bd167771f0c6ebfa00f2d0798a04ad2d1b9d6ee0eaaff6079f3108353e98b4c

SYSDEPS="--with-sysdep-devurandom=yes --with-sysdep-posixspawnearlyreturn=no --with-sysdep-procselfexe=/proc/self/exe --with-sysdep-selectinfinite=yes"

mkdir -p "$BUILD_DIR"
[ -x "$CC_WRAP" ] || { echo "missing cross compiler: $CC_WRAP" >&2; exit 1; }

# verify_any <file> <sha>... —— 任一校验和匹配即通过
verify_any () {
  f=$1; shift
  for s in "$@"; do
    echo "$s  $f" | sha256sum -c - >/dev/null 2>&1 && return 0
  done
  return 1
}

# fetch <dirname> <sha_up> <sha_deb> <url_up> <url_deb>
fetch () {
  dir=$1; sha_up=$2; sha_deb=$3; url_up=$4; url_deb=$5
  tarball="$BUILD_DIR/$dir.tar.gz"
  if [ -f "$tarball" ] && verify_any "$tarball" "$sha_up" "$sha_deb"; then
    echo "source verified: $tarball"
    return 0
  fi
  rm -f "$tarball"
  for url in "$url_up" "$url_deb"; do
    tmp="$tarball.tmp.$$"
    if curl --fail --location --retry 3 --retry-delay 2 --retry-all-errors \
         --connect-timeout 20 --max-time 300 \
         --proto '=https' --silent --show-error -o "$tmp" "$url" 2>/dev/null; then
      if verify_any "$tmp" "$sha_up" "$sha_deb"; then
        mv "$tmp" "$tarball"
        echo "source fetched: $url"
        return 0
      fi
      echo "checksum mismatch, discarding: $url" >&2
    else
      echo "unreachable, trying next source: $url" >&2
    fi
    rm -f "$tmp"
  done
  echo "no usable source for $dir" >&2
  return 1
}

fetch "skalibs-$SKALIBS_VER" "$SKALIBS_SHA_UP" "$SKALIBS_SHA_DEB" \
  "https://skarnet.org/software/skalibs/skalibs-$SKALIBS_VER.tar.gz" \
  "$DEBMIRROR/pool/main/s/skalibs/skalibs_${SKALIBS_VER}.orig.tar.gz"
fetch "execline-$EXECLINE_VER" "$EXECLINE_SHA_UP" "$EXECLINE_SHA_DEB" \
  "https://skarnet.org/software/execline/execline-$EXECLINE_VER.tar.gz" \
  "$DEBMIRROR/pool/main/e/execline/execline_${EXECLINE_VER}.orig.tar.gz"
fetch "s6-$S6_VER" "$S6_SHA_UP" "$S6_SHA_DEB" \
  "https://skarnet.org/software/s6/s6-$S6_VER.tar.gz" \
  "$DEBMIRROR/pool/main/s/s6/s6_${S6_VER}.orig.tar.gz"

rm -rf "$INSTALL_DIR"
mkdir -p "$PREFIX"

build_pkg () {
  pkg=$1
  rm -rf "$BUILD_DIR/$pkg"
  tar -C "$BUILD_DIR" -xf "$BUILD_DIR/$pkg.tar.gz"
  cd "$BUILD_DIR/$pkg"
  CC="$CC_WRAP" ./configure --host="$TRIPLE" --prefix="$PREFIX" \
    --with-sysdeps="$PREFIX/lib/skalibs/sysdeps" \
    --with-include="$PREFIX/include" \
    --with-lib="$PREFIX/lib" \
    --disable-shared --enable-static-libc \
    $SYSDEPS
  make -j"$JOBS"
  make install
}

build_pkg "skalibs-$SKALIBS_VER"
build_pkg "execline-$EXECLINE_VER"
build_pkg "s6-$S6_VER"

find "$PREFIX/bin" -type f -exec "$STRIP" {} +
echo "s6 stack (x86_64) installed under $PREFIX"
