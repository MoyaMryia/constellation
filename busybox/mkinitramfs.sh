#!/bin/sh
# Build the M1 initramfs image from busybox/initramfs/ + the built static BusyBox.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BB_BIN="$ROOT/busybox/src/busybox-1.38.0/busybox"
STAGE="$ROOT/busybox/initramfs/.staging"
OUT="$ROOT/build/initramfs.cpio.gz"

if [ ! -x "$BB_BIN" ]; then
    echo "BusyBox binary not found: $BB_BIN" >&2
    echo "Build it first (see busybox/configs/busybox-1.38.0-M1.config)." >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$ROOT/build"

# /init must be executable and start with #!/bin/sh (CONFIG_BINFMT_SCRIPT=y).
cp "$ROOT/busybox/initramfs/init" "$STAGE/init"
chmod 0755 "$STAGE/init"

cp "$BB_BIN" "$STAGE/bin/busybox"

# Applet symlinks. sh must exist before /init runs (shebang).
ln -sf busybox "$STAGE/bin/sh"
for a in '[' cat echo false halt hostname insmod ls lsmod mknod modprobe mount poweroff printf reboot rmmod sleep sync test true umount uname; do
    ln -sf busybox "$STAGE/bin/$a"
done

( cd "$STAGE" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT" )
echo "initramfs written: $OUT"
ls -l "$OUT"
