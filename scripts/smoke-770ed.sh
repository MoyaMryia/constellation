#!/bin/sh
# 770ED 镜像冒烟验收：真实引导链（BIOS → MBR/GRUB2 → bzImage → ext4 →
# s6-svscan → getty），登录后跑一组检查并把串口全文打出来。
#
# QEMU 没有 440BX/TI1250/Cyber9397DVD/CS4237B 的精确模型，因此这里验的是
# "引导链、用户空间、模块装载路径、USB/网卡热插拔"；显卡/声卡/CardBus 的
# 真机证据要靠目标机上的 hwcheck（见 docs/thinkpad-770ed.md §7.2）。
#
# 用法：
#   SMOKE_PASSWORD=770edtest scripts/smoke-770ed.sh
#   MEM=32 SMOKE_PASSWORD=… scripts/smoke-770ed.sh     # 改内存档位
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${IMAGE:-$ROOT/build/constellation-770ed.img}
MEM=${MEM:-64}
PASSWORD=${SMOKE_PASSWORD:-}
SOCK=${SOCK:-/tmp/constellation-770ed-smoke.sock}
LOG=${LOG:-/tmp/constellation-770ed-smoke.log}

[ -f "$IMAGE" ] || { echo "缺少镜像：$IMAGE（先跑 scripts/mkimage-770ed.sh）" >&2; exit 1; }
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "缺少 qemu-system-i386" >&2; exit 1; }

CHECKS='uname -a; echo ===MEM; head -n 3 /proc/meminfo; echo ===FB; cat /proc/fb 2>/dev/null; echo ===PCM; ls /sys/class/pcmcia_socket 2>/dev/null; echo ===USB; lsusb; echo ===NET; ip addr | grep -E "inet |eth"; echo ===SWAP; cat /proc/swaps; echo ===MODS; lsmod | wc -l; echo ===MIXER; mixer; echo ===DONE'

rm -f "$SOCK" "$LOG"
qemu-system-i386 -M pc -cpu pentium2 -m "$MEM" \
  -drive file="$IMAGE",format=raw,if=ide -boot c \
  -usb -device usb-kbd -device e1000 \
  -display none -monitor none \
  -serial "unix:$SOCK,server=on,wait=off" > /tmp/constellation-770ed-qemu.out 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "QEMU 没起来，见 /tmp/constellation-770ed-qemu.out" >&2; exit 1; }

if [ -n "$PASSWORD" ]; then
  python3 "$ROOT/scripts/qemu-serial.py" "$SOCK" --wait 40 \
    --send root --send "$PASSWORD" --send "$CHECKS" --tail 20 > "$LOG" 2>&1 || true
else
  python3 "$ROOT/scripts/qemu-serial.py" "$SOCK" --wait 45 --tail 1 > "$LOG" 2>&1 || true
fi

echo "== 串口全文：$LOG"
if grep -q 'login:' "$LOG"; then
  echo "PASS  到达 login 提示符（-m $MEM）"
else
  echo "FAIL  没有 login 提示符（-m $MEM）：内存不够或引导链断了"
  exit 1
fi
if [ -n "$PASSWORD" ]; then
  grep -q '===DONE' "$LOG" && echo "PASS  登录并跑完检查脚本" \
    || { echo "FAIL  登录/检查未完成（密码错？）"; exit 1; }
  grep -q 'zram0' "$LOG" && echo "PASS  zram swap 启用" || echo "WARN  zram 未启用"
  grep -qE 'inet 10\.|inet 192\.168\.|inet 172\.' "$LOG" \
    && echo "PASS  网卡驱动加载并取到地址" || echo "WARN  没有网卡地址"
fi
