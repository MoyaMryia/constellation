#!/bin/sh
# 把当前 rootfs 打成一个可放到 U 盘上的更新包（.upd），由目标机上的
# /usr/sbin/osupdate 安装。
#
# 用法：scripts/make-osupdate-770ed.sh [rootfs-dir] [输出文件]
#   → build/constellation-770ed-YYYYmmdd.upd
#
# 包内容（tar.gz）：
#   VERSION   版本行（日期、内核版本、文件数）
#   MANIFEST  "<sha256>  <相对路径>"，osupdate 在动系统之前逐条校验
#   <路径…>   实际文件，目录结构与目标机根目录一致
#
# 不打包的路径：/proc /sys /dev /tmp /var/log /var/run /var/backups /
# /var/lib/constellation /lost+found —— 都是运行期数据。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=$(CDPATH= cd -- "${1:-$ROOT/build/rootfs-770ed}" && pwd)
STAMP=${STAMP:-$(date '+%Y%m%d')}
OUT=${2:-$ROOT/build/constellation-770ed-$STAMP.upd}
KVER=${KVER:-6.6.162}

WORK=$(mktemp -d /tmp/mkupd.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

echo "make-osupdate: 收集文件（$SRC）"
cd "$SRC"
find . -type f \
  -not -path './proc/*' -not -path './sys/*' -not -path './dev/*' \
  -not -path './tmp/*' -not -path './var/log/*' -not -path './var/run/*' \
  -not -path './var/backups/*' -not -path './var/lib/constellation/*' \
  -not -path './lost+found/*' \
  | sed 's|^\./||' | LC_ALL=C sort > "$WORK/list"

n=$(wc -l < "$WORK/list")
echo "make-osupdate: $n 个文件"

# MANIFEST：在源目录里算 sha256，避免先拷贝一遍
: > "$WORK/MANIFEST"
while read -r f; do
  printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f" >> "$WORK/MANIFEST"
done < "$WORK/list"

cat > "$WORK/VERSION" <<EOF
constellation-770ed-$(date '+%Y%m%d-%H%M')
built:    $(date '+%Y-%m-%d %H:%M:%S %z')
kernel:   $KVER
files:    $n
host:     $(uname -sr)
EOF

echo "make-osupdate: 打包 → $OUT"
# tar -C 只能给一次目录：先在 WORK 里铺一份（硬链接，省空间），再整体打包
mkdir -p "$WORK/tree"
while read -r f; do
  mkdir -p "$WORK/tree/$(dirname "$f")"
  ln "$SRC/$f" "$WORK/tree/$f" 2>/dev/null || cp -p "$SRC/$f" "$WORK/tree/$f"
done < "$WORK/list"
cp "$WORK/VERSION" "$WORK/MANIFEST" "$WORK/tree/"
tar -czf "$OUT" -C "$WORK/tree" .
ls -l "$OUT" | awk '{printf "make-osupdate: 完成 %.1f MiB\n", $5/1048576}'
echo "make-osupdate: 拷到 U 盘根目录即可，目标机上跑 osupdate"
