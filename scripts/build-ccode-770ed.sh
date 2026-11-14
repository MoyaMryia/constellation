#!/bin/sh
# 把 ~/Projects/agents/ccode（纯 C 的 AI 编码助手）交叉编译成 770ED 能跑的
# ccode-cli（i486 / musl / 静态 / 零 SSE），并装进镜像。
#
# 用法：scripts/build-ccode-770ed.sh [--install]
#   CCODE_SRC  ccode 源码目录（默认 ~/Projects/agents/ccode/ccode）
#   --install  编译完直接装进 build/rootfs-770ed/usr/bin/ccode-cli
#
# 两个必须的开关（否则编出来是 x86-64，或者链不上 32 位 libc）：
#   HOST_MACH=i486-linux-musl
#       ccode 的 Makefile 用 `$(CC) -dumpmachine` 认平台，而我们的 musl 包装器
#       会报宿主三元组（x86_64-linux-gnu），于是它给链接行塞 -m64/-march=x86-64，
#       结果 -m32 -m64 打架。命令行覆盖 HOST_MACH 即可。
#   CFLAGS/LDFLAGS 里带 -m32
#       musl 的 specs 只在 -m32 时才注入 `-m elf_i386`；不带的话用宿主 ld 就会报
#       `skipping incompatible .../musl-i486/lib/libc.a`。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${CCODE_SRC:-$HOME/Projects/agents/ccode/ccode}
WORK=${CCODE_BUILD:-$ROOT/build/ccode-770ed}
DEST=$ROOT/build/rootfs-770ed
MUSL=$ROOT/toolchain/musl-i486
CC=$MUSL/bin/i486-linux-musl-gcc
CF="-Os -std=c99 -m32 -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector -Wall -Wextra"
LF="-static -m32"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

[ -d "$SRC/src" ] || { echo "找不到 ccode 源码：$SRC" >&2; exit 1; }
[ -x "$CC" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }

mkdir -p "$WORK"
# 只拷构建需要的东西（源码树里有 2 GB 的 iso/img，别整棵搬）
for d in Makefile src vendor tests; do
  [ -e "$SRC/$d" ] || continue
  cp -a "$SRC/$d" "$WORK/" 2>/dev/null || true
done

cd "$WORK"
echo "ccode: 编译 ccode-cli（i486/musl/静态）"
rm -rf .build
PATH=$MUSL/bin:$PATH make CC=i486-linux-musl-gcc HOST_MACH=i486-linux-musl \
  CFLAGS="$CF" LDFLAGS="$LF" ccode-cli > "$WORK/build.log" 2>&1 || {
    echo "ccode: 编译失败，日志 $WORK/build.log" >&2; tail -5 "$WORK/build.log" >&2; exit 1; }

file ccode-cli | grep -q "ELF 32-bit" || { echo "ccode: 产物不是 32 位" >&2; exit 1; }
n=$(objdump -d ccode-cli | grep -c '%xmm' || true)
echo "ccode: 产物 $(stat -c%s ccode-cli) 字节，xmm 指令 $n 条"
[ "$n" = 0 ] || { echo "ccode: 含 SSE 指令，PII 上会 SIGILL" >&2; exit 1; }

if [ "$INSTALL" = 1 ]; then
  install -m 0755 ccode-cli "$DEST/usr/bin/ccode-cli"
  echo "ccode: 已装到 $DEST/usr/bin/ccode-cli"
else
  echo "ccode: 产物在 $WORK/ccode-cli（要装进镜像加 --install）"
fi
