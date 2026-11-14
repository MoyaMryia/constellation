#!/bin/sh
# Build the x86_64 (ThinkPad X61) core: musl toolchain, kernel headers,
# BusyBox, and the kernel image.
#
# 与 scripts/build-core.sh（i486）的关系：同构，差异集中在
#   1) 目标三元组 x86_64-linux-musl，且**不需要 -m32**（宿主即 x86_64，
#      连交叉都不算，只是用 musl 的 specs 换掉 glibc）；
#   2) 内核配置从 tinyconfig + kernel/configs/6.18.44-x61-amd64.fragment
#      生成（而非直接拷一份 L4 .config），因为 x86_64 与 i386 的 Kconfig
#      树不同，逐项意图要重新表达；
#   3) 源码树解到 build/amd64/ 下，避免污染 i486 线正在用的
#      kernel/src/linux-6.18（O= 分离构建会因该树不干净而被拒绝）。
#
# 用法：JOBS=16 scripts/build-core-amd64.sh
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}
HOSTCC=${HOSTCC:-gcc}
BUILD=$ROOT/build/amd64
MUSL_SRC=$ROOT/toolchain/src/musl-1.2.5
MUSL_PREFIX=$ROOT/toolchain/musl-amd64
KERNEL_TARBALL=$ROOT/kernel/src/linux-6.18.44.tar.xz
KERNEL_SRC=$BUILD/linux-6.18.44
HEADERS=$ROOT/build/hdrs-amd64
FRAGMENT=$ROOT/kernel/configs/6.18.44-x61-amd64.fragment
BUSYBOX_SRC=$ROOT/busybox/src/busybox-1.38.0
BUSYBOX_FRAGMENT=$ROOT/busybox/configs/busybox-1.38.0-amd64.fragment

"$ROOT/scripts/fetch-sources.sh"

mkdir -p "$BUILD" "$MUSL_PREFIX"

# ---------- 1) musl x86_64（宿主 gcc + musl specs，静态） ----------
# 关键：AR/RANLIB 必须显式传给 configure。musl 的 Makefile 默认按
# --target 推导 x86_64-linux-musl-ar，宿主没有该名字的工具会直接失败。
rm -rf "$MUSL_SRC"
tar -C "$ROOT/toolchain/src" -xf "$ROOT/toolchain/src/musl-1.2.5.tar.gz"
( cd "$MUSL_SRC" && \
  CC="$HOSTCC" AR=ar RANLIB=ranlib STRIP=strip CFLAGS="-O2 -pipe" \
  ./configure --target=x86_64-linux-musl --prefix="$MUSL_PREFIX" --disable-shared )
make -s -C "$MUSL_SRC" -j"$JOBS"
make -s -C "$MUSL_SRC" install

# 命名空间包装器，与 i486 工具链命名保持一致
cat > "$MUSL_PREFIX/bin/x86_64-linux-musl-gcc" <<EOF
#!/bin/sh
exec "$MUSL_PREFIX/bin/musl-gcc" "\$@"
EOF
for t in ar ranlib strip; do
  cat > "$MUSL_PREFIX/bin/x86_64-linux-musl-$t" <<EOF
#!/bin/sh
exec $t "\$@"
EOF
done
chmod 0755 "$MUSL_PREFIX/bin/x86_64-linux-musl-"*
CC_WRAP=$MUSL_PREFIX/bin/x86_64-linux-musl-gcc

# ---------- 2) 内核：解到干净树，tinyconfig + fragment ----------
rm -rf "$KERNEL_SRC"
tar -C "$BUILD" -xf "$KERNEL_TARBALL"
rm -rf "$HEADERS"
make -s -C "$KERNEL_SRC" ARCH=x86_64 INSTALL_HDR_PATH="$HEADERS" headers_install

make -s -C "$KERNEL_SRC" ARCH=x86_64 tinyconfig
# merge_config.sh 把结果写到**当前目录**的 .config，必须在内核树里执行，
# 否则内核的 .config 仍是 tinyconfig（症状：fragment 全部"未生效"）。
( cd "$KERNEL_SRC" && ./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT" >/dev/null 2>&1 )
make -s -C "$KERNEL_SRC" ARCH=x86_64 olddefconfig

# fragment 逐项核对：任何一项没生效都视为构建失败（这些项都是必需品，
# 静默失败会导致"能编过但起不来"，例如 NETDEVICES 缺失时 E1000E 不可见）
fail=0
while read -r line; do
  case "$line" in \#*|'') continue;; esac
  o=${line%%=*}; w=${line#*=}
  if [ "$w" = y ]; then
    grep -qE "^$o=y" "$KERNEL_SRC/.config" || { echo "fragment 未生效: $o" >&2; fail=1; }
  else
    grep -qE "^$o=y|^$o=m" "$KERNEL_SRC/.config" && { echo "fragment 未关闭: $o" >&2; fail=1; }
  fi
done < "$FRAGMENT"
[ "$fail" = 0 ] || exit 1

cp "$KERNEL_SRC/.config" "$ROOT/kernel/configs/6.18.44-L4-amd64.config"
make -s -C "$KERNEL_SRC" ARCH=x86_64 -j"$JOBS" bzImage
cp "$KERNEL_SRC/arch/x86/boot/bzImage" "$BUILD/bzImage"

# ---------- 3) BusyBox ----------
# 配置合并：先把 fragment 涉及的既有条目从基线 config 里删掉再追加，
# 否则同一符号出现两次，Kconfig 会取先出现的那条并报
# "trying to reassign symbol"（症状：新增 applet 全部被丢弃）。
cp "$ROOT/busybox/configs/busybox-1.38.0-M1.config" "$BUSYBOX_SRC/.config"
for s in $(grep -E '^CONFIG_' "$BUSYBOX_FRAGMENT" | cut -d= -f1); do
  sed -i "/^$s=/d; /^# $s is not set\$/d" "$BUSYBOX_SRC/.config"
done
grep -E '^CONFIG_' "$BUSYBOX_FRAGMENT" >> "$BUSYBOX_SRC/.config"
yes "" | make -s -C "$BUSYBOX_SRC" HOSTCC="$HOSTCC" oldconfig >/dev/null
make -s -C "$BUSYBOX_SRC" -j"$JOBS" HOSTCC="$HOSTCC" CC="$CC_WRAP"
"$MUSL_PREFIX/bin/x86_64-linux-musl-strip" "$BUSYBOX_SRC/busybox"
cp "$BUSYBOX_SRC/.config" "$ROOT/busybox/configs/busybox-1.38.0-amd64.config"

echo "core (x86_64) build complete"
echo "  kernel : $(stat -c%s "$BUILD/bzImage") 字节 -> $BUILD/bzImage"
echo "  busybox: $(stat -c%s "$BUSYBOX_SRC/busybox") 字节"
echo "  headers: $HEADERS"
