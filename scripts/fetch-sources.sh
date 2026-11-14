#!/bin/sh
# Fetch and verify the source archives needed by the core build.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fetch () {
  destination=$1
  sha=$2
  url=$3

  mkdir -p "$(dirname "$destination")"
  if [ -f "$destination" ] && echo "$sha  $destination" | sha256sum -c - >/dev/null 2>&1; then
    echo "source verified: $destination"
    return
  fi

  rm -f "$destination"
  tmp=$destination.tmp.$$
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl --fail --location --proto '=https' --silent --show-error -o "$tmp" "$url"
  echo "$sha  $tmp" | sha256sum -c -
  mv "$tmp" "$destination"
  trap - EXIT HUP INT TERM
}

fetch "$ROOT/kernel/src/linux-6.18.44.tar.xz" \
  0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43 \
  https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.44.tar.xz
# 770ED 风味用 6.6.162 LTS（6.7–6.11 之间上游移除了 16 位 PCMCIA 无线驱动，
# 所以不能只跟最新 LTS）。KVER=6.6.162 的构建需要这一份。
fetch "$ROOT/kernel/src/linux-6.6.162.tar.xz" \
  4aa89f3652fc131e5d39990f3bcd4b9e131028af3f315dbe83f3a8557dc06f06 \
  https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.162.tar.xz
fetch "$ROOT/busybox/src/busybox-1.38.0.tar.bz2" \
  34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2 \
  https://busybox.net/downloads/busybox-1.38.0.tar.bz2
fetch "$ROOT/toolchain/src/musl-1.2.5.tar.gz" \
  83ff394502d1c334b040ea9bc66ec48bba453585e25b05f4bde3741d8245d883 \
  https://musl.libc.org/releases/musl-1.2.5.tar.gz
