#!/bin/sh
# 目标机上的文本必须是纯 ASCII。
#
# 770ED 的控制台是 VGA 文本（8x16 ASCII 字体），JWM 菜单用西文字体，Xorg fbdev
# 也没有 CJK 字体——任何中文都会变成方块/乱码。所以 rootfs-770ed/ 里的模板文件
# （会原样进镜像）一律只允许 ASCII；中文只允许留在仓库侧的 scripts/、docs/ 里。
#
# 用法：scripts/check-ascii-770ed.sh [dir]
# 退出码：0 干净；1 有非 ASCII
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIR=$(CDPATH= cd -- "${1:-$ROOT/rootfs-770ed}" && pwd)

bad=0
for f in $(find "$DIR" -type f); do
  case $f in
    *.fw|*.bin|*.so|*.so.*|*.ko|*.db|*.p7s|*.png|*.jpg|*.gif|*.gz|*.xz|*.bz2|*.zst|\
    *.ttf|*.otf|*.pcf|*.pcf.gz|*.pyc|*.a|*.o|*.bmp|*.ico|*.wav|*.mp3|*.dat|*.ucode)
      continue ;;
  esac
  if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f" 2>/dev/null; then
    rel=${f#"$DIR"/}
    echo "非 ASCII: $rel" >&2
    LC_ALL=C grep -nP '[^\x00-\x7F]' "$f" 2>/dev/null | head -3 | sed 's/^/    /' >&2
    bad=$((bad + 1))
  fi
done

if [ "$bad" -gt 0 ]; then
  echo "check-ascii: $bad 个文件含非 ASCII（目标机没有 CJK 字体，会显示成乱码）" >&2
  exit 1
fi
echo "check-ascii: 干净（$DIR 下目标机文本全为 ASCII）"
