#!/bin/sh
# Build the i486 musl toolchain wrapper, BusyBox, and the L4 kernel.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}
HOSTCC=${HOSTCC:-gcc}
HOSTAR=${HOSTAR:-ar}
HOSTRANLIB=${HOSTRANLIB:-ranlib}
HOSTSTRIP=${HOSTSTRIP:-strip}
MUSL_SRC=$ROOT/toolchain/src/musl-1.2.5
MUSL_PREFIX=$ROOT/toolchain/musl-i486
KERNEL_SRC=$ROOT/kernel/src/linux-6.18
BUSYBOX_SRC=$ROOT/busybox/src/busybox-1.38.0
HEADERS=$ROOT/build/hdrs-i386
KERNEL_FLAVOR=${KERNEL_FLAVOR:-pentium}

"$ROOT/scripts/fetch-sources.sh"

rm -rf "$MUSL_SRC" "$MUSL_PREFIX" "$KERNEL_SRC" "$BUSYBOX_SRC" "$HEADERS"
mkdir -p "$ROOT/toolchain/src" "$ROOT/kernel/src" "$ROOT/busybox/src" "$ROOT/build"
tar -C "$ROOT/toolchain/src" -xf "$ROOT/toolchain/src/musl-1.2.5.tar.gz"
tar -C "$ROOT/kernel/src" -xf "$ROOT/kernel/src/linux-6.18.44.tar.xz"
tar -C "$ROOT/busybox/src" -xf "$ROOT/busybox/src/busybox-1.38.0.tar.bz2"
mv "$ROOT/kernel/src/linux-6.18.44" "$KERNEL_SRC"

make -C "$KERNEL_SRC" ARCH=i386 HOSTCC="$HOSTCC" INSTALL_HDR_PATH="$HEADERS" headers_install

( cd "$MUSL_SRC" && \
  CC="$HOSTCC" AR="$HOSTAR" RANLIB="$HOSTRANLIB" \
  CFLAGS="-m32 -march=i486 -Os -pipe -fomit-frame-pointer" \
  ./configure --target=i486-linux-musl --prefix="$MUSL_PREFIX" --disable-shared )
make -C "$MUSL_SRC" -j"$JOBS"
make -C "$MUSL_SRC" install

# musl-gcc must select the 32-bit linker emulation when hosted by x86_64 GCC.
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

cp "$ROOT/busybox/configs/busybox-1.38.0-M1.config" "$BUSYBOX_SRC/.config"
make -s -C "$BUSYBOX_SRC" HOSTCC="$HOSTCC" \
  CC="$MUSL_PREFIX/bin/i486-linux-musl-gcc" silentoldconfig
make -C "$BUSYBOX_SRC" -j"$JOBS" HOSTCC="$HOSTCC" \
  CC="$MUSL_PREFIX/bin/i486-linux-musl-gcc"
"$MUSL_PREFIX/bin/i486-linux-musl-strip" "$BUSYBOX_SRC/busybox"

cp "$ROOT/kernel/configs/6.18.44-L4.config" "$KERNEL_SRC/.config"
case "$KERNEL_FLAVOR" in
  pentium) ;;
  legacy486)
    "$KERNEL_SRC/scripts/config" --file "$KERNEL_SRC/.config" \
      --enable M486 --disable M586TSC --enable MATH_EMULATION
    ;;
  *) echo "unknown KERNEL_FLAVOR: $KERNEL_FLAVOR" >&2; exit 1 ;;
esac
make -C "$KERNEL_SRC" ARCH=i386 HOSTCC="$HOSTCC" CC="$HOSTCC" olddefconfig
make -C "$KERNEL_SRC" -j"$JOBS" ARCH=i386 HOSTCC="$HOSTCC" CC="$HOSTCC" bzImage modules
rm -rf "$ROOT/build/modroot"
make -C "$KERNEL_SRC" ARCH=i386 INSTALL_MOD_PATH="$ROOT/build/modroot" modules_install
rm -f "$ROOT/build/modroot/lib/modules/6.18.44/build" \
  "$ROOT/build/modroot/lib/modules/6.18.44/source"

"$ROOT/busybox/mkinitramfs.sh"
echo "core build complete"
