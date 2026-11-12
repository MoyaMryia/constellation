#!/bin/sh
# Build static i486 musl s6 stack (skalibs + execline + s6 + s6-rc) for M2.
# Source tarballs are downloaded to /tmp/m2src (not tracked).
# Install root: build/m2root/usr (not tracked).
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${M2_BUILD_DIR:-/tmp/m2src}
INSTALL_DIR=${M2_INSTALL_DIR:-$ROOT/build/m2root}
PREFIX=$INSTALL_DIR/usr
CC_WRAP=$ROOT/toolchain/musl-i486/bin/i486-linux-musl-gcc
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}

# skarnet current stable as of 2026-08
SKALIBS=skalibs-2.15.1.0
SKALIBS_SHA=f9c905e74935c6fe911c7e344e3e89d5fbd2014c1a04650b524b15ce9b5635d1
EXECLINE=execline-2.9.9.2
EXECLINE_SHA=908ed4db3a6b3a23a205d8fd4cf2a71089156f2aeae0f54656045aafad2dee32
S6=s6-2.15.1.0
S6_SHA=eab9c46e22b66b16135f9a05ec68a0ea287d9060b84d10defaaa2caad158ab52
S6RC=s6-rc-0.7.0.0
S6RC_SHA=bf5b8ce0da5a4ee70d642b818b61d9916a7a9b64a457595f388113e54a188688

# Cross-compile sysdeps that cannot be autodetected for i486-musl.
SYSDEPS="--with-sysdep-devurandom=yes --with-sysdep-posixspawnearlyreturn=no --with-sysdep-procselfexe=/proc/self/exe --with-sysdep-selectinfinite=yes"

mkdir -p "$BUILD_DIR"
[ -x "$CC_WRAP" ] || { echo "missing cross compiler: $CC_WRAP" >&2; exit 1; }

download_and_verify () {
  pkg=$1; sha=$2; url=$3
  tarball="$BUILD_DIR/$pkg.tar.gz"
  if [ -f "$tarball" ] && ! echo "$sha  $tarball" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tarball"
  fi
  if [ ! -f "$tarball" ]; then
    tmp="$tarball.tmp.$$"
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    curl --fail --location --retry 4 --retry-delay 2 --retry-all-errors \
      --proto '=https' --silent --show-error -o "$tmp" "$url"
    echo "$sha  $tmp" | sha256sum -c -
    mv "$tmp" "$tarball"
    trap - EXIT HUP INT TERM
  fi
  if ! echo "$sha  $tarball" | sha256sum -c -; then
    rm -f "$tarball"
    echo "removed corrupt download: $tarball" >&2
    exit 1
  fi
}

# download + unpack
for spec in \
  "$SKALIBS $SKALIBS_SHA https://skarnet.org/software/skalibs/$SKALIBS.tar.gz" \
  "$EXECLINE $EXECLINE_SHA https://skarnet.org/software/execline/$EXECLINE.tar.gz" \
  "$S6 $S6_SHA https://skarnet.org/software/s6/$S6.tar.gz" \
  "$S6RC $S6RC_SHA https://skarnet.org/software/s6-rc/$S6RC.tar.gz"
do
  set -- $spec
  download_and_verify "$1" "$2" "$3"
  rm -rf "$BUILD_DIR/$1"
  tar -C "$BUILD_DIR" -xf "$BUILD_DIR/$1.tar.gz"
done

rm -rf "$INSTALL_DIR"
mkdir -p "$PREFIX"

build_pkg () {
  pkg=$1
  cd "$BUILD_DIR/$pkg"
  CC="$CC_WRAP" ./configure --host=i486-linux-musl --prefix="$PREFIX" \
    --with-sysdeps="$PREFIX/lib/skalibs/sysdeps" \
    --with-include="$PREFIX/include" \
    --with-lib="$PREFIX/lib" \
    --disable-shared --enable-static-libc \
    $SYSDEPS
  make -j"$JOBS"
  make install
}

build_pkg "$SKALIBS"
build_pkg "$EXECLINE"
build_pkg "$S6"
build_pkg "$S6RC"

# Static binaries strip
find "$PREFIX/bin" -type f -exec "$ROOT/toolchain/musl-i486/bin/i486-linux-musl-strip" {} +
echo "s6 stack installed under $PREFIX"
