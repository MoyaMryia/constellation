#!/bin/sh
# 给 770ED 镜像装一套"离线可用"的小型开发工具：
#   tcc   —— Tiny C Compiler（C99，自带链接器，258 KiB，PII 上够快）
#   make  —— GNU make 4.4.1（i486 musl 静态）
#   + musl 头文件与静态库、crt 文件、libgcc.a
#
# 为什么不是 gcc：原生 i486 gcc 要 cc1+gcc+binutils+头文件+libgcc，装完 ~40 MiB，
# 而且在 64 MiB 内存的机器上编稍大的文件就会 OOM。tcc 编 + 链单文件够用，
# 配合 make 也能跑小项目。真需要 gcc 时在宿主侧用 toolchain/musl-i486 交叉编。
#
# 为什么自己编：Alpine x86 归档是 SSE 基线，PII 上会 SIGILL；而且这套东西
# 必须能在没有网络的 770ED 上工作，所以全部静态链接、随镜像分发。
#
# 用法：scripts/build-devtools-770ed.sh [rootfs-dir]
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
SRCROOT=${DEVTOOLS_SRC:-$ROOT/toolchain/src/devtools}
MUSL=$ROOT/toolchain/musl-i486
CC_WRAP=$MUSL/bin/i486-linux-musl-gcc
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
CFLAGS_COMMON="-Os -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector"

TCC_VER=0.9.27
MAKE_VER=4.4.1
BINUTILS_VER=2.42

[ -x "$CC_WRAP" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }
mkdir -p "$SRCROOT"
PATH=$MUSL/bin:$PATH
export PATH

fetch () {
  url=$1; sha=${2:-}
  file=$SRCROOT/${url##*/}
  if [ ! -s "$file" ]; then
    echo "dev: 下载 ${url##*/}" >&2
    curl -fsSL --retry 3 -o "$file.part" "$url" && mv "$file.part" "$file" || return 1
  fi
  if [ -n "$sha" ]; then
    echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1 || {
      echo "dev: 校验失败：${url##*/}（删除缓存后重试）" >&2
      rm -f "$file"; return 1; }
  fi
  echo "$file"
}

# libgcc.a 里的 64 位除法助手（__udivdi3/__udivmoddi4）tcc 需要
LIBGCC=$(find /usr/lib/gcc -path '*32/libgcc.a' 2>/dev/null | head -1)
[ -n "$LIBGCC" ] || { echo "找不到 32 位 libgcc.a" >&2; exit 1; }

# ---- tcc ----
TCC_SHA=de23af78fca90ce32dff2dd45b3432b2334740bb9bb7b05bf60fdbfc396ceb9c
TCC_TAR=$(fetch "https://download.savannah.gnu.org/releases/tinycc/tcc-$TCC_VER.tar.bz2" "$TCC_SHA")
cd "$SRCROOT"
[ -d "tcc-$TCC_VER" ] || tar -xjf "$TCC_TAR"
# tcc 0.9.27 的 TCC_MUSL 分支对 32 位 x86 会落到 "#elif !defined(TCC_ARM_EABI)"
# 那一支，把 ELF 解释器写成 /lib/ld-musl-arm.so.1（明显笔误）。不改的话编出来的
# 程序在目标机上直接 "not found"（内核去找 arm 的 loader）。直接改源最稳。
sed -i 's|"/lib/ld-musl-arm.so.1"|"/lib/ld-musl-i386.so.1"|' "tcc-$TCC_VER/tcc.h"
if [ ! -x "tcc-$TCC_VER/tcc" ]; then
  echo "dev: 编 tcc" >&2
  cd "tcc-$TCC_VER"
  # --cpu=i386 必须显式给：configure 用 `$cc -dumpmachine` 猜，宿主会给出 x86_64
  ./configure --cc=i486-linux-musl-gcc --cpu=i386 --os=Linux --prefix=/usr \
    --config-musl --enable-static \
    --extra-cflags="$CFLAGS_COMMON" --extra-ldflags="-static" >/dev/null
  make -j"$JOBS" >/dev/null
  cd "$SRCROOT"
fi
[ -x "tcc-$TCC_VER/tcc" ] || { echo "tcc 构建失败" >&2; exit 1; }

# ---- GNU make ----
MAKE_SHA=dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3
MAKE_TAR=$(fetch "https://ftp.gnu.org/gnu/make/make-$MAKE_VER.tar.gz" "$MAKE_SHA")
cd "$SRCROOT"
[ -d "make-$MAKE_VER" ] || tar -xzf "$MAKE_TAR"
if [ ! -x "make-$MAKE_VER/make" ]; then
  echo "dev: 编 make" >&2
  cd "make-$MAKE_VER"
  ./configure --host=i486-linux-musl --build=x86_64-linux-gnu \
    CC=i486-linux-musl-gcc CFLAGS="$CFLAGS_COMMON" \
    LDFLAGS="-static" --disable-nls >/dev/null
  make -j"$JOBS" >/dev/null 2>&1 || make >/dev/null
  cd "$SRCROOT"
fi
[ -x "make-$MAKE_VER/make" ] || { echo "make 构建失败" >&2; exit 1; }

# ---- binutils（as / ld / ar / nm / objdump / strip / objcopy / readelf / size）----
BINUTILS_SHA=f6e4d41fd5fc778b06b7891457b3620da5ecea1006c6a4a41ae998109f85a800
BU_TAR=$(fetch "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz" "$BINUTILS_SHA")
cd "$SRCROOT"
[ -d "binutils-$BINUTILS_VER" ] || tar -xJf "$BU_TAR"
# 判断"编好了"要看产物是否干净：只检查文件存在的话，之前编坏的（含 SHA-NI
# 的 xorps/pinsrd）会被当成已完成。
NEED_BU=0
if [ ! -x "binutils-$BINUTILS_VER/binutils/objdump" ]; then
  NEED_BU=1
elif objdump -d "binutils-$BINUTILS_VER/binutils/objdump" 2>/dev/null | grep -q '%xmm'; then
  NEED_BU=1
fi
if [ "$NEED_BU" = 1 ]; then
  echo "dev: 编 binutils" >&2
  cd "binutils-$BINUTILS_VER"
  # 只要三组：as / ld / binutils 工具。关掉 gdb、gold、nls、werror 省时间。
  ./configure --host=i486-linux-musl --target=i486-linux-musl \
    --disable-nls --disable-werror --disable-gdb --disable-gprofng \
    --disable-gold --disable-sim --disable-libdecnumber \
    CC=i486-linux-musl-gcc CFLAGS="$CFLAGS_COMMON -Wno-error" \
    LDFLAGS="-static" >/dev/null
  # 注意：必须在 make 命令行上强制 CFLAGS。只在 configure 里给不够——binutils
  # 的某些子目录（libiberty 等）会用自己的 CFLAGS，结果混进 xorps 这类 SSE
  # 指令（PII 上就是 SIGILL）。踩过一次：readelf/objdump/ld 里各有 132 条。
  BU_CFLAGS="$CFLAGS_COMMON"
  # binutils 2.42 的 libiberty/sha1.c 在 configure 检测到 x86 有 SHA 扩展时，会用
  # __attribute__((target("sse4.1,sha"))) 编出 SHA-NI 版本的 sha1 —— 宿主上是 x86_64
  # gcc，检测必然为真，于是 ld/objdump/readelf 里各混进 132 条 xorps/pinsrd。
  # PII 没有这些指令，一调用就 SIGILL。检测是在宿主上做的，与我们 -mno-sse 无关，
  # 所以必须在 configure 之后把它关掉。
  # 直接在源码层面关掉：改 config.h 不够，make 会重新跑子目录的 configure 把
  # libiberty/config.h 又生成回来（这就是第一次"修好"后又冒出 132 条的原因）。
  sed -i 's|^#ifdef HAVE_X86_SHA1_HW_SUPPORT|#if 0 /* 770ED: PII has no SSE4.1/SHA */|' \
    libiberty/sha1.c
  rm -f libiberty/sha1.o
  make -j"$JOBS" CFLAGS="$BU_CFLAGS" all-gas all-ld all-binutils >/dev/null 2>&1 || \
    make -j"$JOBS" CFLAGS="$BU_CFLAGS" all-gas all-ld all-binutils
  cd "$SRCROOT"
fi

# ---- 安装 ----
echo "dev: 安装到 $DEST" >&2
mkdir -p "$DEST/usr/bin" "$DEST/usr/lib/tcc/include" "$DEST/usr/include"
install -m 0755 "tcc-$TCC_VER/tcc" "$DEST/usr/bin/tcc"
install -m 0755 "make-$MAKE_VER/make" "$DEST/usr/bin/make"

# 路径按 tcc 的两套默认值分开放（tcc.h）：
#   CONFIG_TCC_CRTPREFIX = <sysroot>/usr/lib  → crt1.o/crti.o/crtn.o、-lc 用的 libc.a
#   CONFIG_TCCDIR (=tcc_lib_path) = /usr/lib/tcc → libtcc1.a 与 tcc 自己的头
# 放错地方就报 `tcc: error: file 'crt1.o' not found`（踩过一次）。
install -m 0644 "$MUSL/lib/crt1.o" "$MUSL/lib/crti.o" "$MUSL/lib/crtn.o" "$DEST/usr/lib/" 2>/dev/null || true
install -m 0644 "$MUSL/lib/libc.a" "$DEST/usr/lib/"
install -m 0644 "$LIBGCC" "$DEST/usr/lib/libgcc.a"
install -m 0644 "tcc-$TCC_VER/libtcc1.a" "$DEST/usr/lib/tcc/"
install -m 0644 "tcc-$TCC_VER/libtcc1.a" "$DEST/usr/lib/"
# tcc 自己的头（stdarg.h/stddef.h/stdint.h...）
cp -a "tcc-$TCC_VER/include/." "$DEST/usr/lib/tcc/include/"
# musl 头文件（stdio.h 等，tcc 默认会搜 /usr/include）
cp -a "$MUSL/include/." "$DEST/usr/include/"

# binutils：静态链接的 as/ld 与常用 binutils 工具
# 注意：make 之后的可执行文件在源码树里是 *-new（as-new / ld-new / nm-new…），
# 只有 make install 才会改名。这里直接按 -new 找，省一次 install 到宿主的操作。
for t in as ld ar nm objdump strip objcopy readelf size ranlib; do
  src=
  for cand in "binutils-$BINUTILS_VER/gas/$t-new" "binutils-$BINUTILS_VER/ld/$t-new" \
              "binutils-$BINUTILS_VER/binutils/$t-new" \
              "binutils-$BINUTILS_VER/binutils/$t" "binutils-$BINUTILS_VER/ld/$t" \
              "binutils-$BINUTILS_VER/gas/$t"; do
    [ -x "$cand" ] && { src=$cand; break; }
  done
  [ -n "$src" ] || { echo "dev: 跳过 $t（没编出来）" >&2; continue; }
  install -m 0755 "$src" "$DEST/usr/bin/$t"
done

strip --strip-all "$DEST/usr/bin/tcc" "$DEST/usr/bin/make" 2>/dev/null || true
for t in as ld ar nm objdump strip objcopy readelf size ranlib; do
  [ -f "$DEST/usr/bin/$t" ] && strip --strip-all "$DEST/usr/bin/$t" 2>/dev/null || true
done
echo "dev: 完成  tcc=$(du -h "$DEST/usr/bin/tcc" | cut -f1)  make=$(du -h "$DEST/usr/bin/make" | cut -f1)  binutils=$(du -ch "$DEST/usr/bin/"{as,ld,ar,nm,objdump,strip,objcopy,readelf,size,ranlib} 2>/dev/null | tail -1 | cut -f1)  headers=$(du -sh "$DEST/usr/include" | cut -f1)" >&2
