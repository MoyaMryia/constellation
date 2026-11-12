#!/bin/sh
# Build the ThinkPad 770ED core: musl i486 toolchain (共享)，BusyBox（全
# applet 集），以及 770ED 风味的 6.18.44 内核 + 模块。
#
# 与 scripts/build-core.sh（i486/Pentium 线）的关系：
#   1) 用户空间基线不变（musl 1.2.5 i486 + BusyBox 1.38.0）。PII 能跑
#      i486 代码，没必要为 770ED 再造一套 i686 用户空间；好处是整个仓库
#      的 rootfs 模板、s6 二进制、apk 都是同一批产物。
#   2) 内核不走 tinyconfig+fragment，而是直接拷 kernel/configs/6.18.44-770ed.config
#      （那份配置就是从 L4 基线 + 6.18.44-770ed.fragment 生成出来的，
#      校验项写在下方的 CRITICAL 清单里）。
#   3) 内核源码树与 i486 线共用 kernel/src/linux-6.18（同版本、同 sha），
#      切换风味只会换 .config，不会重下源码。因此**不要**在本脚本运行时
#      并行跑 scripts/build-core.sh。
#
# 用法：JOBS=16 scripts/build-core-770ed.sh
#      FORCE_TOOLCHAIN=1 scripts/build-core-770ed.sh   # 强制重建 musl
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}
HOSTCC=${HOSTCC:-gcc}
HOSTAR=${HOSTAR:-ar}
HOSTRANLIB=${HOSTRANLIB:-ranlib}
HOSTSTRIP=${HOSTSTRIP:-strip}
MUSL_SRC=$ROOT/toolchain/src/musl-1.2.5
MUSL_PREFIX=$ROOT/toolchain/musl-i486
# 默认 6.6 LTS：唯一同时具备"现代内核 + 完整 16 位 PCMCIA 无线驱动"的
# LTS（6.12 起 orinoco_cs/hostap_cs/atmel_cs/airo_cs 等被上游移除）。
# 需要 6.18 线时：KVER=6.18.44 scripts/build-core-770ed.sh
KVER=${KVER:-6.6.162}
case "$KVER" in
  6.6.162)
    KERNEL_TARBALL=$ROOT/kernel/src/linux-6.6.162.tar.xz
    KERNEL_SHA=4aa89f3652fc131e5d39990f3bcd4b9e131028af3f315dbe83f3a8557dc06f06
    KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.162.tar.xz
    KCONFIG=$ROOT/kernel/configs/6.6.162-770ed.config ;;
  6.18.44)
    KERNEL_TARBALL=$ROOT/kernel/src/linux-6.18.44.tar.xz
    KERNEL_SHA=0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43
    KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.44.tar.xz
    KCONFIG=$ROOT/kernel/configs/6.18.44-770ed.config ;;
  *) echo "unsupported KVER: $KVER" >&2; exit 1 ;;
esac
KERNEL_SRC=$ROOT/kernel/src/linux-$KVER
BUSYBOX_SRC=$ROOT/busybox/src/busybox-1.38.0
HEADERS=$ROOT/build/hdrs-i386
MODROOT=${MODROOT:-$ROOT/build/modroot-770ed}
BB_FRAGMENTS="$ROOT/busybox/configs/busybox-1.38.0-amd64.fragment $ROOT/busybox/configs/busybox-1.38.0-770ed.fragment"

"$ROOT/scripts/fetch-sources.sh"

mkdir -p "$ROOT/build"

# ---------- 1) musl i486 工具链（已存在则复用） ----------
# 工具链失效的两种情形：
#   1) 从来没建过；
#   2) 整个仓库被移动过——musl 的 musl-gcc.specs 与本脚本生成的 gcc 包装器
#      里都是**绝对路径**，路径一改就报
#      "cannot read spec file .../toolchain/musl-i486/lib/musl-gcc.specs"。
stale=0
if [ -f "$MUSL_PREFIX/lib/musl-gcc.specs" ]; then
  grep -q "$MUSL_PREFIX/lib/musl-gcc.specs" "$MUSL_PREFIX/lib/musl-gcc.specs" || stale=1
  [ -f "$MUSL_PREFIX/bin/i486-linux-musl-gcc" ] || stale=1
else
  stale=1
fi

if [ "${FORCE_TOOLCHAIN:-0}" = 1 ] || [ "$stale" = 1 ]; then
  echo "toolchain: (re)building musl i486"
  rm -rf "$MUSL_SRC" "$MUSL_PREFIX"
  tar -C "$ROOT/toolchain/src" -xf "$ROOT/toolchain/src/musl-1.2.5.tar.gz"
  ( cd "$MUSL_SRC" && \
    CC="$HOSTCC" AR="$HOSTAR" RANLIB="$HOSTRANLIB" \
    CFLAGS="-m32 -march=i486 -Os -pipe -fomit-frame-pointer" \
    ./configure --target=i486-linux-musl --prefix="$MUSL_PREFIX" --enable-shared )
  make -C "$MUSL_SRC" -j"$JOBS"
  make -C "$MUSL_SRC" install

  # musl-gcc 在 x86_64 宿主上必须显式选 32 位链接仿真。
  awk '
    /^\*link:$/ { in_link=1; print; next }
    in_link && NF { print $0 " %{m32:-m elf_i386} %{Wl,*}"; in_link=0; next }
    { print }
  ' "$MUSL_PREFIX/lib/musl-gcc.specs" > "$MUSL_PREFIX/lib/musl-gcc.specs.tmp"
  mv "$MUSL_PREFIX/lib/musl-gcc.specs.tmp" "$MUSL_PREFIX/lib/musl-gcc.specs"

  cat > "$MUSL_PREFIX/bin/i486-linux-musl-gcc" <<EOF
#!/bin/sh
exec "$HOSTCC" -m32 -march=i486 -specs="$MUSL_PREFIX/lib/musl-gcc.specs" "\$@"
EOF
  for tool in ar ranlib strip; do
    case "$tool" in
      ar) host_tool=$HOSTAR ;;
      ranlib) host_tool=$HOSTRANLIB ;;
      strip) host_tool=$HOSTSTRIP ;;
    esac
    cat > "$MUSL_PREFIX/bin/i486-linux-musl-$tool" <<EOF
#!/bin/sh
exec "$host_tool" "\$@"
EOF
  done
  chmod 0755 "$MUSL_PREFIX/bin/i486-linux-musl-"*
fi
CC_WRAP=$MUSL_PREFIX/bin/i486-linux-musl-gcc

# ---------- 2) 内核源码与 uapi 头 ----------
if [ -f "$KERNEL_TARBALL" ] && ! echo "$KERNEL_SHA  $KERNEL_TARBALL" | sha256sum -c - >/dev/null 2>&1; then
  echo "内核源码包校验失败，删除后重下：$KERNEL_TARBALL" >&2
  rm -f "$KERNEL_TARBALL"
fi
if [ ! -f "$KERNEL_TARBALL" ]; then
  tmp=$KERNEL_TARBALL.tmp.$$
  curl --fail --location --proto '=https' --silent --show-error -o "$tmp" "$KERNEL_URL"
  echo "$KERNEL_SHA  $tmp" | sha256sum -c -
  mv "$tmp" "$KERNEL_TARBALL"
fi
if [ ! -d "$KERNEL_SRC" ]; then
  tar -C "$ROOT/kernel/src" -xf "$KERNEL_TARBALL"
fi
if [ ! -f "$HEADERS/linux/version.h" ]; then
  rm -rf "$HEADERS"
  make -s -C "$KERNEL_SRC" ARCH=i386 HOSTCC="$HOSTCC" \
    INSTALL_HDR_PATH="$HEADERS" headers_install
fi

# ---------- 3) BusyBox（M1 → amd64 applet 集 → 770ED 追加 applet） ----------
if [ ! -d "$BUSYBOX_SRC" ]; then
  tar -C "$ROOT/busybox/src" -xf "$ROOT/busybox/src/busybox-1.38.0.tar.bz2"
fi
cp "$ROOT/busybox/configs/busybox-1.38.0-M1.config" "$BUSYBOX_SRC/.config"
# 同一符号出现两次时 Kconfig 取先出现的那条，故先删后追加。
for frag in $BB_FRAGMENTS; do
  for s in $(grep -E '^CONFIG_' "$frag" | cut -d= -f1); do
    sed -i "/^$s=/d; /^# $s is not set\$/d" "$BUSYBOX_SRC/.config"
  done
  grep -E '^CONFIG_' "$frag" >> "$BUSYBOX_SRC/.config"
done
yes "" | make -s -C "$BUSYBOX_SRC" HOSTCC="$HOSTCC" oldconfig >/dev/null
make -s -C "$BUSYBOX_SRC" -j"$JOBS" HOSTCC="$HOSTCC" CC="$CC_WRAP"
"$MUSL_PREFIX/bin/i486-linux-musl-strip" "$BUSYBOX_SRC/busybox"
cp "$BUSYBOX_SRC/.config" "$ROOT/busybox/configs/busybox-1.38.0-770ed.config"

# ---------- 3b) mixer（OSS 混音器客户端，静态） ----------
"$CC_WRAP" -I "$HEADERS" -Os -static -o "$ROOT/build/mixer" "$ROOT/tools/mixer.c"
"$MUSL_PREFIX/bin/i486-linux-musl-strip" "$ROOT/build/mixer"

# ---------- 4) 内核（770ED 配置） ----------
cp "$KCONFIG" "$KERNEL_SRC/.config"
make -s -C "$KERNEL_SRC" ARCH=i386 HOSTCC="$HOSTCC" CC="$HOSTCC" olddefconfig

# 关键项核对。这份配置是"加法"得来的，最怕的是某项被 Kconfig 静默丢掉
# （真实踩过：CONFIG_PCCARD 没开时，所有 PCMCIA 卡驱动被压成 m 甚至消失）。
CRITICAL="
CONFIG_MPENTIUMII
CONFIG_APM
CONFIG_PNPBIOS
CONFIG_ISAPNP
CONFIG_ATA_PIIX
CONFIG_BLK_DEV_SD
CONFIG_EXT4_FS
CONFIG_VFAT_FS
CONFIG_PCCARD
CONFIG_PCMCIA
CONFIG_YENTA
CONFIG_PCMCIA_PCNET
CONFIG_PATA_PCMCIA
CONFIG_USB_UHCI_HCD
CONFIG_UEVENT_HELPER
CONFIG_FRAMEBUFFER_CONSOLE
"
fail=0
for sym in $CRITICAL; do
  grep -qE "^$sym=[ym]" "$KERNEL_SRC/.config" || { echo "critical 未生效: $sym" >&2; fail=1; }
done
# 模块类（=m）单独核对：这些是 770ED 的"外接设备"主力。
for sym in CONFIG_FB_TRIDENT CONFIG_SND_CS4236 CONFIG_MWAVE \
           CONFIG_PCMCIA_PCNET CONFIG_PATA_PCMCIA CONFIG_CFG80211 CONFIG_ATH5K; do
  grep -qE "^$sym=m" "$KERNEL_SRC/.config" || { echo "module 未生效: $sym" >&2; fail=1; }
done
[ "$fail" = 0 ] || exit 1

make -s -C "$KERNEL_SRC" -j"$JOBS" ARCH=i386 HOSTCC="$HOSTCC" CC="$HOSTCC" bzImage modules
rm -rf "$MODROOT"
make -s -C "$KERNEL_SRC" ARCH=i386 INSTALL_MOD_PATH="$MODROOT" modules_install
# build/source 是宿主的绝对路径软链，装进镜像毫无意义且会让 depmod 报警。
for d in "$MODROOT"/lib/modules/*/; do
  rm -f "$d/build" "$d/source"
done

echo "core (770ED) build complete"
echo "  kernel : $(stat -c%s "$KERNEL_SRC/arch/x86/boot/bzImage") 字节"
echo "  busybox: $(stat -c%s "$BUSYBOX_SRC/busybox") 字节"
echo "  modules: $(find "$MODROOT" -name '*.ko' | wc -l) 个 -> $MODROOT"
echo "  kernel : $KVER ($KCONFIG)"
