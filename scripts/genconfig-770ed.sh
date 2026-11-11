#!/bin/sh
# 由基线 + fragment 重新生成 ThinkPad 770ED 的完整内核配置。
#
# 6.18.44 线：
#   kernel/configs/6.18.44-L4.config        （tinyconfig 加法线基线）
# + kernel/configs/6.18.44-770ed.fragment   （770ED 的硬件增量）
# = kernel/configs/6.18.44-770ed.config     （提交进仓库的完整配置）
#
# 6.6.162 线（770ED 的默认风味）：
#   kernel/configs/6.18.44-770ed.config     （先把它落到 6.6 的 Kconfig 树上：
#                                            make olddefconfig 会丢掉 6.6 没有
#                                            的符号、补出 6.6 新增符号的默认值）
# + kernel/configs/6.6.162-770ed.fragment   （6.6 独有项：16 位 PCMCIA 无线、
#                                            zram 作模块等）
# = kernel/configs/6.6.162-770ed.config
#
# 什么时候需要跑：改了 fragment 之后。平时构建只读完整配置，不再重算，
# 这样"构建结果"与"提交的配置"是同一个东西。
#
# 用法：KVER=6.6.162 scripts/genconfig-770ed.sh   （默认）
#      KVER=6.18.44 scripts/genconfig-770ed.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KVER=${KVER:-6.6.162}
KERNEL_SRC=${KERNEL_SRC:-$ROOT/kernel/src/linux-$KVER}

case "$KVER" in
  6.6.162)
    BOOTSTRAP=$ROOT/kernel/configs/6.18.44-770ed.config
    FRAG=$ROOT/kernel/configs/6.6.162-770ed.fragment
    OUT=$ROOT/kernel/configs/6.6.162-770ed.config ;;
  6.18.44)
    BOOTSTRAP=$ROOT/kernel/configs/6.18.44-L4.config
    FRAG=$ROOT/kernel/configs/6.18.44-770ed.fragment
    OUT=$ROOT/kernel/configs/6.18.44-770ed.config ;;
  *) echo "unsupported KVER: $KVER" >&2; exit 1 ;;
esac

[ -d "$KERNEL_SRC" ] || {
  echo "缺少内核源码树 $KERNEL_SRC；先跑 scripts/build-core-770ed.sh（它会解包）" >&2
  exit 1
}

WORK=$(mktemp -d /tmp/genconfig-770ed.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

cp "$BOOTSTRAP" "$WORK/.config"
cp "$WORK/.config" "$KERNEL_SRC/.config"
make -s -C "$KERNEL_SRC" ARCH=i386 olddefconfig

grep -v '^$' "$FRAG" > "$WORK/fragment"
mkdir -p "$WORK/out"
"$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$WORK/out" \
  "$KERNEL_SRC/.config" "$WORK/fragment" > "$WORK/merge.log" 2>&1 || {
    cat "$WORK/merge.log" >&2; exit 1;
  }
cp "$WORK/out/.config" "$KERNEL_SRC/.config"
make -s -C "$KERNEL_SRC" ARCH=i386 olddefconfig
cp "$KERNEL_SRC/.config" "$OUT"

# fragment 逐项核对。=n 在 .config 里写成 "# CONFIG_X is not set"。
fail=0
while read -r line; do
  case "$line" in \#*|'') continue ;; esac
  sym=${line%%=*}; want=${line#*=}
  if [ "$want" = n ]; then
    grep -qx "# $sym is not set" "$OUT" || { echo "fragment 未生效: $sym 想=n" >&2; fail=1; }
  else
    have=$(awk -v s="$sym" 'index($0, s "=") == 1 { print substr($0, length(s) + 2); f = 1 }
                            END { if (!f) print "MISSING" }' "$OUT")
    if [ "$have" != "$want" ]; then
      echo "fragment 未生效: $sym 想=$want 实=$have" >&2
      fail=1
    fi
  fi
done < "$WORK/fragment"
[ "$fail" = 0 ] || exit 1

echo "写出 $OUT (KVER=$KVER)"
echo "  模块: $(grep -c '=m$' "$OUT") 项"
