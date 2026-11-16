#!/bin/sh
# 给 770ED 再补一批常用用户态程序（都用 i486 musl 自己编，零 SSE）：
#
#   mpg123     MP3 播放器（OSS 输出，直接吃 /dev/dsp 的 CS4237B）
#   fbset      帧缓冲查询/设置（调 tridentfb 的 mode 时用得上）
#   lspci      PCI 设备列表（hwcheck 会优先用它）
#   strace     系统调用跟踪（真机排障用）
#   abduco     会话分离/重连（tmux 的 detach/attach 那一半，无依赖）
#   dvtm       平铺窗口（另一半，静态链 ncursesw）
#   mux        abduco + dvtm 的小包装：mux / mux -l / mux NAME
#
# 全部静态链接、放进 /usr/bin。失败的项目跳过而不中断整体构建。
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
SRCROOT=${USERSPACE_SRC:-$ROOT/toolchain/src/userspace}
MUSL=$ROOT/toolchain/musl-i486
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
# Linux UAPI 头（linux/fb.h、linux/soundcard.h、linux/pci.h…）：musl 自带的不含，
# 用构建 X 栈时铺好的那一份。
UAPI=
for d in "$ROOT/build/xlibs-770ed/usr/include" "$ROOT/build/hdrs-i386/include"; do
  [ -f "$d/linux/fb.h" ] && { UAPI=$d; break; }
done
[ -n "$UAPI" ] || { echo "缺少 Linux UAPI 头" >&2; exit 1; }
CFLAGS_COMMON="-Os -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector -I$UAPI"

[ -x "$MUSL/bin/i486-linux-musl-gcc" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }
mkdir -p "$SRCROOT" "$DEST/usr/bin"
PATH=$MUSL/bin:$PATH
export PATH

fetch () {
  url=$1; sha=${2:-}
  file=$SRCROOT/${url##*/}
  if [ ! -s "$file" ]; then
    echo "up: 下载 ${url##*/}" >&2
    curl -fsSL --retry 3 -o "$file.part" "$url" && mv "$file.part" "$file" || return 1
  fi
  if [ -n "$sha" ]; then
    echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1 || {
      echo "up: 校验失败：${url##*/}（删除缓存后重试）" >&2
      rm -f "$file"; return 1; }
  fi
  echo "$file"
}

install_bin () { # install_bin <src> <name>
  [ -f "$1" ] || { echo "up: 跳过 $2（没编出来）" >&2; return 0; }
  install -m 0755 "$1" "$DEST/usr/bin/$2"
  strip --strip-all "$DEST/usr/bin/$2" 2>/dev/null || true
  echo "up: $2  $(du -h "$DEST/usr/bin/$2" | cut -f1)" >&2
}

# ---- Linux UAPI 头：用内核树自己生成一份（arch 正确、完整）----
UAPI_SYS=$ROOT/build/uapi-770ed/include
if [ ! -f "$UAPI_SYS/linux/ioctl.h" ]; then
  echo "up: 生成 UAPI 头（kernel headers_install）" >&2
  make -C "$ROOT/kernel/src/linux-$KVER" headers_install \
    INSTALL_HDR_PATH="$ROOT/build/uapi-770ed" >/dev/null 2>&1 || true
fi
if [ -f "$UAPI_SYS/linux/ioctl.h" ]; then
  mkdir -p "$DEST/usr/include"
  cp -a "$UAPI_SYS/." "$DEST/usr/include/"
  # 老代码常写 <sys/soundcard.h>（OSS），内核里对应 linux/soundcard.h
  ln -sf ../linux/soundcard.h "$DEST/usr/include/sys/soundcard.h"
  echo "up: UAPI 头已装到 /usr/include（$(find "$UAPI_SYS" -name '*.h' | wc -l) 个）" >&2
fi

# ---------------- mpg123 ----------------
if t=$(fetch "https://www.mpg123.de/download/mpg123-1.32.6.tar.bz2" ccdd1d0abc31d73d8b435fc658c79049d0a905b30669b6a42a03ad169dc609e6); then
  cd "$SRCROOT"; [ -d mpg123-1.32.6 ] || tar -xjf "$t"
  if [ ! -x mpg123-1.32.6/src/mpg123 ]; then
    echo "up: 编 mpg123" >&2
    cd mpg123-1.32.6
    ./configure --host=i486-linux-musl --build=x86_64-linux-gnu \
      --disable-shared --enable-static --disable-lfs --disable-network \
      --with-default-audio=oss --disable-shout --disable-ltdl \
      CC=i486-linux-musl-gcc CFLAGS="$CFLAGS_COMMON" \
      LDFLAGS="-static" >/dev/null 2>&1
    make -j"$JOBS" >/dev/null 2>&1 || true
    cd "$SRCROOT"
  fi
  install_bin "$SRCROOT/mpg123-1.32.6/src/mpg123" mpg123
fi

# ---------------- fbset ----------------
if t=$(fetch "http://deb.debian.org/debian/pool/main/f/fbset/fbset_2.1.orig.tar.gz" 517fa062d7b2d367f931a1c6ebb2bef84907077f0ce3f0c899e34490bbea9338); then
  cd "$SRCROOT"; [ -d fbset-2.1 ] || tar -xzf "$t"
  if [ ! -x fbset-2.1/fbset ]; then
    echo "up: 编 fbset" >&2
    make -C fbset-2.1 CC=i486-linux-musl-gcc \
      CFLAGS="$CFLAGS_COMMON -include linux/types.h" \
      LDFLAGS="-static" >/dev/null 2>&1 || true
  fi
  install_bin "$SRCROOT/fbset-2.1/fbset" fbset
fi

# ---------------- pciutils (lspci) ----------------
if t=$(fetch "https://mj.ucw.cz/download/linux/pci/pciutils-3.13.0.tar.gz" a03c88a0aab709b1697ca1753766f443e78297f84c7bcd80a82c1422edd7cb42); then
  cd "$SRCROOT"; [ -d pciutils-3.13.0 ] || tar -xzf "$t"
  if [ ! -x pciutils-3.13.0/lspci ]; then
    echo "up: 编 pciutils" >&2
    make -C pciutils-3.13.0 HOST=i486-linux-musl CROSS_COMPILE=i486-linux-musl- \
      OPT="$CFLAGS_COMMON -fno-stack-protector" ZLIB=no LIBKMOD=no HWDB=no \
      PREFIX=/usr LDFLAGS="-static" lspci >/dev/null 2>&1 || true
  fi
  install_bin "$SRCROOT/pciutils-3.13.0/lspci" lspci
fi

# ---------------- strace ----------------
if t=$(fetch "https://strace.io/files/6.11/strace-6.11.tar.xz" 83262583a3529f02c3501aa8b8ac772b4cbc03dc934e98bab6e4883626e283a5); then
  cd "$SRCROOT"; [ -d strace-6.11 ] || tar -xJf "$t"
  if [ ! -x strace-6.11/src/strace ]; then
    echo "up: 编 strace" >&2
    cd strace-6.11
    ./configure --host=i486-linux-musl --build=x86_64-linux-gnu \
      --disable-mpers --without-libunwind \
      CC=i486-linux-musl-gcc CFLAGS="$CFLAGS_COMMON" \
      LDFLAGS="-static" >/dev/null 2>&1
    make -j"$JOBS" >/dev/null 2>&1 || true
    cd "$SRCROOT"
  fi
  install_bin "$SRCROOT/strace-6.11/src/strace" strace
fi

# ---------------- abduco + dvtm（tmux 的小号替代） ----------------
# 为什么不是 tmux：tmux 要 libevent + ncurses + 一份完整的 terminfo，静态体积
# 1.5 MB 起，冷启动在 266 MHz 上要几秒。abduco（会话分离/重连，单文件、零依赖）
# 配 dvtm（平铺窗口，只要 ncursesw）合起来 ~380 KB，够用且快。
# 分离键是 Ctrl-\ ，重连是 mux <名字>。
if t=$(fetch "https://github.com/martanne/abduco/releases/download/v0.6/abduco-0.6.tar.gz" \
         c90909e13fa95770b5afc3b59f311b3d3d2fdfae23f9569fa4f96a3e192a35f4); then
  cd "$SRCROOT"; [ -d abduco-0.6 ] || tar -xzf "$t"
  if [ ! -x abduco-0.6/abduco ]; then
    echo "up: 编 abduco" >&2
    # 它的 config.mk 用 CFLAGS += ，命令行一覆盖就把 -DVERSION 冲掉，
    # 所以这里显式把 -DVERSION 一起写全。
    make -C abduco-0.6 CC=i486-linux-musl-gcc \
      CFLAGS="$CFLAGS_COMMON -std=c99 -Wall -DVERSION=\"0.6\" -DNDEBUG -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -I." \
      LDFLAGS="-static -lc -lutil" >/dev/null 2>&1 || true
  fi
  install_bin "$SRCROOT/abduco-0.6/abduco" abduco
fi

if t=$(fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz" \
         136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6); then
  cd "$SRCROOT"; [ -d ncurses-6.5 ] || tar -xzf "$t"
  if [ ! -f ncurses-6.5/lib/libncursesw.a ]; then
    echo "up: 编 ncurses（静态，只建库不装）" >&2
    ( cd ncurses-6.5 && ./configure --host=i486-linux-musl --prefix=/usr \
        --without-shared --without-debug --without-ada --without-cxx \
        --without-cxx-binding --without-manpages --with-termlib \
        --disable-db-install --enable-overwrite \
        CFLAGS="$CFLAGS_COMMON" >/dev/null 2>&1 \
      && make -j"$JOBS" >/dev/null 2>&1 ) || true
  fi
  if t2=$(fetch "https://github.com/martanne/dvtm/releases/download/v0.15/dvtm-0.15.tar.gz" \
           8f2015c05e2ad82f12ae4cf12b363d34f527a4bbc8c369667f239e4542e1e510); then
    cd "$SRCROOT"; [ -d dvtm-0.15 ] || tar -xzf "$t2"
    if [ ! -x dvtm-0.15/dvtm ] && [ -f ncurses-6.5/lib/libncursesw.a ]; then
      echo "up: 编 dvtm" >&2
      make -C dvtm-0.15 CC=i486-linux-musl-gcc \
        CFLAGS="$CFLAGS_COMMON -std=c99 -Wall -DVERSION=\"0.15\" -DNDEBUG -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -D_XOPEN_SOURCE_EXTENDED -I. -I$SRCROOT/ncurses-6.5/include" \
        LDFLAGS="-static -L$SRCROOT/ncurses-6.5/lib -lc -lutil -lncursesw -ltinfow" \
        >/dev/null 2>&1 || true
    fi
    install_bin "$SRCROOT/dvtm-0.15/dvtm" dvtm
  fi
fi

# mux 包装（abduco 的 detach + dvtm 的窗口）
if [ -f "$ROOT/rootfs-770ed/usr/bin/mux" ]; then
  install -m 0755 "$ROOT/rootfs-770ed/usr/bin/mux" "$DEST/usr/bin/mux"
  echo "up: mux" >&2
fi

echo "up: 完成" >&2
