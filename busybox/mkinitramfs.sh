#!/bin/sh
# Build the M1 initramfs image from busybox/initramfs/ + the built static BusyBox.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BB_BIN="$ROOT/busybox/src/busybox-1.38.0/busybox"
STAGE="$ROOT/busybox/initramfs/.staging"
OUT="$ROOT/build/initramfs.cpio.gz"
TMP_CPIO="$ROOT/build/initramfs.cpio.tmp.$$"
TMP_OUT="$OUT.tmp.$$"
LIST="$ROOT/build/initramfs.list.tmp.$$"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

cleanup () {
    rm -f "$TMP_CPIO" "$TMP_OUT" "$LIST"
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$BB_BIN" ]; then
    echo "BusyBox binary not found: $BB_BIN" >&2
    echo "Build it first (see busybox/configs/busybox-1.38.0-M1.config)." >&2
    exit 1
fi

for command in cpio file find grep gzip mv sort touch; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Required build tool not found: $command" >&2
        exit 1
    }
done

file "$BB_BIN" | grep -q 'ELF 32-bit.*statically linked' || {
    echo "BusyBox must be a static 32-bit ELF: $BB_BIN" >&2
    exit 1
}

rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$ROOT/build"

# /init must be executable and start with #!/bin/sh (CONFIG_BINFMT_SCRIPT=y).
cp "$ROOT/busybox/initramfs/init" "$STAGE/init"
chmod 0755 "$STAGE/init"

cp "$BB_BIN" "$STAGE/bin/busybox"

# Applet symlinks. sh must exist before /init runs (shebang).
ln -sf busybox "$STAGE/bin/sh"
for a in '[' cat echo false free getty halt hostname init insmod login ls lsmod mknod mkswap modprobe mount poweroff printf reboot rmmod sleep swapoff swapon sync test true umount uname; do
    ln -sf busybox "$STAGE/bin/$a"
done

find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
( cd "$STAGE" && LC_ALL=C find . -print > "$LIST" )
LC_ALL=C sort -o "$LIST" "$LIST"
( cd "$STAGE" && cpio --reproducible --owner=0:0 -o -H newc < "$LIST" > "$TMP_CPIO" )
gzip -9 -n -c "$TMP_CPIO" > "$TMP_OUT"
mv "$TMP_OUT" "$OUT"
echo "initramfs written: $OUT"
ls -l "$OUT"
